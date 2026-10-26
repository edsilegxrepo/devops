#!/usr/bin/env bash
# ==============================================================================
# Library:     /opt/scripts/lib/common.sh
# Version:     1.4.0  2026/10/26
# Standard:    DRY Architecture Framework (Job Automation & Reporting Layer)
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky, CentOS)
#              Debian 12+ (Bookworm), Ubuntu 22.04+ (Jammy/Noble)
# Description: Central DevOps automation library for scheduled batch jobs
#              (vm-backup-gdrive.sh, check-container-updates.sh, job-skeleton.sh).
#              Builds on lib/system.sh, supplying configuration resolution,
#              concurrency locking, execution logging, LIFO cleanup traps,
#              HTML templating, email dispatching, and offsite storage sync/pruning.
# ==============================================================================
set -euo pipefail
umask 077
shopt -u patsub_replacement 2>/dev/null || true

# ------------------------------------------------------------------------------
# 1. System Foundation & Environment Initialization
# ------------------------------------------------------------------------------
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SCRIPTS_DIR="$(dirname "${COMMON_LIB_DIR}")"
COMMON_CONFIG_DIR="${COMMON_SCRIPTS_DIR}/config"
COMMON_TEMPLATES_DIR="${COMMON_SCRIPTS_DIR}/templates"
SHARED_TEMPLATES_DIR="${COMMON_TEMPLATES_DIR}/shared"

# Sourcing Decoupled System Foundation Library (provides require_root, PKG_MGR, etc.)
LIB_SYSTEM="${COMMON_LIB_DIR}/system.sh"
if [[ -f "${LIB_SYSTEM}" ]]; then
    # shellcheck source=/dev/null
    source "${LIB_SYSTEM}"
fi

DEFAULT_MAIL_TO="criticalsys.mis@gmail.com"
DEFAULT_SENDMAIL="/usr/sbin/sendmail"

# ------------------------------------------------------------------------------
# 2. Configuration Loading & Validation Engine
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: load_config
# Purpose:  Resolves and loads multi-tiered configuration hierarchy for a job.
# Precedence Order:
#   1. System-wide common configuration (/etc/devops/common.conf, config/common.env)
#   2. Job-specific configuration (/etc/devops/${job}.conf, config/${job}.env)
#   3. OS-level sysconfig overrides (/etc/sysconfig/${job}, /etc/default/${job})
#   4. Dynamic auto-discovery defaults (hostname, mail sender, log dirs)
#   5. Convention-based validator hook (validate_${job//-/_}_config)
# Arguments:
#   $1 - Job identifier name (e.g. "vm-backup", "container-updates").
# Returns:
#   0 on success; exits or logs error if mandatory configuration is invalid.
# ------------------------------------------------------------------------------
load_config() {
    local job_name="$1"

    # Step 1: Discover System Host Identity
    SYS_HOSTNAME="${SYS_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
    SHORT_HOSTNAME="${SYS_HOSTNAME%%.*}"

    # Step 2: Load Global Common Properties
    local common_configs=(
        "/etc/devops/common.conf"
        "/etc/sysconfig/devops-common"
        "/etc/default/devops-common"
        "${COMMON_CONFIG_DIR}/common.env"
    )
    for cfg in "${common_configs[@]}"; do
        if [[ -f "${cfg}" ]]; then
            # shellcheck source=/dev/null
            source "${cfg}"
            break
        fi
    done

    # Step 3: Load Job-Specific Properties
    local job_configs=(
        "/etc/devops/${job_name}.conf"
        "/etc/sysconfig/${job_name}"
        "/etc/default/${job_name}"
        "${COMMON_CONFIG_DIR}/${job_name}.env"
    )
    for cfg in "${job_configs[@]}"; do
        if [[ -f "${cfg}" ]]; then
            # shellcheck source=/dev/null
            source "${cfg}"
            break
        fi
    done

    # Step 4: Apply Dynamic Auto-Discovery Defaults
    MAIL_TO="${MAIL_TO:-${DEFAULT_MAIL_TO}}"
    MAIL_FROM_NAME="${MAIL_FROM_NAME:-DevOps Automation}"
    MAIL_FROM_DOMAIN="${MAIL_FROM_DOMAIN:-${SYS_HOSTNAME#*.}}"
    [[ "${MAIL_FROM_DOMAIN}" == "${SYS_HOSTNAME}" ]] && MAIL_FROM_DOMAIN="localdomain"
    MAIL_FROM="${MAIL_FROM:-${MAIL_FROM_NAME} <automation@${SYS_HOSTNAME}>}"
    SENDMAIL_BIN="${SENDMAIL_BIN:-${DEFAULT_SENDMAIL}}"

    LOG_BASE_DIR="${LOG_BASE_DIR:-/var/log/jobs}"
    # Backward compatibility: preserve /var/log/backups for vm-backup if BACKUP_LOG_DIR is set
    [[ "${job_name}" == "vm-backup" && -n "${BACKUP_LOG_DIR:-}" ]] && LOG_BASE_DIR="${BACKUP_LOG_DIR}"
    LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-${DEFAULT_LOG_RETENTION_DAYS:-14}}"
    SYS_USER="${SYS_USER:-csysadm}"
    SYS_GROUP="${SYS_GROUP:-root}"
    SYS_DIR_PERMS="${SYS_DIR_PERMS:-0750}"
    SYS_FILE_PERMS="${SYS_FILE_PERMS:-0640}"

    # Step 5: Execute Sanity & Safety Validation
    validate_common_config
    local validator="validate_${job_name//-/_}_config"
    if declare -f "${validator}" >/dev/null 2>&1; then
        "${validator}"
    elif [[ "${job_name}" == "vm-backup" ]] && declare -f validate_backup_config >/dev/null 2>&1; then
        validate_backup_config
    elif [[ "${job_name}" == "container-updates" ]] && declare -f validate_container_config >/dev/null 2>&1; then
        validate_container_config
    fi
}

# ------------------------------------------------------------------------------
# Function: validate_common_config
# Purpose:  Verifies global baseline parameters (sendmail binary, log writeability).
# Arguments:
#   None (operates on global configuration variables).
# Returns:
#   0 on success; emits warning to stderr or returns 1 on fatal error.
# ------------------------------------------------------------------------------
validate_common_config() {
    # Verify sendmail binary exists if MTA is required
    if [[ ! -x "${SENDMAIL_BIN}" ]]; then
        echo "[!] Warning: Sendmail binary '${SENDMAIL_BIN}' not executable. Email dispatch may fail." >&2
    fi

    # Verify log directory base is writeable or creatable if running with root privileges
    if [[ "${EUID}" -eq 0 ]]; then
        local test_dir="${LOG_BASE_DIR}"
        while [[ ! -d "${test_dir}" && "${test_dir}" != "/" ]]; do
            test_dir="$(dirname "${test_dir}")"
        done
        if [[ ! -w "${test_dir}" ]]; then
            echo "[-] Fatal: Base log path '${LOG_BASE_DIR}' is not writeable by root." >&2
            return 1
        fi
    fi
}

