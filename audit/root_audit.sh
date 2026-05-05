#!/bin/bash
# -----------------------------------------------------------------------------
# Audit and Remediate account security (root_audit.sh)
# v1.0.0xg  2026/04/23  XDG
#
# ==============================================================================
# SCRIPT: root_audit.sh
# OBJECTIVE: Audit and Remediate root account security for RHEL 8+ and Ubuntu 22.04+.
#
# CORE COMPONENTS:
#   1. Audit Engine: Non-destructive verification of security posture.
#   2. Remediation Engine: Hardening logic (Passwords, Locking, SSH).
#   3. Safety & Filesystem Layer: Atomic edits, backups, and attribute handling.
#   4. Sudo Safety Kill-Switch: Prevents administrative lockout.
#   5. JSON Engine: CI/CD friendly reporting.
#
# FUNCTIONALITY:
#   - Detects and fixes weak password hashes (SHA-512/Yescrypt).
#   - Enforces 32-character complex password policy.
#   - Locks the root account to prevent direct interactive login.
#   - Hardens SSH configuration (PermitRootLogin no) atomically.
#   - Supports simulation mode (--simulate) for risk assessment.
#   - Supports JSON mode (--json) for automation integration.
#
# DATA FLOW:
#   Input (CLI/Env) -> Root Check -> Audit Checks -> Safety Verification ->
#   Remediation (if enabled) -> Post-Audit -> Result Summary (Text/JSON).
# ==============================================================================

set -euo pipefail

# --- Configuration (Non-hardcoded) ---
# Environment variable overrides allow for flexible integration in CI/CD.
readonly MIN_PASS_LEN="${MIN_PASS_LEN:-32}"
readonly TARGET_USER="${TARGET_USER:-root}"
readonly SHADOW_FILE="${SHADOW_FILE:-/etc/shadow}"
readonly SSH_CONFIG="${SSH_CONFIG:-/etc/ssh/sshd_config}"
readonly SSH_CONFIG_DIR="${SSH_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
readonly SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers}"
readonly SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
readonly PASS_CHARS="${PASS_CHARS:-A-Za-z0-9#%^&}"
readonly SPEC_CHARS_REGEX="${SPEC_CHARS_REGEX:-[#%^&]}"
readonly SUFFIX_DELIM="${SUFFIX_DELIM:-.}"

# --- Globals ---
# State variables used across the execution lifecycle.
MODE="audit"
SIMULATE=false
JSON_MODE=false
LOG_FILE=""

# JSON State Accumulator
declare -A JSON_AUDIT=(
  ["password_exists"]="unknown"
  ["account_locked"]="unknown"
  ["ssh_disabled"]="unknown"
  ["hash_strong"]="unknown"
  ["sudo_user_count"]=0
  ["sudo_user_list"]=""
)
declare -A JSON_REMED=(
  ["password_updated"]="false"
  ["account_locked"]="false"
  ["ssh_hardened"]="false"
  ["backup_created"]="false"
  ["sudo_safety_passed"]="unknown"
)

declare -A JSON_RESTORE=(
  ["shadow_restored"]="false"
  ["ssh_restored"]="false"
)

# --- Logging Functions ---
# Standardized output for INFO, WARN, FAIL, OK, and SIMU states.
# All logging is redirected to STDERR to keep STDOUT clean for JSON output.

log_info() {
  local msg="[INFO] $1"
  [[ -n "${LOG_FILE}" ]] && echo "$(date -Iseconds) ${msg}" >> "${LOG_FILE}"
  [[ "${JSON_MODE}" == "true" ]] && return 0
  echo -e "[\e[34mINFO\e[0m] $1" >&2
}
log_warn() {
  local msg="[WARN] $1"
  [[ -n "${LOG_FILE}" ]] && echo "$(date -Iseconds) ${msg}" >> "${LOG_FILE}"
  [[ "${JSON_MODE}" == "true" ]] && return 0
  echo -e "[\e[33mWARN\e[0m] $1" >&2
}
log_err() {
  local msg="[FAIL] $1"
  [[ -n "${LOG_FILE}" ]] && echo "$(date -Iseconds) ${msg}" >> "${LOG_FILE}"
  [[ "${JSON_MODE}" == "true" ]] && return 0
  echo -e "[\e[31mFAIL\e[0m] $1" >&2
}
log_succ() {
  local msg="[OK]   $1"
  [[ -n "${LOG_FILE}" ]] && echo "$(date -Iseconds) ${msg}" >> "${LOG_FILE}"
  [[ "${JSON_MODE}" == "true" ]] && return 0
  echo -e "[\e[32mOK\e[0m]   $1" >&2
}
log_sim() {
  local msg="[SIMU] $1"
  [[ -n "${LOG_FILE}" ]] && echo "$(date -Iseconds) ${msg}" >> "${LOG_FILE}"
  [[ "${JSON_MODE}" == "true" ]] && return 0
  echo -e "[\e[35mSIMU\e[0m] $1" >&2
}

print_divider() {
  # Objective: Print a horizontal line for visual separation.
  [[ -n "${LOG_FILE}" ]] && printf '%0.s-' {1..82} >> "${LOG_FILE}" && echo "" >> "${LOG_FILE}"
  [[ "${JSON_MODE}" == "true" ]] && return 0
  printf '%0.s-' {1..82} >&2
  echo "" >&2
}

apply_selinux_context() {
  # Objective: Ensure the target file retains its correct SELinux security context.
  # Platform Logic: SELinux is RHEL-specific. On AppArmor-based systems (Ubuntu),
  # this function is a safe no-op.
  local file="$1"
  if command -v selinuxenabled > /dev/null 2>&1 && selinuxenabled; then
    if command -v restorecon > /dev/null 2>&1; then
      log_info "Applying SELinux security context to ${file}..."
      if ! restorecon "${file}" 2> /dev/null; then
        log_warn "Failed to apply SELinux context to ${file} (restorecon error)."
      fi
    fi
  fi
}

# --- JSON Reporting Engine ---

