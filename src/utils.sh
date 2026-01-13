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
smart_ssh_run() {
  local remote_ssh="$1"
  local remote_dir="$2"
  local cmd="$3"

  # Use a temporary file to capture output for analysis
  local output_file=$(mktemp /tmp/rocker_output.XXXXXX)
  local exit_code=0

  # Execute command with a login shell, capturing both stdout and stderr
  # Use script(1) or similar if TTY behavior is needed, but for now we'll stick to direct ssh -t
  # We use tee to show output to user while capturing it
  ssh -t "$remote_ssh" "bash -l -c 'cd $remote_dir && $cmd'" 2>&1 | tee "$output_file"
  exit_code=${PIPESTATUS[0]}

  if [[ $exit_code -ne 0 ]]; then
    # Check for specific "network not found" error
    if grep -q "failed to set up container networking: network .* not found" "$output_file"; then
      echo ""
      echo -e "${YELLOW}⚠️  Detected stale Docker networking issue. Attempting automatic recovery...${NC}"
      echo -e "${CYAN}   Stopping local-tools/dev stacks to reset networks...${NC}"
      
      # Attempt recovery: run compose down to clear stale network references
      # We try both common compose file locations
      ssh "$remote_ssh" "bash -l -c 'cd $remote_dir && (docker compose down || true)'" >/dev/null 2>&1
      
      echo -e "${CYAN}   Retrying original command...${NC}"
      echo ""
      ssh -t "$remote_ssh" "bash -l -c 'cd $remote_dir && $cmd'"
      exit_code=$?
    fi
  fi

  rm -f "$output_file"
  return $exit_code
}
