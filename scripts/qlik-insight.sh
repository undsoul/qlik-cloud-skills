#!/bin/bash
# Qlik Insight Advisor (Natural Language Query) - Cloud & On-Premise
# Ask questions about your data in natural language - returns actual data!
# Works with any language - auto-handles Qlik API requirements internally
#
# Usage: qlik-insight.sh "question" [app-id]
#
# Environment Variables:
#   Cloud:    QLIK_TENANT, QLIK_API_KEY
#   On-Prem:  QLIK_SERVER, QLIK_CERT, QLIK_KEY (or QLIK_USER_DIRECTORY, QLIK_USER_ID)
#             Optional: QLIK_VIRTUAL_PROXY
#
# On-Premise: Requires Insight Advisor Chat enabled in QMC

set -euo pipefail

QUESTION="${1:-}"
APP_ID="${2:-}"
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

if [[ -z "$QUESTION" ]]; then
  echo "{\"success\":false,\"error\":\"Question required. Usage: qlik-insight.sh \\\"question\\\" [app-id]\",\"timestamp\":\"$TIMESTAMP\"}"
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

# ===== CLOUD: QUERY INSIGHT ADVISOR =====

cloud_insight() {
  local q="$1"
  local aid="$2"
  
  local body
  body=$(printf '%s' "$q" | python3 -c "
import json
import sys
question = sys.stdin.read()
body = {
    'text': question,
    'enableVisualizations': True,
    'visualizationOptions': {'includeCellData': True}
}
app_id = '$aid'
if app_id:
    body['app'] = {'id': app_id}
print(json.dumps(body))
")

  curl -sL -X POST \
    -H "Authorization: Bearer ${QLIK_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${BASE_URL}/api/v1/questions/actions/ask"
}

# ===== ON-PREMISE: QUERY INSIGHT ADVISOR CHAT =====
# Uses /api/v1/nl/query endpoint (requires Insight Advisor Chat in QMC)

onprem_insight() {
  local q="$1"
  local aid="$2"
  
  local body
  body=$(printf '%s' "$q" | python3 -c "
import json
import sys
question = sys.stdin.read()
body = {'text': question}
app_id = '$aid'
if app_id:
    body['app'] = {'id': app_id}
print(json.dumps(body))
")

  # Build curl command with auth
  local curl_cmd="curl -sL -X POST"
  
  # Certificate auth
  if [[ -n "${QLIK_CERT:-}" ]] && [[ -n "${QLIK_KEY:-}" ]]; then
    curl_cmd="$curl_cmd --cert \"${QLIK_CERT}\" --key \"${QLIK_KEY}\" --insecure"
  fi
  
  # Header auth
  if [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && [[ -n "${QLIK_USER_ID:-}" ]]; then
    curl_cmd="$curl_cmd -H \"X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}\""
  fi
  
  curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
  curl_cmd="$curl_cmd -d '$body'"
  curl_cmd="$curl_cmd \"${BASE_URL}/api/v1/nl/query\""
  
  eval $curl_cmd 2>/dev/null
}

# ===== EXECUTE QUERY =====

if [[ "$PLATFORM" == "cloud" ]]; then
  RESPONSE=$(cloud_insight "$QUESTION" "$APP_ID")
else
  RESPONSE=$(onprem_insight "$QUESTION" "$APP_ID")
fi

# ===== PROCESS RESPONSE =====

echo "$RESPONSE" | QUESTION="$QUESTION" APP_ID="$APP_ID" TIMESTAMP="$TIMESTAMP" PLATFORM="$PLATFORM" python3 -c "
import json
import sys
import os
import re

question = os.environ.get('QUESTION', '')
app_id = os.environ.get('APP_ID', '')
timestamp = os.environ.get('TIMESTAMP', '')
platform = os.environ.get('PLATFORM', 'cloud')

def extract_cloud_result(data, original_question):
    '''Extract result from Cloud API response'''
    result = {
        'success': True,
        'platform': 'cloud',
        'question': original_question,
        'timestamp': timestamp
    }
    
    if 'errors' in data:
        return {'success': False, 'platform': 'cloud', 'error': data['errors'][0].get('title', 'Unknown error'), 'timestamp': timestamp}
    
    if 'conversationalResponse' not in data:
        return {'success': False, 'platform': 'cloud', 'error': 'No response from Insight Advisor', 'timestamp': timestamp}
    
    resp = data['conversationalResponse']
    has_narrative = False
    has_data = False
    
    # Extract from responses
    for r in resp.get('responses', []):
        # Get narrative (the actual answer)
        if 'narrative' in r:
            narr = r['narrative']
            text = narr.get('text', '') if isinstance(narr, dict) else str(narr)
            if text and text.strip():
                result['narrative'] = text
                has_narrative = True
        
        # Extract data from qHyperCube
        if 'renderVisualization' in r:
            viz = r['renderVisualization']
            qdata = viz.get('data', {})
            cube = qdata.get('qHyperCube', {})
            
            dims = [d.get('qFallbackTitle') for d in cube.get('qDimensionInfo', []) if d.get('qFallbackTitle')]
            measures = [m.get('qFallbackTitle') for m in cube.get('qMeasureInfo', []) if m.get('qFallbackTitle')]
            
            rows = []
            for page in cube.get('qDataPages', []):
                for row in page.get('qMatrix', [])[:50]:  # Up to 50 rows
                    row_data = []
                    for cell in row:
                        val = cell.get('qText') or cell.get('qNum')
                        if val is not None:
                            row_data.append(val)
                    if row_data:
                        rows.append(row_data)
            
            if dims or measures or rows:
                result['data'] = {
                    'dimensions': dims,
                    'measures': measures,
                    'rows': rows[:20],
                    'totalRows': len(rows)
                }
                has_data = True
    
    # App info
    if resp.get('apps'):
        result['app'] = {
            'id': resp['apps'][0].get('id'),
            'name': resp['apps'][0].get('name')
        }
    
    # Recommendations
    if resp.get('recommendations'):
        result['recommendations'] = [
            {'name': rec.get('name'), 'id': rec.get('recId')}
            for rec in resp['recommendations'][:5]
        ]
    
    # Drill-down link
    if resp.get('drillDownURI'):
        result['drillDownLink'] = resp['drillDownURI']
    
    # Hints if no data
    if not has_narrative and not has_data:
        if resp.get('drillDownURI'):
            result['hint'] = 'Try rephrasing your question or use the drill-down link'
        else:
            result['hint'] = 'Question not understood. Try simpler phrasing.'
    
    return result

def extract_onprem_result(data, original_question):
    '''Extract result from On-Premise NL Query API response'''
    result = {
        'success': True,
        'platform': 'onprem',
        'question': original_question,
        'timestamp': timestamp
    }
    
    # Check for errors
    if 'error' in data or 'message' in data:
        error_msg = data.get('error') or data.get('message', 'Unknown error')
        if '404' in str(error_msg) or 'Not Found' in str(error_msg):
            error_msg = 'Insight Advisor Chat not available. Enable in QMC > Natural Language Settings.'
        elif '401' in str(error_msg) or '403' in str(error_msg):
            error_msg = 'Authentication failed for NL Query API'
        return {'success': False, 'platform': 'onprem', 'error': error_msg, 'timestamp': timestamp}
    
    # On-prem response structure varies by version
    # Common fields: narrative, charts, followups, conversationId
    
    if 'narrative' in data:
        result['narrative'] = data['narrative']
    
    # Extract charts/visualizations
    if 'charts' in data:
        for chart in data.get('charts', [])[:5]:
            if 'data' not in result:
                result['data'] = {'charts': []}
            result['data']['charts'].append({
                'type': chart.get('type'),
                'title': chart.get('title'),
                'values': chart.get('values', [])[:20]
            })
    
    # qHyperCube format (similar to cloud)
    if 'qHyperCube' in data:
        cube = data['qHyperCube']
        dims = [d.get('qFallbackTitle') for d in cube.get('qDimensionInfo', []) if d.get('qFallbackTitle')]
        measures = [m.get('qFallbackTitle') for m in cube.get('qMeasureInfo', []) if m.get('qFallbackTitle')]
        
        rows = []
        for page in cube.get('qDataPages', []):
            for row in page.get('qMatrix', [])[:50]:
                row_data = []
                for cell in row:
                    val = cell.get('qText') or cell.get('qNum')
                    if val is not None:
                        row_data.append(val)
                if row_data:
                    rows.append(row_data)
        
        if dims or measures or rows:
            result['data'] = {
                'dimensions': dims,
                'measures': measures,
                'rows': rows[:20],
                'totalRows': len(rows)
            }
    
    # Follow-ups
    if 'followups' in data:
        result['followups'] = data['followups'][:5]
    
    # Conversation ID for multi-turn
    if 'conversationId' in data:
        result['conversationId'] = data['conversationId']
    
    # App info
    if 'app' in data:
        result['app'] = data['app']
    
    return result

try:
    raw = sys.stdin.read()
    
    # Handle empty response
    if not raw or not raw.strip():
        print(json.dumps({
            'success': False,
            'platform': platform,
            'error': 'Empty response from server',
            'hint': 'Check server connectivity and authentication',
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    # Try to parse JSON
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        # Check if it's an HTML error page
        if '<html' in raw.lower() or '<!doctype' in raw.lower():
            error_msg = 'Server returned HTML error page'
            if '404' in raw:
                error_msg = 'Endpoint not found. Insight Advisor Chat may not be enabled.'
            elif '401' in raw or '403' in raw:
                error_msg = 'Authentication failed'
        else:
            error_msg = f'Invalid JSON response: {str(e)}'
        
        print(json.dumps({
            'success': False,
            'platform': platform,
            'error': error_msg,
            'timestamp': timestamp
        }, indent=2))
        sys.exit(1)
    
    # Route to platform-specific extractor
    if platform == 'onprem':
        result = extract_onprem_result(data, question)
    else:
        result = extract_cloud_result(data, question)
    
    print(json.dumps(result, indent=2))
    
except Exception as e:
    print(json.dumps({
        'success': False,
        'platform': platform,
        'error': str(e),
        'timestamp': timestamp
    }, indent=2))
    sys.exit(1)
"
