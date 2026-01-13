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
# Proactively checks for networking issues and handles "network not found" errors
smart_ssh_run() {
  local remote_ssh="$1"
  local remote_dir="$2"
  local cmd="$3"

  local resolved_cmd="$cmd"
  
  # 1. RESOLVE NPM SCRIPTS (if applicable)
  if [[ "$cmd" =~ ^npm\ run\ ([^[:space:]]+) ]]; then
    local script_name="${BASH_REMATCH[1]}"
    local remote_resolve_cmd="jq -r '.scripts[\"$script_name\"] // \"\"' package.json"
    resolved_cmd=$(ssh "$remote_ssh" "bash -l -c 'cd $remote_dir && $remote_resolve_cmd'" 2>/dev/null || echo "")
  fi

  # 2. PROACTIVE HEALTH CHECK
  # If we're doing a "up" or "run" or "restart", check for stale containers first
  if [[ "$resolved_cmd" == *"docker compose"* ]] && [[ "$resolved_cmd" =~ (up|start|restart) ]]; then
    # Extract all -f arguments to target the correct compose stack
    local f_args=$(echo "$resolved_cmd" | grep -oE "\-f [^[:space:]]+" | tr '\n' ' ')
    
    # Check if any container in this stack is in a broken state
    # We look for "failed to set up container networking" in the container's error log
    local broken_containers=$(ssh "$remote_ssh" "bash -l -c \"cd $remote_dir && \
      docker compose $f_args ps -a --format json\"" 2>/dev/null | jq -r 'select(.State == "exited" or .State == "created") | .Name' || echo "")
    
    if [[ -z "$broken_containers" ]]; then
       # Fallback: check project wide if ID-based compose ps didn't work
       broken_containers=$(ssh "$remote_ssh" "docker ps -a --filter 'status=exited' --filter 'status=created' --format '{{.Names}}'" 2>/dev/null)
    fi

    if [[ -n "$broken_containers" ]]; then
      # Test one broken container for the specific networking error
      for container in $broken_containers; do
        if ssh "$remote_ssh" "docker inspect $container --format '{{.State.Error}}'" 2>/dev/null | grep -qi "network.*not found"; then
          echo -e "${YELLOW}⚠️  Proactive check detected stale Docker network for: $container${NC}"
          echo -e "${CYAN}   Refreshing environment for a clean slate...${NC}"
          ssh "$remote_ssh" "bash -l -c 'cd $remote_dir && docker compose $f_args down'" >/dev/null 2>&1
          break
        fi
      done
    fi
  fi

  # 3. EXECUTE ORIGINAL COMMAND
  local output_file=$(mktemp /tmp/rocker_output.XXXXXX)
  local clean_file=$(mktemp /tmp/rocker_clean.XXXXXX)
  local exit_code=0

  ssh -t "$remote_ssh" "bash -l -c 'cd $remote_dir && $cmd'" 2>&1 | tee "$output_file"
  exit_code=${PIPESTATUS[0]}

  # 4. REACTIVE FALLBACK (if proactive check missed it or TTY noise masked it)
  tr -cd '\11\12\40-\176' < "$output_file" | sed 's/\r//g' > "$clean_file"

  if [[ $exit_code -ne 0 ]]; then
    if grep -qi "network" "$clean_file" && grep -qi "not found" "$clean_file"; then
      echo ""
      echo -e "${YELLOW}⚠️  Detected networking issue during execution. Attempting recovery...${NC}"
      
      local recovery_cmd=""
      if [[ "$resolved_cmd" == *"docker compose"* ]]; then
        local f_args=$(echo "$resolved_cmd" | grep -oE "\-f [^[:space:]]+" | tr '\n' ' ')
        recovery_cmd="docker compose $f_args down"
      else
        recovery_cmd="docker compose down"
      fi
      
      ssh "$remote_ssh" "bash -l -c 'cd $remote_dir && ($recovery_cmd || true)'" >/dev/null 2>&1
      echo -e "${CYAN}   Retrying...${NC}"
      echo ""
      ssh -t "$remote_ssh" "bash -l -c 'cd $remote_dir && $cmd'"
      exit_code=$?
    fi
  fi

  rm -f "$output_file" "$clean_file"
  return $exit_code
}