# ------------------------------------------------------------------------------
# Function: validate_backup_config
# Purpose:  Initializes default settings and asserts safety prerequisites for
#           VM snapshot and cloud archive backup jobs (passphrase permissions,
#           compression tools).
# Arguments:
#   None (operates on global configuration variables).
# Returns:
#   0 on success; 1 on missing passphrase or missing compression binary.
# ------------------------------------------------------------------------------
validate_backup_config() {
    BACKUP_DIR="${BACKUP_DIR:-/var/backups/vm-snapshots}"
    ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-${SHORT_HOSTNAME}-backup}"
    TARGET_REMOTE="${TARGET_REMOTE:-gdrive:${SHORT_HOSTNAME}}"
    PASSPHRASE_FILE="${PASSPHRASE_FILE:-/root/.secrets/backup-passphrase}"
    LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-2}"
    REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-14}"
    LOCAL_MIN_KEEP="${LOCAL_MIN_KEEP:-${LOCAL_RETENTION_DAYS}}"
    REMOTE_MIN_KEEP="${REMOTE_MIN_KEEP:-${REMOTE_RETENTION_DAYS}}"
    MIN_ARCHIVE_BYTES="${MIN_ARCHIVE_BYTES:-1048576}"
    COMPRESSION_PROGRAM="${COMPRESSION_PROGRAM:-zstd -T0 -3}"
    COMPRESSION_EXT="${COMPRESSION_EXT:-tar.zst.gpg}"

    # Validate Passphrase File Security (when running as root)
    if [[ "${EUID}" -eq 0 ]]; then
        if [[ ! -f "${PASSPHRASE_FILE}" ]]; then
            echo "[-] Fatal Config Error: Passphrase file '${PASSPHRASE_FILE}' does not exist." >&2
            return 1
        fi
        local file_perms
        file_perms="$(stat -c "%a" "${PASSPHRASE_FILE}" 2>/dev/null || stat -f "%OLp" "${PASSPHRASE_FILE}" 2>/dev/null || true)"
        if [[ -n "${file_perms}" && "${file_perms}" != "600" && "${file_perms}" != "400" ]]; then
            echo "[!] Security Warning: Passphrase file '${PASSPHRASE_FILE}' has permissions ${file_perms}. Hardening to 0600..." >&2
            chmod 600 "${PASSPHRASE_FILE}" 2>/dev/null || true
        fi
    fi

    # Validate Compression Tooling
    local comp_bin="${COMPRESSION_PROGRAM%% *}"
    if ! command -v "${comp_bin}" >/dev/null 2>&1; then
        echo "[-] Fatal Config Error: Compression binary '${comp_bin}' not found in PATH." >&2
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Function: validate_container_config
# Purpose:  Initializes default settings and verifies container engine
#           availability for container inspection and auto-update jobs.
# Arguments:
#   None (operates on global configuration variables).
# Returns:
#   0 on success; 1 if container engine binary is not found.
# ------------------------------------------------------------------------------
validate_container_config() {
    CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
    AUTO_UPDATE="${AUTO_UPDATE:-false}"
    NOTIFY_NEW_ONLY="${NOTIFY_NEW_ONLY:-false}"
    SCAN_TIMEOUT="${SCAN_TIMEOUT:-900}"

    if ! command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1; then
        echo "[-] Fatal Config Error: Configured container engine '${CONTAINER_ENGINE}' is not installed." >&2
        return 1
    fi
}

# Backward-compatibility aliases
validate_vm_backup_config() { validate_backup_config "$@"; }
validate_container_updates_config() { validate_container_config "$@"; }

