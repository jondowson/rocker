#!/usr/bin/env bash

# Headless Mode Menu

headless_menu() {
  while true; do
    clear
    print_header
    echo -e "${BOLD}Headless Mode & Sleep Management: ${GREEN}${REMOTE_HOST}${NC}"
    echo ""

    # Display machine info
    local remote_ip=$(get_ip_address "$REMOTE_HOST")
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}MACHINE${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${BOLD}%-14s %-20s %s${NC}\n" "Type" "Host" "IP"
    echo "────────────────────────────────────────────────────────────────────"
    printf "${GREEN}%-14s${NC} ${GREEN}%-20s${NC} ${CYAN}%s${NC}\n" "Remote" "$REMOTE_HOST" "${remote_ip:--}"
    echo ""

    # Get status information
    # Ensure rocker-headless script exists on remote machine
    scp -q ${SCRIPT_DIR}/rocker-headless "$REMOTE_SSH:~/rocker-headless" 2>/dev/null
    ssh "$REMOTE_SSH" "chmod +x ~/rocker-headless" 2>/dev/null

    local status_output
    status_output=$(ssh "$REMOTE_SSH" "~/rocker-headless status" 2>/dev/null)

    if [[ $? -ne 0 ]]; then
      echo -e "${RED}✗ Failed to connect to remote${NC}"
      echo ""
      press_enter
      return
    fi

    # Parse status information
    local sleep_setting=$(echo "$status_output" | grep "^\s*sleep\s" | awk '{print $2}')
    local displaysleep_setting=$(echo "$status_output" | grep "^\s*displaysleep\s" | awk '{print $2}')
    local disksleep_setting=$(echo "$status_output" | grep "^\s*disksleep\s" | awk '{print $2}')
    local ssh_status=$(echo "$status_output" | grep -A1 "SSH Remote Login" | tail -1)
    local caff_status=$(echo "$status_output" | grep -A1 "Caffeinate" | tail -1)

    # Determine if full headless is enabled (all sleep settings = 0)
    local full_headless="Disabled"
    local full_headless_color="${CYAN}"
    if [[ "$sleep_setting" == "0" && "$displaysleep_setting" == "0" && "$disksleep_setting" == "0" ]]; then
      full_headless="ENABLED"
      full_headless_color="${GREEN}"
    fi

    # Display status table
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}CURRENT STATUS${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${BOLD}%-30s %-20s %s${NC}\n" "Setting" "Status" "Description"
    echo "─────────────────────────────────────────────────────────────────────────────"

    printf "%-30s ${full_headless_color}%-20s${NC} %s\n" "Full Headless Mode" "$full_headless" "pmset sleep prevention (sudo)"

    # Caffeinate status
    if echo "$caff_status" | grep -q "✓.*running"; then
      local caff_pid=$(echo "$caff_status" | grep -oE 'pid [0-9]+' | awk '{print $2}')
      printf "%-30s ${GREEN}%-20s${NC} %s\n" "Caffeinate" "Running (PID: $caff_pid)" "Process-level (no sudo)"
    else
      printf "%-30s ${YELLOW}%-20s${NC} %s\n" "Caffeinate" "Not running" "Separate lightweight option"
    fi

    # Sleep settings
    if [[ "$sleep_setting" == "0" ]]; then
      printf "%-30s ${GREEN}%-20s${NC} %s\n" "System Sleep" "Disabled" "Mac will not sleep"
    else
      printf "%-30s ${CYAN}%-20s${NC} %s\n" "System Sleep" "Enabled (${sleep_setting}min)" "Mac will sleep after idle"
    fi

    # SSH status
    if echo "$ssh_status" | grep -qi "on\|running\|enabled"; then
      printf "%-30s ${GREEN}%-20s${NC} %s\n" "SSH Remote Login" "Enabled" "Can connect remotely"
    else
      printf "%-30s ${YELLOW}%-20s${NC} %s\n" "SSH Remote Login" "Unknown" "Cannot verify status"
    fi

    echo ""
    echo -e "${CYAN}ℹ  Full Headless Mode = pmset sleep disabled + SSH + Wake-on-LAN (requires sudo)${NC}"
    echo -e "${CYAN}ℹ  Caffeinate = Lightweight stay-awake process (no system changes, no sudo)${NC}"
    echo ""

    echo -e "${BOLD}Actions:${NC}"
    echo ""
    echo -e "${BOLD}Full Headless Mode (pmset):${NC}"
    echo "1) Enable full headless mode (system-wide sleep prevention)"
    echo "2) Disable full headless mode (restore normal sleep settings)"
    echo ""
    echo -e "${BOLD}Caffeinate (separate):${NC}"
    echo "3) Start caffeinate (lightweight alternative or extra insurance)"
    echo "4) Stop caffeinate"
    echo ""
    echo "(Press Enter to return to main menu)"
    echo ""
    echo -n "Select option: "
    read -r choice

    case "$choice" in
      0|"") return ;;
      1)
        echo ""
        if confirm "Enable FULL headless mode on ${REMOTE_HOST}? (requires sudo)"; then
          echo ""
          if ssh -t "$REMOTE_SSH" "~/rocker-headless on"; then
            echo ""
            echo -e "${GREEN}✓ Headless mode enabled${NC}"
            echo ""
            echo "Verifying status..."
            ssh "$REMOTE_SSH" "pmset -g | grep -E 'sleep|disablesleep'"
          else
            echo ""
            echo -e "${RED}✗ Failed to enable headless mode${NC}"
          fi
        fi
        press_enter
        ;;
      2)
        echo ""
        if confirm "Disable headless mode on ${REMOTE_HOST}? (requires sudo)"; then
          echo ""
          if ssh -t "$REMOTE_SSH" "~/rocker-headless off"; then
            echo ""
            echo -e "${GREEN}✓ Headless mode disabled${NC}"
            echo ""
            echo "Verifying status..."
            ssh "$REMOTE_SSH" "pmset -g | grep -E 'sleep|disablesleep'"
          else
            echo ""
            echo -e "${RED}✗ Failed to disable headless mode${NC}"
          fi
        fi
        press_enter
        ;;
      3)
        echo ""
        ssh "$REMOTE_SSH" "~/rocker-headless caffeinate-on"
        press_enter
        ;;
      4)
        echo ""
        ssh "$REMOTE_SSH" "~/rocker-headless caffeinate-off"
        press_enter
        ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}
