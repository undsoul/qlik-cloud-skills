#!/bin/bash
# Qlik Reload Status - Cloud & On-Premise
# Check the status of a reload
#
# Usage: qlik-reload-status.sh <reload-id>
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)

set -euo pipefail

RELOAD_ID="${1:-}"
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

if [[ -z "$RELOAD_ID" ]]; then
  echo "{\"success\":false,\"error\":\"Reload ID required. Usage: qlik-reload-status.sh <reload-id>\",\"timestamp\":\"$TIMESTAMP\"}"
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

cloud_reload_status() {
  curl -sL \
    -H "Authorization: Bearer ${QLIK_API_KEY}" \
    -H "Content-Type: application/json" \
    "${BASE_URL}/api/v1/reloads/${RELOAD_ID}"
}

# ===== ON-PREM API (QRS) =====

onprem_reload_status() {
  local xrfkey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  local url="${BASE_URL}/qrs/reloadtask/${RELOAD_ID}?xrfkey=${xrfkey}"
  
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
  cloud_reload_status | python3 -c "
import json
import sys

reload_id = '$RELOAD_ID'
timestamp = '$TIMESTAMP'

try:
    data = json.load(sys.stdin)
    
    if 'errors' in data:
        error = data['errors'][0].get('title', 'Unknown error')
        print(json.dumps({'success': False, 'platform': 'cloud', 'error': error, 'reloadId': reload_id, 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    # Truncate log
    log = data.get('log', '')
    if len(log) > 500:
        log = log[:500] + '... (truncated)'
    
    result = {
        'success': True,
        'platform': 'cloud',
        'reload': {
            'id': data.get('id'),
            'appId': data.get('appId'),
            'status': data.get('status'),
            'type': data.get('type'),
            'partial': data.get('partial'),
            'creationTime': data.get('creationTime'),
            'startTime': data.get('startTime'),
            'endTime': data.get('endTime'),
            'duration': data.get('duration'),
            'errorCode': data.get('errorCode'),
            'errorMessage': data.get('errorMessage'),
            'log': log
        },
        'timestamp': timestamp
    }
    print(json.dumps(result, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'cloud', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
else
  onprem_reload_status | python3 -c "
import json
import sys

reload_id = '$RELOAD_ID'
timestamp = '$TIMESTAMP'

try:
    data = json.load(sys.stdin)
    
    if 'error' in data:
        print(json.dumps({'success': False, 'platform': 'onprem', 'error': data.get('error', 'Unknown error'), 'reloadId': reload_id, 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    # Map QRS status
    status = 'UNKNOWN'
    op = data.get('operational', {})
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
    
    result = {
        'success': True,
        'platform': 'onprem',
        'reload': {
            'id': data.get('id'),
            'appId': data.get('app', {}).get('id') if data.get('app') else None,
            'appName': data.get('app', {}).get('name') if data.get('app') else None,
            'name': data.get('name'),
            'status': status,
            'startTime': last_result.get('startTime'),
            'endTime': last_result.get('stopTime'),
            'duration': last_result.get('duration'),
            'nextExecution': op.get('nextExecution'),
            'errorMessage': last_result.get('details'),
            'taskType': data.get('taskType'),
            'enabled': data.get('enabled', True)
        },
        'timestamp': timestamp
    }
    print(json.dumps(result, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'onprem', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
fi