render_json() {
  local status="${1:-failure}"
  local json
  json="{"
  json+="\"timestamp\":\"$(date -Iseconds)\","
  json+="\"target_user\":\"${TARGET_USER}\","
  json+="\"mode\":\"${MODE}\","

  local imm_detected="false"
  is_immutable "${SHADOW_FILE}" && imm_detected="true"
  is_immutable "${SSH_CONFIG}" && imm_detected="true"
  json+="\"immutable\":${imm_detected},"

  json+="\"simulate\":${SIMULATE},"
  json+="\"status\":\"${status}\""

  # Audit Results (only in audit mode)
  if [[ "${MODE}" == "audit" ]]; then
    json+=",\"audit\":{"
    json+="\"password_exists\":\"${JSON_AUDIT[password_exists]}\","
    json+="\"account_locked\":\"${JSON_AUDIT[account_locked]}\","
    json+="\"ssh_disabled\":\"${JSON_AUDIT[ssh_disabled]}\","
    json+="\"hash_strong\":\"${JSON_AUDIT[hash_strong]}\","
    json+="\"sudo_user_count\":${JSON_AUDIT[sudo_user_count]},"
    json+="\"sudo_user_list\":\"${JSON_AUDIT[sudo_user_list]}\""
    json+="}"
  fi

  # Remediation Results (only in remediate mode)
  if [[ "${MODE}" == "remediate" ]]; then
    json+=",\"remediation\":{"
    json+="\"password_updated\":${JSON_REMED[password_updated]},"
    json+="\"account_locked\":${JSON_REMED[account_locked]},"
    json+="\"ssh_hardened\":${JSON_REMED[ssh_hardened]},"
    json+="\"backup_created\":${JSON_REMED[backup_created]},"
    json+="\"sudo_safety_passed\":\"${JSON_REMED[sudo_safety_passed]}\""
    json+="}"
  fi

  # Restore Results (only in restore mode)
  if [[ "${MODE}" == "restore" ]]; then
    json+=",\"restore\":{"
    json+="\"shadow_restored\":${JSON_RESTORE[shadow_restored]},"
    json+="\"ssh_restored\":${JSON_RESTORE[ssh_restored]}"
    json+="}"
  fi

  json+="}"

  if command -v jq > /dev/null 2>&1; then
    echo "${json}" | jq .
  else
    echo "${json}"
  fi
}

# --- Utility Functions ---

usage() {
  cat << EOF

Usage: $0 [--mode audit|remediate|restore] [options]

Options:
  * AUDIT Mode
      --mode audit        Read-only security check (default)
  * REMEDIATE Mode
      --mode remediate    Fix security issues (if missing only)
      --password <PASS>   Provide a ${MIN_PASS_LEN}-char password
                          Note: Passwords on the command line may be visible in process lists.
                          Prefer setting the ROOT_PASSWORD environment variable instead.
      --generate          Generate a ${MIN_PASS_LEN}-char password
  * RESTORE MODE
      --mode restore      Restore configuration from backup
      --suffix <SUFFIX>   Suffix of backup to restore (e.g. 20260423160441)
      --list-backups      List all available backups in a table
      --latest            Automatically restore the most recent backup
      --oldest            Automatically restore the oldest available backup
  * COMMON
      --simulate          Explain changes without applying them (Remediate/Restore mode only)
      --json              Output results in CI/CD friendly JSON format
      --log <file>        Log all messages to a specific file

EOF
  return 1
}

check_root() {
  # Objective: Ensure sufficient privileges for reading protected system files.
  # Verification Layer:
  #   1. EUID Check: Confirm process is running with root-level effective UID (0).
  #   2. Authorization Check: Execute 'sudo -l' and perform fuzzy matching for (ALL : ALL) ALL.
  #      This ensures the operator possesses a full administrative policy, not just a root shell.
  local sudo_out
  if ! sudo_out=$(sudo -l 2> /dev/null); then
    log_err "This script must be run with sudo/root privileges (sudo -l failed)."
    return 1
  fi

  # Fuzzy matching handles variations like (ALL : ALL) ALL, (root) ALL, or (ALL) ALL.
  if [[ "${EUID}" -ne 0 ]] || ! echo "${sudo_out}" | grep -qiE "\((ALL|root)([[:space:]]*:[[:space:]]*(ALL|root))?\)[[:space:]]*ALL"; then
    log_err "Administrative check failed: Full (ALL : ALL) ALL privileges not detected."
    return 1
  fi
  return 0
}

# --- Safety Check: Sudo Users ---

get_sudo_group_members() {
  # Objective: Retrieve all users in a group (explicit members + primary GID members).
  local grp="${1}"
  local gid
  gid=$(getent group "${grp}" | cut -d: -f3 || echo "")

  # 1. Explicit members from /etc/group
  getent group "${grp}" | cut -d: -f4 | tr ',' ' ' || true

  # 2. Users whose primary GID matches this group
  if [[ -n "${gid}" ]]; then
    getent passwd | awk -F: -v gid="${gid}" '$4 == gid {print $1}'
  fi
}

get_sudoers_paths() {
  # Objective: Identify all active sudoers configuration files.
  echo "${SUDOERS_FILE}"
  if [[ -d "${SUDOERS_DIR}" ]]; then
    find "${SUDOERS_DIR}" -type f 2> /dev/null
  fi
}

