#!/bin/bash
# Qlik Common Library - Shared functions for Cloud & On-Premise
# Source this in other scripts: source "$(dirname "$0")/lib/qlik-common.sh"

set -euo pipefail

# ===== PLATFORM DETECTION =====

detect_platform() {
  # On-prem uses QLIK_SERVER, cloud uses QLIK_TENANT
  if [[ -n "${QLIK_SERVER:-}" ]]; then
    echo "onprem"
  elif [[ -n "${QLIK_TENANT:-}" ]]; then
    echo "cloud"
  else
    echo "unknown"
  fi
}

# ===== URL BUILDING =====

get_base_url() {
  local platform=$(detect_platform)
  
  if [[ "$platform" == "cloud" ]]; then
    local tenant="${QLIK_TENANT%/}"
    [[ "$tenant" != http* ]] && tenant="https://$tenant"
    echo "$tenant"
  elif [[ "$platform" == "onprem" ]]; then
    local server="${QLIK_SERVER%/}"
    [[ "$server" != http* ]] && server="https://$server"
    # Add virtual proxy if configured
    if [[ -n "${QLIK_VIRTUAL_PROXY:-}" ]]; then
      server="$server/${QLIK_VIRTUAL_PROXY}"
    fi
    echo "$server"
  fi
}

# ===== XRF KEY (On-Prem) =====

generate_xrfkey() {
  # Generate 16-char alphanumeric key for QRS API
  cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

# ===== AUTH HEADERS =====

get_auth_args() {
  local platform=$(detect_platform)
  
  if [[ "$platform" == "cloud" ]]; then
    # Cloud: Bearer token
    echo "-H \"Authorization: Bearer ${QLIK_API_KEY}\""
  elif [[ "$platform" == "onprem" ]]; then
    local xrfkey=$(generate_xrfkey)
    local args=""
    
    # Certificate auth
    if [[ -n "${QLIK_CERT:-}" ]] && [[ -n "${QLIK_KEY:-}" ]]; then
      args="--cert \"${QLIK_CERT}\" --key \"${QLIK_KEY}\" --insecure"
    fi
    
    # Header auth (user directory + user id)
    if [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && [[ -n "${QLIK_USER_ID:-}" ]]; then
      args="$args -H \"X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}\""
    fi
    
    # XRF key header (required for all QRS calls)
    args="$args -H \"X-Qlik-Xrfkey: $xrfkey\""
    
    echo "$args"
  fi
}

get_xrfkey_param() {
  # Returns ?xrfkey=xxx or &xrfkey=xxx for on-prem
  local platform=$(detect_platform)
  
  if [[ "$platform" == "onprem" ]]; then
    local xrfkey=$(generate_xrfkey)
    echo "xrfkey=$xrfkey"
  else
    echo ""
  fi
}

# ===== API PATH MAPPING =====

get_api_path() {
  local resource="$1"
  local platform=$(detect_platform)
  
  if [[ "$platform" == "cloud" ]]; then
    case "$resource" in
      apps)     echo "/api/v1/apps" ;;
      app)      echo "/api/v1/apps" ;;
      reloads)  echo "/api/v1/reloads" ;;
      spaces)   echo "/api/v1/spaces" ;;
      users)    echo "/api/v1/users" ;;
      items)    echo "/api/v1/items" ;;
      *)        echo "/api/v1/$resource" ;;
    esac
  elif [[ "$platform" == "onprem" ]]; then
    case "$resource" in
      apps)     echo "/qrs/app" ;;
      app)      echo "/qrs/app" ;;
      reloads)  echo "/qrs/reloadtask" ;;
      spaces)   echo "/qrs/stream" ;;  # Streams = Spaces in on-prem
      streams)  echo "/qrs/stream" ;;
      users)    echo "/qrs/user" ;;
      *)        echo "/qrs/$resource" ;;
    esac
  fi
}

# ===== CURL WRAPPER =====

qlik_curl() {
  local method="${1:-GET}"
  local path="$2"
  shift 2
  local extra_args="$@"
  
  local platform=$(detect_platform)
  local base_url=$(get_base_url)
  local url="${base_url}${path}"
  
  # Add xrfkey for on-prem
  if [[ "$platform" == "onprem" ]]; then
    local xrfkey=$(generate_xrfkey)
    if [[ "$url" == *"?"* ]]; then
      url="${url}&xrfkey=${xrfkey}"
    else
      url="${url}?xrfkey=${xrfkey}"
    fi
  fi
  
  # Build curl command
  local curl_cmd="curl -sL -X $method"
  
  # Add auth
  if [[ "$platform" == "cloud" ]]; then
    curl_cmd="$curl_cmd -H \"Authorization: Bearer ${QLIK_API_KEY}\""
  elif [[ "$platform" == "onprem" ]]; then
    # Certificate auth
    if [[ -n "${QLIK_CERT:-}" ]] && [[ -n "${QLIK_KEY:-}" ]]; then
      curl_cmd="$curl_cmd --cert \"${QLIK_CERT}\" --key \"${QLIK_KEY}\" --insecure"
    fi
    # Header auth
    if [[ -n "${QLIK_USER_DIRECTORY:-}" ]] && [[ -n "${QLIK_USER_ID:-}" ]]; then
      curl_cmd="$curl_cmd -H \"X-Qlik-User: UserDirectory=${QLIK_USER_DIRECTORY}; UserId=${QLIK_USER_ID}\""
    fi
    # XRF key header
    curl_cmd="$curl_cmd -H \"X-Qlik-Xrfkey: ${xrfkey}\""
  fi
  
  # Common headers
  curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
  
  # Add extra args and URL
  curl_cmd="$curl_cmd $extra_args \"$url\""
  
  # Execute
  eval $curl_cmd
}

# ===== VALIDATION =====

validate_config() {
  local platform=$(detect_platform)
  
  if [[ "$platform" == "unknown" ]]; then
    echo "{\"success\":false,\"error\":\"Configuration required: QLIK_TENANT + QLIK_API_KEY (cloud) or QLIK_SERVER + auth (on-prem)\"}"
    return 1
  fi
  
  if [[ "$platform" == "cloud" ]]; then
    if [[ -z "${QLIK_API_KEY:-}" ]]; then
      echo "{\"success\":false,\"error\":\"QLIK_API_KEY required for Qlik Cloud\"}"
      return 1
    fi
  elif [[ "$platform" == "onprem" ]]; then
    # Need either certificate or header auth
    if [[ -z "${QLIK_CERT:-}" ]] && [[ -z "${QLIK_USER_DIRECTORY:-}" ]]; then
      echo "{\"success\":false,\"error\":\"On-premise requires QLIK_CERT+QLIK_KEY or QLIK_USER_DIRECTORY+QLIK_USER_ID\"}"
      return 1
    fi
  fi
  
  return 0
}

# ===== JSON HELPERS =====

json_error() {
  local msg="$1"
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"success\":false,\"error\":\"$msg\",\"timestamp\":\"$timestamp\"}"
}

json_success() {
  local data="$1"
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"success\":true,\"data\":$data,\"platform\":\"$(detect_platform)\",\"timestamp\":\"$timestamp\"}"
}
