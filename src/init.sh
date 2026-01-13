#!/usr/bin/env bash
# ============================================================
# Initialization & Bootstrap
# ============================================================

# Configuration
CONFIG_FILE="${SCRIPT_DIR}/rocker-config.json"

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for JSON config parsing"
  echo "Install with: brew install jq"
  exit 1
fi

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG_FILE"
  echo "Please create it. See README.md"
  exit 1
fi

# Initialize context by detecting current docker context (no state file)
# Always calculate fresh on startup
current_docker_ctx=$(docker context show 2>/dev/null || echo "default")
docker_endpoint=$(docker context inspect "$current_docker_ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo "")

# Determine what rocker context to use based on actual docker context
if [[ "$docker_endpoint" == ssh://* ]]; then
  # Remote docker context - find matching rocker context
  remote_hostname=$(echo "$docker_endpoint" | sed -E 's|ssh://([^@]+@)?([^:/]+).*|\2|')

  # Try exact match first, then try matching base hostname (without domain)
  rocker_context=""

  # First try exact match
  rocker_context=$(jq -r --arg host "$remote_hostname" '.contexts[] | select(.host == $host) | .name' "$CONFIG_FILE" 2>/dev/null | tr -d '\n' || echo "")

  # If no exact match, try base hostname matching
  if [[ -z "$rocker_context" ]]; then
    # Extract base hostname without domain (zermatt from zermatt.local)
    base_remote="${remote_hostname%%.*}"

    rocker_context=$(jq -r --arg base "$base_remote" '.contexts[] | select(.host != null) | select(.host | startswith($base)) | .name' "$CONFIG_FILE" 2>/dev/null | tr -d '\n' || echo "")
  fi

  if [[ -n "$rocker_context" ]]; then
    CURRENT_CONTEXT="$rocker_context"
  else
    # No matching rocker context found, default to local
    CURRENT_CONTEXT="local"
  fi
else
  # Local docker context
  CURRENT_CONTEXT="local"
fi

# Export context for remote script
export REMOTE_CONTEXT="$CURRENT_CONTEXT"

# Global variable to store selected compose files for port discovery
declare -a SELECTED_COMPOSE_FILES=()
