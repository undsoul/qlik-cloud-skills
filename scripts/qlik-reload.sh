#!/bin/bash
# Qlik Reload Trigger - Cloud & On-Premise
# Trigger an app reload
#
# Usage: qlik-reload.sh <app-id> [--partial]
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)

set -euo pipefail

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
APP_ID="${1:-}"
PARTIAL=false

# Parse args
shift || true
while [[ $# -gt 0 ]]; do
  case $1 in
    --partial) PARTIAL=true; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$APP_ID" ]]; then
  echo "{\"success\":false,\"error\":\"App ID required. Usage: qlik-reload.sh <app-id>\",\"timestamp\":\"$TIMESTAMP\"}"
  exit 1
fi

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

if [[ "$PLATFORM" == "unknown" ]]; then
  echo "{\"success\":false,\"error\":\"Configuration required\",\"timestamp\":\"$TIMESTAMP\"}"
  exit 1
fi

# ===== BUILD BASE URL =====

if [[ "$PLATFORM" == "cloud" ]]; then
  TENANT="${QLIK_TENANT%/}"
  [[ "$TENANT" != http* ]] && TENANT="https://$TENANT"
  BASE_URL="$TENANT"
else
  SERVER="${QLIK_SERVER%/}"
  [[ "$SERVER" != http* ]] && SERVER="https://$SERVER"
  [[ -n "${QLIK_VIRTUAL_PROXY:-}" ]] && SERVER="$SERVER/${QLIK_VIRTUAL_PROXY}"
  BASE_URL="$SERVER"
fi

# ===== CLOUD RELOAD =====

cloud_reload() {
  local body="{\"appId\":\"$APP_ID\"}"
  [[ "$PARTIAL" == "true" ]] && body="{\"appId\":\"$APP_ID\",\"partial\":true}"
  
  curl -sL \
    -X POST \
    -H "Authorization: Bearer ${QLIK_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${BASE_URL}/api/v1/reloads"
}

# ===== ON-PREM RELOAD =====

onprem_reload() {
  local xrfkey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  
  # First, find or create a reload task for this app
  # Try to find existing task
  local filter="app.id%20eq%20${APP_ID}"
  local url="${BASE_URL}/qrs/reloadtask/full?filter=${filter}&xrfkey=${xrfkey}"
  
  local curl_args="-sL"
  [[ -n "${QLIK_CERT:-}" ]] && curl_args="$curl_args --cert \"${QLIK_CERT}\" --key \"${QLIK_KEY}\" --insecure"
  [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && curl_args="$curl_args -H \"X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}\""
  curl_args="$curl_args -H \"X-Qlik-Xrfkey: ${xrfkey}\" -H \"Content-Type: application/json\""
  
  local tasks=$(eval curl $curl_args "\"$url\"")
  
  # Parse task ID
  local task_id=$(echo "$tasks" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    if data and len(data) > 0:
        print(data[0].get('id', ''))
except:
    pass
")
  
  if [[ -n "$task_id" ]]; then
    # Start existing task
    local start_url="${BASE_URL}/qrs/reloadtask/${task_id}/start/synchronous?xrfkey=${xrfkey}"
    eval curl $curl_args -X POST "\"$start_url\""
  else
    # No task found - trigger hub reload
    local hub_url="${BASE_URL}/qrs/app/${APP_ID}/reload?xrfkey=${xrfkey}"
    eval curl $curl_args -X POST "\"$hub_url\""
  fi
}

# ===== PROCESS RESPONSE =====

if [[ "$PLATFORM" == "cloud" ]]; then
  cloud_reload | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'
app_id = '$APP_ID'

try:
    data = json.load(sys.stdin)
    
    if 'errors' in data:
        print(json.dumps({
            'success': False,
            'platform': 'cloud',
            'error': data['errors'][0].get('title', 'Reload failed'),
            'appId': app_id,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    print(json.dumps({
        'success': True,
        'platform': 'cloud',
        'message': 'Reload triggered',
        'reloadId': data.get('id'),
        'appId': app_id,
        'status': data.get('status'),
        'type': data.get('type'),
        'createdAt': data.get('creationTime'),
        'timestamp': timestamp
    }, indent=2))
except Exception as e:
    print(json.dumps({
        'success': False,
        'platform': 'cloud',
        'error': str(e),
        'appId': app_id,
        'timestamp': timestamp
    }, indent=2))
    sys.exit(1)
"
else
  onprem_reload | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'
app_id = '$APP_ID'

try:
    data = json.load(sys.stdin)
    
    if isinstance(data, dict) and 'error' in data:
        print(json.dumps({
            'success': False,
            'platform': 'onprem',
            'error': data.get('error', 'Reload failed'),
            'appId': app_id,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    # QRS reload response varies
    if isinstance(data, dict):
        print(json.dumps({
            'success': True,
            'platform': 'onprem',
            'message': 'Reload triggered',
            'appId': app_id,
            'taskId': data.get('id'),
            'status': data.get('operational', {}).get('lastExecutionResult', {}).get('status'),
            'timestamp': timestamp
        }, indent=2))
    else:
        print(json.dumps({
            'success': True,
            'platform': 'onprem',
            'message': 'Reload triggered',
            'appId': app_id,
            'timestamp': timestamp
        }, indent=2))
except Exception as e:
    # Empty response might mean success
    print(json.dumps({
        'success': True,
        'platform': 'onprem',
        'message': 'Reload triggered (no response body)',
        'appId': app_id,
        'timestamp': timestamp
    }, indent=2))
"
fi