verify_sudo_users() {
  # Objective: PRE-REMEDIATION KILL-SWITCH.
  # Logic: Verify at least one non-root user has full sudo access.
  # This version supports User_Aliases and flexible whitespace.
  log_info "Verifying authorized sudo privileges (including Aliases and Groups)..."
  local sudo_users=()
  
  local paths
  paths=$(get_sudoers_paths)
  # Flexible regex: matches 'ALL = ALL', 'ALL=(ALL) ALL', 'ALL= NOPASSWD: ALL', etc.
  local sudo_regex="ALL[[:space:]]*=?[[:space:]]*(\([^)]*\)[[:space:]]*)?(NOPASSWD:[[:space:]]*)?ALL"

  local active_lines
  active_lines=$(echo "${paths}" | xargs grep -vhE "^[[:blank:]]*#|^[[:blank:]]*$" 2> /dev/null || true)

  # Helper to recursively resolve Users, Groups, and Aliases
  resolve_sudo_entity() {
    local entity="${1}"
    # 1. Handle Groups (%group)
    if [[ "${entity}" == "%"* ]]; then
      get_sudo_group_members "${entity#%}"
      return
    fi
    # 2. Handle User_Aliases
    local alias_line
    alias_line=$(echo "${active_lines}" | grep -iE "^[[:space:]]*User_Alias[[:space:]]+${entity}[[:space:]]*=" | head -n 1)
    if [[ -n "${alias_line}" ]]; then
      local members
      members=$(echo "${alias_line}" | cut -d= -f2- | tr ',' ' ')
      for m in ${members}; do
        resolve_sudo_entity "${m}"
      done
      return
    fi
    # 3. Literal User
    echo "${entity}"
  }

  # 2. Identify all entities (Users/Groups/Aliases) with full sudo access
  local authorized_entities
  authorized_entities=$(echo "${active_lines}" | grep -E "${sudo_regex}" | awk '{print $1}' || true)

  for entity in ${authorized_entities}; do
    local resolved
    resolved=$(resolve_sudo_entity "${entity}")
    for r in ${resolved}; do
       [[ -z "${r}" || "${r}" == "root" ]] && continue
       # Skip if already verified to prevent duplicate messages
       [[ " ${sudo_users[*]:-} " =~ " ${r} " ]] && continue
       
       # 1. Primary Validation: Use sudo's internal engine.
       if sudo -l -U "${r}" 2>/dev/null | grep -qiE "\((ALL|root)[^)]*\).*ALL"; then
         sudo_users+=("${r}")
         continue
       fi

       # 2. Heuristic Fallback
       log_info "Verified administrator '${r}' via policy files (Direct system check was restricted)."
       sudo_users+=("${r}")
    done
  done

  # 3. Dynamic Environment Check: If running via sudo, validate the caller.
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    # Skip if already verified
    if [[ ! " ${sudo_users[*]:-} " =~ " ${SUDO_USER} " ]]; then
       # Validate the SUDO_USER same as others for consistency
       if sudo -l -U "${SUDO_USER}" 2>/dev/null | grep -qiE "\((ALL|root)[^)]*\).*ALL"; then
          sudo_users+=("${SUDO_USER}")
       else
          # Even if validation fails (e.g. TTY), we know the caller used sudo to run this.
          log_info "Verified administrator '${SUDO_USER}' via environment (Direct system check was restricted)."
          sudo_users+=("${SUDO_USER}")
       fi
    fi
  fi

  local unique_list
  unique_list=$(echo "${sudo_users[@]:-}" | tr ' ' '\n' | grep -vE "^(root|ALL)$" | grep -v "^$" | sort -u || true)

  local count
  count=$(echo "${unique_list}" | grep -c . || true)
  local user_names
  user_names=$(echo "${unique_list}" | tr '\n' ',' | sed 's/,$//')

  JSON_AUDIT["sudo_user_count"]="${count}"
  JSON_AUDIT["sudo_user_list"]="${user_names}"

  if [[ "${count}" -eq 0 ]]; then
    log_err "CRITICAL SAFETY CHECK FAILED: No authorized non-root administrators found (checked Users, Groups, and Aliases)."
    [[ "${MODE}" == "remediate" ]] && log_err "Aborting remediation to prevent total lockout."
    JSON_REMED["sudo_safety_passed"]="false"
    return 1
  fi

  log_succ "Found ${count} authorized administrator(s): ${user_names}. Safety check passed."
  JSON_REMED["sudo_safety_passed"]="true"
  return 0
}

# --- Attribute and Backup Helpers ---

is_immutable() {
  # Objective: Detect 'i' (immutable) attribute that blocks all write operations.
  local file="${1}"
  if command -v lsattr > /dev/null 2>&1; then
    lsattr "${file}" 2> /dev/null | awk '{print $1}' | grep -q 'i'
  else
    return 1
  fi
}

backup_file() {
  # Objective: Create timestamped copy for rollback capability.
  # Constraint: Backups MUST be compressed with gzip to prevent accidental loading.
  # Security: Explicitly preserve permissions and ownership from the source.
  local file="${1}"
  [[ ! -f "${file}" ]] && return 1
  local timestamp
  timestamp=$(date +"%Y%m%d%H%M%S")
  local backup="${file}${SUFFIX_DELIM}${timestamp}.gz"
  log_info "Backing up ${file} to ${backup}..."

  # Compress to a temporary file first to apply permissions before the final move
  local tmp_bkp
  tmp_bkp=$(mktemp "${backup}.XXXXXX")
  gzip -c "${file}" > "${tmp_bkp}" || {
    log_err "Failed to compress backup for ${file}."
    rm -f "${tmp_bkp}"
    return 1
  }

  # Mirror metadata from the original file
  chmod --reference="${file}" "${tmp_bkp}"
  chown --reference="${file}" "${tmp_bkp}"

  mv "${tmp_bkp}" "${backup}" || {
    log_err "Failed to move backup to ${backup}."
    rm -f "${tmp_bkp}"
    return 1
  }
  JSON_REMED["backup_created"]="true"
}

prepare_for_edit() {
  # Objective: Unified state management before file modification.
  # Flow: Backup -> Handle Immutability -> Ensure Writeability.
  local file="${1}"
  backup_file "${file}" || {
    log_err "Cannot backup ${file}"
    return 1
  }
  local was_immutable=1
  if is_immutable "${file}"; then
    log_info "File ${file} is immutable. Removing flag temporarily..."
    chattr -i "${file}" || {
      log_err "Failed to remove immutable flag from ${file}."
      return 1
    }
    was_immutable=0
  fi
  if [[ ! -w "${file}" ]]; then
    log_warn "File ${file} is not writeable. Attempting to chmod +w..."
    chmod +w "${file}"
  fi
  echo "${was_immutable}"
}

finalize_edit() {
  # Objective: Complete the editing process by restoring attributes and security context.
  local file="${1}"
  local was_immutable="${2}"
  if [[ "${was_immutable}" -eq 0 ]]; then
    log_info "Restoring immutable flag for ${file}..."
    chattr +i "${file}" || log_warn "Failed to restore immutable flag for ${file}."
  fi
  apply_selinux_context "${file}"
}

# --- Password and Audit Logic ---

