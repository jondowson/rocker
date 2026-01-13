#!/usr/bin/env bash

# NPM Commands

npm_commands_menu() {
  clear
  print_header
  echo -e "${BOLD}NPM Commands Browser${NC}"
  echo ""

  # Use current project if set, otherwise show selection menu
  local project_name="$CURRENT_PROJECT"
  local project_dir=""

  if [[ -z "$project_name" ]]; then
    echo "No project selected."
    echo ""
    echo "Scanning local folders for projects (synced)..."
    echo ""

    # Find all directories with package.json
    local -a projects=()
    local -a project_paths=()

    # Search locally (always, since folders are synced)
    # Search in LOCAL_NAMESPACE first
    if [[ -d "${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}" ]]; then
      while IFS= read -r pkg_file; do
        local dir=$(dirname "$pkg_file")
        projects+=("$(basename "$dir")")
        project_paths+=("$dir")
      done < <(find "${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}" -maxdepth 2 -name "package.json" -type f 2>/dev/null | sort)
    fi

    # Also search in root directory
    while IFS= read -r pkg_file; do
      local dir=$(dirname "$pkg_file")
      local proj_name=$(basename "$dir")
      # Only add if not already in list
      local already_added=false
      for existing in "${projects[@]}"; do
        if [[ "$existing" == "$proj_name" ]]; then
          already_added=true
          break
        fi
      done
      if ! $already_added; then
        projects+=("$proj_name")
        project_paths+=("$dir")
      fi
    done < <(find "${LOCAL_ROOT_DIR}" -maxdepth 2 -name "package.json" -type f 2>/dev/null | sort)

    if [[ ${#projects[@]} -eq 0 ]]; then
      echo -e "${RED}No projects with package.json found${NC}"
      press_enter
      return
    fi

    echo -e "${BOLD}Available Projects:${NC}"
    echo ""
    local idx=1
    for proj in "${projects[@]}"; do
      echo "$idx) $proj"
      idx=$((idx + 1))
    done

    echo ""
    echo "(Press Enter to return to main menu)"
    echo ""
    echo -n "Select project: "
    read -r proj_choice

    if [[ -z "$proj_choice" ]]; then
      return
    fi

    if [[ "$proj_choice" =~ ^[0-9]+$ ]] && [[ $proj_choice -ge 1 ]] && [[ $proj_choice -le ${#projects[@]} ]]; then
      project_name="${projects[$((proj_choice-1))]}"
      project_dir="${project_paths[$((proj_choice-1))]}"
      echo ""
      echo -e "${GREEN}✓ Selected: $project_name${NC}"
      echo ""
    else
      echo -e "${RED}Invalid selection${NC}"
      press_enter
      return
    fi
  else
    if [[ "$CONTEXT_TYPE" == "remote" ]]; then
      echo -e "Using current project on ${REMOTE_HOST}: ${GREEN}${project_name}${NC}"
    else
      echo -e "Using current project: ${GREEN}${project_name}${NC}"
    fi
    echo ""
  fi

  # Get available scripts
  echo ""
  echo "Fetching npm scripts from ${project_name}..."

  # Resolve project directory if not already set
  if [[ -z "$project_dir" ]]; then
    # Try to resolve project locally
    if [[ -d "${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}/${project_name}" ]]; then
      project_dir="${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}/${project_name}"
    elif [[ -d "${LOCAL_ROOT_DIR}/${project_name}" ]]; then
      project_dir="${LOCAL_ROOT_DIR}/${project_name}"
    else
      # Try prefix match
      local matches
      matches=$(find "${LOCAL_ROOT_DIR}/${LOCAL_NAMESPACE}" -maxdepth 1 -name "${project_name}*" -type d 2>/dev/null || true)
      if [[ -z "$matches" ]]; then
        matches=$(find "${LOCAL_ROOT_DIR}" -maxdepth 1 -name "${project_name}*" -type d 2>/dev/null || true)
      fi

      local count
      count=$(echo "$matches" | wc -l | tr -d ' ')
      if [[ "$count" -eq 1 && -n "$matches" ]]; then
        project_dir="$matches"
      else
        echo -e "${RED}Project not found or multiple matches${NC}"
        press_enter
        return
      fi
    fi
  fi

  # Verify package.json exists locally (always)
  if [[ ! -f "$project_dir/package.json" ]]; then
    echo -e "${RED}No package.json found in $project_dir locally${NC}"
    press_enter
    return
  fi

  # Parse scripts with descriptions
  clear
  print_header
  echo -e "${BOLD}NPM Scripts for: $(basename "$project_dir")${NC}"
  echo ""

  local scripts
  # Parse scripts locally (always, as files are synced)
  scripts=$(node -e "
    const p = require('$project_dir/package.json');
    const scripts = p.scripts || {};
    const info = p['scripts-info'] || {};
    const keys = Object.keys(scripts).sort();
    keys.forEach((k, i) => {
      const desc = info[k] || scripts[k];
      console.log(\`\${i+1}|\${k}|\${desc}\`);
    });
  " 2>/dev/null || echo "")

  if [[ -z "$scripts" ]]; then
    echo -e "${RED}No scripts found${NC}"
    press_enter
    return
  fi

  # Display scripts
  declare -A script_map
  local idx=1
  echo "Available commands:"
  echo ""
  while IFS='|' read -r num name desc; do
    script_map[$num]="$name"
    printf "${GREEN}%3s${NC}) ${BOLD}%-30s${NC} %s\n" "$num" "$name" "$desc"
    idx=$((idx + 1))
  done <<< "$scripts"

  echo ""
  echo "(Press Enter to return to main menu)"
  echo ""
  echo -n "Select command to run (number): "
  read -r cmd_choice

  if [[ -z "$cmd_choice" || "$cmd_choice" == "0" ]]; then
    return
  fi

  local cmd_name="${script_map[$cmd_choice]}"
  if [[ -z "$cmd_name" ]]; then
    echo "Invalid selection"
    press_enter
    return
  fi

  # Check if dangerous command
  local dangerous_patterns="rebuild|reset|delete|drop|clear|down"
  if [[ "$cmd_name" =~ $dangerous_patterns ]]; then
    echo ""
    if ! confirm "⚠️  This command may be destructive. Continue?"; then
      echo "Cancelled"
      press_enter
      return
    fi
  fi

  # Execute command
  echo ""
  if [[ "$CONTEXT_TYPE" == "remote" ]]; then
    echo -e "${CYAN}Running on remote (${REMOTE_HOST}): npm run $cmd_name${NC}"
    echo ""
    # Translate local path to remote-friendly path (using ~ to handle different home dirs)
    local remote_project_dir="${project_dir/#$HOME/\~}"
    ssh -t "$REMOTE_SSH" "cd \"$remote_project_dir\" && npm run $cmd_name"
  else
    echo -e "${CYAN}Running locally: npm run $cmd_name${NC}"
    echo ""
    # Run locally
    (cd "$project_dir" && npm run "$cmd_name")
  fi

  echo ""
  press_enter
}
