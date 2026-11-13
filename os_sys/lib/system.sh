#!/usr/bin/env bash
# ==============================================================================
# Library:     /opt/scripts/lib/system.sh
# Version:     2.0.0  2026/11/06
# Standard:    DRY Architecture Framework (Universal System Foundation Layer)
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: POSIX compliant Linux (Enterprise Linux 8/9/10, Debian 12+,
#              Ubuntu 22.04+, Linux Mint, Fedora, CentOS Stream, Rocky, Alma)
# Description: Production-hardened universal Linux foundation layer supplying
#              core host discovery, superuser privilege enforcement, CLI
#              dependency checks, platform & virtualization detection (WSL),
#              unified console/file/syslog logging, POSIX storage capacity
#              auditing (/ and /boot), atomic symlink mutation, and process
#              lock PID discovery.
# ==============================================================================
set -euo pipefail

# Idempotent include guard
[[ -n "${_SYSTEM_SH_LOADED:-}" ]] && return 0
_SYSTEM_SH_LOADED=1

# Ensure standard system umask for administrative & system tasks (drwxr-xr-x / -rw-r--r--)
umask 022

# ------------------------------------------------------------------------------
# 1. System Host Identity & Discovery
# ------------------------------------------------------------------------------
# Resolve canonical fully-qualified domain name (FQDN) and short hostname
SYS_HOSTNAME="${SYS_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
# shellcheck disable=SC2034 # Exported for sourcing scripts
SHORT_HOSTNAME="${SYS_HOSTNAME%%.*}"

# ------------------------------------------------------------------------------
# 2. Unified Logging Subsystem
# ------------------------------------------------------------------------------
# Global log file target (can be overridden by caller via init_system_logging)
LOG_FILE="${LOG_FILE:-/var/log/sys_devops.log}"

init_system_logging() {
    local target_log="${1:-}"
    if [[ -n "${target_log}" ]]; then
        LOG_FILE="${target_log}"
    fi
    local log_dir
    log_dir="$(dirname "${LOG_FILE}")"
    if [[ ! -d "${log_dir}" ]] && [[ "${EUID}" -eq 0 ]]; then
        mkdir -p "${log_dir}" 2>/dev/null || true
    fi
    if [[ "${EUID}" -eq 0 ]] && [[ -f "${LOG_FILE}" ]]; then
        chmod 0640 "${LOG_FILE}" 2>/dev/null || true
    fi
}

init_debian_logging() {
    init_system_logging "${1:-/var/log/debian_sys.log}"
}

log_info() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[+] [${ts}] ${msg}"
    if [[ -w "${LOG_FILE}" ]] || { [[ ! -f "${LOG_FILE}" ]] && [[ -w "$(dirname "${LOG_FILE}" 2>/dev/null)" ]]; }; then
        echo "[INFO] [${ts}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

log_warn() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[!] [${ts}] WARNING: ${msg}" >&2
    if [[ -w "${LOG_FILE}" ]] || { [[ ! -f "${LOG_FILE}" ]] && [[ -w "$(dirname "${LOG_FILE}" 2>/dev/null)" ]]; }; then
        echo "[WARN] [${ts}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

log_error() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[-] [${ts}] ERROR: ${msg}" >&2
    if [[ -w "${LOG_FILE}" ]] || { [[ ! -f "${LOG_FILE}" ]] && [[ -w "$(dirname "${LOG_FILE}" 2>/dev/null)" ]]; }; then
        echo "[ERROR] [${ts}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

log_audit() {
    local msg="$1"
    local tag="${2:-system-audit}"
    if command -v logger >/dev/null 2>&1; then
        logger -t "${tag}" "${msg}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 3. Privilege & Platform Verification Guards
# ------------------------------------------------------------------------------
require_root() {
    local err_msg="${1:-This script must be executed as root (or via sudo).}"
    if [[ "${EUID}" -ne 0 ]]; then
        echo "[-] Security Error: ${err_msg}" >&2
        exit 1
    fi
}

verify_dependencies() {
    local missing=()
    for bin in "$@"; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            missing+=("${bin}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        local err="[-] Error: Missing required CLI dependencies: ${missing[*]}"
        if declare -f log_msg >/dev/null 2>&1; then
            log_msg "${err}" 1 >&2
        else
            echo "${err}" >&2
        fi
        return 1
    fi
    return 0
}

is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || \
    [[ -n "${WSL_INTEROP:-}" ]] || \
    [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] || \
    [[ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]] || \
    grep -qi microsoft /proc/version 2>/dev/null
}

# ------------------------------------------------------------------------------
# Function: validate_os
# Purpose:  Inspects /etc/os-release to detect and validate the host distribution
#           and family. Supports RHEL (RHEL, AlmaLinux, Rocky, CentOS, Fedora,
#           Oracle Linux, Amazon Linux) and Debian (Ubuntu, Debian, Linux Mint, etc.).
# Arguments:
#   $1 (Optional) - Expected OS family constraint: "debian", "rhel", or "any" (default: "any").
# Returns:
#   0 on success; exits 1 on fatal OS incompatibility.
# Variables Exported:
#   OS_FAMILY   - Detected family: "debian" or "rhel"
#   OS_ID       - Lowercase distro ID (e.g., "ubuntu", "rocky", "almalinux")
#   OS_PRETTY   - Human-readable operating system string (e.g. "Ubuntu 22.04.4 LTS")
#   OS_VERSION  - Distro version identifier (e.g. "22.04", "9.3")
# ------------------------------------------------------------------------------
validate_os() {
    local target_family="${1:-any}"

    if [[ ! -f /etc/os-release ]]; then
        log_error "Operating System Error: /etc/os-release not found. Unable to identify distribution."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"
    # shellcheck disable=SC2034 # Public library variable exposed by validate_os() for callers
    OS_VERSION="${VERSION_ID:-unknown}"
    local id_like="${ID_LIKE:-}"

    # Determine distribution family
    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali)
            OS_FAMILY="debian"
            ;;
        rhel|centos|almalinux|rocky|fedora|ol|amzn)
            OS_FAMILY="rhel"
            ;;
        *)
            if [[ "${id_like}" =~ debian|ubuntu ]]; then
                OS_FAMILY="debian"
            elif [[ "${id_like}" =~ rhel|fedora|centos ]]; then
                OS_FAMILY="rhel"
            else
                OS_FAMILY="unknown"
            fi
            ;;
    esac

    # Validate against requested constraint
    case "${target_family}" in
        debian|ubuntu)
            if [[ "${OS_FAMILY}" != "debian" ]]; then
                log_error "Operating System Error: Detected OS '${OS_ID}' (${OS_PRETTY}). This utility requires Debian, Ubuntu, Linux Mint, or derivative."
                exit 1
            fi
            ;;
        rhel|fedora|centos)
            if [[ "${OS_FAMILY}" != "rhel" ]]; then
                log_error "Operating System Error: Detected OS '${OS_ID}' (${OS_PRETTY}). This utility requires Enterprise Linux (RHEL, AlmaLinux, Rocky, CentOS, Fedora)."
                exit 1
            fi
            ;;
        any)
            if [[ "${OS_FAMILY}" == "unknown" ]]; then
                log_error "Operating System Error: Unsupported operating system '${OS_ID}' (${OS_PRETTY}). Expected RHEL or Debian family."
                exit 1
            fi
            ;;
        *)
            log_error "Internal Error: Unknown target OS family '${target_family}' passed to validate_os."
            exit 1
            ;;
    esac

    # --------------------------------------------------------------------------
    # Dynamic Domain Layer Auto-Router
    # --------------------------------------------------------------------------
    local lib_dir
    lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

    if [[ "${OS_FAMILY}" == "rhel" && -z "${_RHEL_SYS_LOADED:-}" ]]; then
        local rhel_lib="${lib_dir}/rhel_sys.sh"
        [[ -f "${rhel_lib}" ]] || rhel_lib="/opt/scripts/lib/rhel_sys.sh"
        if [[ -f "${rhel_lib}" ]]; then
            # shellcheck source=/dev/null
            source "${rhel_lib}"
        fi
    elif [[ "${OS_FAMILY}" == "debian" && -z "${_DEBIAN_SYS_LOADED:-}" ]]; then
        local deb_lib="${lib_dir}/debian_sys.sh"
        [[ -f "${deb_lib}" ]] || deb_lib="/opt/scripts/lib/debian_sys.sh"
        if [[ -f "${deb_lib}" ]]; then
            # shellcheck source=/dev/null
            source "${deb_lib}"
        fi
    fi

    return 0
}

