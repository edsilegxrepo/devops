#!/usr/bin/env bash
# ==============================================================================
# Library: /opt/scripts/lib/common.sh
# Purpose: Core infrastructure functions for DevOps automation scripts
# Host:    cs-us-pweb001.criticalsys.net (Universal RHEL & Debian Compatibility)
# Standard: DRY Architecture Framework
# ==============================================================================
set -euo pipefail
umask 077
shopt -u patsub_replacement 2>/dev/null || true

# Standard Environment Variables
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SCRIPTS_DIR="$(dirname "${COMMON_LIB_DIR}")"
COMMON_CONFIG_DIR="${COMMON_SCRIPTS_DIR}/config"
COMMON_TEMPLATES_DIR="${COMMON_SCRIPTS_DIR}/templates"
SHARED_TEMPLATES_DIR="${COMMON_TEMPLATES_DIR}/shared"

DEFAULT_MAIL_TO="criticalsys.mis@gmail.com"
DEFAULT_SENDMAIL="/usr/sbin/sendmail"
SYS_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
SHORT_HOSTNAME="${SYS_HOSTNAME%%.*}"

# ------------------------------------------------------------------------------
# 1. Configuration & Privilege Guards
# ------------------------------------------------------------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "[-] Error: This script must be executed as root (or via sudo)." >&2
        exit 1
    fi
}

# Usage: verify_dependencies "tar" "zstd" "gpg" "rclone" "find"
verify_dependencies() {
    local missing=()
    for bin in "$@"; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            missing+=("${bin}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_msg "[-] Error: Missing required CLI dependencies: ${missing[*]}" 1 >&2
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 2. Configuration Loading & Validation Engine
# ------------------------------------------------------------------------------
# Usage: load_config "job-name"
# Resolves configuration in order:
#   1. Global Common Configuration (/etc/devops/common.conf, config/common.env)
#   2. Job-Specific Configuration  (/etc/devops/${job}.conf, config/${job}.env)
#   3. OS-level overrides          (/etc/sysconfig/${job}, /etc/default/${job})
#   4. Dynamic Auto-Discovery Fallbacks
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
    if [[ "${job_name}" == "vm-backup" ]]; then
        validate_backup_config
    elif [[ "${job_name}" == "container-updates" ]]; then
        validate_container_config
    fi
}

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

validate_backup_config() {
    BACKUP_DIR="${BACKUP_DIR:-/var/backups/vm-snapshots}"
    ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-${SHORT_HOSTNAME}-backup}"
    TARGET_REMOTE="${TARGET_REMOTE:-gdrive:${SHORT_HOSTNAME}}"
    PASSPHRASE_FILE="${PASSPHRASE_FILE:-/root/.secrets/backup-passphrase}"
    LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-2}"
    REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-14}"
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

# ------------------------------------------------------------------------------
# 3. Concurrency Locking
# ------------------------------------------------------------------------------
# Usage: acquire_lock "job-name"
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

# Usage: register_cleanup "rm -rf '${STAGING_DIR}'"
# Registers a cleanup command on the LIFO stack to execute upon script exit or signal.
register_cleanup() {
    CLEANUP_HOOKS+=("$*")
}

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

# Usage: init_job_log "job-name" "/var/log/jobs" 14
# Exports: JOB_LOG_FILE, JOB_START_TS, JOB_CHECK_TIME
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

log_msg() {
    local msg="$1"
    local to_stdout="${2:-1}"
    if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] ${msg}" >> "${JOB_LOG_FILE}"
    fi
    if [[ "${to_stdout}" -eq 1 ]]; then
        echo "${msg}"
    fi
}

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
escape_html() {
    local input
    if [[ $# -gt 0 ]]; then
        input="$1"
    else
        input="$(cat)"
    fi
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<< "${input}"
}

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

render_template() {
    local tmpl_file="$1"
    shift
    if [[ ! -f "${tmpl_file}" ]]; then
        log_msg "[-] Error: Template file not found: ${tmpl_file}" 1 >&2
        return 1
    fi
    local content
    content="$(cat "${tmpl_file}")"
    while [[ $# -ge 2 ]]; do
        local key="$1"
        local val="$2"
        shift 2
        content="${content//\{\{${key}\}\}/${val}}"
    done
    echo "${content}"
}

get_status_badge() {
    local status_type="$1" # success | failed | warning
    local icon="$2"
    local label="$3"
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
# 6. Storage & DR Recovery Manifest Helpers
# ------------------------------------------------------------------------------
sync_to_remote() {
    local source_archive="$1"
    local remote_target="$2"
    local remote_type="${3:-${TARGET_REMOTE_TYPE:-rclone}}"
    local checksum_file="${source_archive}.sha256"

    case "${remote_type}" in
        rclone)
            log_msg "[+] Syncing archive to remote via Rclone: ${remote_target}..."
            rclone copy "${source_archive}" "${remote_target}" \
                --fast-list \
                --drive-chunk-size 64M \
                --timeout 10m \
                --log-level NOTICE
            if [[ -f "${checksum_file}" ]]; then
                rclone copy "${checksum_file}" "${remote_target}" \
                    --fast-list \
                    --timeout 2m \
                    --log-level NOTICE
            fi
            ;;
        s3)
            log_msg "[+] Uploading archive to AWS S3: ${remote_target}..."
            aws s3 cp "${source_archive}" "${remote_target}/" --no-progress
            if [[ -f "${checksum_file}" ]]; then
                aws s3 cp "${checksum_file}" "${remote_target}/" --no-progress
            fi
            ;;
        local)
            local dest_dir="${remote_target#local:}"
            log_msg "[+] Copying archive to local/NFS destination: ${dest_dir}..."
            mkdir -p "${dest_dir}"
            cp -a "${source_archive}" "${dest_dir}/"
            if [[ -f "${checksum_file}" ]]; then
                cp -a "${checksum_file}" "${dest_dir}/"
            fi
            ;;
        sftp)
            local sftp_dest="${remote_target#sftp:}"
            log_msg "[+] Transferring archive via SFTP/Rsync: ${sftp_dest}..."
            rsync -avz -e ssh "${source_archive}" "${sftp_dest}/"
            if [[ -f "${checksum_file}" ]]; then
                rsync -avz -e ssh "${checksum_file}" "${sftp_dest}/"
            fi
            ;;
        *)
            log_msg "[-] Error: Unknown remote storage type: ${remote_type}"
            return 1
            ;;
    esac
}

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
