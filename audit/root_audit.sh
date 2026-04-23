#!/bin/bash

# ==============================================================================
# SCRIPT: root_audit.sh
# OBJECTIVE: Audit and Remediate root account security for RHEL 9+ and Ubuntu 24.04+.
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
readonly SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers}"
readonly SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
readonly PASS_CHARS="${PASS_CHARS:-A-Za-z0-9#%^&}"
readonly SPEC_CHARS_REGEX="${SPEC_CHARS_REGEX:-[#%^&]}"

# --- Globals ---
# State variables used across the execution lifecycle.
MODE="audit"
PASSWORD=""
GENERATE_PASS=false
SIMULATE=false
JSON_MODE=false

# JSON State Accumulator
declare -A JSON_AUDIT=(
    ["password_exists"]="unknown"
    ["account_locked"]="unknown"
    ["ssh_disabled"]="unknown"
    ["hash_strong"]="unknown"
)
declare -A JSON_REMED=(
    ["password_updated"]="false"
    ["account_locked"]="false"
    ["ssh_hardened"]="false"
    ["backup_created"]="false"
    ["sudo_safety_passed"]="unknown"
)

# --- Logging Functions ---
# Standardized output for INFO, WARN, FAIL, OK, and SIMU states.
# All logging is redirected to STDERR to keep STDOUT clean for JSON output.

log_info() { [[ "${JSON_MODE}" == "true" ]] && return 0; echo -e "[\e[34mINFO\e[0m] $1" >&2; }
log_warn() { [[ "${JSON_MODE}" == "true" ]] && return 0; echo -e "[\e[33mWARN\e[0m] $1" >&2; }
log_err()  { [[ "${JSON_MODE}" == "true" ]] && return 0; echo -e "[\e[31mFAIL\e[0m] $1" >&2; }
log_succ() { [[ "${JSON_MODE}" == "true" ]] && return 0; echo -e "[\e[32mOK\e[0m]   $1" >&2; }
log_sim()  { [[ "${JSON_MODE}" == "true" ]] && return 0; echo -e "[\e[35mSIMU\e[0m] $1" >&2; }

print_divider() {
    [[ "${JSON_MODE}" == "true" ]] && return 0
    printf '%0.s-' {1..100} >&2
    echo "" >&2
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
        json+="\"hash_strong\":\"${JSON_AUDIT[hash_strong]}\""
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
    json+="}"

    if command -v jq >/dev/null 2>&1; then
        echo "${json}" | jq .
    else
        echo "${json}"
    fi
}

# --- Utility Functions ---

usage() {
    cat <<EOF

Usage: $0 [--mode audit|remediate] [--password <PASS>] [--generate] [--simulate] [--json]

Options:
  --mode audit        Read-only security check (default)
  --mode remediate    Fix security issues (if missing only)
  --password <PASS>   (Remediate mode only) Provide a ${MIN_PASS_LEN}-char password
                      Note: Passwords on the command line may be visible in process lists.
                      Prefer setting the ROOT_PASSWORD environment variable instead.
  --generate          (Remediate mode only) Generate a ${MIN_PASS_LEN}-char password
  --simulate          (Remediate mode only) Explain changes without applying them
  --json              Output results in CI/CD friendly JSON format

EOF
    return 1
}

check_root() {
    # Objective: Ensure sufficient privileges for reading /etc/shadow and /etc/sudoers.
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "This script must be run with sudo/root privileges."
        return 1
    fi
    return 0
}

# --- Safety Check: Sudo Users ---

get_sudo_group_members() {
    # Objective: Retrieve users in administrative groups via getent.
    local grp="${1}"
    if getent group "${grp}" >/dev/null 2>&1; then
        getent group "${grp}" | cut -d: -f4 | tr ',' ' '
    fi
}

get_sudoers_paths() {
    # Objective: Identify all active sudoers configuration files.
    echo "${SUDOERS_FILE}"
    if [[ -d "${SUDOERS_DIR}" ]]; then
        find "${SUDOERS_DIR}" -type f 2>/dev/null
    fi
}

