#!/usr/bin/env bash

# Docker Context Management

docker_contexts_menu() {
  clear
  print_header

  if [[ "$CONTEXT_TYPE" == "remote" ]]; then
    echo -e "${BOLD}Docker Context Management (Remote: ${REMOTE_HOST})${NC}"
  else
    echo -e "${BOLD}Docker Context Management (Local)${NC}"
  fi
  echo ""

  # Get contexts
  if [[ "$CONTEXT_TYPE" == "remote" ]]; then
    echo "Fetching Docker contexts from ${REMOTE_HOST}..."
    local contexts
    contexts=$(ssh "$REMOTE_SSH" "docker context ls" 2>/dev/null || echo "")

    if [[ -z "$contexts" ]]; then
      echo -e "${RED}Failed to fetch Docker contexts${NC}"
      press_enter
      return
    fi

    echo "$contexts"
  else
    echo "Fetching local Docker contexts..."
    docker context ls
  fi
  echo ""

  echo "Available actions:"
  echo "1) Switch context"
  echo "2) Show current context"
  echo ""
  echo "(Press Enter to return to main menu)"
  echo ""
  echo -n "Select option: "
  read -r choice

  case "$choice" in
    0|"") return ;;
    1)
      echo ""
      echo -n "Enter context name: "
      read -r ctx_name
      if [[ "$CONTEXT_TYPE" == "remote" ]]; then
        ssh "$REMOTE_SSH" "docker context use $ctx_name"
      else
        docker context use "$ctx_name"
      fi
      press_enter
      ;;
    2)
      echo ""
      if [[ "$CONTEXT_TYPE" == "remote" ]]; then
        ssh "$REMOTE_SSH" "docker context show"
      else
        docker context show
      fi
      press_enter
      ;;
    *) echo "Invalid option"; sleep 1 ;;
  esac
}

