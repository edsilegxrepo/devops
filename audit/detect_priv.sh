#!/bin/bash
# -----------------------------------------------------------------------------
# Privileged User Detection Utility (detect_priv.sh)
# v1.1.0xg  2026/05/05 XDG
#
# ==============================================================================
# SCRIPT: detect_priv.sh
# OBJECTIVE: Identify and categorize users with administrative (root) access.
#
# CORE COMPONENTS:
#   1. Identity Layer: Detects UID 0 accounts (Direct Root).
#   2. Sudo Evaluation Engine: Leverages 'sudo -l -U' to process system policies.
#   3. Abstraction Parser: Joins multi-line rules and splits command lists.
#   4. Capability Mapper: Summarizes raw paths into unique Access Point binaries.
#
# FUNCTIONALITY:
#   - Detects UID 0 users who bypass sudo policy entirely.
#   - Distinguishes between Global Admin (ALL) and Restricted Sudo access.
#   - Handles NOPASSWD vs PASSWD variants for risk assessment.
#   - Correctly parses complex, multi-line sudo rules with wildcards.
#
# DATA FLOW:
#   Input (Local/LDAP/AD Users via getent) -> Root Check -> Sudo Policy Fetch ->
#   Multi-line Joining -> Tokenization -> Categorization -> Result Summary.
# ==============================================================================

set -euo pipefail

# --- Globals and Configuration ---
JSON_MODE=false

# --- Helper Functions ---

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Identify and categorize users with administrative (root) access.

Options:
  --json      Output results in neutral, monochrome JSON format.
  -h, --help  Display this help message and exit.

EOF
  exit 0
}