verify_sudo_users() {
    # Objective: PRE-REMEDIATION KILL-SWITCH.
    # Logic: Verify at least one non-root user has full sudo access to prevent total lockout.
    log_info "Verifying that at least one non-root user has sudo privileges..."
    local sudo_users=()
    local grp
    for grp in wheel sudo; do
        local members
        members=$(get_sudo_group_members "${grp}")
        for m in ${members}; do [[ -n "${m}" ]] && sudo_users+=("${m}"); done
    done
    local paths
    paths=$(get_sudoers_paths)
    local explicit_users
    explicit_users=$(grep -h "^[^#% \t]" ${paths} 2>/dev/null | grep "ALL=(ALL)" | awk '{print $1}' || true)
    for m in ${explicit_users}; do [[ -n "${m}" ]] && sudo_users+=("${m}"); done
    local explicit_groups
    explicit_groups=$(grep -h "^%" ${paths} 2>/dev/null | grep "ALL=(ALL)" | awk '{print $1}' | sed 's/^%//' | grep -vE "^(wheel|sudo)$" || true)
    for g in ${explicit_groups}; do
        local gmembers
        gmembers=$(get_sudo_group_members "${g}")
        for gm in ${gmembers}; do [[ -n "${gm}" ]] && sudo_users+=("${gm}"); done
    done
    local unique_list
    unique_list=$(echo "${sudo_users[@]:-}" | tr ' ' '\n' | grep -v "^root$" | grep -v "^$" | sort -u || true)
    if [[ -z "${unique_list}" ]]; then
        log_err "CRITICAL SAFETY CHECK FAILED: No non-root users with sudo privileges found."
        log_err "Aborting remediation to prevent total lockout."
        JSON_REMED["sudo_safety_passed"]="false"
        return 1
    fi
    local count
    count=$(echo "${unique_list}" | grep -c .)
    local user_names
    user_names=$(echo "${unique_list}" | tr '\n' ',' | sed 's/,$//')
    log_succ "Found ${count} user(s) with sudo privileges: ${user_names}. Safety check passed."
    JSON_REMED["sudo_safety_passed"]="true"
    return 0
}

# --- Attribute and Backup Helpers ---

is_immutable() {
    # Objective: Detect 'i' (immutable) attribute that blocks all write operations.
    local file="${1}"
    if command -v lsattr >/dev/null 2>&1; then
        lsattr "${file}" 2>/dev/null | awk '{print $1}' | grep -q 'i'
    else
        return 1
    fi
}

backup_file() {
    # Objective: Create timestamped copy for rollback capability.
    local file="${1}"
    [[ ! -f "${file}" ]] && return 1
    local timestamp
    timestamp=$(date +"%Y%m%d%H%M%S")
    local backup="${file}.${timestamp}"
    log_info "Backing up ${file} to ${backup}..."
    cp -p "${file}" "${backup}"
    JSON_REMED["backup_created"]="true"
}

prepare_for_edit() {
    # Objective: Unified state management before file modification.
    # Flow: Backup -> Handle Immutability -> Ensure Writeability.
    local file="${1}"
    backup_file "${file}" || { log_err "Cannot backup ${file}"; return 1; }
    local was_immutable=1
    if is_immutable "${file}"; then
        log_info "File ${file} is immutable. Removing flag temporarily..."
        chattr -i "${file}"
        was_immutable=0
    fi
    if [[ ! -w "${file}" ]]; then
        log_warn "File ${file} is not writeable. Attempting to chmod +w..."
        chmod +w "${file}"
    fi
    echo "${was_immutable}"
}

finalize_edit() {
    # Objective: Restore original filesystem state after modification.
    local file="${1}"
    local was_immutable="${2}"
    if [[ "${was_immutable}" -eq 0 ]]; then
        log_info "Restoring immutable flag to ${file}..."
        chattr +i "${file}"
    fi
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
    # Objective: Extract shadow entry for the target user.
    grep "^${TARGET_USER}:" "${SHADOW_FILE}" | cut -d: -f2
}