# ------------------------------------------------------------------------------
# Function: bootstrap_job
# Purpose:  Orchestrates standard startup lifecycle for batch automation jobs:
#           enforces root constraints, checks CLI dependencies, sources configuration,
#           acquires singleton execution lock, and initializes structured log.
# Arguments:
#   $1      - Unique job identifier name (e.g. "vm-backup", "container-updates")
#   Options:
#     --require-root     Enforce UID 0 / root execution
#     --deps "<list>"    Space-separated list of required CLI executables
#     --log-dir "<dir>"  Base directory for job logs
#     --retention <days> Retention period in days for execution logs
# Returns:
#   0 on successful bootstrap; exits on guard failure or concurrency conflict.
# ------------------------------------------------------------------------------
bootstrap_job() {
    local job_name="$1"
    shift
    local req_root=0
    local deps=()
    local log_base=""
    local retention=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --require-root) req_root=1; shift ;;
            --deps) shift; read -ra deps <<< "$1"; shift ;;
            --log-dir) shift; log_base="$1"; shift ;;
            --retention) shift; retention="$1"; shift ;;
            *) shift ;;
        esac
    done

    [[ ${req_root} -eq 1 ]] && require_root
    [[ ${#deps[@]} -gt 0 ]] && verify_dependencies "${deps[@]}"
    load_config "${job_name}"
    acquire_lock "${job_name}"
    init_job_log "${job_name}" "${log_base:-${LOG_BASE_DIR:-/var/log/jobs}}" "${retention:-${LOG_RETENTION_DAYS:-14}}"
}

# ------------------------------------------------------------------------------
# 3. Concurrency Locking
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: acquire_lock
# Purpose:  Enforces non-blocking singleton process execution using kernel file
#           locking (flock) on dynamic file descriptors (Bash 4.1+).
# Arguments:
#   $1 (Optional) - Job lock identifier name (default: "script").
# Returns:
#   0 if lock acquired; exits with code 0 if another instance is already running.
# ------------------------------------------------------------------------------
acquire_lock() {
    local lock_name="${1:-script}"
    local lock_dir="/run/lock"
    [[ -w "${lock_dir}" ]] || lock_dir="/tmp"
    local lock_file="${lock_dir}/${lock_name}.lock"

    # Allocate dynamic file descriptor (Bash 4.1+) to prevent FD number collisions
    exec {LOCK_FD}>>"${lock_file}"
    if ! flock -n "${LOCK_FD}"; then
        echo "[-] Notice: Another instance of ${lock_name} is running. Exiting." >&2
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# 4. Lifecycle, Cleanup Trap Dispatcher & Execution Logging
# ------------------------------------------------------------------------------
declare -a CLEANUP_HOOKS=()

# ------------------------------------------------------------------------------
# Function: register_cleanup
# Purpose:  Registers an arbitrary shell command on the LIFO cleanup stack to
#           be executed when the script exits or receives a termination signal.
# Arguments:
#   $* - Shell command string to execute during cleanup (e.g. "rm -rf '${DIR}'").
# Returns:
#   None.
# ------------------------------------------------------------------------------
register_cleanup() {
    CLEANUP_HOOKS+=("$*")
}

# ------------------------------------------------------------------------------
# Function: dispatch_cleanup
# Purpose:  Central trap handler executing registered cleanup commands in
#           reverse order (LIFO) and finalizing job execution logs.
# Arguments:
#   Implicit: captures the active exit code ($?) at trap invocation.
# Returns:
#   Exits with the captured exit code.
# ------------------------------------------------------------------------------
dispatch_cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM HUP
    set +e

    # Execute registered cleanup handlers in reverse order (LIFO)
    for (( i=${#CLEANUP_HOOKS[@]}-1; i>=0; i-- )); do
        eval "${CLEANUP_HOOKS[i]}" 2>/dev/null || true
    done

    # Automatically finalize job execution log if initialized
    if [[ -n "${JOB_LOG_FILE:-}" && "${JOB_LOG_FINALIZED:-0}" -eq 0 ]]; then
        local status="COMPLETED"
        [[ "${exit_code}" -ne 0 ]] && status="FAILED"
        finalize_job_log "${exit_code}" "${status}"
    fi

    exit "${exit_code}"
}

# Automatically wire trap dispatcher upon sourcing lib/common.sh
trap dispatch_cleanup EXIT
trap "exit 130" INT
trap "exit 143" TERM
trap "exit 129" HUP

# ------------------------------------------------------------------------------
# Function: init_job_log
# Purpose:  Initializes structured per-run execution log file with header metadata,
#           secures filesystem permissions, and registers environment state.
# Arguments:
#   $1 - Job identifier name (e.g. "vm-backup").
#   $2 (Optional) - Base log directory (default: "/var/log/jobs").
#   $3 (Optional) - Log retention window in days (default: 14).
# Exports:
#   JOB_LOG_FILE, JOB_START_TS, JOB_CHECK_TIME, JOB_NAME, JOB_LOG_DIR
# Returns:
#   0 on successful initialization.
# ------------------------------------------------------------------------------
init_job_log() {
    local job_name="$1"
    local log_dir="${2:-/var/log/jobs}"
    local retention_days="${3:-14}"

    JOB_NAME="${job_name}"
    JOB_LOG_DIR="${log_dir}"
    JOB_RETENTION_DAYS="${retention_days}"
    JOB_START_TS="$(date +%s)"
    JOB_DATE_STAMP="$(date +%Y%m%d_%H%M%S)"
    JOB_CHECK_TIME="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    JOB_LOG_FILE="${JOB_LOG_DIR}/${job_name}-${JOB_DATE_STAMP}.log"
    JOB_LOG_FINALIZED=0

    mkdir -p "${JOB_LOG_DIR}"
    chmod "${SYS_DIR_PERMS:-0750}" "${JOB_LOG_DIR}" 2>/dev/null || true
    chown "${SYS_USER:-csysadm}:${SYS_GROUP:-root}" "${JOB_LOG_DIR}" 2>/dev/null || true

    touch "${JOB_LOG_FILE}"
    chmod "${SYS_FILE_PERMS:-0640}" "${JOB_LOG_FILE}" 2>/dev/null || true
    chown "${SYS_USER:-csysadm}:${SYS_GROUP:-root}" "${JOB_LOG_FILE}" 2>/dev/null || true

    cat <<EOF > "${JOB_LOG_FILE}"
================================================================================
Execution Log: ${job_name}
Host:       ${SYS_HOSTNAME}
Start Time: ${JOB_CHECK_TIME}
Script:     $0
Arguments:  ${CLI_ARGS:-"(none)"}
User:       $(id -un) (UID: ${EUID})
PID:        $$
================================================================================
EOF
}

# ------------------------------------------------------------------------------
# Function: log_msg
# Purpose:  Emits timestamped operational messages to stdout, active job log file,
#           and optionally syslog / journald.
# Arguments:
#   $1 - Message text to log.
#   $2 (Optional) - Flag whether to print to stdout (1 = yes, 0 = silent; default: 1).
#   $3 (Optional) - Syslog tag name (if set, routes message to logger).
# Returns:
#   0.
# ------------------------------------------------------------------------------
log_msg() {
    local msg="$1"
    local to_stdout="${2:-1}"
    local syslog_tag="${3:-}"
    if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] ${msg}" >> "${JOB_LOG_FILE}"
    fi
    if [[ -n "${syslog_tag}" ]] && command -v logger >/dev/null 2>&1; then
        logger -t "${syslog_tag}" "${msg}" 2>/dev/null || true
    fi
    if [[ "${to_stdout}" -eq 1 ]]; then
        echo "${msg}"
    fi
}

# ------------------------------------------------------------------------------
# Function: finalize_job_log
# Purpose:  Appends execution summary footer (status, duration, timestamps) to
#           job log file and purges expired historical logs per retention policy.
# Arguments:
#   $1 (Optional) - Script exit code (default: 0).
#   $2 (Optional) - Status message label (e.g. "COMPLETED", "FAILED"; default: "COMPLETED").
# Returns:
#   0.
# ------------------------------------------------------------------------------
finalize_job_log() {
    if [[ "${JOB_LOG_FINALIZED:-0}" -eq 1 ]]; then
        return 0
    fi
    JOB_LOG_FINALIZED=1
    local exit_code="${1:-0}"
    local status_msg="${2:-COMPLETED}"
    local end_ts
    end_ts="$(date +%s)"
    local duration=$(( end_ts - ${JOB_START_TS:-end_ts} ))

    if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
        cat <<EOF >> "${JOB_LOG_FILE}"

================================================================================
Execution Summary:
Status:     ${status_msg} (Exit Code: ${exit_code})
End Time:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Duration:   ${duration}s
Log File:   ${JOB_LOG_FILE}
================================================================================
EOF
    fi

    # Enforce retention policy
    if [[ -d "${JOB_LOG_DIR:-}" && -n "${JOB_NAME:-}" ]]; then
        find "${JOB_LOG_DIR}" -type f -name "${JOB_NAME}-*.log" -mmin "+$(( ${JOB_RETENTION_DAYS:-14} * 1440 ))" -delete 2>/dev/null || true
        find "${JOB_LOG_DIR}" -xtype l -delete 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 5. HTML Utilities & Template Engine
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: escape_html
# Purpose:  Sanitizes input text for safe embedding within HTML email templates
#           by escaping &, <, >, and ".
# Arguments:
#   $1 (Optional) - Input string. If omitted, reads raw content from stdin.
# Returns:
#   Outputs escaped HTML string to stdout.
# ------------------------------------------------------------------------------
escape_html() {
    local input
    if [[ $# -gt 0 ]]; then
        input="$1"
    else
        input="$(cat)"
    fi
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<< "${input}"
}

# ------------------------------------------------------------------------------
# Function: prepare_email_log
# Purpose:  Filters verbose manifests from log files, truncates output to maximum
#           allowed lines, and escapes content for HTML email display.
# Arguments:
#   $1 - Path to the source log file.
#   $2 (Optional) - Maximum lines to display in email body (default: 400).
# Returns:
#   Outputs sanitized and truncated log text to stdout.
# ------------------------------------------------------------------------------
prepare_email_log() {
    local log_file="$1"
    local max_lines="${2:-400}"

    if [[ ! -s "${log_file}" ]]; then
        echo "No logs were captured during this execution."
        return 0
    fi

    local log_filtered
    log_filtered=$(sed '/^=== Backed Up Files Manifest/,/^=== End of Backed Up Files Manifest/d' "${log_file}")
    local total_lines
    total_lines=$(wc -l <<< "${log_filtered}")

    local log_display
    if (( total_lines > max_lines )); then
        log_display="[... Output truncated. Showing last ${max_lines} of ${total_lines} lines ...]"$'\n'
        log_display+=$(tail -n "${max_lines}" <<< "${log_filtered}")
    else
        log_display="${log_filtered}"
    fi

    escape_html "${log_display}"
}

# ------------------------------------------------------------------------------
# Function: render_snippet
# Purpose:  Performs token replacement on in-memory template strings replacing
#           occurrences of {{KEY}} with corresponding values.
# Arguments:
#   $1    - Raw template string.
#   $2,$3 - Key/value substitution pairs (e.g. "KEY1" "val1" "KEY2" "val2").
# Returns:
#   Outputs rendered template string to stdout.
# ------------------------------------------------------------------------------
render_snippet() {
    local content="$1"
    shift
    while [[ $# -ge 2 ]]; do
        local key="$1"
        local val="$2"
        shift 2
        content="${content//\{\{${key}\}\}/${val}}"
    done
    echo "${content}"
}

# ------------------------------------------------------------------------------
# Function: render_template
# Purpose:  Loads an HTML template file from disk and performs variable
#           substitutions using render_snippet.
# Arguments:
#   $1    - Absolute filesystem path to template file.
#   $2,$3 - Key/value substitution pairs.
# Returns:
#   Outputs rendered template content to stdout; returns 1 if file missing.
# ------------------------------------------------------------------------------
render_template() {
    local tmpl_file="$1"
    shift
    if [[ ! -f "${tmpl_file}" ]]; then
        log_msg "[-] Error: Template file not found: ${tmpl_file}" 1 >&2
        return 1
    fi
    local content
    content="$(cat "${tmpl_file}")"
    render_snippet "${content}" "$@"
}

# ------------------------------------------------------------------------------
# Function: get_status_badge
# Purpose:  Generates an HTML status badge component with appropriate palette
#           and iconography for header cards or summary tables.
# Arguments:
#   $1 - Status classification ("success" | "failed" | "warning" | "info").
#   $2 - Status icon symbol (e.g. "✓", "✕", "⚡").
#   $3 - Badge text label (e.g. "COMPLETED", "FAILED").
#   $4 (Optional) - Rendering mode ("default" for header card, "table" for tabular badge).
# Returns:
#   Outputs HTML badge snippet to stdout.
# ------------------------------------------------------------------------------
get_status_badge() {
    local status_type="$1" # success | failed | warning | info
    local icon="$2"
    local label="$3"
    local mode="${4:-default}" # default | table
    if [[ "${mode}" == "table" ]]; then
        local color="#16a34a" bg="#f0fdf4" border="#bbf7d0"
        case "${status_type}" in
            failed)  color="#dc2626"; bg="#fef2f2"; border="#fecaca" ;;
            warning) color="#d97706"; bg="#fffbeb"; border="#fde68a" ;;
            info)    color="#2563eb"; bg="#eff6ff"; border="#bfdbfe" ;;
            success) color="#16a34a"; bg="#f0fdf4"; border="#bbf7d0" ;;
        esac
        echo "<span style=\"display: inline-block; padding: 2px 8px; font-size: 11px; font-weight: 700; color: ${color}; background-color: ${bg}; border: 1px solid ${border}; border-radius: 9999px;\">${label}</span>"
        return 0
    fi
    local tmpl="${SHARED_TEMPLATES_DIR}/badge-${status_type}.html"
    if [[ -f "${tmpl}" ]]; then
        local badge
        badge="$(cat "${tmpl}")"
        badge="${badge//\{\{STATUS_ICON\}\}/${icon}}"
        badge="${badge//\{\{STATUS_LABEL\}\}/${label}}"
        echo "${badge}"
    else
        echo "[${icon} ${label}]"
    fi
}

# ------------------------------------------------------------------------------
# Function: send_html_email
# Purpose:  Dispatches RFC-compliant MIME multipart/alternative or HTML emails
#           directly via local sendmail / Postfix MTA.
# Arguments:
#   $1 (Optional) - Recipient email address (default: $DEFAULT_MAIL_TO).
#   $2 (Optional) - Sender From header string (default: formatted $MAIL_FROM).
#   $3            - Email Subject line.
#   $4            - Complete HTML document body.
#   $5 (Optional) - Custom SMTP tracking header (e.g. "X-DevOps-Job: ...").
# Returns:
#   0 on successful handoff to MTA; 1 on sendmail execution failure.
# ------------------------------------------------------------------------------
send_html_email() {
    local to="${1:-${DEFAULT_MAIL_TO}}"
    local from="${2:-${MAIL_FROM:-DevOps Automation <do-not-reply@${SYS_HOSTNAME}>}}"
    local subject="${3}"
    local body="${4}"
    local x_header="${5:-X-DevOps-Job: ${JOB_NAME:-automation}}"

    local sendmail_exec="${SENDMAIL_BIN:-${DEFAULT_SENDMAIL}}"
    if [[ ! -x "${sendmail_exec}" ]]; then
        log_msg "[-] Error: sendmail binary not executable at ${sendmail_exec}" 1 >&2
        return 1
    fi

    "${sendmail_exec}" -t -oi <<EOF
From: ${from}
To: ${to}
Subject: ${subject}
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8
Auto-Submitted: auto-generated
${x_header}

${body}
EOF
}

# ------------------------------------------------------------------------------
# Function: dispatch_job_notification
# Purpose:  High-level notification assembler that compiles status badges,
#           summary grids, optional action instructions, and execution logs into
#           the standard enterprise HTML email layout and dispatches it.
# Arguments (Named Options):
#   --title <title>            Job Title (e.g. "VM Snapshot & Cloud Backup")
#   --category <category>      Service Category (e.g. "Disaster Recovery & Snapshots")
#   --status <status>          Status type: success | failed | warning | info
#   --badge-icon <icon>        Status icon (e.g. "✓", "✕", "⚡")
#   --badge-label <label>      Status badge text (e.g. "BACKUP SUCCESS", "FAILED")
#   --subject <subject>        Email Subject (auto-generated if omitted)
#   --content <html>           Main body HTML / summary grid
#   --action <html>            Action block HTML (optional)
#   --log-file <path>          Path to log file (default: $JOB_LOG_FILE)
#   --log-lines <count>        Max log lines to include (default: 350, 0 to suppress)
#   --terminal-title <title>   Title of log card (default: "Execution Log")
#   --extra-header <header>    Custom SMTP header (e.g. "X-Backup-Status: SUCCESS")
#   --to <email>               Recipient address (default: $MAIL_TO)
#   --from <email>             Sender address (default: $MAIL_FROM)
# Returns:
#   0 on successful dispatch; 1 on sendmail failure.
# ------------------------------------------------------------------------------
dispatch_job_notification() {
    local title="${JOB_NAME:-DevOps Automation}"
    local category="SYSTEM AUTOMATION"
    local status="success"
    local badge_icon="✓"
    local badge_label="COMPLETED"
    local subject=""
    local content=""
    local action=""
    local log_file="${JOB_LOG_FILE:-}"
    local log_lines=350
    local terminal_title="Execution Log"
    local extra_header="X-DevOps-Job: ${JOB_NAME:-automation}"
    local to="${MAIL_TO:-${DEFAULT_MAIL_TO}}"
    local from="${MAIL_FROM:-${MAIL_FROM_NAME:-DevOps Automation} <automation@${SYS_HOSTNAME}>}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title) shift; title="$1"; shift ;;
            --category) shift; category="$1"; shift ;;
            --status) shift; status="$1"; shift ;;
            --badge-icon) shift; badge_icon="$1"; shift ;;
            --badge-label) shift; badge_label="$1"; shift ;;
            --subject) shift; subject="$1"; shift ;;
            --content) shift; content="$1"; shift ;;
            --action) shift; action="$1"; shift ;;
            --log-file) shift; log_file="$1"; shift ;;
            --log-lines) shift; log_lines="$1"; shift ;;
            --terminal-title) shift; terminal_title="$1"; shift ;;
            --extra-header) shift; extra_header="$1"; shift ;;
            --to) shift; to="$1"; shift ;;
            --from) shift; from="$1"; shift ;;
            *) shift ;;
        esac
    done

    # Generate default subject if not provided
    if [[ -z "${subject}" ]]; then
        local prefix="[INFO]"
        [[ "${status}" == "success" ]] && prefix="[SUCCESS]"
        [[ "${status}" == "failed" ]] && prefix="[ALERT]"
        [[ "${status}" == "warning" ]] && prefix="[REVIEW]"
        subject="${prefix} ${title} - ${SYS_HOSTNAME}"
    fi

    # Render status badge
    local status_badge
    status_badge="$(get_status_badge "${status}" "${badge_icon}" "${badge_label}")"

    # Render terminal block if log lines > 0 and log file exists
    local terminal_block=""
    if (( log_lines > 0 )) && [[ -n "${log_file}" && -f "${log_file}" ]]; then
        local formatted_log
        formatted_log="$(prepare_email_log "${log_file}" "${log_lines}")"
        terminal_block="$(render_template "${SHARED_TEMPLATES_DIR}/terminal-card.html" \
            "TERMINAL_TITLE" "${terminal_title}" \
            "TERMINAL_SUBTITLE" "" \
            "TERMINAL_CONTENT" "${formatted_log}")"
    fi

    # Format action block if provided
    local action_block=""
    if [[ -n "${action}" ]]; then
        action_block="<tr><td style=\"padding: 12px 28px 16px 28px;\">${action}</td></tr>"
    fi

    # Render final email layout
    local email_body
    email_body="$(render_template "${SHARED_TEMPLATES_DIR}/base-layout.html" \
        "SUBJECT" "${subject}" \
        "SERVICE_CATEGORY" "${category}" \
        "JOB_TITLE" "${title}" \
        "STATUS_BADGE" "${status_badge}" \
        "CONTENT_BODY" "${content}" \
        "ACTION_BLOCK" "${action_block}" \
        "TERMINAL_BLOCK" "${terminal_block}" \
        "HOST_NAME" "${SYS_HOSTNAME}" \
        "EXECUTION_TIME" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
        "LOG_FILE_PATH" "${log_file}")"

    send_html_email "${to}" "${from}" "${subject}" "${email_body}" "${extra_header}"
}

