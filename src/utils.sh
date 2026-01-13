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
    ip=$(ping -c 1 -W 1 "$hostname" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
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
# Detects "network not found" errors and tries to recover by resetting the relevant Docker Compose stack (if applicable)
smart_ssh_run() {
  local remote_ssh="$1"
  local remote_dir="$2"
  local cmd="$3"

  # Use a temporary file to capture output for analysis
  local output_file=$(mktemp /tmp/rocker_output.XXXXXX)
  local exit_code=0

  # Execute command with a login shell, capturing both stdout and stderr
  # We use tee to show output to user while capturing it
  ssh -t "$remote_ssh" "bash -l -c 'cd $remote_dir && $cmd'" 2>&1 | tee "$output_file"
  exit_code=${PIPESTATUS[0]}

  if [[ $exit_code -ne 0 ]]; then
    # Check for specific "network not found" error (be robust against \r and colors)
    if grep -aiE "failed to set up container networking.*network.*not found" "$output_file" >/dev/null 2>&1; then
      echo ""
      echo -e "${YELLOW}⚠️  Detected stale Docker networking issue. Attempting automatic recovery...${NC}"
      
      # Determine the appropriate recovery action
      local recovery_cmd=""
      
      # If it's a docker compose command, try to extract its specific context
      if [[ "$cmd" == *"docker compose"* ]]; then
        # Extract all -f arguments to target the correct compose stack
        local f_args=$(echo "$cmd" | grep -oE "\-f [^[:space:]]+" | tr '\n' ' ')
        recovery_cmd="docker compose $f_args down"
        echo -e "${CYAN}   Identified Docker Compose context. Running recovery: $recovery_cmd${NC}"
      else
        # Generic fallback for other docker commands
        recovery_cmd="docker compose down"
        echo -e "${CYAN}   No specific compose context found. Running generic recovery: $recovery_cmd${NC}"
      fi
      
      # Execute recovery on remote host
      ssh "$remote_ssh" "bash -l -c 'cd $remote_dir && ($recovery_cmd || true)'" >/dev/null 2>&1
      
      echo -e "${CYAN}   Retrying original command...${NC}"
      echo ""
      ssh -t "$remote_ssh" "bash -l -c 'cd $remote_dir && $cmd'"
      exit_code=$?
    fi
  fi

  rm -f "$output_file"
  return $exit_code
}
