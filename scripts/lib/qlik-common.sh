#!/bin/bash
# ===== QLIK COMMON LIBRARY =====
# Shared functions for Cloud and On-Premise support
# Source this in scripts: source "$(dirname "$0")/lib/qlik-common.sh"

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

# ===== XRF KEY GENERATION (On-Premise) =====

generate_xrf_key() {
  cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

# ===== BUILD BASE URL =====

get_base_url() {
  local platform=$(detect_platform)
  
  if [[ "$platform" == "cloud" ]]; then
    local tenant="${QLIK_TENANT%/}"
    [[ "$tenant" != http* ]] && tenant="https://$tenant"
    echo "$tenant"
  elif [[ "$platform" == "onprem" ]]; then
    local server="${QLIK_SERVER%/}"
    [[ "$server" != http* ]] && server="https://$server"
    if [[ -n "${QLIK_VIRTUAL_PROXY:-}" ]]; then
      server="$server/${QLIK_VIRTUAL_PROXY}"
    fi
    echo "$server"
  else
    echo ""
  fi
}

# ===== BUILD CURL COMMAND =====
# Returns curl command with proper auth for platform
# Usage: eval "$(build_curl_cmd) -X GET '$url'"

build_curl_cmd() {
  local platform=$(detect_platform)
  local cmd="curl -sL"
  
  if [[ "$platform" == "cloud" ]]; then
    cmd="$cmd -H 'Authorization: Bearer ${QLIK_API_KEY}'"
    cmd="$cmd -H 'Content-Type: application/json'"
  elif [[ "$platform" == "onprem" ]]; then
    # Certificate auth
    if [[ -n "${QLIK_CERT:-}" ]] && [[ -n "${QLIK_KEY:-}" ]]; then
      cmd="$cmd --cert '${QLIK_CERT}' --key '${QLIK_KEY}' --insecure"
    fi
    
    # Header auth (X-Qlik-User)
    if [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && [[ -n "${QLIK_USER_ID:-}" ]]; then
      cmd="$cmd -H 'X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}'"
    fi
    
    cmd="$cmd -H 'Content-Type: application/json'"
  fi
  
  echo "$cmd"
}

# ===== MAKE API REQUEST =====
# Handles platform differences automatically
# Usage: qlik_request "GET" "/api/v1/apps" "" 
#        qlik_request "POST" "/api/v1/reloads" '{"appId":"xxx"}'

qlik_request() {
  local method="${1:-GET}"
  local endpoint="$2"
  local data="${3:-}"
  local platform=$(detect_platform)
  local base_url=$(get_base_url)
  local xrf_key=""
  local url=""
  
  # Build URL based on platform
  if [[ "$platform" == "onprem" ]] && [[ "$endpoint" == /qrs/* ]]; then
    # QRS API requires XRF key
    xrf_key=$(generate_xrf_key)
    local separator="?"
    [[ "$endpoint" == *"?"* ]] && separator="&"
    url="${base_url}${endpoint}${separator}xrfkey=${xrf_key}"
  else
    url="${base_url}${endpoint}"
  fi
  
  # Build curl command
  local curl_cmd=$(build_curl_cmd)
  
  # Add XRF key header for QRS
  if [[ -n "$xrf_key" ]]; then
    curl_cmd="$curl_cmd -H 'X-Qlik-Xrfkey: ${xrf_key}'"
  fi
  
  # Add method
  curl_cmd="$curl_cmd -X $method"
  
  # Add data for POST/PUT
  if [[ -n "$data" ]] && [[ "$method" != "GET" ]]; then
    curl_cmd="$curl_cmd -d '$data'"
  fi
  
  # Add URL and execute
  curl_cmd="$curl_cmd '$url'"
  
  # Execute and capture response + status
  local response
  response=$(eval "$curl_cmd -w '\n%{http_code}'" 2>/dev/null || echo -e "\n000")
  
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  # Return as JSON with metadata
  echo "{\"body\":$body,\"status\":$status,\"platform\":\"$platform\"}" 2>/dev/null || \
  echo "{\"body\":null,\"status\":$status,\"platform\":\"$platform\",\"raw\":\"$(echo "$body" | head -c 500 | sed 's/"/\\"/g')\"}"
}

# ===== API PATH MAPPING =====
# Maps Cloud API paths to On-Prem equivalents

map_api_path() {
  local endpoint="$1"
  local platform=$(detect_platform)
  
  if [[ "$platform" == "onprem" ]]; then
    case "$endpoint" in
      /api/v1/apps*)     echo "${endpoint/\/api\/v1\/apps/\/qrs\/app}" ;;
      /api/v1/reloads*)  echo "${endpoint/\/api\/v1\/reloads/\/qrs\/reloadtask}" ;;
      /api/v1/spaces*)   echo "${endpoint/\/api\/v1\/spaces/\/qrs\/stream}" ;;
      /api/v1/users*)    echo "${endpoint/\/api\/v1\/users/\/qrs\/user}" ;;
      *)                 echo "$endpoint" ;;  # Keep as-is (some APIs same on both)
    esac
  else
    echo "$endpoint"
  fi
}

# ===== ERROR JSON =====

error_json() {
  local message="$1"
  local platform=$(detect_platform)
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"success\":false,\"platform\":\"$platform\",\"error\":\"$message\",\"timestamp\":\"$timestamp\"}"
}

# ===== SUCCESS JSON =====

success_json() {
  local data="$1"
  local platform=$(detect_platform)
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"success\":true,\"platform\":\"$platform\",\"data\":$data,\"timestamp\":\"$timestamp\"}"
}

# ===== VALIDATE CONFIG =====

validate_config() {
  local platform=$(detect_platform)
  
  if [[ "$platform" == "unknown" ]]; then
    error_json "Configuration required: QLIK_TENANT + QLIK_API_KEY (cloud) or QLIK_SERVER + auth (on-prem)"
    return 1
  fi
  
  if [[ "$platform" == "cloud" ]] && [[ -z "${QLIK_API_KEY:-}" ]]; then
    error_json "QLIK_API_KEY required for Qlik Cloud"
    return 1
  fi
  
  if [[ "$platform" == "onprem" ]]; then
    # Need either certificate or header auth
    if [[ -z "${QLIK_CERT:-}" ]] && [[ -z "${QLIK_USER_DIRECTORY:-}" ]]; then
      error_json "On-premise requires certificate auth (QLIK_CERT + QLIK_KEY) or header auth (QLIK_USER_DIRECTORY + QLIK_USER_ID)"
      return 1
    fi
  fi
  
  return 0
}

# ===== NORMALIZE APP RESPONSE =====
# Converts platform-specific app format to common format

normalize_app() {
  local app_json="$1"
  local platform=$(detect_platform)
  
  if [[ "$platform" == "onprem" ]]; then
    # QRS format → common format
    echo "$app_json" | python3 -c "
import json, sys
app = json.load(sys.stdin)
print(json.dumps({
    'id': app.get('id'),
    'name': app.get('name'),
    'description': app.get('description'),
    'ownerId': app.get('owner', {}).get('id') if isinstance(app.get('owner'), dict) else app.get('owner'),
    'spaceId': app.get('stream', {}).get('id') if isinstance(app.get('stream'), dict) else app.get('stream'),
    'createdDate': app.get('createdDate'),
    'modifiedDate': app.get('modifiedDate'),
    'publishTime': app.get('publishTime'),
    'published': app.get('published', False),
    'streamName': app.get('stream', {}).get('name') if isinstance(app.get('stream'), dict) else None
}))
"
  else
    # Cloud format - already normalized mostly
    echo "$app_json"
  fi
}

# ===== NORMALIZE RELOAD RESPONSE =====

normalize_reload() {
  local reload_json="$1"
  local platform=$(detect_platform)
  
  if [[ "$platform" == "onprem" ]]; then
    echo "$reload_json" | python3 -c "
import json, sys
task = json.load(sys.stdin)

# Map QRS status to common status
status = 'PENDING'
op = task.get('operational', {})
if op.get('lastExecutionResult'):
    result = op['lastExecutionResult']
    s = result.get('status', 0)
    if s == 0 or s == 'Success': status = 'SUCCESS'
    elif s == 1 or s == 'Failed': status = 'FAILED'
    elif s == 2 or s == 'Running': status = 'RUNNING'

print(json.dumps({
    'id': task.get('id'),
    'appId': task.get('app', {}).get('id') if isinstance(task.get('app'), dict) else task.get('app'),
    'status': status,
    'startTime': op.get('lastExecutionResult', {}).get('startTime'),
    'endTime': op.get('lastExecutionResult', {}).get('stopTime'),
    'duration': op.get('lastExecutionResult', {}).get('duration'),
    'log': op.get('lastExecutionResult', {}).get('details'),
    'errorMessage': op.get('lastExecutionResult', {}).get('fileReferenceDetails')
}))
"
  else
    echo "$reload_json"
  fi
}