# ------------------------------------------------------------------------------
# 6. Storage & DR Recovery Manifest Helpers
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: sync_to_remote
# Purpose:  Synchronizes local backup archives and companion checksums to remote
#           or secondary storage (Rclone, AWS S3, Local/NFS, or SFTP/Rsync) with
#           strict exit code trapping.
# Arguments:
#   $1 - Absolute path to local source archive.
#   $2 - Remote storage destination target (e.g. "gdrive:remote-path", "s3://...").
#   $3 (Optional) - Remote backend type ("rclone", "s3", "local", "sftp"; default: "rclone").
# Returns:
#   0 on success; non-zero exit code if transfer or checksum copy fails.
# ------------------------------------------------------------------------------
sync_to_remote() {
    local source_archive="$1"
    local remote_target="$2"
    local remote_type="${3:-${TARGET_REMOTE_TYPE:-rclone}}"
    local checksum_file="${source_archive}.sha256"

    local sync_err_tmp
    sync_err_tmp="$(mktemp /tmp/sync-remote-err.XXXXXX)"
    register_cleanup "rm -f '${sync_err_tmp}'"

    case "${remote_type}" in
        rclone)
            log_msg "[+] Syncing archive to remote via Rclone: ${remote_target}..."
            rclone copy "${source_archive}" "${remote_target}" \
                --fast-list \
                --drive-chunk-size 64M \
                --timeout 10m \
                --log-level NOTICE > "${sync_err_tmp}" 2>&1
            local rc=$?
            if [[ -s "${sync_err_tmp}" ]]; then
                cat "${sync_err_tmp}" >&2
                if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
                    sed 's/^/    [rclone] /' "${sync_err_tmp}" >> "${JOB_LOG_FILE}"
                fi
            fi
            if [[ ${rc} -ne 0 ]]; then
                log_msg "[-] Error: Rclone failed to sync archive to ${remote_target} (Exit code: ${rc})."
                return ${rc}
            fi
            if [[ -f "${checksum_file}" ]]; then
                rclone copy "${checksum_file}" "${remote_target}" \
                    --fast-list \
                    --timeout 2m \
                    --log-level NOTICE > "${sync_err_tmp}" 2>&1
                local rc_chk=$?
                if [[ -s "${sync_err_tmp}" ]]; then
                    cat "${sync_err_tmp}" >&2
                    if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
                        sed 's/^/    [rclone] /' "${sync_err_tmp}" >> "${JOB_LOG_FILE}"
                    fi
                fi
                if [[ ${rc_chk} -ne 0 ]]; then
                    log_msg "[-] Error: Rclone failed to sync checksum file to ${remote_target} (Exit code: ${rc_chk})."
                    return ${rc_chk}
                fi
            fi
            log_msg "[✓] Remote sync to ${remote_target} completed successfully."
            ;;
        s3)
            log_msg "[+] Uploading archive to AWS S3: ${remote_target}..."
            aws s3 cp "${source_archive}" "${remote_target}/" --no-progress > "${sync_err_tmp}" 2>&1
            local rc=$?
            if [[ -s "${sync_err_tmp}" ]]; then
                cat "${sync_err_tmp}" >&2
                if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
                    sed 's/^/    [aws] /' "${sync_err_tmp}" >> "${JOB_LOG_FILE}"
                fi
            fi
            if [[ ${rc} -ne 0 ]]; then
                log_msg "[-] Error: AWS S3 upload failed for ${remote_target} (Exit code: ${rc})."
                return ${rc}
            fi
            if [[ -f "${checksum_file}" ]]; then
                aws s3 cp "${checksum_file}" "${remote_target}/" --no-progress > "${sync_err_tmp}" 2>&1
                local rc_chk=$?
                if [[ -s "${sync_err_tmp}" ]]; then
                    cat "${sync_err_tmp}" >&2
                    if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
                        sed 's/^/    [aws] /' "${sync_err_tmp}" >> "${JOB_LOG_FILE}"
                    fi
                fi
                if [[ ${rc_chk} -ne 0 ]]; then
                    log_msg "[-] Error: AWS S3 checksum upload failed for ${remote_target} (Exit code: ${rc_chk})."
                    return ${rc_chk}
                fi
            fi
            log_msg "[✓] Remote upload to S3 completed successfully."
            ;;
        local)
            local dest_dir="${remote_target#local:}"
            log_msg "[+] Copying archive to local/NFS destination: ${dest_dir}..."
            mkdir -p "${dest_dir}"
            cp -a "${source_archive}" "${dest_dir}/" > "${sync_err_tmp}" 2>&1
            local rc=$?
            if [[ -s "${sync_err_tmp}" ]]; then
                cat "${sync_err_tmp}" >&2
                if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
                    sed 's/^/    [cp] /' "${sync_err_tmp}" >> "${JOB_LOG_FILE}"
                fi
            fi
            if [[ ${rc} -ne 0 ]]; then
                log_msg "[-] Error: Failed copying archive to ${dest_dir} (Exit code: ${rc})."
                return ${rc}
            fi
            if [[ -f "${checksum_file}" ]]; then
                cp -a "${checksum_file}" "${dest_dir}/" > "${sync_err_tmp}" 2>&1
                local rc_chk=$?
                if [[ -s "${sync_err_tmp}" ]]; then
                    cat "${sync_err_tmp}" >&2
                    if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
                        sed 's/^/    [cp] /' "${sync_err_tmp}" >> "${JOB_LOG_FILE}"
                    fi
                fi
                if [[ ${rc_chk} -ne 0 ]]; then
                    log_msg "[-] Error: Failed copying checksum file to ${dest_dir} (Exit code: ${rc_chk})."
                    return ${rc_chk}
                fi
            fi
            log_msg "[✓] Local sync to ${dest_dir} completed successfully."
            ;;
        sftp)
            local sftp_dest="${remote_target#sftp:}"
            log_msg "[+] Transferring archive via SFTP/Rsync: ${sftp_dest}..."
            rsync -avz -e ssh "${source_archive}" "${sftp_dest}/" > "${sync_err_tmp}" 2>&1
            local rc=$?
            if [[ -s "${sync_err_tmp}" ]]; then
                cat "${sync_err_tmp}" >&2
                if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
                    sed 's/^/    [rsync] /' "${sync_err_tmp}" >> "${JOB_LOG_FILE}"
                fi
            fi
            if [[ ${rc} -ne 0 ]]; then
                log_msg "[-] Error: Rsync failed to transfer archive to ${sftp_dest} (Exit code: ${rc})."
                return ${rc}
            fi
            if [[ -f "${checksum_file}" ]]; then
                rsync -avz -e ssh "${checksum_file}" "${sftp_dest}/" > "${sync_err_tmp}" 2>&1
                local rc_chk=$?
                if [[ -s "${sync_err_tmp}" ]]; then
                    cat "${sync_err_tmp}" >&2
                    if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
                        sed 's/^/    [rsync] /' "${sync_err_tmp}" >> "${JOB_LOG_FILE}"
                    fi
                fi
                if [[ ${rc_chk} -ne 0 ]]; then
                    log_msg "[-] Error: Rsync failed to transfer checksum file to ${sftp_dest} (Exit code: ${rc_chk})."
                    return ${rc_chk}
                fi
            fi
            log_msg "[✓] SFTP sync to ${sftp_dest} completed successfully."
            ;;
        *)
            log_msg "[-] Error: Unknown remote storage type: ${remote_type}"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Function: prune_local_storage
