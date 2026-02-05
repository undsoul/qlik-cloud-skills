#!/bin/bash
# Qlik Health Check - Cloud & On-Premise
# Test connectivity and authentication
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)
#             Optional: QLIK_VIRTUAL_PROXY

set -euo pipefail

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ===== PLATFORM DETECTION =====

detect_platform() {
  if [[ -n "${QLIK_SERVER:-}" ]]; then
    echo "onprem"
  elif [[ -n "${QLIK_TENANT:-}" ]]; then
    echo "cloud"
  else
    echo "unknown"
  fi
}

PLATFORM=$(detect_platform)

# ===== VALIDATION =====

if [[ "$PLATFORM" == "unknown" ]]; then
  echo "{\"success\":false,\"error\":\"Configuration required: QLIK_TENANT + QLIK_API_KEY (cloud) or QLIK_SERVER + auth (on-prem)\",\"timestamp\":\"$TIMESTAMP\"}"
  exit 1
fi

# ===== BUILD BASE URL =====

if [[ "$PLATFORM" == "cloud" ]]; then
  if [[ -z "${QLIK_API_KEY:-}" ]]; then
    echo "{\"success\":false,\"error\":\"QLIK_API_KEY required for Qlik Cloud\",\"timestamp\":\"$TIMESTAMP\"}"
    exit 1
  fi
  TENANT="${QLIK_TENANT%/}"
  [[ "$TENANT" != http* ]] && TENANT="https://$TENANT"
  BASE_URL="$TENANT"
else
  SERVER="${QLIK_SERVER%/}"
  [[ "$SERVER" != http* ]] && SERVER="https://$SERVER"
  if [[ -n "${QLIK_VIRTUAL_PROXY:-}" ]]; then
    SERVER="$SERVER/${QLIK_VIRTUAL_PROXY}"
  fi
  BASE_URL="$SERVER"
fi

# ===== CLOUD HEALTH CHECK =====

cloud_health() {
  # Check /users/me endpoint
  local response=$(curl -sL -w "\n%{http_code}" \
    -H "Authorization: Bearer ${QLIK_API_KEY}" \
    -H "Content-Type: application/json" \
    "${BASE_URL}/api/v1/users/me" 2>/dev/null || echo -e "\n000")
  
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  echo "$body" | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'
status_code = int('$status')
base_url = '$BASE_URL'

try:
    if status_code == 0:
        print(json.dumps({
            'success': False,
            'platform': 'cloud',
            'error': 'Connection failed - check QLIK_TENANT',
            'baseUrl': base_url,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    if status_code == 401:
        print(json.dumps({
            'success': False,
            'platform': 'cloud',
            'error': 'Authentication failed - check QLIK_API_KEY',
            'httpStatus': status_code,
            'baseUrl': base_url,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    if status_code >= 400:
        print(json.dumps({
            'success': False,
            'platform': 'cloud',
            'error': f'HTTP error {status_code}',
            'httpStatus': status_code,
            'baseUrl': base_url,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    data = json.load(sys.stdin)
    
    print(json.dumps({
        'success': True,
        'platform': 'cloud',
        'message': 'Connected to Qlik Cloud',
        'tenant': base_url,
        'user': {
            'id': data.get('id'),
            'name': data.get('name'),
            'email': data.get('email'),
            'tenantId': data.get('tenantId')
        },
        'timestamp': timestamp
    }, indent=2))
    
except json.JSONDecodeError:
    print(json.dumps({
        'success': False,
        'platform': 'cloud',
        'error': 'Invalid response from server',
        'httpStatus': status_code,
        'baseUrl': base_url,
        'timestamp': timestamp
    }, indent=2))
    sys.exit(1)
except Exception as e:
    print(json.dumps({
        'success': False,
        'platform': 'cloud',
        'error': str(e),
        'timestamp': timestamp
    }, indent=2))
    sys.exit(1)
"
}

# ===== ON-PREM HEALTH CHECK =====

onprem_health() {
  local xrfkey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  local url="${BASE_URL}/qrs/about?xrfkey=${xrfkey}"
  
  # Build curl command
  local curl_cmd="curl -sL -w '\n%{http_code}'"
  
  # Certificate auth
  if [[ -n "${QLIK_CERT:-}" ]] && [[ -n "${QLIK_KEY:-}" ]]; then
    curl_cmd="$curl_cmd --cert \"${QLIK_CERT}\" --key \"${QLIK_KEY}\" --insecure"
  fi
  
  # Header auth
  if [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && [[ -n "${QLIK_USER_ID:-}" ]]; then
    curl_cmd="$curl_cmd -H \"X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}\""
  fi
  
  # XRF key header
  curl_cmd="$curl_cmd -H \"X-Qlik-Xrfkey: ${xrfkey}\""
  curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
  curl_cmd="$curl_cmd \"$url\""
  
  local response=$(eval $curl_cmd 2>/dev/null || echo -e "\n000")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  echo "$body" | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'
status_code = int('$status')
base_url = '$BASE_URL'

try:
    if status_code == 0:
        print(json.dumps({
            'success': False,
            'platform': 'onprem',
            'error': 'Connection failed - check QLIK_SERVER and network',
            'baseUrl': base_url,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    if status_code == 401 or status_code == 403:
        print(json.dumps({
            'success': False,
            'platform': 'onprem',
            'error': 'Authentication failed - check certificates or header auth',
            'httpStatus': status_code,
            'baseUrl': base_url,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    if status_code >= 400:
        print(json.dumps({
            'success': False,
            'platform': 'onprem',
            'error': f'HTTP error {status_code}',
            'httpStatus': status_code,
            'baseUrl': base_url,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    data = json.load(sys.stdin)
    
    print(json.dumps({
        'success': True,
        'platform': 'onprem',
        'message': 'Connected to Qlik Sense Enterprise',
        'server': base_url,
        'serverInfo': {
            'buildVersion': data.get('buildVersion'),
            'buildDate': data.get('buildDate'),
            'databaseProvider': data.get('databaseProvider'),
            'nodeType': data.get('nodeType'),
            'schemaPath': data.get('schemaPath')
        },
        'timestamp': timestamp
    }, indent=2))
    
except json.JSONDecodeError:
    # QRS API might return empty for /about on some versions
    if status_code == 200:
        print(json.dumps({
            'success': True,
            'platform': 'onprem',
            'message': 'Connected to Qlik Sense Enterprise',
            'server': base_url,
            'note': 'Server responded but /qrs/about returned no data',
            'timestamp': timestamp
        }, indent=2))
    else:
        print(json.dumps({
            'success': False,
            'platform': 'onprem',
            'error': 'Invalid response from server',
            'httpStatus': status_code,
            'baseUrl': base_url,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
except Exception as e:
    print(json.dumps({
        'success': False,
        'platform': 'onprem',
        'error': str(e),
        'timestamp': timestamp
    }, indent=2))
    sys.exit(1)
"
}

# ===== EXECUTE =====

if [[ "$PLATFORM" == "cloud" ]]; then
  cloud_health
else
  onprem_health
fi
