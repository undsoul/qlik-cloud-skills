#!/bin/bash
# Qlik Reload Failures - Cloud & On-Premise
# Find recent failed reloads with app names
#
# Usage: qlik-reload-failures.sh [days-back] [limit]
#
# days-back: How many days to look back (default: 7)
# limit: Max results (default: 50)
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)

set -euo pipefail

DAYS="${1:-7}"
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

# ===== CLOUD IMPLEMENTATION =====

if [[ "$PLATFORM" == "cloud" ]]; then
  python3 << PYTHON
import json
import urllib.request
import ssl
from datetime import datetime, timedelta, timezone

tenant = "$BASE_URL"
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
    
    # Fetch app names
    app_names = {}
    for app_id in app_ids:
        try:
            app_data = api_get(f"/api/v1/apps/{app_id}")
            attrs = app_data.get('attributes', app_data)
            app_names[app_id] = attrs.get('name', 'Unknown')
        except:
            app_names[app_id] = 'Unknown (deleted?)'
    
    # Build result
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
    
    failures.sort(key=lambda x: x.get('createdAt', ''), reverse=True)
    
    result = {
        'success': True,
        'platform': 'cloud',
        'daysBack': days,
        'failureCount': len(failures),
        'failures': failures,
        'timestamp': timestamp
    }
    
    if len(failures) == 0:
        result['message'] = f'No reload failures in the last {days} days! 🎉'
    
    print(json.dumps(result, indent=2))
    
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'cloud', 'error': str(e), 'timestamp': timestamp}, indent=2))
PYTHON

# ===== ON-PREM IMPLEMENTATION =====

else
  # Build curl auth args
  CURL_AUTH=""
  if [[ -n "${QLIK_CERT:-}" ]] && [[ -n "${QLIK_KEY:-}" ]]; then
    CURL_AUTH="--cert ${QLIK_CERT} --key ${QLIK_KEY} --insecure"
  fi
  
  QLIK_USER_HEADER=""
  if [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && [[ -n "${QLIK_USER_ID:-}" ]]; then
    QLIK_USER_HEADER="X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}"
  fi
  
  python3 << PYTHON
import json
import subprocess
import random
import string
from datetime import datetime, timedelta, timezone

base_url = "$BASE_URL"
days = int("$DAYS")
limit = int("$LIMIT")
timestamp = "$TIMESTAMP"
curl_auth = "$CURL_AUTH"
user_header = "$QLIK_USER_HEADER"

def generate_xrf():
    return ''.join(random.choices(string.ascii_letters + string.digits, k=16))

def qrs_get(path):
    xrf = generate_xrf()
    sep = '&' if '?' in path else '?'
    url = f"{base_url}{path}{sep}xrfkey={xrf}"
    
    cmd = ['curl', '-sL']
    if curl_auth:
        cmd.extend(curl_auth.split())
    if user_header:
        cmd.extend(['-H', user_header])
    cmd.extend(['-H', f'X-Qlik-Xrfkey: {xrf}'])
    cmd.extend(['-H', 'Content-Type: application/json'])
    cmd.append(url)
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    return json.loads(result.stdout) if result.stdout else []

try:
    # Get all reload tasks with execution info
    tasks = qrs_get('/qrs/reloadtask/full')
    
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    
    failures = []
    for task in tasks if isinstance(tasks, list) else []:
        op = task.get('operational', {})
        last_result = op.get('lastExecutionResult', {})
        status = last_result.get('status', -1)
        
        # Status 1 = Failed
        if status != 1 and status != 'Failed':
            continue
        
        # Check date
        stop_time = last_result.get('stopTime', '')
        if stop_time:
            try:
                dt = datetime.fromisoformat(stop_time.replace('Z', '+00:00'))
                if dt < cutoff:
                    continue
            except:
                pass
        
        app = task.get('app', {})
        failures.append({
            'appId': app.get('id') if isinstance(app, dict) else app,
            'appName': app.get('name', 'Unknown') if isinstance(app, dict) else 'Unknown',
            'taskName': task.get('name'),
            'taskId': task.get('id'),
            'status': 'FAILED',
            'errorMessage': (last_result.get('details') or '')[:300],
            'startTime': last_result.get('startTime'),
            'endTime': last_result.get('stopTime'),
            'duration': last_result.get('duration'),
            'nextExecution': op.get('nextExecution'),
            'enabled': task.get('enabled', True)
        })
    
    # Sort by date descending
    failures.sort(key=lambda x: x.get('endTime', ''), reverse=True)
    failures = failures[:limit]
    
    result = {
        'success': True,
        'platform': 'onprem',
        'daysBack': days,
        'failureCount': len(failures),
        'failures': failures,
        'timestamp': timestamp
    }
    
    if len(failures) == 0:
        result['message'] = f'No reload failures in the last {days} days! 🎉'
    
    print(json.dumps(result, indent=2))
    
except Exception as e:
    print(json.dumps({'success': False, 'platform': 'onprem', 'error': str(e), 'timestamp': timestamp}, indent=2))
PYTHON
fi