# Purpose:  Purges local backup archives and companion checksums older than the
#           specified retention threshold, while enforcing an absolute minimum
#           backup count floor to prevent wiping historical recovery points
#           during or after extended outages.
# Arguments:
#   $1 - Directory path containing local backups.
#   $2 - Retention threshold in days.
#   $3 (Optional) - Filename match pattern (default: "*").
#   $4 (Optional) - Minimum backup count floor (default: $LOCAL_MIN_KEEP or $retention_days).
# Returns:
#   0.
# ------------------------------------------------------------------------------
prune_local_storage() {
    local dir="$1"
    local retention_days="$2"
    local file_pattern="${3:-*}"
    local min_keep="${4:-${LOCAL_MIN_KEEP:-${retention_days}}}"

    if [[ ! -d "${dir}" ]]; then
        return 0
    fi

    # Discover matching primary archives (excluding .sha256 companion files), sorted chronologically
    local archives=()
    mapfile -t archives < <(find "${dir}" -maxdepth 1 -type f -name "${file_pattern}" ! -name "*.sha256" 2>/dev/null | sort)
    local total="${#archives[@]}"

    if (( total <= min_keep )); then
        log_msg "[+] Pruning local files in ${dir}: count (${total}) <= retention floor (${min_keep}). Preserving all existing recovery points."
        return 0
    fi

    local excess=$(( total - min_keep ))
    log_msg "[+] Pruning local files in ${dir}: ${total} archives found, retention floor is ${min_keep} (inspecting ${excess} older candidate(s) for age > ${retention_days} days)..."

    local cutoff_sec=$(( $(date +%s) - (retention_days * 86400) ))
    local pruned_count=0

    # Only inspect the excess oldest archives; the newest $min_keep archives are strictly protected
    for (( i=0; i<excess; i++ )); do
        local candidate="${archives[i]}"
        local cand_mtime
        cand_mtime=$(stat -c %Y "${candidate}" 2>/dev/null || echo 0)
        if (( cand_mtime < cutoff_sec )); then
            rm -f "${candidate}" "${candidate}.sha256"
            pruned_count=$(( pruned_count + 1 ))
        fi
    done

    log_msg "[✓] Local pruning complete in ${dir}: ${pruned_count} expired archive(s) deleted; $(( total - pruned_count )) preserved."
}

