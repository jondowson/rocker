#!/usr/bin/env bash
# SSH Tunnel Operations

# ============================================================
# SSH Tunnel Management
# ============================================================

tunnel_status() {
  # Check if tunnel ports are actually listening (more reliable than process matching)
  local ports_listening=0
  local ports_checked=0

  for port_map in $TUNNEL_PORTS; do
    local local_port=$(echo "$port_map" | cut -d: -f1)
    if lsof -nP -iTCP:${local_port} -sTCP:LISTEN >/dev/null 2>&1; then
      ports_listening=$((ports_listening + 1))
    fi
    ports_checked=$((ports_checked + 1))
  done

  if [[ $ports_listening -eq $ports_checked && $ports_checked -gt 0 ]]; then
    echo -e "${GREEN}✓ SSH tunnel is running${NC}"
    echo "   Listening ports: $TUNNEL_PORTS"
    # Show the SSH control master or tunnel process
    local ssh_pid=$(lsof -nP -iTCP:$(echo "$TUNNEL_PORTS" | cut -d' ' -f1 | cut -d: -f1) -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $2}')
    if [[ -n "$ssh_pid" ]]; then
      echo "   Process: $(ps -p $ssh_pid -o args= 2>/dev/null || echo 'unknown')"
    fi
    return 0
  else
    echo -e "${RED}✗ SSH tunnel is NOT running${NC}"
    if [[ $ports_listening -gt 0 ]]; then
      echo "   ($ports_listening of $ports_checked ports listening)"
    fi
    return 1
  fi
}