audit_no_password() {
    # Objective: Verify that the root user has a password defined.
    local shadow
    shadow=$(get_user_shadow)
    if [[ -z "${shadow}" ]]; then
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
    permit=$(sshd -T 2>/dev/null | grep -i '^permitrootlogin' | awk '{print $2}' || echo "unknown")
    if [[ "${permit}" == "yes" ]] || [[ "${permit}" == "prohibit-password" ]] || [[ "${permit}" == "without-password" ]]; then
        log_warn "Direct root SSH login is ENABLED (${permit})."
        JSON_AUDIT["ssh_disabled"]="false"
        return 1
    fi
    log_succ "Direct root SSH login is disabled."
    JSON_AUDIT["ssh_disabled"]="true"
    return 0
}

audit_hashes() {
    # Objective: Verify that modern, strong hashing algorithms are in use.
    local shadow
    shadow=$(get_user_shadow)
    if [[ "${shadow}" =~ ^\$6\$ ]] || [[ "${shadow}" =~ ^\$y\$ ]]; then
        log_succ "Password hash is strong (SHA-512 or Yescrypt)."
        JSON_AUDIT["hash_strong"]="true"
        return 0
    fi
    log_warn "Password hash is weak or uses a deprecated format."
    JSON_AUDIT["hash_strong"]="false"
    return 1
}

run_full_audit() {
    # Objective: Orchestrate the complete suite of security checks.
    local audit_fail=0
    audit_no_password || audit_fail=1
    audit_unlocked    || audit_fail=1
    audit_ssh_login   || audit_fail=1
    audit_hashes      || audit_fail=1
    return "${audit_fail}"
}

# --- Remediation Functions ---

remediate_password() {
    # Objective: Securely update the root password.
    local target_pass="${1}"
    if [[ "${SIMULATE}" == "true" ]]; then
        log_sim "Would enforce strong 32-char password for '${TARGET_USER}' using chpasswd."
        return 0
    fi
    local was_immutable
    was_immutable=$(prepare_for_edit "${SHADOW_FILE}")
    log_info "Enforcing strong password for '${TARGET_USER}'..."
    echo "${TARGET_USER}:${target_pass}" | chpasswd
    log_succ "Password for '${TARGET_USER}' updated."
    JSON_REMED["password_updated"]="true"
    finalize_edit "${SHADOW_FILE}" "${was_immutable}"
}

remediate_lock() {
    # Objective: Lock the root account via passwd utility.
    if [[ "${SIMULATE}" == "true" ]]; then
        log_sim "Would lock the '${TARGET_USER}' account in ${SHADOW_FILE} (passwd -l)."
        return 0
    fi
    local was_immutable
    was_immutable=$(prepare_for_edit "${SHADOW_FILE}")
    log_info "Locking '${TARGET_USER}' account..."
    passwd -l "${TARGET_USER}"
    log_succ "User '${TARGET_USER}' locked."
    JSON_REMED["account_locked"]="true"
    finalize_edit "${SHADOW_FILE}" "${was_immutable}"
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
    # Objective: Harden SSH configuration via atomic "write-then-move" pattern.
    if [[ "${SIMULATE}" == "true" ]]; then
        log_sim "Would update ${SSH_CONFIG} to set 'PermitRootLogin no' atomically."
        log_sim "Pattern: Create backup, use mktemp, sed for replacement, and atomic mv."
        reload_ssh_service
        return 0
    fi
    log_info "Modifying SSH configuration safely..."
    local was_immutable
    was_immutable=$(prepare_for_edit "${SSH_CONFIG}")
    local tmp_config
    tmp_config=$(mktemp "${SSH_CONFIG}.XXXXXX")
    cp -p "${SSH_CONFIG}" "${tmp_config}"
    if grep -q "^PermitRootLogin" "${tmp_config}"; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "${tmp_config}"
    else
        echo "PermitRootLogin no" >> "${tmp_config}"
    fi
    mv "${tmp_config}" "${SSH_CONFIG}"
    reload_ssh_service
    JSON_REMED["ssh_hardened"]="true"
    finalize_edit "${SSH_CONFIG}" "${was_immutable}"
}