# ------------------------------------------------------------------------------
# Function: prune_remote_storage
# Purpose:  Removes expired backup files from remote storage backends (Rclone,
#           Local/NFS) based on retention age policies, while enforcing an
#           absolute minimum backup count floor to prevent wiping historical
#           recovery points during or after extended outages.
# Arguments:
#   $1 - Remote target identifier (e.g. "gdrive:hostname").
#   $2 (Optional) - Remote backend type ("rclone", "local", "s3", "sftp"; default: "rclone").
#   $3 - Retention threshold in days.
#   $4 (Optional) - Filename match pattern (default: "*").
#   $5 (Optional) - Minimum backup count floor (default: $REMOTE_MIN_KEEP or $retention_days).
# Returns:
#   0.
# ------------------------------------------------------------------------------
prune_remote_storage() {
    local remote_target="$1"
    local remote_type="${2:-${TARGET_REMOTE_TYPE:-rclone}}"
    local retention_days="$3"
    local file_pattern="${4:-*}"
    local min_keep="${5:-${REMOTE_MIN_KEEP:-${retention_days}}}"

    [[ -z "${remote_target}" ]] && return 0

    case "${remote_type}" in
        rclone)
            # Query remote for existing primary archives matching pattern (excluding companion .sha256 files)
            local remote_archives=()
            mapfile -t remote_archives < <(rclone lsf "${remote_target}" --include "${file_pattern}" 2>/dev/null | grep -v '\.sha256$' | grep -v '^$' | sort)
            local total="${#remote_archives[@]}"

            if (( total <= min_keep )); then
                log_msg "[+] Pruning remote backups in ${remote_target}: count (${total}) <= retention floor (${min_keep}). Preserving all existing recovery points."
                return 0
            fi

            local excess=$(( total - min_keep ))
            log_msg "[+] Pruning remote backups in ${remote_target}: ${total} archives found, retention floor is ${min_keep} (inspecting ${excess} older candidate(s) for age > ${retention_days} days)..."

            # Construct targeted filter arguments strictly for the excess oldest candidates
            local filter_args=()
            for (( i=0; i<excess; i++ )); do
                local candidate="${remote_archives[i]}"
                filter_args+=(--include "${candidate}" --include "${candidate}.sha256")
            done

            if [[ ${#filter_args[@]} -gt 0 ]]; then
                rclone delete "${remote_target}" \
                    "${filter_args[@]}" \
                    --min-age "${retention_days}d" 2>/dev/null || true
            fi
            log_msg "[✓] Remote pruning evaluated for ${remote_target}: enforced retention floor of at least ${min_keep} newest backups."
            ;;
        local)
            local dest_dir="${remote_target#local:}"
            prune_local_storage "${dest_dir}" "${retention_days}" "${file_pattern}" "${min_keep}"
            ;;
        s3|sftp)
            log_msg "[*] Notice: Pruning for ${remote_type} relies on cloud lifecycle policies or external management."
            ;;
        *)
            log_msg "[-] Warning: Unsupported remote type for pruning: ${remote_type}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Function: sqlite_hot_backup
