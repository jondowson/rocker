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
# Detects "network not found" errors and recovers by resetting the relevant Docker Compose stack
smart_ssh_run() {
  local remote_ssh="$1"
  local remote_dir="$2"
  local cmd="$3"

  # Use a temporary file to capture output for analysis
  local tmp_out=$(mktemp /tmp/rocker_ssh.XXXXXX)
  
  # 1. Resolve script context ahead of time (so we know what to 'down' if it fails)
  local script_content=""
  if [[ "$cmd" =~ ^npm\ run\ ([^[:space:]]+) ]]; then
    local sname="${BASH_REMATCH[1]}"
    # Use remote jq to find the actual command called by npm
    script_content=$(ssh "$remote_ssh" "bash -l -c \"cd $remote_dir && jq -r '.scripts[\\\"$sname\\\"] // \\\"\\\"' package.json\"" 2>/dev/null || echo "")
  fi

  # Determine targeted recovery command
  local recovery_cmd=""
  local full_ctx="${script_content:-$cmd}"
  if [[ "$full_ctx" == *"docker compose"* ]]; then
    local f_args=$(echo "$full_ctx" | grep -oE "\-f [^[:space:]]+" | tr '\n' ' ')
    recovery_cmd="docker compose $f_args down"
  else
    recovery_cmd="docker compose down"
  fi

  # 2. Execute original command
  # We use tee to show output while capturing it
  ssh -t "$remote_ssh" "bash -l -c \"cd $remote_dir && $cmd\"" 2>&1 | tee "$tmp_out"
  local exit_code=${PIPESTATUS[0]}

  # 3. Detection & Recovery
  # Check for the specific "network not found" error string
  # We look for "failed to set up container networking" as a primary indicator
  if grep -qi "failed to set up container networking" "$tmp_out" || grep -aiE "network .* not found" "$tmp_out" >/dev/null 2>&1; then
    echo ""
    echo -e "${YELLOW}⚠️  Detected stale Docker networking references.${NC}"
    echo -e "${CYAN}   This happens when the network ID changes but containers still hold the old ID.${NC}"
    echo -e "${CYAN}   Attempting automatic 'clean slate' reset...${NC}"
    echo ""
    
    # Run targeted recovery on remote
    echo -e "${BOLD}Running: $recovery_cmd${NC}"
    ssh "$remote_ssh" "bash -l -c \"cd $remote_dir && ($recovery_cmd || true)\"" >/dev/null 2>&1
    
    echo -e ""
    echo -e "${GREEN}✓ Environment reset. Retrying your original command now...${NC}"
    echo ""
    
    # Retry original command
    ssh -t "$remote_ssh" "bash -l -c \"cd $remote_dir && $cmd\""
    exit_code=$?
  fi

  rm -f "$tmp_out"
  return $exit_code
}
