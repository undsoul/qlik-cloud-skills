#!/bin/bash
# Qlik Spaces/Streams Catalog - Cloud & On-Premise
# List all spaces (Cloud) or streams (On-Premise)
#
# Usage: qlik-spaces.sh [limit]
#
# Cloud: Lists spaces (shared, managed, data)
#        NOTE: Personal space is VIRTUAL and will NOT appear here!
#        To list personal space apps, use: qlik-apps.sh --space personal
#
# On-Prem: Lists streams (equivalent to spaces)
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)

set -euo pipefail

LIMIT="${1:-100}"
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

# ===== CLOUD API =====

cloud_list_spaces() {
  curl -sL \
    -H "Authorization: Bearer ${QLIK_API_KEY}" \
    -H "Content-Type: application/json" \
    "${BASE_URL}/api/v1/spaces?limit=${LIMIT}"
}

# ===== ON-PREM API (QRS) =====

onprem_list_streams() {
  local xrfkey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  local url="${BASE_URL}/qrs/stream/full?xrfkey=${xrfkey}"
  
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
  cloud_list_spaces | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'

try:
    data = json.load(sys.stdin)
    if 'errors' in data:
        print(json.dumps({'success': False, 'platform': 'cloud', 'error': data['errors'][0].get('title', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    spaces = []
    for s in data.get('data', []):
        spaces.append({
            'id': s.get('id'),
            'name': s.get('name'),
            'type': s.get('type'),
            'description': s.get('description'),
            'ownerId': s.get('ownerId'),
            'createdAt': s.get('createdAt'),
            'updatedAt': s.get('updatedAt')
        })
    
    # Count by type
    type_counts = {}
    for s in spaces:
        t = s.get('type', 'unknown')
        type_counts[t] = type_counts.get(t, 0) + 1
    
    print(json.dumps({
        'success': True,
        'platform': 'cloud',
        'spaces': spaces, 
        'totalCount': len(spaces),
        'byType': type_counts,
        'note': 'Personal space is VIRTUAL and not listed here. Use qlik-apps.sh --space personal',
        'timestamp': timestamp
    }, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'cloud', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
else
  onprem_list_streams | python3 -c "
import json
import sys

timestamp = '$TIMESTAMP'
limit = int('$LIMIT')

try:
    data = json.load(sys.stdin)
    
    if isinstance(data, dict) and 'error' in data:
        print(json.dumps({'success': False, 'platform': 'onprem', 'error': data.get('error', 'Unknown error'), 'timestamp': timestamp}, indent=2))
        sys.exit(1)
    
    streams = []
    for s in data[:limit] if isinstance(data, list) else []:
        streams.append({
            'id': s.get('id'),
            'name': s.get('name'),
            'type': 'stream',  # Equivalent to 'shared' in Cloud
            'ownerId': s.get('owner', {}).get('id') if s.get('owner') else None,
            'ownerName': s.get('owner', {}).get('name') if s.get('owner') else None,
            'createdDate': s.get('createdDate'),
            'modifiedDate': s.get('modifiedDate'),
            'privileges': s.get('privileges', [])
        })
    
    print(json.dumps({
        'success': True,
        'platform': 'onprem',
        'streams': streams,
        'totalCount': len(streams),
        'note': 'On-premise uses streams (similar to Cloud spaces). Personal/unpublished apps are not in streams.',
        'timestamp': timestamp
    }, indent=2))
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'onprem', 'error': str(e), 'timestamp': timestamp}, indent=2))
    sys.exit(1)
"
fi