validate_password() {
  # Objective: Enforce 32-char complexity policy (A-Z, a-z, 0-9, special).
  local pass="${1:-}"
  [[ ${#pass} -lt "${MIN_PASS_LEN}" ]] && return 1
  [[ ! "${pass}" =~ [a-z] ]] && return 1
  [[ ! "${pass}" =~ [A-Z] ]] && return 1
  [[ ! "${pass}" =~ [0-9] ]] && return 1
  [[ ! "${pass}" =~ ${SPEC_CHARS_REGEX} ]] && return 1
  return 0
}

generate_password() {
  # Objective: Generate a policy-compliant password from /dev/urandom.
  local pass=""
  while true; do
    pass=$(tr -dc "${PASS_CHARS}" < /dev/urandom | head -c "${MIN_PASS_LEN}")
    if validate_password "${pass}"; then
      echo "${pass}"
      return 0
    fi
  done
}

get_user_shadow() {
  # Objective: Extract the shadow entry for the target user directly from source.
  grep "^${TARGET_USER}:" "${SHADOW_FILE}" | cut -d: -f2 || echo ""
}

audit_no_password() {
  # Objective: Verify that the root user has a password defined.
  local shadow
  shadow=$(get_user_shadow)
  if [[ -z "${shadow}" ]] || [[ "${shadow}" == "!" ]] || [[ "${shadow}" == "!!" ]] || [[ "${shadow}" == "*" ]]; then
    log_warn "User '${TARGET_USER}' has NO PASSWORD set."
    JSON_AUDIT["password_exists"]="false"
    return 1
  fi
  log_succ "User '${TARGET_USER}' has a password hash."
  JSON_AUDIT["password_exists"]="true"
  return 0
}

audit_unlocked() {
  # Objective: Verify if the account is locked in the shadow file.
  local shadow
  shadow=$(get_user_shadow)
  if [[ "${shadow}" != "!"* ]] && [[ "${shadow}" != "*"* ]]; then
    log_warn "User '${TARGET_USER}' is UNLOCKED."
    JSON_AUDIT["account_locked"]="false"
    return 1
  fi
  log_succ "User '${TARGET_USER}' is locked."
  JSON_AUDIT["account_locked"]="true"
  return 0
}

audit_ssh_login() {
  # Objective: Audit effective sshd configuration for root login permissions.
  local permit
  # Use -f to ensure we audit the specific file we manage.
  permit=$(sshd -T -f "${SSH_CONFIG}" 2> /dev/null | grep -i '^permitrootlogin' | awk '{print $2}' || echo "error")

  # Requirement: Explicitly inspect all configuration files for unauthorized 'PermitRootLogin' directives.
  # We flag ANY 'PermitRootLogin' found in the main config or modular files (excluding our authorized policy).
  # This includes commented-out lines to ensure a completely clean configuration.
  local policy_file="${SSH_CONFIG_DIR}/99-secure-policy.conf"
  local unauthorized_configs
  unauthorized_configs=$(grep -riE "^[[:space:]]*#?[[:space:]]*PermitRootLogin\b" "${SSH_CONFIG}" "${SSH_CONFIG_DIR}" 2> /dev/null | grep -v "${policy_file}" || true)

  # Logic: Ensure that the modular configuration directory is explicitly included.
  local included
  included=$(grep -iE "^[[:space:]]*Include[[:space:]]+${SSH_CONFIG_DIR}/" "${SSH_CONFIG}" 2> /dev/null || true)

  if [[ -n "${unauthorized_configs}" ]]; then
    log_warn "Unauthorized 'PermitRootLogin' directives found in configuration files (should be centralized in ${policy_file})."
    JSON_AUDIT["ssh_disabled"]="false"
    return 1
  fi

  if [[ "${permit}" == "no" ]]; then
    if [[ -z "${included}" ]]; then
      log_err "Structural Audit FAILED: Modular Include directive missing in ${SSH_CONFIG}."
      JSON_AUDIT["ssh_disabled"]="false"
      return 1
    fi
    log_succ "Direct root SSH login is disabled and policy is centralized."
    JSON_AUDIT["ssh_disabled"]="true"
    return 0
  elif [[ "${permit}" == "error" ]] || [[ "${permit}" == "unknown" ]]; then
    log_err "Could not reliably determine SSH root login status (Result: ${permit})."
    JSON_AUDIT["ssh_disabled"]="unknown"
    return 1
  else
    log_warn "Direct root SSH login is ENABLED (${permit})."
    JSON_AUDIT["ssh_disabled"]="false"
    return 1
  fi
}

verify_sshd_config() {
  # Objective: Validate the integrity and structure of the SSH configuration.
  # This prevents service failures and ensures policies are correctly loaded.
  if [[ "${SIMULATE}" == "true" ]]; then
    log_sim "Would verify configuration using 'sshd -t' and check for modular Include."
    return 0
  fi

  # 1. Syntax Check
  if ! sshd -t -f "${SSH_CONFIG}" 2> /dev/null; then
    log_err "SSH configuration validation FAILED (sshd -t detected syntax errors)."
    return 1
  fi

  # 2. Structural Check: Ensure the modular Include directive exists.
  # Without this, our modular policy files in .d/ will be ignored.
  if ! grep -qE "^[[:space:]]*Include[[:space:]]+${SSH_CONFIG_DIR}/" "${SSH_CONFIG}" 2> /dev/null; then
    log_err "Structural Audit FAILED: Modular Include directive missing in ${SSH_CONFIG}."
    return 1
  fi

  log_info "SSH configuration validation and structural audit passed."
  return 0
}

audit_hashes() {
  # Objective: Verify that modern, strong hashing algorithms are in use.
  local shadow
  shadow=$(get_user_shadow)

  # Extract algorithm identifier (e.g. 1 for MD5, 6 for SHA-512, y for Yescrypt)
  local algo_id
  # Remove leading ! or * (lock chars) then extract field between first two $
  algo_id=$(echo "${shadow}" | sed 's/^[!*]*//' | cut -d'$' -f2 || echo "")

  local algo_name="Unknown"
  case "${algo_id}" in
    1) algo_name="MD5" ;;
    2a | 2b | 2y) algo_name="Blowfish/Bcrypt" ;;
    5) algo_name="SHA-256" ;;
    6) algo_name="SHA-512" ;;
    y) algo_name="Yescrypt" ;;
    7) algo_name="Scrypt" ;;
  esac

  if [[ "${algo_id}" == "6" ]] || [[ "${algo_id}" == "y" ]]; then
    log_succ "Password hash [${algo_name}] is strong."
    JSON_AUDIT["hash_strong"]="true"
    return 0
  fi

  if [[ -z "${algo_id}" ]]; then
    log_warn "Password hash does not exist."
  else
    log_warn "Password hash [${algo_name}] is weak or uses a deprecated format."
  fi
  JSON_AUDIT["hash_strong"]="false"
  return 1
}

run_full_audit() {
  # Objective: Orchestrate the complete suite of security checks.
  # Returns: Total number of failed checks (findings).
  local findings=0
  audit_no_password || ((findings++))
  audit_unlocked || ((findings++))
  audit_ssh_login || ((findings++))
  audit_hashes || ((findings++))

  # Audit sudoers population (Safety metric)
  verify_sudo_users || ((findings++))

  return "${findings}"
}

# --- Remediation Functions ---

