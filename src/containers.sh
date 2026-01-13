#!/usr/bin/env bash

# Container Viewing & Management

view_project_info_menu() {
  clear
  print_header
  echo -e "${BOLD}Project Information${NC}"
  echo ""

  if [[ -z "$CURRENT_PROJECT" ]]; then
    echo -e "${RED}✗ No project selected${NC}"
    echo ""
    echo "Please select a project first (Main Menu → Select Project)"
    press_enter
    return
  fi

  echo -e "${BOLD}Fetching information for: ${GREEN}${CURRENT_PROJECT}${NC}"
  echo ""

  # Run ctx command and capture output
  local ctx_output
  ctx_output=$(${SCRIPT_DIR}/remote "$CURRENT_PROJECT" ctx 2>&1)

  # Check if command succeeded
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}✗ Failed to get project information${NC}"
    echo ""
    echo "Error output:"
    echo "$ctx_output"
    press_enter
    return
  fi

  # Parse the output
  local machine_type=$(echo "$ctx_output" | grep -E -- "Context:" | grep -q -- "local" && echo "Local" || echo "Remote: ${REMOTE_HOST}")
  local project_dir=$(echo "$ctx_output" | grep -E -- "Project dir" | cut -d: -f2- | xargs)
  local docker_engine=$(echo "$ctx_output" | grep -E -- "Docker engine" | cut -d: -f2- | xargs)
  local colima_profile=$(echo "$ctx_output" | grep -E -- "Colima profile" | cut -d: -f2- | xargs)
  local docker_context=$(echo "$ctx_output" | grep -E -- "Docker context:" | cut -d: -f2- | xargs)
  local active_context=$(echo "$ctx_output" | grep -E -- "Current Docker context:" -A1 | tail -1 | xargs)

  # Draw table
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "${BOLD}%-20s${NC} : %s\n" "Machine" "$machine_type"
  printf "${BOLD}%-20s${NC} : %s\n" "Project" "$CURRENT_PROJECT"
  printf "${BOLD}%-20s${NC} : %s\n" "Project Directory" "$project_dir"
  printf "${BOLD}%-20s${NC} : %s\n" "Docker Engine" "$docker_engine"
  if [[ -n "$colima_profile" ]]; then
    printf "${BOLD}%-20s${NC} : %s\n" "Colima Profile" "$colima_profile"
  fi
  printf "${BOLD}%-20s${NC} : %s\n" "Docker Context" "$docker_context"
  printf "${BOLD}%-20s${NC} : ${GREEN}%s${NC}\n" "Active Context" "$active_context"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Show running containers
  echo -e "${BOLD}Running Containers:${NC}"
  echo ""

  # Extract docker ps output (everything after "Running containers:")
  local docker_ps_output=$(echo "$ctx_output" | awk '/Running containers:/{flag=1;next} flag')

  if [[ -n "$docker_ps_output" && "$docker_ps_output" != *"CONTAINER ID"* ]]; then
    echo -e "${YELLOW}No containers running${NC}"
  elif [[ -n "$docker_ps_output" ]]; then
    echo "$docker_ps_output"
  else
    echo -e "${YELLOW}No containers running${NC}"
  fi

  echo ""
  press_enter
}