# Purpose:  Performs a non-blocking hot online backup of active SQLite databases
#           using the sqlite3 .backup API (preventing WAL / lock concurrency issues)
#           with automatic fallback to atomic copy, securing destination to 0600.
# Arguments:
#   $1 - Absolute filesystem path to the source SQLite database.
#   $2 - Destination snapshot file path.
# Returns:
#   0 on success; 1 on error.
# ------------------------------------------------------------------------------
sqlite_hot_backup() {
    local src_db="$1"
    local dst_file="$2"
    mkdir -p "$(dirname "${dst_file}")"
    rm -f "${dst_file}"*
    local err_msg
    if command -v sqlite3 >/dev/null 2>&1; then
        if ! err_msg="$(sqlite3 "${src_db}" ".backup '${dst_file}'" 2>&1)"; then
            log_msg "[-] Error during sqlite hot backup of ${src_db}: ${err_msg}"
            return 1
        fi
    else
        if ! err_msg="$(cp -a "${src_db}" "${dst_file}" 2>&1)"; then
            log_msg "[-] Error copying database ${src_db}: ${err_msg}"
            return 1
        fi
    fi
    chmod 600 "${dst_file}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Function: generate_dr_manifest
# Purpose:  Generates a cross-platform, bare-metal Disaster Recovery (DR) manifest
#           documenting package inventory, kernel/OS summary, user accounts,
#           partition tables (sfdisk), LVM metadata (vgcfgbackup), filesystem
#           mounts, block UUIDs, network interfaces, firewall rules, and container
#           workloads to enable full system reconstruction.
# Arguments:
#   $1 - Target directory where manifest files will be generated.
#   $2 (Optional) - Human-readable display directory name for logging.
# Returns:
#   0 on completion.
# ------------------------------------------------------------------------------
generate_dr_manifest() {
    local manifest_dir="$1"
    local display_dir="${2:-}"

    # If display_dir is not explicitly passed, strip transient STAGING_DIR prefix if present
    if [[ -z "${display_dir}" ]]; then
        if [[ -n "${STAGING_DIR:-}" && "${manifest_dir}" == "${STAGING_DIR}"* ]]; then
            display_dir="${manifest_dir#"${STAGING_DIR}"}"
            [[ "${display_dir}" != /* ]] && display_dir="/${display_dir}"
        else
            display_dir="${manifest_dir}"
        fi
    fi

    mkdir -p "${manifest_dir}"

    log_msg "[+] Generating cross-platform Disaster Recovery manifest in ${display_dir}..."

    # 1. Package Inventory (RHEL & Debian Families)
    if command -v dnf &>/dev/null; then
        rpm -qa --qf "%{NAME}\n" 2>/dev/null | sort -u > "${manifest_dir}/installed-packages.txt" || true
        dnf repoquery --userinstalled --qf "%{NAME}" 2>/dev/null | sort -u > "${manifest_dir}/user-installed-packages.txt" || true
    elif command -v dpkg &>/dev/null; then
        dpkg --get-selections > "${manifest_dir}/installed-packages.txt" 2>/dev/null || true
    fi

    # 2. Kernel, Operating System & User Accounts Summary
    {
        echo "=== Host & OS Summary ==="
        uname -a
        [[ -f /etc/os-release ]] && cat /etc/os-release
        echo -e "\n=== Interactive User Accounts (UID >= 1000) ==="
        awk -F: '$3 >= 1000 && $1 != "nobody" {printf "%-16s UID:%-5s GID:%-5s Home:%-20s Shell:%s\n", $1, $3, $4, $6, $7}' /etc/passwd 2>/dev/null || true
    } > "${manifest_dir}/system-summary.txt" 2>/dev/null || true

    # 3. Storage, Partitioning, LVM & Filesystem Layout
    mkdir -p "${manifest_dir}/storage"

    # A. Partition Tables (Replayable via sfdisk and readable via fdisk)
    if command -v sfdisk &>/dev/null; then
        for dev in $(lsblk -dpno NAME 2>/dev/null | grep -v 'loop\|ram'); do
            [[ -b "${dev}" ]] && sfdisk -d "${dev}" > "${manifest_dir}/storage/partition-table-$(basename "${dev}").sfdisk" 2>/dev/null || true
        done
    fi
    command -v fdisk &>/dev/null && fdisk -l > "${manifest_dir}/storage/fdisk-all.txt" 2>/dev/null || true

    # B. LVM Layout & Raw Metadata Backup (Restorable via vgcfgrestore)
    if command -v lvs &>/dev/null; then
        {
            echo "=== Physical Volumes (PVS) ===" && pvs
            echo -e "\n=== Volume Groups (VGS) ===" && vgs
            echo -e "\n=== Logical Volumes (LVS) ===" && lvs -o lv_name,vg_name,lv_size,lv_attr,data_percent
        } > "${manifest_dir}/storage/lvm-layout.txt" 2>/dev/null || true

        mkdir -p "${manifest_dir}/storage/lvm-backup"
        vgcfgbackup -f "${manifest_dir}/storage/lvm-backup/%s.vgcfg" &>/dev/null || true
    fi

    # C. Filesystem Utilization, Mount Hierarchy & Block IDs
    df -hT > "${manifest_dir}/storage/filesystem-usage.txt" 2>/dev/null || true
    command -v findmnt &>/dev/null && findmnt > "${manifest_dir}/storage/findmnt-tree.txt" 2>/dev/null || true
    command -v lsblk &>/dev/null && lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS > "${manifest_dir}/storage/lsblk.txt" 2>/dev/null || true
    command -v blkid &>/dev/null && blkid > "${manifest_dir}/storage/blkid.txt" 2>/dev/null || true

    # Maintain root-level summary file for backwards compatibility
    if command -v lsblk &>/dev/null; then
        lsblk -o NAME,FSTYPE,LABEL,UUID,MOUNTPOINTS > "${manifest_dir}/disk-and-filesystems.txt" 2>/dev/null || true
    fi
    if command -v blkid &>/dev/null; then
        echo -e "\n=== Block Device IDs (blkid) ===" >> "${manifest_dir}/disk-and-filesystems.txt"
        blkid >> "${manifest_dir}/disk-and-filesystems.txt" 2>/dev/null || true
    fi

    # D. Swap Configuration
    command -v swapon &>/dev/null && swapon --show > "${manifest_dir}/storage/swap.txt" 2>/dev/null || true

    # E. Software RAID (MD) if present
    [[ -f /proc/mdstat ]] && cat /proc/mdstat > "${manifest_dir}/storage/mdstat.txt" 2>/dev/null || true

    # 4. Network Interfaces, Routing & Packet Filtering
    if command -v ip &>/dev/null; then
        ip -br addr > "${manifest_dir}/network-configuration.txt" 2>/dev/null || true
        echo -e "\n=== Routing Table ===" >> "${manifest_dir}/network-configuration.txt"
        ip route >> "${manifest_dir}/network-configuration.txt" 2>/dev/null || true
    fi
    if [[ -f /etc/resolv.conf ]]; then
        echo -e "\n=== DNS Resolvers ===" >> "${manifest_dir}/network-configuration.txt"
        cat /etc/resolv.conf >> "${manifest_dir}/network-configuration.txt" 2>/dev/null || true
    fi
    if command -v nft &>/dev/null; then
        nft list ruleset > "${manifest_dir}/firewall-rules.txt" 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
        iptables-save > "${manifest_dir}/firewall-rules.txt" 2>/dev/null || true
    fi

    # 5. Service, Daemon & Scheduled Timer State
    if command -v systemctl &>/dev/null; then
        systemctl list-unit-files --state=enabled --no-pager > "${manifest_dir}/enabled-systemd-units.txt" 2>/dev/null || true
        systemctl list-timers --all --no-pager > "${manifest_dir}/systemd-timers.txt" 2>/dev/null || true
    fi

    # 6. Container Inventory
    if command -v podman &>/dev/null; then
        podman ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" > "${manifest_dir}/containers.txt" 2>/dev/null || true
    elif command -v docker &>/dev/null; then
        docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" > "${manifest_dir}/containers.txt" 2>/dev/null || true
    fi

    # 7. Listening Ports
    if command -v ss &>/dev/null; then
        ss -tulpn > "${manifest_dir}/listening-ports.txt" 2>/dev/null || true
    fi

    log_msg "    [✓] DR recovery manifest successfully captured."
}
