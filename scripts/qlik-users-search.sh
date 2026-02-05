#!/bin/bash
# Qlik User Search - Cloud & On-Premise
# Search for users by name or email
#
# Usage: qlik-users-search.sh "query" [limit]
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)

set -euo pipefail

QUERY="${1:-}"
LIMIT="${2:-50}"
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

if [[ -z "$QUERY" ]]; then
  echo "{\"success\":false,\"error\":\"Search query required. Usage: qlik-users-search.sh \\\"query\\\"\",\"timestamp\":\"$TIMESTAMP\"}"
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

# ===== CLOUD API =====

cloud_search_users() {
  # Build and URL encode the filter
  local encoded_filter=$(python3 -c "
import urllib.parse
query = '''$QUERY'''
filter_str = f'name co \"{query}\"'
print(urllib.parse.quote(filter_str, safe=''))
")

  curl -sL \
    -H "Authorization: Bearer ${QLIK_API_KEY}" \
    -H "Content-Type: application/json" \
    "${BASE_URL}/api/v1/users?filter=${encoded_filter}&limit=${LIMIT}"
}

# ===== ON-PREM API (QRS) =====

onprem_search_users() {
  local xrfkey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  
  # URL encode filter for QRS
  local encoded_filter=$(python3 -c "
import urllib.parse
query = '''$QUERY'''
# QRS uses different filter syntax
filter_str = f\"name sw '{query}' or userId sw '{query}'\"
print(urllib.parse.quote(filter_str, safe=''))
")
  
  local url="${BASE_URL}/qrs/user/full?filter=${encoded_filter}&xrfkey=${xrfkey}"
  
  local curl_cmd="curl -sL"
  
  # Certificate auth
  if [[ -n "${QLIK_CERT:-}" ]] && [[ -n "${QLIK_KEY:-}" ]]; then
    curl_cmd="$curl_cmd --cert \"${QLIK_CERT}\" --key \"${QLIK_KEY}\" --insecure"
  fi
  
  # Header auth
  if [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && [[ -n "${QLIK_USER_ID:-}" ]]; then
    curl_cmd="$curl_cmd -H \"X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}\""
  fi
  
  curl_cmd="$curl_cmd -H \"X-Qlik-Xrfkey: ${xrfkey}\""
  curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
  
  eval $curl_cmd "\"$url\""
}

# ===== EXECUTE =====

if [[ "$PLATFORM" == "cloud" ]]; then
  cloud_search_users | python3 -c "
import json
import sys

query = '''$QUERY'''
timestamp = '$TIMESTAMP'

try:
    raw = sys.stdin.read()
    if not raw.strip():
        print(json.dumps({'success': True, 'platform': 'cloud', 'query': query, 'users': [], 'totalCount': 0, 'timestamp': timestamp}, indent=2))
        sys.exit(0)
        
    data = json.loads(raw)
    if 'errors' in data:
        print(json.dumps({'success': False, 'platform': 'cloud', 'error': data['errors'][0].get('title', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    users = []
    for u in data.get('data', []):
        users.append({
            'id': u.get('id'),
            'name': u.get('name'),
            'email': u.get('email'),
            'status': u.get('status')
        })
    
    print(json.dumps({'success': True, 'platform': 'cloud', 'query': query, 'users': users, 'totalCount': len(users), 'timestamp': timestamp}, indent=2))
except json.JSONDecodeError:
    print(json.dumps({'success': True, 'platform': 'cloud', 'query': query, 'users': [], 'totalCount': 0, 'timestamp': timestamp}, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'cloud', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
else
  onprem_search_users | python3 -c "
import json
import sys

query = '''$QUERY'''
timestamp = '$TIMESTAMP'
limit = int('$LIMIT')

try:
    raw = sys.stdin.read()
    if not raw.strip():
        print(json.dumps({'success': True, 'platform': 'onprem', 'query': query, 'users': [], 'totalCount': 0, 'timestamp': timestamp}, indent=2))
        sys.exit(0)
    
    data = json.loads(raw)
    
    if isinstance(data, dict) and 'error' in data:
        print(json.dumps({'success': False, 'platform': 'onprem', 'error': data.get('error', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    users = []
    for u in data[:limit] if isinstance(data, list) else []:
        users.append({
            'id': u.get('id'),
            'name': u.get('name'),
            'userId': u.get('userId'),
            'userDirectory': u.get('userDirectory'),
            'email': u.get('email'),
            'inactive': u.get('inactive', False),
            'removedExternally': u.get('removedExternally', False),
            'lastUsed': u.get('lastUsed'),
            'roles': [r.get('name') for r in u.get('roles', []) if r.get('name')]
        })
    
    print(json.dumps({'success': True, 'platform': 'onprem', 'query': query, 'users': users, 'totalCount': len(users), 'timestamp': timestamp}, indent=2))
except json.JSONDecodeError:
    print(json.dumps({'success': True, 'platform': 'onprem', 'query': query, 'users': [], 'totalCount': 0, 'timestamp': timestamp}, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'onprem', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
fi