view_all_containers_menu() {
  clear
  print_header
  echo -e "${BOLD}Local Status${NC}"
  echo ""

  # ============================================================
  # Current Active Context
  # ============================================================
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}CURRENT ACTIVE CONTEXT${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Get current docker context
  local current_docker_ctx=$(docker context show 2>/dev/null || echo "unknown")

  # Get local project from directory inference
  local local_project=$(infer_current_project)

  # Display context info using echo -e for proper color rendering
  echo -e "${BOLD}Docker Context:     ${GREEN}${current_docker_ctx}${NC}"
  if [[ -n "$local_project" ]]; then
    echo -e "${BOLD}Current Project:    ${GREEN}${local_project}${NC}"
  else
    echo -e "${BOLD}Current Project:    ${YELLOW}(none detected)${NC}"
  fi

  # Show namespace and root dir if available
  if [[ -n "$LOCAL_NAMESPACE" ]]; then
    echo -e "${BOLD}Namespace:          ${CYAN}${LOCAL_NAMESPACE}${NC}"
  fi
  echo -e "${BOLD}Root Directory:     ${CYAN}${LOCAL_ROOT_DIR}${NC}"

  echo ""

  # ============================================================
  # All Available Docker Contexts
  # ============================================================
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}AVAILABLE DOCKER CONTEXTS${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  printf "${BOLD}%-20s %-35s %s${NC}\n" "Name" "Description" "Docker Endpoint"
  echo "────────────────────────────────────────────────────────────────────"

  # Get current active docker context
  local active_docker_ctx=$(docker context show 2>/dev/null || echo "")

  # List all docker contexts
  local contexts_found=false
  while IFS=$'\t' read -r name description endpoint; do
    if [[ -n "$name" && "$name" != "NAME" ]]; then
      contexts_found=true
      # Remove trailing asterisk if present in name
      local ctx_name="${name% \*}"
      ctx_name="${ctx_name%\*}"

      # Check if this is the active context (by comparing or by asterisk)
      if [[ "$ctx_name" == "$active_docker_ctx" ]] || [[ "$name" == *"*"* ]]; then
        printf "${GREEN}%-20s${NC} ${CYAN}%-35s${NC} ${CYAN}%s${NC} ${YELLOW}*${NC}\n" \
          "$ctx_name" "${description:--}" "${endpoint:--}"
      else
        printf "%-20s ${CYAN}%-35s${NC} ${CYAN}%s${NC}\n" \
          "$ctx_name" "${description:--}" "${endpoint:--}"
      fi
    fi
  done < <(docker context ls --format "{{.Name}}\t{{.Description}}\t{{.DockerEndpoint}}" 2>/dev/null)

  if ! $contexts_found; then
    echo -e "${YELLOW}No docker contexts found${NC}"
  fi

  echo ""

  # ============================================================
  # Local Running Containers (always show)
  # ============================================================
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}LOCAL RUNNING CONTAINERS${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  printf "${BOLD}%-30s %-15s %s${NC}\n" "Container" "Port" "Access URL"
  echo "────────────────────────────────────────────────────────────────────"

  local containers_found=false

  # Get local containers using the 'default' or local context
  local local_containers=$(DOCKER_CONTEXT=default docker ps --format "{{.Names}}|{{.Ports}}" 2>/dev/null)
  if [[ -n "$local_containers" ]]; then
    while IFS='|' read -r name ports_raw; do
      containers_found=true
      # Parse ports (e.g., "0.0.0.0:5173->5173/tcp")
      local port=$(echo "$ports_raw" | grep -oE -- '[0-9]+->([0-9]+)' | head -1 | cut -d'>' -f2)

      if [[ -n "$port" ]]; then
        printf "${GREEN}%-30s${NC} %-15s ${CYAN}%s${NC}\n" \
          "$name" "$port" "http://localhost:$port"
      else
        printf "${GREEN}%-30s${NC} %-15s %s\n" \
          "$name" "-" "-"
      fi
    done <<< "$local_containers"
  fi

  if ! $containers_found; then
    echo -e "${YELLOW}No containers running locally${NC}"
  fi

  echo ""

  # ============================================================
  # Remote Running Containers (only if current context is remote)
  # ============================================================
  # Check if current docker context is actually remote
  local current_docker_ctx=$(docker context show 2>/dev/null || echo "unknown")
  local docker_endpoint=$(docker context inspect "$current_docker_ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo "")

  if [[ "$docker_endpoint" == ssh://* ]]; then
    # Extract remote hostname
    local remote_host=$(echo "$docker_endpoint" | sed -E 's|ssh://([^@]+@)?([^:/]+).*|\2|')

    # Use full hostname from rocker config if available
    if [[ -n "$REMOTE_HOST" ]] && [[ "$remote_host" == "$REMOTE_HOST" || "$REMOTE_HOST" == *"$remote_host"* ]]; then
      remote_host="$REMOTE_HOST"
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}REMOTE RUNNING CONTAINERS (${remote_host})${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${BOLD}%-30s %-15s %-15s %s${NC}\n" "Container" "Remote Port" "Local Port" "Access URL"
    echo "────────────────────────────────────────────────────────────────────"

    local remote_containers_found=false

    # Get active SSH tunnel mappings (local:remote)
    declare -A tunnel_port_map
    local ssh_pid=$(pgrep -f "ssh.*-N.*${remote_host}" | head -1)
    if [[ -n "$ssh_pid" ]]; then
      local ssh_cmd=$(ps -p "$ssh_pid" -o args= 2>/dev/null || echo "")
      while IFS= read -r mapping; do
        if [[ -n "$mapping" ]]; then
          local local_port=$(echo "$mapping" | cut -d: -f1)
          local remote_port=$(echo "$mapping" | cut -d: -f3)
          tunnel_port_map[$remote_port]=$local_port
        fi
      done < <(echo "$ssh_cmd" | grep -oE -- '-L [0-9]+:localhost:[0-9]+' | sed 's/-L //' || true)
    fi

    # Get remote containers using current (remote) context
    local remote_containers=$(docker ps --format "{{.Names}}|{{.Ports}}" 2>/dev/null)
    if [[ -n "$remote_containers" ]]; then
      while IFS='|' read -r name ports_raw; do
        remote_containers_found=true
        local host_ports=""
        local local_ports=""
        local first_url=""
        local is_tunneled=false

        if [[ -n "$ports_raw" ]]; then
          # Extract all ports from ports_raw (handles multiple and ranges)
          declare -A seen_ports
          while IFS= read -r p_entry; do
            [[ -n "$p_entry" ]] || continue
            # Extract host part: after colon, before arrow
            local h_part=$(echo "$p_entry" | sed -E 's/.*:([0-9-]+)->.*/\1/')
            # Handle ranges (e.g., 9000-9001)
            if [[ "$h_part" =~ - ]]; then
              local start=$(echo "$h_part" | cut -d- -f1)
              local end=$(echo "$h_part" | cut -d- -f2)
              if [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]]; then
                for ((p=start; p<=end; p++)); do
                  # De-duplicate: only process this port if not seen before for this container
                  if [[ -z "${seen_ports[$p]:-}" ]]; then
                    seen_ports[$p]=1
                    local lp="${tunnel_port_map[$p]:-}"
                    host_ports="${host_ports}${p}, "
                    if [[ -n "$lp" ]]; then
                      local_ports="${local_ports}${lp}, "
                      is_tunneled=true
                      [[ -z "$first_url" ]] && first_url="http://localhost:$lp"
                    else
                      local_ports="${local_ports}?, "
                    fi
                  fi
                done
              fi
            else
              # Single port
              local hp=$(echo "$h_part" | grep -oE -- '^[0-9]+$' || echo "")
              if [[ -n "$hp" ]]; then
                # De-duplicate
                if [[ -z "${seen_ports[$hp]:-}" ]]; then
                  seen_ports[$hp]=1
                  local lp="${tunnel_port_map[$hp]:-}"
                  host_ports="${host_ports}${hp}, "
                  if [[ -n "$lp" ]]; then
                    local_ports="${local_ports}${lp}, "
                    is_tunneled=true
                    [[ -z "$first_url" ]] && first_url="http://localhost:$lp"
                  else
                    local_ports="${local_ports}?, "
                  fi
                fi
              fi
            fi
          done < <(echo "$ports_raw" | tr ',' '\n' | grep -- '->' || true)

          # Clean up trailing commas
          host_ports=${host_ports%, }
          local_ports=${local_ports%, }

          if [[ -z "$host_ports" ]]; then
             # Case for exposed but not mapped ports or other formats
             host_ports=$(echo "$ports_raw" | sed 's/0\.0\.0\.0//g; s/\[::\]//g' | grep -oE -- '[0-9]+' | head -1 || echo "-")
             local_ports="-"
             first_url="-"
          fi

          if $is_tunneled; then
            printf "${GREEN}%-30s${NC} %-15s ${CYAN}%-15s${NC} ${CYAN}%s${NC}\n" \
              "$name" "$host_ports" "$local_ports" "$first_url"
          else
            printf "${GREEN}%-30s${NC} %-15s ${YELLOW}%-15s${NC} ${YELLOW}%s${NC}\n" \
              "$name" "$host_ports" "(not tunneled)" "-"
          fi
        else
          printf "${GREEN}%-30s${NC} %-15s %-15s %s\n" \
            "$name" "-" "-" "-"
        fi
      done <<< "$remote_containers"
    fi

    if ! $remote_containers_found; then
      echo -e "${YELLOW}No containers running on remote${NC}"
    fi

    echo ""
  fi

  press_enter
}