validate_debian_os() {
    validate_os "debian"
}

validate_rhel_os() {
    validate_os "rhel"
}

# ------------------------------------------------------------------------------
# 4. Storage Capacity & Partition Monitoring Engine
# ------------------------------------------------------------------------------
get_partition_summary() {
    local target_path="$1"
    [[ -d "${target_path}" ]] || target_path="/"
    df -h "${target_path}" 2>/dev/null | awk 'NR==2 {print $6 " (" $4 " free / " $5 " used)"}' || echo "N/A"
}

get_free_mb() {
    local target_path="$1"
    [[ -d "${target_path}" ]] || target_path="/"
    local free_mb=""
    # Try POSIX block-size 1M first (GNU df)
    free_mb="$(df -P -BM "${target_path}" 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}' || true)"
    if [[ "${free_mb}" =~ ^[0-9]+$ ]]; then
        echo "${free_mb}"
        return 0
    fi
    # Fallback to standard 1K blocks
    local free_kb
    free_kb="$(df -P "${target_path}" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    if [[ "${free_kb}" =~ ^[0-9]+$ ]]; then
        echo "$((free_kb / 1024))"
        return 0
    fi
    echo "9999"
}

check_storage_capacity() {
    local root_min_mb="${1:-1024}"
    local boot_min_mb="${2:-100}"
    local force_flag="${3:-false}"
    local is_detect="${4:-false}"
    # $5 (script_name) intentionally unused; kept as positional slot before $6 (purge_hint).
    local purge_hint="${6:-}"

    local boot_path="/boot"
    [[ -d "${boot_path}" ]] || boot_path="/"

    local root_free_mb
    root_free_mb="$(get_free_mb "/")"
    local boot_free_mb
    boot_free_mb="$(get_free_mb "${boot_path}")"

    local root_summary
    root_summary="$(get_partition_summary "/")"
    local boot_summary
    boot_summary="$(get_partition_summary "${boot_path}")"

    log_info "Filesystem capacity metrics:"
    log_info "  -> Root (/) : ${root_summary} (free: ${root_free_mb} MB, recommended >= ${root_min_mb} MB)"
    log_info "  -> Boot     : ${boot_summary} (free: ${boot_free_mb} MB, recommended >= ${boot_min_mb} MB)"

    local issues=0

    if [[ "${root_free_mb}" =~ ^[0-9]+$ ]] && [[ ${root_free_mb} -lt ${root_min_mb} ]]; then
        log_warn "Root (/) filesystem storage is critically low: ${root_free_mb} MB free (minimum recommended: ${root_min_mb} MB)!"
        issues=$((issues + 1))
    fi

    if [[ "${boot_free_mb}" =~ ^[0-9]+$ ]] && [[ ${boot_free_mb} -lt ${boot_min_mb} ]]; then
        log_warn "${boot_path} filesystem storage is critically low: ${boot_free_mb} MB free (minimum recommended: ${boot_min_mb} MB)!"
        log_warn "Low storage on ${boot_path} may cause initramfs generation to fail during kernel transactions."
        issues=$((issues + 1))
    fi

    if [[ ${issues} -gt 0 ]]; then
        if [[ "${is_detect}" == "true" ]]; then
            log_warn "[DETECT] Storage capacity warning: ${issues} filesystem(s) below recommended threshold."
        elif [[ "${force_flag}" == "true" ]]; then
            log_warn "Proceeding with low storage capacity due to '--force' flag."
        else
            log_error "Aborting transaction due to critically low disk capacity (${issues} issue(s) detected)."
            if [[ -n "${purge_hint}" ]]; then
                echo "    Hint: Run 'sudo ${purge_hint}' to remove retired kernels, or pass '-f/--force'." >&2
            else
                echo "    Hint: Clean unneeded packages or pass '-f/--force' to bypass." >&2
            fi
            exit 1
        fi
    else
        log_info "Storage capacity check passed. Filesystems have sufficient headroom."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 5. Process & Transaction Lock Inspector
# ------------------------------------------------------------------------------
get_lock_pids() {
    local lock_file="$1"
    local pids=""
    if command -v fuser >/dev/null 2>&1; then
        pids="$(fuser "${lock_file}" 2>/dev/null || true)"
    elif command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -t "${lock_file}" 2>/dev/null || true)"
    fi
    echo "${pids}" | tr '\n' ' ' | xargs 2>/dev/null || echo ""
}

