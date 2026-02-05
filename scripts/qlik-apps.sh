#!/bin/bash
# Qlik Apps List - Cloud & On-Premise
# List apps with optional space/stream filtering
#
# Usage: qlik-apps.sh [--space <personal|spaceId>] [--limit <n>]
#
# Cloud Examples:
#   qlik-apps.sh                           # List all accessible apps
#   qlik-apps.sh --space personal          # List apps in personal space
#   qlik-apps.sh --space abc-123-uuid      # List apps in specific space
#
# On-Premise Examples:
#   qlik-apps.sh                           # List all apps
#   qlik-apps.sh --space stream-id         # List apps in specific stream
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LIMIT=50
SPACE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --space)
      SPACE="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    *)
      # Legacy: first positional arg is limit
      if [[ -z "$SPACE" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
        LIMIT="$1"
      fi
      shift
      ;;
  esac
done

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

if [[ "$PLATFORM" == "cloud" ]] && [[ -z "${QLIK_API_KEY:-}" ]]; then
  echo "{\"success\":false,\"error\":\"QLIK_API_KEY required for Qlik Cloud\",\"timestamp\":\"$TIMESTAMP\"}"
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
  if [[ -n "${QLIK_VIRTUAL_PROXY:-}" ]]; then
    SERVER="$SERVER/${QLIK_VIRTUAL_PROXY}"
  fi
  BASE_URL="$SERVER"
fi

# ===== CLOUD API =====

cloud_list_apps() {
  if [[ -n "$SPACE" ]]; then
    # Use /items API for space filtering (personal or specific space)
    curl -sL \
      -H "Authorization: Bearer ${QLIK_API_KEY}" \
      -H "Content-Type: application/json" \
      "${BASE_URL}/api/v1/items?resourceType=app&spaceId=${SPACE}&limit=${LIMIT}"
  else
    # Use /apps API for all apps
    curl -sL \
      -H "Authorization: Bearer ${QLIK_API_KEY}" \
      -H "Content-Type: application/json" \
      "${BASE_URL}/api/v1/apps?limit=${LIMIT}"
  fi
}

# ===== ON-PREM API (QRS) =====

onprem_list_apps() {
  local xrfkey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  local url="${BASE_URL}/qrs/app/full?xrfkey=${xrfkey}"
  
  # Add stream filter if specified
  if [[ -n "$SPACE" ]]; then
    url="${url}&filter=stream.id%20eq%20${SPACE}"
  fi
  
  # Build curl args
  local curl_args="-sL"
  
  # Certificate auth
  if [[ -n "${QLIK_CERT:-}" ]] && [[ -n "${QLIK_KEY:-}" ]]; then
    curl_args="$curl_args --cert \"${QLIK_CERT}\" --key \"${QLIK_KEY}\" --insecure"
  fi
  
  # Header auth
  if [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && [[ -n "${QLIK_USER_ID:-}" ]]; then
    curl_args="$curl_args -H \"X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}\""
  fi
  
  # XRF key header
  curl_args="$curl_args -H \"X-Qlik-Xrfkey: ${xrfkey}\""
  curl_args="$curl_args -H \"Content-Type: application/json\""
  
  eval curl $curl_args "\"$url\""
}

# ===== PROCESS RESPONSE =====

if [[ "$PLATFORM" == "cloud" ]]; then
  cloud_list_apps | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'
space = '$SPACE'
platform = 'cloud'

try:
    data = json.load(sys.stdin)
    if 'errors' in data:
        print(json.dumps({'success': False, 'error': data['errors'][0].get('title', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    apps = []
    
    # Handle /items API response (space filtering)
    if space:
        for item in data.get('data', []):
            apps.append({
                'resourceId': item.get('resourceId'),
                'id': item.get('id'),
                'name': item.get('name'),
                'description': item.get('description', '')[:100] if item.get('description') else None,
                'spaceId': item.get('spaceId'),
                'ownerId': item.get('ownerId'),
                'updatedAt': item.get('updatedAt'),
                'createdAt': item.get('createdAt')
            })
        space_label = 'personal space' if space == 'personal' else f'space {space}'
    else:
        # Handle /apps API response
        for item in data.get('data', []):
            attrs = item.get('attributes', item)
            apps.append({
                'resourceId': attrs.get('id'),
                'name': attrs.get('name'),
                'description': attrs.get('description', '')[:100] if attrs.get('description') else None,
                'spaceId': attrs.get('spaceId'),
                'published': attrs.get('published'),
                'lastReloadTime': attrs.get('lastReloadTime'),
                'modified': attrs.get('modifiedDate')
            })
    
    result = {
        'success': True,
        'platform': platform,
        'apps': apps,
        'totalCount': len(apps),
        'timestamp': timestamp
    }
    if space:
        result['space'] = space
    
    print(json.dumps(result, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
else
  # On-Prem
  onprem_list_apps | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'
space = '$SPACE'
platform = 'onprem'
limit = int('$LIMIT')

try:
    data = json.load(sys.stdin)
    
    # QRS API returns array directly
    if isinstance(data, dict) and 'error' in data:
        print(json.dumps({'success': False, 'error': data.get('error', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    apps = []
    for item in data[:limit] if isinstance(data, list) else []:
        apps.append({
            'resourceId': item.get('id'),
            'name': item.get('name'),
            'description': item.get('description', '')[:100] if item.get('description') else None,
            'streamId': item.get('stream', {}).get('id') if item.get('stream') else None,
            'streamName': item.get('stream', {}).get('name') if item.get('stream') else None,
            'ownerId': item.get('owner', {}).get('id') if item.get('owner') else None,
            'ownerName': item.get('owner', {}).get('name') if item.get('owner') else None,
            'published': item.get('published'),
            'lastReloadTime': item.get('lastReloadTime'),
            'modifiedDate': item.get('modifiedDate'),
            'createdDate': item.get('createdDate')
        })
    
    result = {
        'success': True,
        'platform': platform,
        'apps': apps,
        'totalCount': len(apps),
        'timestamp': timestamp
    }
    if space:
        result['stream'] = space
    
    print(json.dumps(result, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e), 'platform': platform, 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
fi
