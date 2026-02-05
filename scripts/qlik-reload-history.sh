#!/bin/bash
# Qlik Reload History - Cloud & On-Premise
# Get reload history for an app
#
# Usage: qlik-reload-history.sh <app-id> [limit]
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)

set -euo pipefail

APP_ID="${1:-}"
LIMIT="${2:-10}"
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

if [[ -z "$APP_ID" ]]; then
  echo "{\"success\":false,\"error\":\"App ID required. Usage: qlik-reload-history.sh <app-id> [limit]\",\"timestamp\":\"$TIMESTAMP\"}"
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

cloud_reload_history() {
  curl -sL \
    -H "Authorization: Bearer ${QLIK_API_KEY}" \
    -H "Content-Type: application/json" \
    "${BASE_URL}/api/v1/reloads?appId=${APP_ID}&limit=${LIMIT}"
}

# ===== ON-PREM API (QRS) =====

onprem_reload_history() {
  local xrfkey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  
  # URL encode the filter
  local encoded_filter=$(python3 -c "
import urllib.parse
app_id = '$APP_ID'
filter_str = f\"app.id eq {app_id}\"
print(urllib.parse.quote(filter_str, safe=''))
")
  
  local url="${BASE_URL}/qrs/reloadtask/full?filter=${encoded_filter}&xrfkey=${xrfkey}"
  
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
  cloud_reload_history | python3 -c "
import json
import sys

app_id = '$APP_ID'
timestamp = '$TIMESTAMP'

try:
    data = json.load(sys.stdin)
    
    if 'errors' in data:
        print(json.dumps({'success': False, 'platform': 'cloud', 'error': data['errors'][0].get('title', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    reloads = []
    for r in data.get('data', []):
        reloads.append({
            'id': r.get('id'),
            'status': r.get('status'),
            'type': r.get('type'),
            'partial': r.get('partial'),
            'creationTime': r.get('creationTime'),
            'startTime': r.get('startTime'),
            'endTime': r.get('endTime'),
            'duration': r.get('duration'),
            'errorCode': r.get('errorCode')
        })
    
    print(json.dumps({
        'success': True,
        'platform': 'cloud',
        'appId': app_id,
        'reloads': reloads,
        'count': len(reloads),
        'timestamp': timestamp
    }, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'cloud', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
else
  onprem_reload_history | python3 -c "
import json
import sys

app_id = '$APP_ID'
timestamp = '$TIMESTAMP'
limit = int('$LIMIT')

try:
    data = json.load(sys.stdin)
    
    if isinstance(data, dict) and 'error' in data:
        print(json.dumps({'success': False, 'platform': 'onprem', 'error': data.get('error', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    reloads = []
    for r in data[:limit] if isinstance(data, list) else []:
        # Map QRS status
        status = 'UNKNOWN'
        op = r.get('operational', {})
        last_result = op.get('lastExecutionResult', {})
        qrs_status = last_result.get('status', -1)
        
        if qrs_status == 0 or qrs_status == 'Success':
            status = 'SUCCESS'
        elif qrs_status == 1 or qrs_status == 'Failed':
            status = 'FAILED'
        elif qrs_status == 2 or qrs_status == 'Running':
            status = 'RUNNING'
        elif qrs_status == 3 or qrs_status == 'Aborted':
            status = 'CANCELLED'
        elif qrs_status == 4 or qrs_status == 'NeverStarted':
            status = 'QUEUED'
        
        reloads.append({
            'id': r.get('id'),
            'name': r.get('name'),
            'status': status,
            'taskType': r.get('taskType'),
            'enabled': r.get('enabled', True),
            'startTime': last_result.get('startTime'),
            'endTime': last_result.get('stopTime'),
            'duration': last_result.get('duration'),
            'nextExecution': op.get('nextExecution'),
            'errorMessage': last_result.get('details')
        })
    
    print(json.dumps({
        'success': True,
        'platform': 'onprem',
        'appId': app_id,
        'reloads': reloads,
        'count': len(reloads),
        'timestamp': timestamp
    }, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'onprem', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
fi