tunnel_start() {
  # If SELECTED_COMPOSE_FILES is empty, prompt user to select project and compose files
  if [[ ${#SELECTED_COMPOSE_FILES[@]} -eq 0 ]] && [[ -n "$LOCAL_NAMESPACE" ]] && [[ "$CONTEXT_TYPE" == "remote" ]]; then
    echo -e "${YELLOW}No compose files selected. Let's select which project to tunnel.${NC}"
    echo ""

    # STEP 1: Ask user to select project
    echo -e "${BOLD}Select Project for Remote Development:${NC}"
    echo ""

    local -a projects=()
    local project_path="${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}"

    if [[ -d "$project_path" ]]; then
      local idx=1
      while IFS= read -r dir; do
        local project_name=$(basename "$dir")
        projects+=("$project_name")
        echo "$idx) $project_name"
        ((idx++))
      done < <(find "$project_path" -mindepth 1 -maxdepth 1 -type d | sort)

      echo ""
      echo -n "Select project: "
      read -r proj_choice

      if [[ "$proj_choice" =~ ^[0-9]+$ ]] && [[ $proj_choice -ge 1 ]] && [[ $proj_choice -lt $idx ]]; then
        CURRENT_PROJECT="${projects[$((proj_choice-1))]}"
        echo ""
        echo -e "${GREEN}✓ Selected project: $CURRENT_PROJECT${NC}"

        # STEP 2: Ask user to select compose file(s)
        echo ""
        echo -e "${BOLD}Select Compose File(s):${NC}"
        echo ""

        local -a compose_files=()
        local project_full_path="${project_path}/${CURRENT_PROJECT}"

        # Find all compose files in project
        while IFS= read -r compose_file; do
          compose_files+=("$compose_file")
        done < <(find "$project_full_path" -maxdepth 5 -type f \( -name "compose.yml" -o -name "compose.yaml" -o -name "docker-compose.yml" -o -name "docker-compose.yaml" \) 2>/dev/null | sort)

        if [[ ${#compose_files[@]} -gt 0 ]]; then
          echo "1) All compose files (${#compose_files[@]} found)"
          local idx=2
          for compose_file in "${compose_files[@]}"; do
            local relative_path="${compose_file#$project_full_path/}"
            echo "$idx) $relative_path"
            ((idx++))
          done

          echo ""
          echo -n "Select compose file: "
          read -r compose_choice

          if [[ "$compose_choice" == "1" ]]; then
            # Use all compose files
            SELECTED_COMPOSE_FILES=("${compose_files[@]}")
            echo ""
            echo -e "${GREEN}✓ Using all ${#compose_files[@]} compose files${NC}"
          elif [[ "$compose_choice" =~ ^[0-9]+$ ]] && [[ $compose_choice -ge 2 ]] && [[ $compose_choice -lt $idx ]]; then
            # Use specific compose file
            SELECTED_COMPOSE_FILES=("${compose_files[$((compose_choice-2))]}")
            echo ""
            echo -e "${GREEN}✓ Using: ${compose_files[$((compose_choice-2))]}${NC}"
          fi
        else
          echo -e "${YELLOW}No compose files found in project${NC}"
          SELECTED_COMPOSE_FILES=()
        fi
      fi
    fi

    echo ""
  fi

  echo "Starting SSH tunnel..."
  echo ""

  # Generate dynamic tunnel mappings from local compose files
  echo "1. Discovering ports from local compose files..."
  if [[ -n "$CURRENT_PROJECT" ]]; then
    echo "   Project: ${CYAN}${CURRENT_PROJECT}${NC}"
  fi
  if [[ ${#SELECTED_COMPOSE_FILES[@]} -gt 0 ]]; then
    echo "   Using ${#SELECTED_COMPOSE_FILES[@]} compose file(s)"
  fi
  local -a tunnel_mappings=()
  while IFS= read -r mapping; do
    tunnel_mappings+=("$mapping")
  done < <(generate_tunnel_mappings "$REMOTE_SSH")

  if [[ ${#tunnel_mappings[@]} -eq 0 ]]; then
    echo -e "   ${YELLOW}⚠ No ports found in local compose files${NC}"
    echo -e "   ${CYAN}→ Tunnel will start without port forwards${NC}"
    echo -e "   ${CYAN}→ Add ports to compose files to enable forwarding${NC}"
    TUNNEL_PORTS=""
  else
    # Convert array to space-separated string for TUNNEL_PORTS
    TUNNEL_PORTS="${tunnel_mappings[*]}"
    echo -e "   ${GREEN}✓ Found ${#tunnel_mappings[@]} port(s) from compose files${NC}"
  fi

  # Always clean up any existing tunnels first
  echo ""
  echo "2. Checking for existing tunnels..."
  if pgrep -f "ssh.*-N.*${REMOTE_HOST}" >/dev/null 2>&1; then
    echo "   Found existing tunnel(s), stopping them first..."
    pkill -f "ssh.*-N.*${REMOTE_HOST}" 2>/dev/null || true
    sleep 1
    # Force kill if still running
    if pgrep -f "ssh.*-N.*${REMOTE_HOST}" >/dev/null 2>&1; then
      echo "   Force killing..."
      pkill -9 -f "ssh.*-N.*${REMOTE_HOST}" 2>/dev/null || true
      sleep 1
    fi
    echo "   ✓ Old tunnels cleared"
  else
    echo "   ✓ No existing tunnels found"
  fi

  echo ""
  echo "3. Testing SSH connection to $REMOTE_SSH..."
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_SSH" "echo test" >/dev/null 2>&1; then
    echo -e "   ${RED}✗ Cannot connect to $REMOTE_SSH${NC}"
    echo ""
    echo "   Attempting connection with error output:"
    ssh -o ConnectTimeout=5 "$REMOTE_SSH" "echo test"
    return 1
  fi
  echo "   ✓ SSH connection works"

  echo ""
  if [[ ${#tunnel_mappings[@]} -gt 0 ]]; then
    echo "4. Starting tunnel with ${#tunnel_mappings[@]} port mappings..."
  else
    echo "4. Starting tunnel (no port forwards yet)..."
  fi

  # Build tunnel command arguments
  local -a tunnel_args=()
  if [[ -n "$TUNNEL_PORTS" ]]; then
    for port_map in $TUNNEL_PORTS; do
      tunnel_args+=(-L "$port_map")
    done
  fi

  # Add keepalive and reliability options
  tunnel_args+=(-o ServerAliveInterval=30)      # Send keepalive every 30 seconds
  tunnel_args+=(-o ServerAliveCountMax=3)       # Disconnect after 3 failed keepalives (90s timeout)
  tunnel_args+=(-o TCPKeepAlive=yes)            # Enable TCP-level keepalives
  tunnel_args+=(-o ConnectTimeout=10)           # Connection timeout
  tunnel_args+=(-o ConnectionAttempts=3)        # Retry connection attempts
  tunnel_args+=(-v)  # Verbose to capture port forward failures
  tunnel_args+=(-f)  # Fork to background AFTER authentication
  tunnel_args+=(-N)  # No remote command
  tunnel_args+=("$REMOTE_SSH")

  # Debug: show the actual command
  echo "   Command: ssh ${tunnel_args[*]}"

  # Create a temporary log file for SSH errors
  local log_file=$(mktemp /tmp/rocker-tunnel.XXXXXX)

  # Start tunnel - ssh -f will fork to background after connecting
  echo "   Connecting and establishing tunnel..."
  if ssh "${tunnel_args[@]}" 2>"$log_file"; then
    echo -e "   ${GREEN}✓ SSH tunnel forked to background${NC}"
  else
    echo -e "   ${RED}✗ Failed to establish SSH tunnel${NC}"
    echo ""
    if [[ -s "$log_file" ]]; then
      echo "   Error output:"
      cat "$log_file"
    else
      echo "   No error output"
    fi
    rm -f "$log_file"
    return 1
  fi

  sleep 2

  # Check for port forward failures in the log
  if [[ -s "$log_file" ]]; then
    local failed_binds=$(grep -i "bind.*failed\|cannot listen" "$log_file" || true)
    if [[ -n "$failed_binds" ]]; then
      echo -e "   ${YELLOW}⚠ Some port forwards may have failed:${NC}"
      echo "$failed_binds" | sed 's/^/     /' | head -5
      echo ""
    fi
  fi

  # Check if tunnel is working
  if tunnel_status_check; then
    echo -e "   ${GREEN}✓ SSH tunnel process started${NC}"
    echo ""

    if [[ ${#tunnel_mappings[@]} -gt 0 ]]; then
      # Count how many ports are actually listening FROM SSH TUNNEL
      local listening_count=0
      for port_map in $TUNNEL_PORTS; do
        local local_port=$(echo "$port_map" | cut -d: -f1 || echo "")
        [[ -z "$local_port" ]] && continue

        # Check if SSH process is holding this port (not just any process)
        if lsof -nP -iTCP:${local_port} -sTCP:LISTEN 2>/dev/null | grep -q "ssh"; then
          listening_count=$((listening_count + 1))
        fi
      done

      echo "   Active forwards: ${listening_count}/${#tunnel_mappings[@]} ports"
    else
      echo "   No port forwards (no ports in compose files)"
      echo "   Tunnel established for SSH access"
    fi
    echo ""
    echo "Return to tunnel management to view detailed port status."
    rm -f "$log_file"
  else
    echo -e "   ${RED}✗ Tunnel process running but not detected${NC}"
    if [[ -s "$log_file" ]]; then
      echo ""
      echo "   Error output:"
      cat "$log_file"
    fi
    rm -f "$log_file"
    return 1
  fi
}

tunnel_stop() {
  echo "Stopping SSH tunnel..."

  # Kill all SSH processes with port forwarding to the current remote host
  local ssh_pids=$(pgrep -f "ssh.*-N.*${REMOTE_HOST}" || true)

  if [[ -z "$ssh_pids" ]]; then
    echo "No tunnel running."
    return 0
  fi

  # Kill each SSH tunnel process
  for pid in $ssh_pids; do
    echo "   Killing SSH tunnel process (PID: $pid)"
    kill "$pid" 2>/dev/null || true
  done

  sleep 1

  # Check if any tunnels are still running
  if pgrep -f "ssh.*-N.*${REMOTE_HOST}" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Some tunnel processes still running${NC}"
    echo "   Trying force kill..."
    pkill -9 -f "ssh.*-N.*${REMOTE_HOST}" 2>/dev/null || true
    sleep 1
    if pgrep -f "ssh.*-N.*${REMOTE_HOST}" >/dev/null 2>&1; then
      echo -e "${RED}✗ Could not stop all tunnels${NC}"
    else
      echo -e "${GREEN}✓ SSH tunnel stopped${NC}"
    fi
  else
    echo -e "${GREEN}✓ SSH tunnel stopped${NC}"
  fi
}

# Simple check if tunnel is running (for use in conditionals)
tunnel_status_check() {
  # Check if any SSH tunnel process exists for this remote host
  # Look for ssh with -N flag (no command execution) which indicates a tunnel
  pgrep -f "ssh.*-N.*${REMOTE_HOST}" >/dev/null 2>&1
}

# Detailed tunnel status display
tunnel_status_detailed() {
  echo ""
  echo -e "${BOLD}Detailed Tunnel Status${NC}"
  echo ""

  if tunnel_status_check; then
    echo -e "${GREEN}✓ SSH tunnel is running${NC}"
    echo ""

    # Show the SSH process(es)
    local ssh_pids=$(pgrep -f "ssh.*-N.*${REMOTE_HOST}" || true)

    if [[ -n "$ssh_pids" ]]; then
      for pid in $ssh_pids; do
        echo "Process ID: $pid"
        echo "Command: $(ps -p $pid -o args= 2>/dev/null || echo 'unknown')"
      done
    fi
  else
    echo -e "${RED}✗ SSH tunnel is NOT running${NC}"
  fi
  echo ""
}

tunnel_menu() {
  while true; do
    clear
    print_header
    echo -e "${BOLD}SSH Tunnel Management${NC}"
    echo ""

    # Get all remote contexts from config
    local -a remote_contexts=()
    local -a remote_hosts=()
    local -a remote_users=()

    while IFS='|' read -r name host user; do
      if [[ -n "$name" ]]; then
        remote_contexts+=("$name")
        remote_hosts+=("$host")
        remote_users+=("$user")
      fi
    done < <(jq -r '.contexts[] | select(.type == "remote") | "\(.name)|\(.host)|\(.user // "")"' "$CONFIG_FILE" 2>/dev/null)

    if [[ ${#remote_contexts[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No remote contexts configured${NC}"
      echo ""
      echo "Add remote contexts to rocker-config.json"
      echo ""
      press_enter
      return
    fi

    # Display all remote hosts and their tunnel status
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}REMOTE HOSTS & TUNNEL STATUS${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Header
    printf "${BOLD}%-3s %-20s %-22s %-12s %s${NC}\n" "#" "Context Name" "Host" "Status" "Ports"
    echo "────────────────────────────────────────────────────────────────────────"

    # Display each remote host
    for i in "${!remote_contexts[@]}"; do
      local ctx_name="${remote_contexts[$i]}"
      local ctx_host="${remote_hosts[$i]}"
      local display_idx=$((i + 1))

      # Check if tunnel is running for this host
      local ssh_pids=$(pgrep -f "ssh.*-N.*${ctx_host}" 2>/dev/null || true)

      if [[ -n "$ssh_pids" ]]; then
        # Tunnel is running - extract port mappings (safe grep for macOS)
        local ssh_pid=$(echo "$ssh_pids" | tr -d '\n' | awk '{print $1}')
        local ssh_cmd=$(ps -p "$ssh_pid" -o args= 2>/dev/null || echo "")
        local port_count=$(echo "$ssh_cmd" | grep -oE -- '-L [0-9]+:localhost:[0-9]+' | wc -l | xargs)
        local first_mapping=$(echo "$ssh_cmd" | grep -oE -- '-L [0-9]+:localhost:[0-9]+' | head -1 | sed 's/-L //' || echo "")

        printf "${BOLD}%-3s${NC} %-20s %-22s " "$display_idx" "$ctx_name" "$ctx_host"
        echo -e -n "${GREEN}● Active${NC}        "
        echo -e "${CYAN}${port_count} ports${NC} ${DIM}(${first_mapping}...)${NC}"
      else
        printf "${BOLD}%-3s${NC} %-20s %-22s " "$display_idx" "$ctx_name" "$ctx_host"
        echo -e -n "${DIM}○ Inactive${NC}      "
        echo -e "${DIM}n/a${NC}"
      fi
    done

    echo ""
    echo -e "${BOLD}Actions:${NC} Select host number (#) or press Enter to return"
    echo ""
    echo -n "Select host: "
    read -r host_num

    if [[ -z "$host_num" || "$host_num" == "0" ]]; then
      return
    fi

    if [[ "$host_num" =~ ^[0-9]+$ ]] && [[ $host_num -ge 1 ]] && [[ $host_num -le ${#remote_contexts[@]} ]]; then
      local selected_idx=$((host_num - 1))
      local selected_name="${remote_contexts[$selected_idx]}"
      local selected_host="${remote_hosts[$selected_idx]}"
      local selected_user="${remote_users[$selected_idx]}"
      local selected_ssh="$selected_host"
      [[ -n "$selected_user" ]] && selected_ssh="${selected_user}@${selected_host}"

      while true; do
        clear
        print_header
        echo -e "${BOLD}Host Actions: ${selected_name} (${selected_host})${NC}"
        echo ""
        
        # Current status
        if pgrep -f "ssh.*-N.*${selected_host}" >/dev/null 2>&1; then
          echo -e "Status: ${GREEN}● Tunnel Active${NC}"
        else
          echo -e "Status: ${DIM}○ Tunnel Inactive${NC}"
        fi
        echo ""
        echo "1) Start tunnel"
        echo "2) Stop tunnel"
        echo "3) Restart (Refresh port mappings)"
        echo "4) Show detailed port mappings"
        echo ""
        echo "(Press Enter to return to host list)"
        echo ""
        echo -n "Select action: "
        read -r action_choice

        case "$action_choice" in
          1) # Start
            echo ""
            if pgrep -f "ssh.*-N.*${selected_host}" >/dev/null 2>&1; then
              echo -e "${YELLOW}Tunnel already running.${NC}"
            else
              echo "Starting tunnel..."
              # Need to set REMOTE_SSH for tunnel_start to work
              REMOTE_SSH="$selected_ssh"
              REMOTE_HOST="$selected_host"
              tunnel_start
            fi
            press_enter
            ;;
          2) # Stop
            echo ""
            echo "Stopping tunnel..."
            pkill -f "ssh.*-N.*${selected_host}" 2>/dev/null || true
            echo -e "${GREEN}✓ Tunnel stopped${NC}"
            press_enter
            ;;
          3) # Restart/Refresh
            echo ""
            echo -e "${YELLOW}Restarting SSH tunnel for ${selected_host}...${NC}"
            pkill -f "ssh.*-N.*${selected_host}" 2>/dev/null || true
            sleep 1
            REMOTE_SSH="$selected_ssh"
            REMOTE_HOST="$selected_host"
            tunnel_start
            press_enter
            ;;
          4) # Details
            clear
            print_header
            echo -e "${BOLD}Tunnel Details: ${selected_name} (${selected_host})${NC}"
            echo ""
            # ... (details logic similar to original case 4 but simplified)
            local ssh_pid=$(pgrep -f "ssh.*-N.*${selected_host}" | head -1)
            if [[ -n "$ssh_pid" ]]; then
              local ssh_cmd=$(ps -p "$ssh_pid" -o args= 2>/dev/null || echo "")
              echo -e "${BOLD}Port Mappings:${NC}"
              printf "  ${BOLD}%-15s %-15s %s${NC}\n" "Local Port" "Remote Port" "Status"
              echo "  ──────────────────────────────────────────────"
              while IFS= read -r mapping; do
                if [[ -n "$mapping" ]]; then
                  local lp=$(echo "$mapping" | cut -d: -f1)
                  local rp=$(echo "$mapping" | cut -d: -f3)
                  printf "  %-15s %-15s ${GREEN}%s${NC}\n" "$lp" "$rp" "✓ Active"
                fi
              done < <(echo "$ssh_cmd" | grep -oE -- '-L [0-9]+:localhost:[0-9]+' | sed 's/-L //' || true)
            else
              echo -e "${DIM}No port mappings active (tunnel is down)${NC}"
            fi
            echo ""
            press_enter
            ;;
          0|"") break ;;
        esac
      done
    else
      echo -e "${RED}Invalid selection${NC}"
      sleep 1
    fi
  done
}
