#!/usr/bin/env bash
# ============================================================
# General Utility Functions
# ============================================================

# Get IP address for hostname
get_ip_address() {
  local hostname="$1"

  # Try getent first (Linux)
  local ip=$(getent hosts "$hostname" 2>/dev/null | awk '{ print $1; exit }')

  if [[ -z "$ip" ]]; then
    # Try dscacheutil on macOS
    ip=$(dscacheutil -q host -a name "$hostname" 2>/dev/null | awk '/^ip_address:/ { print $2; exit }')
  fi

  if [[ -z "$ip" ]]; then
    # Try dns-sd for mDNS .local hostnames on macOS
    ip=$(dns-sd -G v4 "$hostname" 2>/dev/null | awk '/^.*Addr/ { print $7; exit }' &)
    local dns_pid=$!
    sleep 0.5
    kill "$dns_pid" 2>/dev/null
    wait "$dns_pid" 2>/dev/null
  fi

  if [[ -z "$ip" ]]; then
    # Final fallback: try ping to resolve
    ip=$(ping -c 1 -W 1 "$hostname" 2>/dev/null | head -1 | grep -oE -- '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  fi

  echo "$ip"
}

# Print header banner
print_header() {
  echo -e "${BLUE}${BOLD}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "ROCKER - Remote Docker Manager"
  echo -e "${NC}${CYAN}"
  echo "1 - Select docker context."
  echo "    --> ssh tunnel auto created for remote machines."
  echo "2 - Develop locally and sync with 'syncthing'."
  echo "    --> remote services now accessible locally via ssh tunnel."
  echo "    --> use command browser to easily run remote commands."
  echo -e "${BLUE}${BOLD}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
}

# Confirmation prompt
confirm() {
  local prompt="$1"
  local response
  echo -e "${YELLOW}${prompt} (yes/no):${NC}"
  read -r response
  [[ "$response" =~ ^[Yy][Ee][Ss]$ ]]
}

# Press enter to continue
press_enter() {
  echo ""
  echo -e "${CYAN}Press Enter to continue...${NC}"
  read -r
}

# Smart SSH execution with automatic recovery for common errors
# Detects "network not found" errors by querying Docker directly when a command fails
smart_ssh_run() {
  local remote_ssh="$1"
  local remote_dir="$2"
  local cmd="$3"

  # 1. Resolve script context (extract which compose files are being used)
  local script_content=""
  if [[ "$cmd" =~ ^npm\ run\ ([^[:space:]]+) ]]; then
    local sname="${BASH_REMATCH[1]}"
    script_content=$(ssh "$remote_ssh" "bash -l -c \"cd $remote_dir && jq -r '.scripts[\\\"$sname\\\"] // \\\"\\\"' package.json\"" 2>/dev/null || echo "")
  fi

  local full_ctx="${script_content:-$cmd}"
  local f_args=""
  if [[ "$full_ctx" == *"docker compose"* ]]; then
    f_args=$(echo "$full_ctx" | grep -oE -- "-f [^[:space:]]+" | tr '\n' ' ')
  fi

  # 2. Execute original command
  # We use '|| exit_code=$?' to prevent 'set -e' from aborting the script on failure
  local exit_code=0
  ssh -t "$remote_ssh" "bash -l -c \"cd $remote_dir && $cmd\"" || exit_code=$?

  # 3. Detection & Recovery (only if command failed)
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    echo -e "${YELLOW}🔍 Command failed (exit: $exit_code). checking for environmental issues...${NC}"
    
    # Check for networking errors in the containers of this stack
    # We query Docker directly so results aren't affected by TTY noise
    local networking_error_found=false
    
    # Get names of all containers in this stack (handling both compose v2 and legacy styles)
    local container_names=$(ssh "$remote_ssh" "bash -l -c \"cd $remote_dir && docker compose $f_args ps -a --format '{{.Name}}'\"" 2>/dev/null || echo "")
    
    if [[ -n "$container_names" ]]; then
      for container in $container_names; do
        # Inspect each container for the specific "network not found" error state
        # We also check for 'endpoint with name ... already exists' which is related
        local error_msg=$(ssh "$remote_ssh" "docker inspect $container --format '{{.State.Error}}'" 2>/dev/null || echo "")
        if [[ "$error_msg" =~ "network" && "$error_msg" =~ "not found" ]] || [[ "$error_msg" =~ "endpoint" && "$error_msg" =~ "already exists" ]]; then
          networking_error_found=true
          echo -e "${YELLOW}⚠️  Detected stale networking reference in container: $container${NC}"
          echo -e "${RED}   Error: $error_msg${NC}"
          break
        fi
      done
    fi

    if [ "$networking_error_found" = true ]; then
      echo -e "${CYAN}   This is a known Docker issue where containers hold onto old Network IDs.${NC}"
      echo -e "${CYAN}   Attempting automatic 'clean slate' reset for this project...${NC}"
      echo ""
      
      local recovery_cmd="docker compose $f_args down"
      echo -e "${BOLD}Running: $recovery_cmd${NC}"
      ssh "$remote_ssh" "bash -l -c \"cd $remote_dir && ($recovery_cmd || true)\"" >/dev/null 2>&1
      
      echo -e ""
      echo -e "${GREEN}✓ Done. Environment reset.${NC}"
      echo -e "${CYAN}   Retrying original command...${NC}"
      echo ""
      
      # Retry original command
      ssh -t "$remote_ssh" "bash -l -c \"cd $remote_dir && $cmd\""
      exit_code=$?
    fi
  fi

  # 4. Trigger Tunnel Refresh (if it was an 'up', 'start', or 'restart' command)
  # Only refresh if the command was successful and the tunnel function is available
  if [[ $exit_code -eq 0 ]] && [[ "$cmd" =~ (up|start|restart) ]]; then
    if command -v tunnel_start >/dev/null 2>&1; then
      echo ""
      echo -e "${CYAN}🚀 New services may be active. Refreshing SSH tunnel...${NC}"
      # Run in background to avoid blocking the UI, but with a small delay
      # to ensure Docker has finished its internal networking setup
      (sleep 2 && tunnel_start >/dev/null 2>&1) &
      disown
      echo -e "${GREEN}✓ Tunnel refresh triggered.${NC}"
    fi
  fi

  return $exit_code
}
