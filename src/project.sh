#!/usr/bin/env bash
# Project Discovery & Selection

# ============================================================
# Machine Selection
# ============================================================

machine_select_menu() {
  while true; do
    clear
    print_header
    echo -e "${BOLD}Machine Selection${NC}"
    echo ""

    # Load all contexts
    local -a contexts=()
    local -a context_types=()
    local -a context_hosts=()
    local -a context_descriptions=()

    while IFS='|' read -r name type host desc; do
      contexts+=("$name")
      context_types+=("$type")
      context_hosts+=("$host")
      context_descriptions+=("$desc")
    done < <(jq -r '.contexts[] | "\(.name)|\(.type)|\(.host // "local")|\(.description // "")"' "$CONFIG_FILE")

    if [[ ${#contexts[@]} -eq 0 ]]; then
      echo -e "${RED}No machines found in config!${NC}"
      press_enter
      return
    fi

    echo -e "${BOLD}Available Machines:${NC}"
    echo ""

    local idx=1
    for i in "${!contexts[@]}"; do
      local name="${contexts[$i]}"
      local type="${context_types[$i]}"
      local host="${context_hosts[$i]}"
      local desc="${context_descriptions[$i]}"

      local display_line=""
      if [[ "$type" == "remote" ]]; then
        display_line="Remote: ${host} ${CYAN}(${desc})${NC}"
      else
        display_line="Local ${CYAN}(${desc})${NC}"
      fi

      if [[ "$name" == "$CURRENT_CONTEXT" ]]; then
        echo -e "${GREEN}${idx}) ${display_line} ${BOLD}(current)${NC}"
      else
        echo -e "${idx}) ${display_line}"
      fi
      idx=$((idx + 1))
    done

    echo ""
    echo "(Press Enter to return to main menu)"
    echo ""
    echo -n "Select machine (number): "
    read -r choice

    if [[ -z "$choice" || "$choice" == "0" ]]; then
      return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#contexts[@]} ]]; then
      local new_context="${contexts[$((choice-1))]}"
      CURRENT_CONTEXT="$new_context"
      export REMOTE_CONTEXT="$CURRENT_CONTEXT"

      # Reload context config
      load_context_config

      # Re-infer project for new machine
      CURRENT_PROJECT=$(infer_current_project)

      echo ""
      echo -e "${GREEN}✓ Switched to machine: ${CONTEXT_TYPE^}${NC}"
      if [[ "$CONTEXT_TYPE" == "remote" ]]; then
        echo -e "  Host: ${REMOTE_HOST}"
      fi

      # Show inferred project if any
      if [[ -n "$CURRENT_PROJECT" ]]; then
        echo -e "  Active project: ${GREEN}${CURRENT_PROJECT}${NC}"
      fi

      echo ""
      press_enter
      return
    else
      echo "Invalid selection"
      sleep 1
    fi
  done
}

# ============================================================
# Project Selection
# ============================================================

has_project_markers() {
  local d="$1"
  [[ -f "$d/package.json" ]] || [[ -f "$d/compose.yml" ]] || [[ -f "$d/docker-compose.yml" ]]
}

discover_projects() {
  local -a projects=()
  local search_paths=("${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}" "${LOCAL_ROOT_DIR}")

  for base_path in "${search_paths[@]}"; do
    if [[ -d "$base_path" ]]; then
      while IFS= read -r dir; do
        if has_project_markers "$dir"; then
          projects+=("$(basename "$dir")")
        fi
      done < <(find "$base_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    fi
  done

  # Remove duplicates
  printf '%s\n' "${projects[@]}" | sort -u
}

# ============================================================
# Port Discovery from Docker Compose
# ============================================================
get_project_ports() {
  local project_name="$1"
  local project_dir=""

  # Find project directory
  if [[ -d "${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}/${project_name}" ]]; then
    project_dir="${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}/${project_name}"
  elif [[ -d "${LOCAL_ROOT_DIR}/${project_name}" ]]; then
    project_dir="${LOCAL_ROOT_DIR}/${project_name}"
  else
    return
  fi

  # Find compose file
  local compose_file=""
  if [[ -f "$project_dir/compose.yml" ]]; then
    compose_file="$project_dir/compose.yml"
  elif [[ -f "$project_dir/docker-compose.yml" ]]; then
    compose_file="$project_dir/docker-compose.yml"
  else
    return
  fi

  # Extract local ports from compose file (left side of port mappings)
  # Match patterns like "5173:5173" or "3000:3000" and extract the first number
  grep -E -- '^\s*-\s*"?[0-9]+:[0-9]+"?' "$compose_file" 2>/dev/null | \
    sed -E 's/.*"?([0-9]+):[0-9]+.*/\1/' | \
    sort -u
}

# ============================================================
# Dynamic Port Discovery for Remote Containers
# ============================================================

# Discover ports exposed by running containers on remote machine
discover_remote_ports() {
  local remote_ssh="$1"

  # Get all HOST ports from running containers on remote
  # docker port output: "5173/tcp -> 0.0.0.0:5173" or "5173/tcp -> :::5173"
  # We need to extract the HOST port (after the last colon), not the container port
  ssh "$remote_ssh" 'docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
    docker port "$name" 2>/dev/null | grep -oE -- ":[0-9]+" | grep -oE -- "[0-9]+" || true
  done' 2>/dev/null | sort -u || true

  return 0
}

# Discover ALL compose files recursively and extract their ports
discover_all_local_ports() {
  {
    local -a files_to_scan=()
    if [[ ${#SELECTED_COMPOSE_FILES[@]} -gt 0 ]]; then
      files_to_scan=("${SELECTED_COMPOSE_FILES[@]}")
    else
      local search_path="${LOCAL_ROOT_DIR}"
      if [[ -n "$CURRENT_PROJECT" ]] && [[ -n "$LOCAL_NAMESPACE" ]]; then
        search_path="${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}/${CURRENT_PROJECT}"
      elif [[ -n "$LOCAL_NAMESPACE" ]] && [[ -d "${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}" ]]; then
        search_path="${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}"
      fi

      while IFS= read -r f; do
        [[ -n "$f" ]] && files_to_scan+=("$f")
      done < <(find "${search_path}" -maxdepth 5 -type f \( -name "compose.yml" -o -name "compose.yaml" -o -name "docker-compose.yml" -o -name "docker-compose.yaml" \) 2>/dev/null || true)
    fi

    for compose_file in "${files_to_scan[@]}"; do
      [[ ! -f "$compose_file" ]] && continue
      # Robust extraction: handle IP:HOST:CONT, HOST:CONT, comments, and ranges
      grep -E -- '^[[:space:]]*-([[:space:]]|")[0-9.:-]+:[0-9-]+' "$compose_file" 2>/dev/null | \
        sed -E 's/.*-([[:space:]]|")//; s/[#"].*//; s/ //g' | \
        while read -r mapping; do
          [[ -n "$mapping" ]] || continue
          local host_part=$(echo "$mapping" | sed -E 's/.*:([0-9-]+):[0-9-]+/\1/; s/([0-9-]+):[0-9]+/\1/')
          if [[ "$host_part" =~ - ]]; then
            local start=$(echo "$host_part" | cut -d- -f1)
            local end=$(echo "$host_part" | cut -d- -f2)
            if [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]]; then
              for ((p=start; p<=end; p++)); do echo "$p"; done
            fi
          else
            echo "$host_part" | grep -oE -- '^[0-9]+$' || true
          fi
        done
    done

    # From running containers
    docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | \
      grep -oE -- ':[0-9-]+(->|$)' | sed 's/[:>]//g; s/-$//' | \
      while read -r p_range; do
        [[ -n "$p_range" ]] || continue
        if [[ "$p_range" =~ - ]]; then
          local start=$(echo "$p_range" | cut -d- -f1)
          local end=$(echo "$p_range" | cut -d- -f2)
          if [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]]; then
            for ((p=start; p<=end; p++)); do echo "$p"; done
          fi
        else
          echo "$p_range" | grep -oE -- '^[0-9]+$' || true
        fi
      done
  } | grep -v -- '^0$' | sort -u -n || true
}

# Generate dynamic tunnel port mappings with conflict resolution
generate_tunnel_mappings() {
  local remote_ssh="$1"
  local -A port_usage
  local -a tunnel_mappings=()
  local -a compose_ports=()

  # Step 1: Get all ports from local compose files (these define what we want to tunnel)
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    compose_ports+=("$port")
    port_usage[$port]="local:reserved"
  done < <(discover_all_local_ports)

  # Step 2: Reserve ports already used by active SSH tunnels
  # This prevents conflicts when running multiple remote tunnels simultaneously
  while IFS= read -r local_port; do
    [[ -n "$local_port" ]] || continue
    port_usage[$local_port]="tunnel:active"
  done < <(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep 'ssh' | grep -oE -- ':[0-9]+' | sed 's/://' | sort -u || true)

  # Step 3: Create tunnel mappings for each compose port
  # Use compose file ports as the REMOTE ports, find available LOCAL ports
  for remote_port in "${compose_ports[@]}"; do
    [[ -n "$remote_port" ]] || continue

    # Start searching from incremented port to avoid conflicts with local services
    local local_port=$((remote_port + 1))

    # If remote port is privileged (< 1024), start from unprivileged range
    # This avoids "Permission denied" errors when creating SSH tunnels
    if [[ $remote_port -lt 1024 ]]; then
      local_port=$((remote_port + 8000))  # e.g., 80 → 8080
    fi

    # Find next available local port
    while [[ -n "${port_usage[$local_port]:-}" ]]; do
      local_port=$((local_port + 1))
    done

    # Create mapping: local_port:localhost:remote_port
    tunnel_mappings+=("${local_port}:localhost:${remote_port}")
    port_usage[$local_port]="remote:$remote_port"
  done

  # Return space-separated mappings
  if [[ ${#tunnel_mappings[@]} -gt 0 ]]; then
    printf '%s\n' "${tunnel_mappings[@]}"
  fi

  return 0
}

# ============================================================
# Port Conflict Validation & Auto-Fix (DEPRECATED - now dynamic)
# ============================================================
validate_and_fix_port_conflicts() {
  local -A port_usage
  local -A project_local_ports
  local conflicts_found=false
  local config_updated=false

  # Step 1a: Reserve explicitly configured local ports
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    port_usage[$port]="local:reserved"
  done < <(jq -r '.contexts[] | select(.type == "local" and .reserved_ports) | .reserved_ports[]' "$CONFIG_FILE" 2>/dev/null)

  # Step 1b: Discover local ports from all projects' compose files
  while IFS= read -r proj; do
    [[ -n "$proj" ]] || continue
    local ports=$(get_project_ports "$proj")
    if [[ -n "$ports" ]]; then
      project_local_ports[$proj]="$ports"
      # Reserve these ports
      for port in $ports; do
        port_usage[$port]="local:$proj"
      done
    fi
  done < <(discover_projects)

  # Step 2: Check remote tunnel ports against reserved local ports
  local -a contexts_to_fix=()
  while IFS='|' read -r name ports; do
    local needs_fix=false
    for port_mapping in $ports; do
      local local_port=$(echo "$port_mapping" | cut -d: -f1)

      if [[ -n "${port_usage[$local_port]:-}" ]]; then
        echo -e "${YELLOW}⚠️  Port conflict: ${local_port} reserved for ${port_usage[$local_port]}, but used by tunnel ${name}${NC}" >&2
        conflicts_found=true
        needs_fix=true
      fi
    done

    if $needs_fix; then
      contexts_to_fix+=("$name|$ports")
    fi
  done <<< ""  # DEPRECATED: Static tunnel_ports removed - now using dynamic discovery
  # Original line: done < <(jq -r '.contexts[] | select(.type == "remote" and .tunnel_ports) | "\(.name)|\(.tunnel_ports | join(" "))"' "$CONFIG_FILE")

  # Step 3: Auto-fix conflicts by incrementing ports
  if $conflicts_found; then
    echo "" >&2
    echo -e "${CYAN}Auto-fixing port conflicts...${NC}" >&2

    for entry in "${contexts_to_fix[@]}"; do
      local ctx_name=$(echo "$entry" | cut -d'|' -f1)
      local old_ports=$(echo "$entry" | cut -d'|' -f2)
      local -a new_ports=()

      for port_mapping in $old_ports; do
        local local_port=$(echo "$port_mapping" | cut -d: -f1)
        local remote_port=$(echo "$port_mapping" | cut -d: -f2)

        # Find next available port
        while [[ -n "${port_usage[$local_port]:-}" ]]; do
          local_port=$((local_port + 1))
        done

        new_ports+=("${local_port}:${remote_port}")
        port_usage[$local_port]="$ctx_name"
        echo -e "  ${ctx_name}: ${port_mapping} → ${local_port}:${remote_port}" >&2
      done

      # Update config file
      local new_ports_json=$(printf '%s\n' "${new_ports[@]}" | jq -R . | jq -s .)
      jq --arg name "$ctx_name" --argjson ports "$new_ports_json" \
        '(.contexts[] | select(.name == $name) | .tunnel_ports) = $ports' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

      config_updated=true
    done

    if $config_updated; then
      echo "" >&2
      echo -e "${GREEN}✓ Configuration updated with conflict-free ports${NC}" >&2
      echo -e "${CYAN}Reloading configuration...${NC}" >&2
      sleep 2
      exec "$0" "$@"  # Restart rocker with new config
    fi
  fi
}

# Validate and auto-fix ports on startup (DISABLED - using dynamic discovery)
# validate_and_fix_port_conflicts

project_select_menu() {
  while true; do
    clear
    print_header
    echo -e "${BOLD}Project Selection${NC}"
    echo ""
    echo "Discovering projects in:"
    echo "  • ${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}"
    echo "  • ${LOCAL_ROOT_DIR}"
    echo ""

    local -a projects=()
    while IFS= read -r proj; do
      [[ -n "$proj" ]] && projects+=("$proj")
    done < <(discover_projects)

    if [[ ${#projects[@]} -eq 0 ]]; then
      echo -e "${RED}No projects found!${NC}"
      echo ""
      echo "Projects must have package.json, compose.yml, or docker-compose.yml"
      press_enter
      return
    fi

    echo -e "${BOLD}Available Projects:${NC}"
    echo ""
    local idx=1
    for proj in "${projects[@]}"; do
      if [[ "$proj" == "$CURRENT_PROJECT" ]]; then
        echo -e "${GREEN}${idx}) ${proj} ${BOLD}(current)${NC}"
      else
        echo "${idx}) ${proj}"
      fi
      idx=$((idx + 1))
    done

    echo ""
    echo "(Press Enter to return to main menu)"
    echo ""
    echo -n "Select project (number): "
    read -r choice

    if [[ -z "$choice" || "$choice" == "0" ]]; then
      return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#projects[@]} ]]; then
      local selected_project="${projects[$((choice-1))]}"

      echo ""
      echo -e "${GREEN}✓ Selected project: ${selected_project}${NC}"
      echo ""

      # Auto-start tunnel for remote machines
      if [[ "$CONTEXT_TYPE" == "remote" ]]; then
        echo "Setting up remote environment..."
        echo ""

        # Check if tunnel is running
        if ! tunnel_status_check; then
          echo "Starting SSH tunnel to ${REMOTE_HOST}..."
          if tunnel_start; then
            echo ""
          else
            echo ""
            echo -e "${YELLOW}⚠ Tunnel start had issues, but continuing...${NC}"
            echo ""
          fi
        else
          echo -e "${GREEN}✓ SSH tunnel already active${NC}"
          echo ""
        fi

        echo "Initializing Docker context on ${REMOTE_HOST}..."
      else
        echo "Initializing local Docker context..."
      fi
      echo ""

      # Run ctx command to initialize Docker context (show output)
      if ${SCRIPT_DIR}/remote "$selected_project" ctx; then
        echo ""
        echo -e "${GREEN}✓ Docker context initialized${NC}"

        # Re-infer project after initialization
        CURRENT_PROJECT=$(infer_current_project)
      else
        echo ""
        echo -e "${YELLOW}⚠ Context initialization completed with warnings${NC}"

        # Still try to infer project
        CURRENT_PROJECT=$(infer_current_project)
      fi

      press_enter
      return
    else
      echo "Invalid selection"
      sleep 1
    fi
  done
}