select_docker_context_menu() {
  clear
  print_header
  echo -e "${BOLD}Select Docker Context${NC}"
  echo ""

  # List all local docker contexts
  echo -e "${BLUE}Available Docker Contexts:${NC}"
  echo ""

  local -a context_names=()
  local -a context_endpoints=()
  local idx=1

  # Parse docker context list
  while IFS=$'\t' read -r name endpoint; do
    if [[ -n "$name" ]]; then
      context_names+=("$name")
      context_endpoints+=("$endpoint")

      # Check if this is current context
      local marker=""
      if [[ "$name" == "$(docker context show 2>/dev/null)" ]]; then
        marker=" ${GREEN}(current)${NC}"
      fi

      # Check if remote (ssh endpoint)
      if [[ "$endpoint" == ssh://* ]]; then
        echo -e "$idx) ${CYAN}$name${NC} - ${YELLOW}[remote]${NC}${marker}"
      else
        echo -e "$idx) ${CYAN}$name${NC} - ${GREEN}[local]${NC}${marker}"
      fi
      ((idx++))
    fi
  done < <(docker context ls --format "{{.Name}}\t{{.DockerEndpoint}}" 2>/dev/null)

  echo ""
  echo "(Press Enter to return to main menu)"
  echo ""
  echo -n "Select context: "
  read -r choice

  if [[ -z "$choice" ]]; then
    return
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -lt $idx ]]; then
    local selected_context="${context_names[$((choice-1))]}"
    local selected_endpoint="${context_endpoints[$((choice-1))]}"

    echo ""
    echo -e "Switching to ${CYAN}$selected_context${NC}..."

    # Switch docker context
    docker context use "$selected_context" >/dev/null 2>&1

    # If remote, check if we need to start tunnel
    if [[ "$selected_endpoint" == ssh://* ]]; then
      # Extract hostname from ssh://user@host or ssh://host
      local remote_host=$(echo "$selected_endpoint" | sed -E 's|ssh://([^@]+@)?([^:/]+).*|\2|')

      # Find the rocker context name for this host
      local rocker_context=""

      # First try exact match
      rocker_context=$(jq -r --arg host "$remote_host" '.contexts[] | select(.host == $host) | .name' "$CONFIG_FILE" 2>/dev/null | tr -d '\n' || echo "")

      # If no exact match, try base hostname matching (zermatt matches zermatt.local)
      if [[ -z "$rocker_context" ]]; then
        local base_remote="${remote_host%%.*}"
        rocker_context=$(jq -r --arg base "$base_remote" '.contexts[] | select(.host != null) | select(.host | startswith($base)) | .name' "$CONFIG_FILE" 2>/dev/null | tr -d '\n' || echo "")
      fi

      if [[ -n "$rocker_context" ]]; then
        # Update current context state
        CURRENT_CONTEXT="$rocker_context"
        load_context_config

        # Now select which Docker context to use on the remote machine
        echo ""
        echo -e "${BOLD}Select Docker Context on ${REMOTE_HOST}:${NC}"
        echo ""
        echo "Fetching available contexts..."

        # Get Docker contexts from remote machine
        local -a remote_contexts=()
        local -a remote_context_names=()
        while IFS= read -r ctx_line; do
          if [[ -n "$ctx_line" ]]; then
            local ctx_name=$(echo "$ctx_line" | awk '{print $1}')
            remote_context_names+=("$ctx_name")
            remote_contexts+=("$ctx_line")
          fi
        done < <(ssh "$REMOTE_SSH" "docker context ls --format '{{.Name}}\t{{.Current}}'" 2>/dev/null | grep -v '^NAME')

        if [[ ${#remote_context_names[@]} -eq 0 ]]; then
          echo -e "${RED}No Docker contexts found on remote${NC}"
          press_enter
          return
        fi

        echo ""
        local idx=1
        for i in "${!remote_context_names[@]}"; do
          local ctx_info="${remote_contexts[$i]}"
          local ctx_name="${remote_context_names[$i]}"
          # Check if this is the current context
          if echo "$ctx_info" | grep -q '\*'; then
            echo -e "${GREEN}$idx) $ctx_name (current)${NC}"
          else
            echo "$idx) $ctx_name"
          fi
          idx=$((idx + 1))
        done

        echo ""
        echo -n "Select context: "
        read -r remote_ctx_choice

        if [[ "$remote_ctx_choice" =~ ^[0-9]+$ ]] && [[ $remote_ctx_choice -ge 1 ]] && [[ $remote_ctx_choice -le ${#remote_context_names[@]} ]]; then
          local selected_remote_ctx="${remote_context_names[$((remote_ctx_choice-1))]}"
          echo ""
          echo -e "${CYAN}Switching to $selected_remote_ctx on remote...${NC}"

          # Switch context on remote machine
          ssh "$REMOTE_SSH" "docker context use $selected_remote_ctx" >/dev/null 2>&1

          # Infer project name from context (e.g., colima-tapestry-mono -> tapestry-mono)
          if [[ "$selected_remote_ctx" =~ ^colima-(.+)$ ]]; then
            CURRENT_PROJECT="${BASH_REMATCH[1]}"
            echo -e "${GREEN}✓ Detected project: $CURRENT_PROJECT${NC}"
          elif [[ "$selected_remote_ctx" != "default" && "$selected_remote_ctx" != "desktop-linux" ]]; then
            CURRENT_PROJECT="$selected_remote_ctx"
            echo -e "${GREEN}✓ Using context as project: $CURRENT_PROJECT${NC}"
          else
            CURRENT_PROJECT=""
          fi
        else
          echo -e "${RED}Invalid selection${NC}"
          press_enter
          return
        fi
      fi
    else
      # Local context - update state to local
      load_context_config
    fi

    echo -e "${GREEN}✓ Switched to $selected_context${NC}"
    echo ""
    press_enter
  else
    echo -e "${RED}Invalid selection${NC}"
    sleep 1
  fi
}