remediate_password() {
  # Objective: Securely update the root password.
  local target_pass="${1}"
  if [[ "${SIMULATE}" == "true" ]]; then
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    log_sim "Would enforce strong 32-char password for '${TARGET_USER}' using chpasswd."
    log_sim "Action: Create backup (Suffix: ${timestamp}) for file ${SHADOW_FILE}"
    return 0
  fi
  local was_immutable
  was_immutable=$(prepare_for_edit "${SHADOW_FILE}")
  log_info "Enforcing strong password for '${TARGET_USER}'..."

  local remed_pass_fail=0
  # Use printf instead of echo to avoid mangling passwords starting with - or containing \
  printf "%s:%s\n" "${TARGET_USER}" "${target_pass}" | chpasswd || remed_pass_fail=1

  # Verification: Ensure the hash was actually updated and is strong.
  local new_hash
  new_hash=$(get_user_shadow)
  if [[ "${new_hash}" == *"\$6\$"* ]] || [[ "${new_hash}" == *"\$y\$"* ]]; then
    log_succ "Password for '${TARGET_USER}' updated and verified as strong."
  else
    log_err "Password update failed verification: Hash is missing or weak."
    remed_pass_fail=1
  fi

  JSON_REMED["password_updated"]="true"
  finalize_edit "${SHADOW_FILE}" "${was_immutable}"
  return "${remed_pass_fail}"
}

remediate_lock() {
  # Objective: Lock the root account via passwd utility.
  if [[ "${SIMULATE}" == "true" ]]; then
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    log_sim "Would lock the '${TARGET_USER}' account in ${SHADOW_FILE} (passwd -l)."
    log_sim "Action: Create backup (Suffix: ${timestamp}) for file ${SHADOW_FILE}"
    return 0
  fi
  local was_immutable
  was_immutable=$(prepare_for_edit "${SHADOW_FILE}")
  log_info "Locking '${TARGET_USER}' account..."
  passwd -l "${TARGET_USER}" || {
    log_err "Failed to lock account '${TARGET_USER}'."
    return 1
  }
  log_succ "User '${TARGET_USER}' locked."
  JSON_REMED["account_locked"]="true"
  finalize_edit "${SHADOW_FILE}" "${was_immutable}"
  return 0
}

reload_ssh_service() {
  # Objective: Detect active SSH service and reload configuration atomically.
  local ssh_service="sshd"
  systemctl is-active --quiet "${ssh_service}" || ssh_service="ssh"
  if [[ "${SIMULATE}" == "true" ]]; then
    log_sim "Would reload SSH service ('${ssh_service}') using systemctl reload."
    return 0
  fi
  if systemctl is-active --quiet "${ssh_service}"; then
    systemctl reload "${ssh_service}"
    log_succ "SSH service ('${ssh_service}') reloaded."
  else
    log_warn "SSH service is not active. Config updated but not reloaded."
  fi
}

remediate_ssh() {
  # Objective: Harden SSH configuration via modular "policy-in-d" pattern.
  # 1. Cleanup main sshd_config (remove ALL 'PermitRootLogin' directives)
  # 2. Ensure 'Include /etc/ssh/sshd_config.d/*.conf' is present.
  # 3. Recursively remove ALL 'PermitRootLogin' directives from modular config files.
  # 4. Remove legacy modular files (specifically 01-permitrootlogin.conf).
  # 5. Create new modular policy file (99-secure-policy.conf).
  #    Note: Disabling direct SSH access is VERY important for security compliance.

  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)

  if [[ "${SIMULATE}" == "true" ]]; then
    log_sim "Would modularize SSH hardening (Comprehensive Cleanup):"
    log_sim "  - Backup ${SSH_CONFIG} (Suffix: ${timestamp})"
    log_sim "  - Remove ALL instances of 'PermitRootLogin' from ${SSH_CONFIG}"
    log_sim "  - Ensure modular 'Include' directive exists in ${SSH_CONFIG}"
    log_sim "  - Scan and clean ALL instances of 'PermitRootLogin' from ALL files in ${SSH_CONFIG_DIR}"
    log_sim "  - Delete legacy file ${SSH_CONFIG_DIR}/01-permitrootlogin.conf (if exists)"
    log_sim "  - Create modular policy file ${SSH_CONFIG_DIR}/99-secure-policy.conf"
    reload_ssh_service
    return 0
  fi

  log_info "Applying comprehensive modular SSH hardening..."

  # --- Part 1: Main Configuration Cleanup ---
  local was_imm_main
  was_imm_main=$(prepare_for_edit "${SSH_CONFIG}")
  local tmp_main
  tmp_main=$(mktemp "${SSH_CONFIG}.XXXXXX")

  # Requirement: Remove ALL instances of PermitRootLogin (regardless of value or if commented out)
  # This ensures that our modular policy file is the sole source of truth and prevents confusion.
  grep -viE "^[[:space:]]*#?[[:space:]]*PermitRootLogin\b" "${SSH_CONFIG}" > "${tmp_main}" || true

  if ! grep -qE "^[[:space:]]*Include[[:space:]]+${SSH_CONFIG_DIR}/" "${tmp_main}"; then
    log_info "Appending modular Include directive to the end of ${SSH_CONFIG}..."
    local header="# To modify the system-wide sshd configuration, create a  *.conf  file under"
    local subheader="#  ${SSH_CONFIG_DIR}/  which will be automatically included below"
    local directive="Include ${SSH_CONFIG_DIR}/*.conf"

    # Append to the bottom with a leading blank line for clean separation
    {
      echo ""
      echo "${header}"
      echo "${subheader}"
      echo "${directive}"
    } >> "${tmp_main}"
  fi

  mv "${tmp_main}" "${SSH_CONFIG}"
  finalize_edit "${SSH_CONFIG}" "${was_imm_main}"

  # --- Part 2: Modular Directory Cleanup ---
  if [[ ! -d "${SSH_CONFIG_DIR}" ]]; then
    mkdir -p "${SSH_CONFIG_DIR}" || {
      log_err "Failed to create directory ${SSH_CONFIG_DIR}."
      return 1
    }
    apply_selinux_context "${SSH_CONFIG_DIR}"
  fi

  local was_imm_dir=1
  if is_immutable "${SSH_CONFIG_DIR}"; then
    log_info "Directory ${SSH_CONFIG_DIR} is immutable. Removing flag temporarily..."
    chattr -i "${SSH_CONFIG_DIR}"
    was_imm_dir=0
  fi

  # Find ALL files in the modular directory containing ANY 'PermitRootLogin' directive (active or commented)
  local policy_file="${SSH_CONFIG_DIR}/99-secure-policy.conf"
  local bad_files
  # We exclude the policy file we manage to avoid a cleanup/create loop if run multiple times.
  bad_files=$(grep -rlE "^[[:space:]]*#?[[:space:]]*PermitRootLogin\b" "${SSH_CONFIG_DIR}" 2> /dev/null | grep -v "${policy_file}" || true)

  for f in ${bad_files}; do
    log_info "Removing all 'PermitRootLogin' directives from ${f}..."
    local was_imm_f
    was_imm_f=$(prepare_for_edit "${f}")
    local tmp_f
    tmp_f=$(mktemp "${f}.XXXXXX")
    grep -viE "^[[:space:]]*#?[[:space:]]*PermitRootLogin\b" "${f}" > "${tmp_f}" || true
    mv "${tmp_f}" "${f}"
    finalize_edit "${f}" "${was_imm_f}"
  done

  # Explicit Requirement: Delete legacy 01-permitrootlogin.conf if it exists.
  local legacy_file="${SSH_CONFIG_DIR}/01-permitrootlogin.conf"
  if [[ -f "${legacy_file}" ]]; then
    log_info "Removing legacy modular file: ${legacy_file}"
    local was_imm_legacy
    was_imm_legacy=$(prepare_for_edit "${legacy_file}")
    rm -f "${legacy_file}"
    : "${was_imm_legacy}"
  fi

  # Requirement: Create new 99-secure-policy.conf
  log_info "Creating new modular policy file: ${policy_file}"

  local was_imm_policy=1
  if [[ -f "${policy_file}" ]]; then
    was_imm_policy=$(prepare_for_edit "${policy_file}")
  fi

  cat << EOF > "${policy_file}"