log_header() {
  [[ "${JSON_MODE}" == "true" ]] && return
  echo -e "\n----- $1 -----"
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      usage
      ;;
  esac
done

render_json() {
  local timestamp
  timestamp=$(date -Iseconds)
  local json="{"
  json+="\"timestamp\":\"${timestamp}\","
  
  # 1. Direct Root
  json+="\"direct_root\":["
  local roots
  roots=$(getent passwd | awk -F: '$3 == 0 {print "\"" $1 "\""}' | tr '\n' ',' | sed 's/,$//')
  json+="${roots}],"
  
  # 2. Full Sudo
  json+="\"full_sudo\":["
  local first=true
  for entry in "${full_sudo_users[@]:-}"; do
    [[ -z "${entry}" ]] && continue
    [[ "${first}" == "false" ]] && json+=","
    IFS='|' read -r name stype <<< "${entry}"
    json+="{\"user\":\"${name}\",\"type\":\"${stype//[\[\]]/}\"}"
    first=false
  done
  json+="],"
  
  # 3. Restricted Sudo
  json+="\"restricted_sudo\":["
  first=true
  for entry in "${restricted_sudo_users[@]:-}"; do
    [[ -z "${entry}" ]] && continue
    [[ "${first}" == "false" ]] && json+=","
    IFS='|' read -r name count points <<< "${entry}"
    # Convert comma-separated points to JSON array
    local points_json
    points_json=$(echo "${points}" | tr ',' '\n' | awk '{print "\"" $0 "\""}' | tr '\n' ',' | sed 's/,$//')
    json+="{\"user\":\"${name}\",\"command_count\":${count},\"access_points\":[${points_json}]}"
    first=false
  done
  json+="]"
  json+="}"
  
  if command -v jq >/dev/null 2>&1; then
    # Use monochrome output to ensure neutrality (no ANSI colors)
    echo "${json}" | jq -M .
  else
    echo "${json}"
  fi
}

# --- Pre-flight Checks ---
# Objective: Ensure the operator has sufficient privileges to query the sudo engine
# for other users. This prevents partial/inaccurate audit results.
if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: This script must be run as root to evaluate policies for other users." >&2
  exit 1
fi

log_header "Detecting privileged users"

# 1. Detect Direct Root Access (UID 0)
if [[ "${JSON_MODE}" == "false" ]]; then
  echo "Direct Root Access (UID 0):"
  getent passwd | awk -F: '$3 == 0 {printf "  - %-15s (UID 0)\n", $1}'
fi

# 2. Detect Full vs Restricted Sudo Access
# Purpose: Categorize users based on the scope of their root-level capabilities.
full_sudo_users=()
restricted_sudo_users=()

# Iterate through all users discovered by getent.
# This approach ensures we capture users from all NSS sources (files, sssd, etc).
for u in $(getent passwd | cut -d: -f1); do 
  # Fetch effective sudo policy for the user.
  # Internal Sudo Engine Check:
  # -n (non-interactive) to avoid prompt hangs.
  # -l (list) to show permissions.
  # -U (User) to check another user's permissions (requires root/sudo).
  sudo_out=$(sudo -n -l -U "${u}" 2>/dev/null || true)
  
  if [[ -n "${sudo_out}" ]]; then
    # --- Abstraction Layer: Sudo Policy Parser ---
    
    # 1. Join continuation lines:
    #    sudo -l wraps long command lists using 8+ leading spaces on the next line.
    #    The sed logic below joins these continuations to the parent rule for accurate parsing.
    # 2. Filter rules:
    #    We focus only on rules targeting (ALL) or (root) identities.
    clean_rules=$(echo "${sudo_out}" | sed -E ':a;N;$!ba;s/\n[[:space:]]{5,}/ /g' | grep -iE "^[[:space:]]+\([^)]*(ALL|root)[^)]*\)" || true)
    
    if [[ -n "${clean_rules}" ]]; then
      # A. Check for Full Sudo (Global ALL command)
      #    A user is considered a full administrator if they can execute the 'ALL' command
      #    under a root or ALL RunAs identity.
      if echo "${clean_rules}" | grep -qiE "\([^)]*(ALL|root)[^)]*\).*\bALL\b"; then
        type="[PASSWD]"
        # Detect if the 'ALL' privilege is granted without a password requirement.
        echo "${clean_rules}" | grep -qi "NOPASSWD:.*\bALL\b" && type="[NOPASSWD]"
        full_sudo_users+=("${u}|${type}")
      else
        # B. Check for Restricted Sudo (Specific commands)
        
        # 1. Tokenization:
        #    Strip the RunAs/Flag prefixes to isolate the comma-separated command list.
        #    Then split commas into individual newlines for per-command processing.
        raw_commands=$(echo "${clean_rules}" | sed -E 's/^[[:space:]]+\([^)]+\)([[:space:]]+[A-Z]+:)?//g' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v "^$" || true)
        
        if [[ -n "${raw_commands}" ]]; then
          # 2. Aggregation:
          #    Calculate the total number of command entries.
          cmd_count=$(echo "${raw_commands}" | wc -l)
          
          # 3. Abstraction (Capability Mapping):
          #    Extract the unique base binaries (the first word of each command string)
          #    to summarize the user's effective surface area (e.g. systemctl, nginx).
          access_points=$(echo "${raw_commands}" | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')
          restricted_sudo_users+=("${u}|${cmd_count}|${access_points}")
        fi
      fi
    fi
  fi
done

# --- Report Generation Section ---

if [[ "${JSON_MODE}" == "true" ]]; then
  render_json
else
  # Output Full Sudo Users
  echo -e "\nFull Sudo Privileges (Global Administrative Access):"
  if [[ ${#full_sudo_users[@]} -eq 0 ]]; then
    echo "  - None detected"
  else
    for entry in "${full_sudo_users[@]}"; do
      IFS='|' read -r name stype <<< "${entry}"
      printf "  - %-15s %s\n" "${name}" "${stype}"
    done
  fi

  # Output Restricted Sudo Users
  echo -e "\nRestricted Sudo Privileges (Limited Commands as Root):"
  if [[ ${#restricted_sudo_users[@]} -eq 0 ]]; then
    echo "  - None detected"
  else
    printf "  %-15s %-10s %s\n" "USER" "CMDS" "ACCESS POINTS (BINARIES)"
    printf "  %-15s %-10s %s\n" "----" "----" "------------------------"
    for entry in "${restricted_sudo_users[@]}"; do
      IFS='|' read -r name count points <<< "${entry}"
      printf "  %-15s %-10s %s\n" "${name}" "${count}" "${points}"
    done
  fi
  echo ""
fi
