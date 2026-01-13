#!/usr/bin/env bash
# Main Menu & Application Loop

# ============================================================
# Main Menu
# ============================================================

main_menu() {
  # DEBUG: Entered main_menu function" >&2
  while true; do
    # DEBUG: Main menu loop iteration" >&2
    # Get current docker context and sync rocker config
    # DEBUG: Getting docker context..." >&2
    local current_docker_ctx=$(docker context show 2>/dev/null || echo "unknown")
    # DEBUG: Docker context: $current_docker_ctx" >&2
    local docker_endpoint=$(docker context inspect "$current_docker_ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo "")

    # Determine current rocker context from docker context
    # DEBUG: Determining rocker context..." >&2
    local new_rocker_context="local"
    if [[ "$docker_endpoint" == ssh://* ]]; then
      # Remote context - find matching rocker context (same logic as startup)
      local remote_hostname=$(echo "$docker_endpoint" | sed -E 's|ssh://([^@]+@)?([^:/]+).*|\2|')

      # First try exact match
      local found_context=$(jq -r --arg host "$remote_hostname" '.contexts[] | select(.host == $host) | .name' "$CONFIG_FILE" 2>/dev/null | tr -d '\n' || echo "")

      # If no exact match, try base hostname matching
      if [[ -z "$found_context" ]]; then
        # Extract base hostname without domain (zermatt from zermatt.local)
        local base_hostname="${remote_hostname%%.*}"
        found_context=$(jq -r --arg base "$base_hostname" '.contexts[] | select(.host != null) | select(.host | startswith($base)) | .name' "$CONFIG_FILE" 2>/dev/null | tr -d '\n' || echo "")
      fi

      if [[ -n "$found_context" ]]; then
        new_rocker_context="$found_context"
      fi
    fi

    # Reload config if context changed
    # DEBUG: Checking if config needs reload..." >&2
    if [[ "$CURRENT_CONTEXT" != "$new_rocker_context" ]]; then
      # DEBUG: Reloading config..." >&2
      CURRENT_CONTEXT="$new_rocker_context"
      load_context_config
    fi

    # Re-infer project on each menu display (in case context changed outside rocker)
    # DEBUG: Re-inferring project..." >&2
    CURRENT_PROJECT=$(infer_current_project)
    # DEBUG: Project: $CURRENT_PROJECT" >&2

    # DEBUG: About to clear screen..." >&2
    clear
    # DEBUG: About to print header..." >&2
    print_header
    # DEBUG: Header printed" >&2

    # ============================================================
    # Current Status
    # ============================================================

    # Determine host and IP based on ACTUAL current docker context
    local host ip tunnel_status

    if [[ "$docker_endpoint" == ssh://* ]]; then
      # Remote context - use REMOTE_HOST from loaded config
      host="${REMOTE_HOST}"

      # Fallback to extracted hostname if config not loaded
      if [[ -z "$host" ]]; then
        host=$(echo "$docker_endpoint" | sed -E 's|ssh://([^@]+@)?([^:/]+).*|\2|')
      fi

      ip=$(get_ip_address "$host" 2>/dev/null || echo "-")

      # Check tunnel status for remote
      if pgrep -f "ssh.*-N.*${host}" >/dev/null 2>&1; then
        tunnel_status="${GREEN}active${NC}"
      else
        tunnel_status="${YELLOW}inactive${NC}"
      fi
    else
      # Local context - check if any SSH tunnels are running
      host="local"
      ip="127.0.0.1"

      # Check for any active SSH tunnels
      if pgrep -f "ssh.*-N" >/dev/null 2>&1; then
        tunnel_status="${GREEN}active${NC}"
      else
        tunnel_status="${CYAN}n/a${NC}"
      fi
    fi


    printf "%-28s %b\n" "Current selected context:" "${GREEN}${current_docker_ctx}${NC}"
    printf "%-28s %b\n" "Host:" "${CYAN}${host}${NC}"
    printf "%-28s %b\n" "IP address:" "${CYAN}${ip}${NC}"
    if [[ -n "$CURRENT_PROJECT" ]]; then
      printf "%-28s %b\n" "Project:" "${CYAN}${CURRENT_PROJECT}${NC}"
    fi
    printf "%-28s %b\n" "SSH tunnel:" "${tunnel_status}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${BOLD}Main Menu:${NC}"
    echo ""
    echo "1) View status"
    echo "2) Select Docker context"
    echo "3) SSH tunnel management"
    echo "4) NPM commands browser"
    echo "5) Remote headless mode (Mac)"
    echo ""
    echo "0) Exit"
    echo ""
    echo -n "Select option: "
    read -r choice

    case "$choice" in
      1) view_all_containers_menu ;;  # View status
      2) select_docker_context_menu ;;  # NEW: Select Docker context
      3) tunnel_menu ;;  # SSH tunnel management
      4) npm_commands_menu ;;  # NPM commands browser
      5) headless_menu ;;  # Remote headless mode (Mac)
      0)
        echo ""
        echo "Goodbye!"
        exit 0
        ;;
      *)
        echo "Invalid option"
        sleep 1
        ;;
    esac
  done
}

# ============================================================
# Entry point
# ============================================================

# DEBUG: Starting main menu..." >&2
main_menu