get_active_pkg_managers() {
    local procs=""
    if command -v pgrep >/dev/null 2>&1; then
        procs="$(pgrep -a -x "apt|apt-get|dpkg|dpkg-deb|aptitude|synaptic|dnf|dnf-3|dnf5|yum|rpm|rpmdb" 2>/dev/null || true)"
        local bg_procs
        bg_procs="$(pgrep -a -f "unattended-upgr|apt\.systemd\.daily|packagekitd|dnf-automatic" 2>/dev/null || true)"
        if [[ -n "${bg_procs}" ]]; then
            if [[ -n "${procs}" ]]; then
                procs="${procs}"$'\n'"${bg_procs}"
            else
                procs="${bg_procs}"
            fi
        fi
    fi
    echo "${procs}"
}

# ------------------------------------------------------------------------------
# 6. Atomic Symlink Management
# ------------------------------------------------------------------------------
update_link() {
    local link_path="$1"
    local target="$2"
    local tmp_link
    tmp_link="$(mktemp -u "${link_path}.tmp.XXXXXX")"
    ln -sf "${target}" "${tmp_link}"
    mv -f "${tmp_link}" "${link_path}"
}

# ------------------------------------------------------------------------------
# 7. Bootloader Configuration Hardening (GNU GRUB)
# ------------------------------------------------------------------------------
harden_grub_config() {
    local is_detect="${1:-false}"
    if [[ "${is_detect}" == "true" ]]; then
        log_info "[DETECT] Verifying bootloader configurations for recovery safety..."
    else
        log_info "Verifying bootloader configurations for recovery safety..."
    fi
    local grub_conf="/etc/default/grub"

    if [[ ! -f "${grub_conf}" ]]; then
        log_warn "/etc/default/grub not found. Skipping bootloader safety hardening."
        return 0
    fi

    local temp_backup=""
    if [[ "${is_detect}" == "false" ]]; then
        temp_backup="$(mktemp -u "/tmp/grub.XXXXXX")"
        cp -p "${grub_conf}" "${temp_backup}"
    fi

    local modified=false

    # 1. Enforce visible recovery menu style
    if grep -q "^GRUB_TIMEOUT_STYLE=hidden" "${grub_conf}"; then
        if [[ "${is_detect}" == "true" ]]; then
            log_info "[DETECT]   -> Would change GRUB_TIMEOUT_STYLE from 'hidden' to 'menu' for menu visibility."
        else
            log_info "  -> Changing GRUB_TIMEOUT_STYLE from 'hidden' to 'menu' for menu visibility."
            sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/' "${grub_conf}"
            modified=true
        fi
    fi

    # 2. Enforce minimum recovery timeout of 5 seconds
    if grep -q "^GRUB_TIMEOUT=0" "${grub_conf}"; then
        if [[ "${is_detect}" == "true" ]]; then
            log_info "[DETECT]   -> Would change GRUB_TIMEOUT from '0' to '5' to allow fallback selection."
        else
            log_info "  -> Changing GRUB_TIMEOUT from '0' to '5' to allow fallback selection."
            sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' "${grub_conf}"
            modified=true
        fi
    fi

    # 3. Optimize default kernel parameters in GRUB_CMDLINE_LINUX_DEFAULT:
    #    - Remove 'quiet' if present (to show diagnostics)
    #    - Add 'nomodeset' if absent (to guarantee screen compatibility)
    #    - Add 'panic=30' if absent (to enable auto-reboot on crash)
    if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" "${grub_conf}"; then
        local current_line current_val
        current_line="$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "${grub_conf}")"
        current_val="$(echo "${current_line}" | sed -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=//' -e 's/^"//' -e 's/"$//')"

        local -a params=()
        local -a new_params=()
        read -r -a params <<< "${current_val}"

        local has_nomodeset=false
        local has_panic=false

        for param in "${params[@]}"; do
            [[ -z "${param}" ]] && continue
            if [[ "${param}" == "quiet" ]]; then
                continue
            fi
            if [[ "${param}" == "nomodeset" ]]; then
                has_nomodeset=true
            fi
            if [[ "${param}" =~ ^panic= ]]; then
                has_panic=true
            fi
            new_params+=("${param}")
        done

        if [[ "${has_nomodeset}" == "false" ]]; then
            new_params+=("nomodeset")
        fi
        if [[ "${has_panic}" == "false" ]]; then
            new_params+=("panic=30")
        fi

        local new_val="${new_params[*]}"
        local new_line="GRUB_CMDLINE_LINUX_DEFAULT=\"${new_val}\""

        if [[ "${current_line}" != "${new_line}" ]]; then
            if [[ "${is_detect}" == "true" ]]; then
                log_info "[DETECT]   -> Would optimize GRUB_CMDLINE_LINUX_DEFAULT: removing 'quiet', ensuring 'nomodeset' and 'panic=30'."
            else
                log_info "  -> Optimizing GRUB_CMDLINE_LINUX_DEFAULT: removing 'quiet', ensuring 'nomodeset' and 'panic=30'."
                sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${new_line}|" "${grub_conf}"
                modified=true
            fi
        fi
    fi

    # 4. Enforce GRUB_RECORDFAIL_TIMEOUT to prevent headless boot hangs on failure
    if ! grep -q "^GRUB_RECORDFAIL_TIMEOUT=" "${grub_conf}"; then
        if [[ "${is_detect}" == "true" ]]; then
            log_info "[DETECT]   -> Would append 'GRUB_RECORDFAIL_TIMEOUT=5' to prevent boot menu hangs after failed boot."
        else
            log_info "  -> Appending 'GRUB_RECORDFAIL_TIMEOUT=5' to prevent boot menu hangs after failed boot."
            echo "GRUB_RECORDFAIL_TIMEOUT=5" >> "${grub_conf}"
            modified=true
        fi
    fi

    if [[ "${is_detect}" == "false" ]]; then
        if [[ "${modified}" == "true" ]]; then
            local timestamp_backup
            timestamp_backup="${grub_conf}.$(date '+%Y%m%d-%H%M%S')"
            mv "${temp_backup}" "${timestamp_backup}"
            log_info "Bootloader settings hardened successfully! Backup saved to ${timestamp_backup}."
        else
            rm -f "${temp_backup}"
            log_info "Bootloader recovery settings are already hardened and healthy."
        fi
    fi
}

