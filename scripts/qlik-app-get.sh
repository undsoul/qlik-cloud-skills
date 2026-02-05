#!/bin/bash
# Qlik Get App - Cloud & On-Premise
# Get details of a specific app
#
# Usage: qlik-app-get.sh <app-id>
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)

set -euo pipefail

APP_ID="${1:-}"
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
  echo "{\"success\":false,\"error\":\"App ID required. Usage: qlik-app-get.sh <app-id>\",\"timestamp\":\"$TIMESTAMP\"}"
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

cloud_get_app() {
  curl -sL \
    -H "Authorization: Bearer ${QLIK_API_KEY}" \
    -H "Content-Type: application/json" \
    "${BASE_URL}/api/v1/apps/${APP_ID}"
}

# ===== ON-PREM API (QRS) =====

onprem_get_app() {
  local xrfkey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  local url="${BASE_URL}/qrs/app/${APP_ID}?xrfkey=${xrfkey}"
  
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
  cloud_get_app | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'

try:
    data = json.load(sys.stdin)
    
    if 'errors' in data:
        print(json.dumps({'success': False, 'platform': 'cloud', 'error': data['errors'][0].get('title', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    attrs = data.get('attributes', data)
    result = {
        'success': True,
        'platform': 'cloud',
        'app': {
            'id': data.get('id', attrs.get('id')),
            'name': attrs.get('name'),
            'description': attrs.get('description'),
            'spaceId': attrs.get('spaceId'),
            'ownerId': attrs.get('ownerId'),
            'published': attrs.get('published', False),
            'publishTime': attrs.get('publishTime'),
            'lastReloadTime': attrs.get('lastReloadTime'),
            'thumbnail': attrs.get('thumbnail'),
            'created': attrs.get('createdDate'),
            'modified': attrs.get('modifiedDate')
        },
        'timestamp': timestamp
    }
    print(json.dumps(result, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'cloud', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
else
  onprem_get_app | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'

try:
    data = json.load(sys.stdin)
    
    if 'error' in data:
        print(json.dumps({'success': False, 'platform': 'onprem', 'error': data.get('error', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    result = {
        'success': True,
        'platform': 'onprem',
        'app': {
            'id': data.get('id'),
            'name': data.get('name'),
            'description': data.get('description'),
            'streamId': data.get('stream', {}).get('id') if data.get('stream') else None,
            'streamName': data.get('stream', {}).get('name') if data.get('stream') else None,
            'ownerId': data.get('owner', {}).get('id') if data.get('owner') else None,
            'ownerName': data.get('owner', {}).get('name') if data.get('owner') else None,
            'published': data.get('published', False),
            'publishTime': data.get('publishTime'),
            'lastReloadTime': data.get('lastReloadTime'),
            'thumbnail': data.get('thumbnail'),
            'fileSize': data.get('fileSize'),
            'created': data.get('createdDate'),
            'modified': data.get('modifiedDate'),
            'migrationHash': data.get('migrationHash'),
            'dynamicColor': data.get('dynamicColor')
        },
        'timestamp': timestamp
    }
    print(json.dumps(result, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'onprem', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
fi
