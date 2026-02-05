#!/bin/bash
# Qlik Cloud Reload Failures
# Find recent failed reloads with app names
# Usage: qlik-reload-failures.sh [days-back] [limit]
#
# days-back: How many days to look back (default: 7)
# limit: Max results (default: 50)

set -euo pipefail

DAYS="${1:-7}"
LIMIT="${2:-50}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ -z "${QLIK_TENANT:-}" ]] || [[ -z "${QLIK_API_KEY:-}" ]]; then
  echo "{\"success\":false,\"error\":\"QLIK_TENANT and QLIK_API_KEY required\",\"timestamp\":\"$TIMESTAMP\"}"
  exit 1
fi

TENANT="${QLIK_TENANT%/}"
[[ "$TENANT" != http* ]] && TENANT="https://$TENANT"

# Fetch failed reloads and enrich with app names
python3 << PYTHON
import json
import urllib.request
import ssl
from datetime import datetime, timedelta, timezone

tenant = "$TENANT"
api_key = "${QLIK_API_KEY}"
days = int("$DAYS")
limit = int("$LIMIT")
timestamp = "$TIMESTAMP"

ssl_ctx = ssl._create_unverified_context()
headers = {
    "Authorization": f"Bearer {api_key}",
    "Content-Type": "application/json"
}

def api_get(path):
    url = f"{tenant}{path}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, context=ssl_ctx) as resp:
        return json.load(resp)

try:
    # Get failed reloads
    reloads_data = api_get(f"/api/v1/reloads?limit={limit}&status=FAILED")
    reloads = reloads_data.get('data', [])
    
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    
    # Collect unique app IDs
    app_ids = set()
    filtered_reloads = []
    
    for r in reloads:
        # Only include actual failures
        if r.get('status') != 'FAILED':
            continue
        created = r.get('creationTime', '')
        if created:
            try:
                dt = datetime.fromisoformat(created.replace('Z', '+00:00'))
                if dt < cutoff:
                    continue
            except:
                pass
        filtered_reloads.append(r)
        if r.get('appId'):
            app_ids.add(r['appId'])
    
    # Fetch app names in batch
    app_names = {}
    for app_id in app_ids:
        try:
            app_data = api_get(f"/api/v1/apps/{app_id}")
            attrs = app_data.get('attributes', app_data)
            app_names[app_id] = attrs.get('name', 'Unknown')
        except:
            app_names[app_id] = 'Unknown (deleted?)'
    
    # Build result with app names
    failures = []
    for r in filtered_reloads:
        app_id = r.get('appId', '')
        failures.append({
            'appId': app_id,
            'appName': app_names.get(app_id, 'Unknown'),
            'status': r.get('status'),
            'errorCode': r.get('errorCode'),
            'errorMessage': (r.get('errorMessage') or r.get('log', ''))[:300],
            'createdAt': r.get('creationTime'),
            'duration': r.get('duration'),
            'type': r.get('type')
        })
    
    # Sort by date descending
    failures.sort(key=lambda x: x.get('createdAt', ''), reverse=True)
    
    result = {
        'success': True,
        'daysBack': days,
        'failureCount': len(failures),
        'failures': failures,
        'timestamp': timestamp
    }
    
    if len(failures) == 0:
        result['message'] = f'No reload failures in the last {days} days! 🎉'
    
    print(json.dumps(result, indent=2))
    
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e), 'timestamp': timestamp}, indent=2))
PYTHON