# ------------------------------------------------------------------------------
# 8. System Maintenance, Locking & UI Helpers
# ------------------------------------------------------------------------------
is_reboot_required() {
    if [[ -f /run/reboot-required ]]; then
        return 0
    fi
    if command -v needs-restarting >/dev/null 2>&1; then
        if ! needs-restarting -r >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

acquire_script_lock() {
    local script_base
    script_base="$(basename "$0" .sh)"
    local lock_file="${1:-/run/${script_base}.lock}"

    exec 8>"${lock_file}"
    if ! flock -n 8; then
        log_error "Another instance of $(basename "$0") is currently running (lock ${lock_file} held). Aborting."
        exit 1
    fi
}

get_safe_hostname() {
    (hostname -f 2>/dev/null || hostname 2>/dev/null || uname -n || echo "localhost") | tr -dc 'a-zA-Z0-9_.-'
}

print_section_header() {
    local title="$1"
    local tag="${2:-${NODE_TAG:-$(get_safe_hostname)}}"
    local formatted_title="${title}->${tag}"
    local total_len=75
    local current_len=${#formatted_title}
    local fill_len=$((total_len - current_len - 5))
    if [[ ${fill_len} -lt 1 ]]; then fill_len=1; fi

    printf '_____%s' "${formatted_title}"
    local fill
    printf -v fill "%0${fill_len}d" 0
    echo "${fill//0/_}"
}

print_header() {
    print_section_header "$@"
}

print_storage_summary() {
    local boot_path="${1:-/boot}"
    [[ -d "${boot_path}" ]] || boot_path="/"
    log_info "Post-transaction filesystem storage metrics:"
    log_info "  -> Root (/) : $(get_partition_summary "/")"
    log_info "  -> Boot     : $(get_partition_summary "${boot_path}")"
}