perform_remediation() {
    # Objective: Orchestrate the hardening process.
    local final_pass="${1}"
    remediate_password "${final_pass}"
    remediate_lock
    remediate_ssh
}

# --- Main Flow ---

main() {
    # Objective: CLI Entry Point.
    # Flow: Argument Parsing -> Env Injection -> Root Check -> Audit -> Safety -> Remediation.
    
    [[ $# -eq 0 ]] && { usage || return 1; }
    local mode="audit"
    local password="${ROOT_PASSWORD:-}"
    local generate_pass=false
    local simulate=false
    local json_out=false

    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --mode) mode="${2:-}"; shift 2 ;;
            --password) password="${2:-}"; log_warn "Using CLI password is insecure."; shift 2 ;;
            --generate) generate_pass=true; shift ;;
            --simulate) simulate=true; shift ;;
            --json) json_out=true; shift ;;
            *) usage || return 1 ;;
        esac
    done

    MODE="${mode}"
    SIMULATE="${simulate}"
    JSON_MODE="${json_out}"

    # Validation: Ensure arguments are sane for the selected mode.
    [[ "${mode}" != "audit" && "${mode}" != "remediate" ]] && { usage || return 1; }
    [[ "${mode}" == "audit" && (-n "${password}" || "${generate_pass}" == "true" || "${SIMULATE}" == "true") ]] && { log_err "Flags restricted in audit mode"; return 1; }

    check_root || return 1
    
    [[ "${JSON_MODE}" != "true" ]] && echo "" >&2
    log_info "Starting Security Audit (User: ${TARGET_USER}, Mode: ${mode}, Simulate: ${SIMULATE})"
    print_divider

    local audit_fail=0
    run_full_audit || audit_fail=1

    print_divider
    if [[ "${mode}" == "audit" ]]; then
        local status="success"
        [[ "${audit_fail}" -eq 0 ]] && log_succ "Audit PASSED" || { log_warn "Audit FAILED"; status="failure"; }
        [[ "${JSON_MODE}" == "true" ]] && render_json "${status}"
        [[ "${JSON_MODE}" != "true" ]] && echo "" >&2
        return "${audit_fail}"
    fi

    # Remediation Logic
    if [[ "${audit_fail}" -ne 0 ]]; then
        verify_sudo_users || { [[ "${JSON_MODE}" == "true" ]] && render_json "failure"; return 1; }
    fi
    
    if [[ "${audit_fail}" -eq 0 ]]; then
        log_info "Already clean. No remediation needed."
        [[ "${JSON_MODE}" == "true" ]] && render_json "success"
        [[ "${JSON_MODE}" != "true" ]] && echo "" >&2
        return 0
    fi

    [[ "${SIMULATE}" == "true" ]] && log_sim "ENTERING SIMULATION MODE - No changes will be written."

    log_info "Proceeding with Remediation..."
    local final_pass=""
    if [[ -n "${password}" ]]; then
        validate_password "${password}" || { log_err "Invalid password policy"; [[ "${JSON_MODE}" == "true" ]] && render_json "failure"; return 1; }
        final_pass="${password}"
    elif [[ "${generate_pass}" == "true" ]]; then
        final_pass=$(generate_password)
        log_info "Password to be used: ${final_pass}"
    else
        log_err "Remediation requires source (use --password or --generate)"; [[ "${JSON_MODE}" == "true" ]] && render_json "failure"; return 1
    fi

    perform_remediation "${final_pass}"
    
    # Secure cleanup of sensitive variables in memory.
    final_pass="" ; password="" ; unset final_pass ; unset password

    local remediate_status="success"
    if [[ "${SIMULATE}" != "true" ]]; then
        log_succ "Remediation complete. Performing final audit..."
        print_divider
        run_full_audit || remediate_status="failure"
        print_divider
    else
        log_succ "Simulation complete. Review the steps above."
    fi
    
    log_info "Process Finished."
    [[ "${JSON_MODE}" == "true" ]] && render_json "${remediate_status}"
    [[ "${JSON_MODE}" != "true" ]] && echo "" >&2
    return 0
}

# Entry point logic for sourcing vs direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit $?
fi
