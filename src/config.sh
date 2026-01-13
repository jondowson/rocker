#!/usr/bin/env bash
# ============================================================
# Configuration Management
# ============================================================

# Global variables
CURRENT_PROJECT=""
declare -a SELECTED_COMPOSE_FILES=()

# Load context configuration
load_context_config() {
  # Handle special "local" context
  if [[ "$CURRENT_CONTEXT" == "local" ]]; then
    CONTEXT_TYPE="local"
    CONTEXT_DESCRIPTION="Local development"
    REMOTE_HOST=""
    REMOTE_USER=""
    REMOTE_SSH=""
    TUNNEL_PORTS=""

    LOCAL_ROOT_DIR=$(jq -r '.paths.local_root_dir' "$CONFIG_FILE")
    LOCAL_NAMESPACE=$(jq -r '.paths.local_namespace' "$CONFIG_FILE")
    LOCAL_ROOT_DIR="${LOCAL_ROOT_DIR/#\~/$HOME}"
    return 0
  fi

  local context_json
  context_json=$(jq -r --arg name "$CURRENT_CONTEXT" '.contexts[] | select(.name == $name)' "$CONFIG_FILE")

  if [[ -z "$context_json" || "$context_json" == "null" ]]; then
    echo "ERROR: Context '$CURRENT_CONTEXT' not found in config"
    exit 1
  fi

  CONTEXT_TYPE=$(echo "$context_json" | jq -r '.type')
  CONTEXT_DESCRIPTION=$(echo "$context_json" | jq -r '.description // ""')

  if [[ "$CONTEXT_TYPE" == "remote" ]]; then
    REMOTE_HOST=$(echo "$context_json" | jq -r '.host')
    REMOTE_USER=$(echo "$context_json" | jq -r '.user // ""')

    # tunnel_ports are now dynamically discovered, not from config
    TUNNEL_PORTS=""

    REMOTE_SSH="${REMOTE_HOST}"
    if [[ -n "$REMOTE_USER" ]]; then
      REMOTE_SSH="${REMOTE_USER}@${REMOTE_HOST}"
    fi
  else
    # Local context - no remote host or tunnels needed
    REMOTE_HOST=""
    REMOTE_USER=""
    REMOTE_SSH=""
    TUNNEL_PORTS=""
  fi

  LOCAL_ROOT_DIR=$(jq -r '.paths.local_root_dir' "$CONFIG_FILE")
  LOCAL_NAMESPACE=$(jq -r '.paths.local_namespace' "$CONFIG_FILE")

  # Expand tilde
  LOCAL_ROOT_DIR="${LOCAL_ROOT_DIR/#\~/$HOME}"
}

# Infer current project from active Docker context
infer_current_project() {
  local active_context=""

  # Get active Docker context based on machine type
  if [[ "$CONTEXT_TYPE" == "remote" ]]; then
    # Query remote machine's active Docker context with aggressive timeout
    active_context=$(timeout 1 ssh -o ConnectTimeout=1 -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_SSH" "docker context show 2>/dev/null" 2>/dev/null | tr -d '\n' | xargs || echo "")
  else
    # Query local Docker context
    active_context=$(docker context show 2>/dev/null | tr -d '\n' | xargs)
  fi

  if [[ -z "$active_context" ]]; then
    echo ""
    return
  fi

  # Parse project name from context
  # Pattern: colima-{project} or just check if it contains colima-
  if [[ "$active_context" =~ ^colima-(.+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$active_context" == "desktop-linux" || "$active_context" == "default" ]]; then
    # Shared context - no specific project
    echo ""
  else
    # Unknown pattern - could be a custom context
    echo ""
  fi
}

# Load context config and infer project on startup
load_context_config
CURRENT_PROJECT=$(infer_current_project)