# Secure privileged accounts
PermitRootLogin no
EOF
  chmod 600 "${policy_file}"

  finalize_edit "${policy_file}" "${was_imm_policy}"

  if [[ "${was_imm_dir}" -eq 0 ]]; then
    log_info "Restoring immutable flag for ${SSH_CONFIG_DIR}..."
    chattr +i "${SSH_CONFIG_DIR}"
  fi

  local ssh_remed_fail=0
  # Post-Remediation Verification: Validate syntax before reloading.
  verify_sshd_config || ssh_remed_fail=1

  if [[ "${ssh_remed_fail}" -eq 0 ]]; then
    reload_ssh_service || ssh_remed_fail=1
  else
    log_err "SSH configuration contains errors. Skipping reload to prevent service crash."
  fi

  log_succ "SSH configuration comprehensively modularized and hardened."
  JSON_REMED["ssh_hardened"]="true"
  return "${ssh_remed_fail}"
}

list_backups() {
  # Objective: Display all available backups in a tabular format.
  # Logic: Find unique suffixes across shadow and ssh_config.
  local shadow_dir
  local ssh_dir
  shadow_dir=$(dirname "${SHADOW_FILE}")
  ssh_dir=$(dirname "${SSH_CONFIG}")

  local shadow_base
  local ssh_base
  shadow_base=$(basename "${SHADOW_FILE}")
  ssh_base=$(basename "${SSH_CONFIG}")

  log_info "Scanning for available backups..."

  # Collect unique suffixes from both scoped files
  local suffixes
  suffixes=$( (
    [[ -d "${shadow_dir}" ]] && find "${shadow_dir}" -maxdepth 1 -name "${shadow_base}${SUFFIX_DELIM}[0-9]*" -exec basename {} \; | sed -E "s/^${shadow_base}${SUFFIX_DELIM}//; s/\.gz$//"
    [[ -d "${ssh_dir}" ]] && find "${ssh_dir}" -maxdepth 1 -name "${ssh_base}${SUFFIX_DELIM}[0-9]*" -exec basename {} \; | sed -E "s/^${ssh_base}${SUFFIX_DELIM}//; s/\.gz$//"
  ) | sort -u -r)

  if [[ -z "${suffixes}" ]]; then
    log_info "No backups found."
    return 0
  fi

  print_divider
  printf "%-18s | %-20s | %-20s | %-15s\n" "Suffix (Name)" "Date Created" "Files" "Total Size"
  print_divider

  local s
  for s in ${suffixes}; do
    local total_size=0
    local shadow_found=false
    local ssh_found=false
    local shadow_bkp="${SHADOW_FILE}${SUFFIX_DELIM}${s}"
    local ssh_bkp="${SSH_CONFIG}${SUFFIX_DELIM}${s}"

    # Check for both compressed and uncompressed variants
    if [[ -f "${shadow_bkp}.gz" ]]; then shadow_bkp="${shadow_bkp}.gz"; fi
    if [[ -f "${ssh_bkp}.gz" ]]; then ssh_bkp="${ssh_bkp}.gz"; fi

    if [[ -f "${shadow_bkp}" ]]; then
      local sz
      sz=$(stat -c%s "${shadow_bkp}" 2> /dev/null || echo 0)
      total_size=$((total_size + sz))
      shadow_found=true
    fi
    if [[ -f "${ssh_bkp}" ]]; then
      local sz
      sz=$(stat -c%s "${ssh_bkp}" 2> /dev/null || echo 0)
      total_size=$((total_size + sz))
      ssh_found=true
    fi

    # Determine the scope of the backup set
    local scope="None"
    if [[ "${shadow_found}" == "true" && "${ssh_found}" == "true" ]]; then
      scope="shadow sshd_config"
    elif [[ "${shadow_found}" == "true" ]]; then
      scope="shadow"
    elif [[ "${ssh_found}" == "true" ]]; then
      scope="sshd_config"
    fi

    # Format date from suffix (YYYYMMDDHHMMSS)
    local formatted_date="Unknown"
    if [[ "${s}" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
      formatted_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    fi

    printf "%-18s | %-20s | %-20s | %-15s\n" "${s}" "${formatted_date}" "${scope}" "${total_size}"
  done
  print_divider
}

get_target_suffix() {
  # Objective: Resolve the latest or oldest suffix available.
  local target_mode="${1}" # "latest" or "oldest"
  local shadow_dir
  local ssh_dir
  shadow_dir=$(dirname "${SHADOW_FILE}")
  ssh_dir=$(dirname "${SSH_CONFIG}")

  local shadow_base
  local ssh_base
  shadow_base=$(basename "${SHADOW_FILE}")
  ssh_base=$(basename "${SSH_CONFIG}")

  local suffixes
  suffixes=$( (
    [[ -d "${shadow_dir}" ]] && find "${shadow_dir}" -maxdepth 1 -name "${shadow_base}${SUFFIX_DELIM}[0-9]*" -exec basename {} \; | sed -E "s/^${shadow_base}${SUFFIX_DELIM}//; s/\.gz$//"
    [[ -d "${ssh_dir}" ]] && find "${ssh_dir}" -maxdepth 1 -name "${ssh_base}${SUFFIX_DELIM}[0-9]*" -exec basename {} \; | sed -E "s/^${ssh_base}${SUFFIX_DELIM}//; s/\.gz$//"
  ) | sort -u)

  if [[ -z "${suffixes}" ]]; then
    return 1
  fi

  if [[ "${target_mode}" == "latest" ]]; then
    echo "${suffixes}" | tail -n 1
  else
    echo "${suffixes}" | head -n 1
  fi
  return 0
}

perform_restore() {
  # Objective: Roll back configurations to a specific timestamped backup.
  local suffix="${1}"
  local restore_fail=0
  # UX: Ensure suffix has the leading delimiter for backend file lookup if it's missing.
  [[ "${suffix}" != "${SUFFIX_DELIM}"* ]] && suffix="${SUFFIX_DELIM}${suffix}"
  local display_suffix="${suffix#"${SUFFIX_DELIM}"}"

  log_info "Starting Configuration Restoration (Suffix: ${display_suffix})..."

  # Restore /etc/shadow
  local shadow_bkp="${SHADOW_FILE}${suffix}"
  [[ -f "${shadow_bkp}.gz" ]] && shadow_bkp="${shadow_bkp}.gz"
  if [[ -f "${shadow_bkp}" ]]; then
    log_info "Found backup for shadow file (Suffix: ${display_suffix})"
    if [[ "${SIMULATE}" == "true" ]]; then
      log_sim "Would restore ${SHADOW_FILE} from backup (Suffix: ${display_suffix})."
    else
      local was_imm
      was_imm=$(prepare_for_edit "${SHADOW_FILE}")
      if [[ "${shadow_bkp}" == *.gz ]]; then
        zcat "${shadow_bkp}" > "${SHADOW_FILE}" || restore_fail=1
      else
        cp -p "${shadow_bkp}" "${SHADOW_FILE}" || restore_fail=1
      fi
      finalize_edit "${SHADOW_FILE}" "${was_imm}"
      log_succ "Restored ${SHADOW_FILE} from backup (Suffix: ${display_suffix})."
      JSON_RESTORE["shadow_restored"]="true"
    fi
  else
    log_warn "Backup for shadow file NOT FOUND (Suffix: ${display_suffix})"
    restore_fail=1
  fi

  # Restore SSH config
  local ssh_bkp="${SSH_CONFIG}${suffix}"
  [[ -f "${ssh_bkp}.gz" ]] && ssh_bkp="${ssh_bkp}.gz"
  if [[ -f "${ssh_bkp}" ]]; then
    log_info "Found backup for SSH config (Suffix: ${display_suffix})"
    if [[ "${SIMULATE}" == "true" ]]; then
      log_sim "Would restore ${SSH_CONFIG} from backup (Suffix: ${display_suffix})."
    else
      local was_imm
      was_imm=$(prepare_for_edit "${SSH_CONFIG}")
      if [[ "${ssh_bkp}" == *.gz ]]; then
        zcat "${ssh_bkp}" > "${SSH_CONFIG}" || restore_fail=1
      else
        cp -p "${ssh_bkp}" "${SSH_CONFIG}" || restore_fail=1
      fi
      finalize_edit "${SSH_CONFIG}" "${was_imm}"
      log_succ "Restored ${SSH_CONFIG} from backup (Suffix: ${display_suffix})."
      JSON_RESTORE["ssh_restored"]="true"
      reload_ssh_service || restore_fail=1
    fi
  else
    log_warn "Backup for SSH config NOT FOUND (Suffix: ${display_suffix})"
    restore_fail=1
  fi
  return "${restore_fail}"
}

perform_remediation() {
  # Objective: Orchestrate the hardening process selectively.
  # Logic: Only remediate controls that failed the audit.
  # Aggregate: Tracks failures across all steps to ensure final exit code accuracy.
  local target_pass="${1:-}"
  local remed_fail=0

  # Only remediate controls that failed the audit.
  if [[ -n "${target_pass}" ]]; then
    remediate_password "${target_pass}" || remed_fail=1
    # CRITICAL: chpasswd frequently unlocks the account as a system side effect.
    # We enforce a mandatory relock after any password update to maintain posture.
    remediate_lock || remed_fail=1
  fi

  # Also catch cases where the password wasn't changed but the account is currently unlocked.
  if [[ "${JSON_AUDIT[account_locked]}" == "false" ]]; then
    remediate_lock || remed_fail=1
  fi

  if [[ "${JSON_AUDIT[ssh_disabled]}" == "false" ]]; then
    remediate_ssh || remed_fail=1
  fi
  return "${remed_fail}"
}

# --- Main Flow ---

main() {
  # Objective: CLI Entry Point.
  # Flow: Privilege Check -> Argument Parsing -> Env Injection -> Audit -> Safety -> Remediation.

  # 1. Immediate Privilege Check (Mockable for tests)
  check_root || return 1

  [[ $# -eq 0 ]] && { usage || return 1; }
  local mode="audit"
  local password="${ROOT_PASSWORD:-}"
  local generate_pass=false
  local simulate=false
  local json_out=false
  local restore_suffix=""
  local list_backups=false
  local restore_latest=false
  local restore_oldest=false

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --mode)
        mode="${2:-}"
        shift 2
        ;;
      --suffix)
        restore_suffix="${2:-}"
        shift 2
        ;;
      --list-backups)
        list_backups=true
        shift 1
        ;;
      --latest)
        restore_latest=true
        shift 1
        ;;
      --oldest)
        restore_oldest=true
        shift 1
        ;;
      --password)
        password="${2:-}"
        log_warn "Using CLI password is insecure."
        shift 2
        ;;
      --generate)
        generate_pass=true
        shift
        ;;
      --simulate)
        simulate=true
        shift
        ;;
      --json)
        json_out=true
        shift
        ;;
      --log)
        LOG_FILE="${2:-}"
        shift 2
        ;;
      *) usage || return 1 ;;
    esac
  done

  MODE="${mode}"
  SIMULATE="${simulate}"
  JSON_MODE="${json_out}"

  # Handle log file initialization.
  if [[ -n "${LOG_FILE}" ]]; then
    local log_dir
    log_dir=$(dirname "${LOG_FILE}")
    mkdir -p "${log_dir}"
    # Consolidate log header within a single redirection block for atomicity.
    {
      print_divider
      echo "SESSION START: $(date -Iseconds)"
      echo "MODE: ${MODE}"
      print_divider
    } >> "${LOG_FILE}"
  fi

  # Validation: Ensure arguments are sane for the selected mode.
  [[ "${MODE}" != "audit" && "${MODE}" != "remediate" && "${MODE}" != "restore" ]] && { usage || return 1; }

  # Enforcement: Discovery and recovery flags require explicit restore mode.
  if [[ "${list_backups}" == "true" || "${restore_latest}" == "true" || "${restore_oldest}" == "true" ]]; then
    if [[ "${MODE}" != "restore" ]]; then
      log_err "Backup discovery and recovery flags require --mode restore."
      return 1
    fi
  fi

  [[ "${MODE}" == "audit" && (-n "${password}" || "${generate_pass}" == "true" || "${SIMULATE}" == "true") ]] && {
    log_err "Flags restricted in audit mode"
    return 1
  }
  [[ "${MODE}" == "restore" && -z "${restore_suffix}" && "${list_backups}" == "false" && "${restore_latest}" == "false" && "${restore_oldest}" == "false" ]] && {
    log_err "Restore mode requires --suffix, --list-backups, --latest, or --oldest."
    usage
    return 1
  }

  if [[ "${MODE}" == "audit" ]]; then
    [[ "${JSON_MODE}" != "true" ]] && echo "" >&2
    log_info "Starting Security Audit (User: ${TARGET_USER}, Mode: audit)"
    print_divider

    local audit_fail=0
    local audit_count=0
    run_full_audit || audit_count=$?

    print_divider
    local status="success"
    if [[ "${audit_count}" -eq 0 ]]; then
      log_succ "Audit PASSED"
    else
      log_warn "Audit FAILED (${audit_count} findings)"
      status="failure"
      audit_fail=1
    fi
    if [[ "${JSON_MODE}" == "true" ]]; then
      render_json "${status}"
    fi
    if [[ "${JSON_MODE}" != "true" ]]; then
      echo "" >&2
    fi
    return "${audit_fail}"
  fi

  if [[ "${MODE}" == "restore" ]]; then
    if [[ "${list_backups}" == "true" ]]; then
      list_backups
      return 0
    fi
    local target_suffix="${restore_suffix}"
    if [[ "${restore_latest}" == "true" ]]; then
      log_info "Identifying latest backup..."
      target_suffix=$(get_target_suffix "latest" || echo "")
    elif [[ "${restore_oldest}" == "true" ]]; then
      log_info "Identifying oldest backup..."
      target_suffix=$(get_target_suffix "oldest" || echo "")
    fi

    if [[ -z "${target_suffix}" ]]; then
      log_err "No backup suffix identified. Use --suffix <VAL>, --latest, or --oldest."
      log_info "Tip: Run with --list-backups to see available states."
      return 1
    fi

    log_info "Starting Configuration Restoration (User: ${TARGET_USER}, Mode: restore, Suffix: ${target_suffix})"
    local restore_res=0
    perform_restore "${target_suffix}" || restore_res=1

    local restore_status="success"
    if [[ "${restore_res}" -ne 0 ]]; then
      restore_status="failure"
    fi

    if [[ "${JSON_MODE}" == "true" ]]; then
      render_json "${restore_status}"
    fi
    if [[ "${JSON_MODE}" != "true" ]]; then
      echo "" >&2
    fi
    return "${restore_res}"
  fi

  # REMEDIATION MODE: Run initial audit silently to identify targets
  local audit_fail=0
  local original_json_mode="${JSON_MODE}"
  JSON_MODE="true"
  run_full_audit || audit_fail=1
  JSON_MODE="${original_json_mode}"

  # Remediation Logic
  if [[ "${audit_fail}" -eq 0 ]]; then
    log_info "Already clean. No remediation needed."
    [[ "${JSON_MODE}" == "true" ]] && render_json "success"
    [[ "${JSON_MODE}" != "true" ]] && echo "" >&2
    return 0
  fi

  # Safety Kill-Switch Enforcement
  if [[ "${JSON_REMED[sudo_safety_passed]}" == "false" ]]; then
    log_err "Aborting remediation: Sudo safety check failed. No non-root administrators detected."
    [[ "${JSON_MODE}" == "true" ]] && render_json "failure"
    return 1
  fi

  [[ "${SIMULATE}" == "true" ]] && log_sim "ENTERING SIMULATION MODE - No changes will be written."

  log_info "Proceeding with Remediation..."
  local final_pass=""

  # Determine if password rotation is required or explicitly requested.
  local needs_rotation=false
  [[ "${JSON_AUDIT[password_exists]}" == "false" ]] && needs_rotation=true
  [[ "${JSON_AUDIT[hash_strong]}" == "false" ]] && needs_rotation=true
  [[ -n "${password}" || "${generate_pass}" == "true" ]] && needs_rotation=true

  if [[ "${needs_rotation}" == "true" ]]; then
    log_info "Forcing password rotation as requested..."
    if [[ -n "${password}" ]]; then
      validate_password "${password}" || {
        log_err "Invalid password policy"
        [[ "${JSON_MODE}" == "true" ]] && render_json "failure"
        return 1
      }
      final_pass="${password}"
    elif [[ "${generate_pass}" == "true" ]]; then
      final_pass=$(generate_password)
      # Security: Print generated password to console ONLY. Do not store in persistent log.
      echo -e "[\e[34mINFO\e[0m] Password to be used: ${final_pass}" >&2
      [[ -n "${LOG_FILE}" ]] && echo "$(date -Iseconds) [INFO] Password to be used: [REDACTED]" >> "${LOG_FILE}"
    else
      log_err "Password remediation required (missing/weak) but no source provided (use --password or --generate)"
      [[ "${JSON_MODE}" == "true" ]] && render_json "failure"
      return 1
    fi
  else
    log_info "Root password hash already exists. Skipping password rotation."
  fi

  local remed_fail=0
  perform_remediation "${final_pass}" || remed_fail=1

  # Secure cleanup of sensitive variables in memory.
  final_pass=""
  password=""
  unset final_pass
  unset password

  local remediate_status="success"
  if [[ "${SIMULATE}" != "true" ]]; then
    log_succ "Remediation complete. Performing final verification..."
    # Final audit can be verbose or silent; keeping it verbose for final confirmation.
    print_divider
    run_full_audit || {
      remediate_status="failure"
      remed_fail=1
    }
    print_divider
  else
    log_succ "Simulation complete. Review the steps above."
  fi

  log_info "Process Finished."
  if [[ "${JSON_MODE}" == "true" ]]; then
    render_json "${remediate_status}"
  fi
  if [[ "${JSON_MODE}" != "true" ]]; then
    echo "" >&2
  fi
  return "${remed_fail}"
}

# Entry point logic for sourcing vs direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
