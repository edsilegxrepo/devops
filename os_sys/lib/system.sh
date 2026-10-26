#!/usr/bin/env bash
# ==============================================================================
# Library:     /opt/scripts/lib/system.sh
# Version:     1.4.0  2026/10/26
# Standard:    DRY Architecture Framework (System Foundation Layer)
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky, CentOS)
#              Debian 12+ (Bookworm), Ubuntu 22.04+ (Jammy/Noble)
# Description: Lightweight OS-level foundation library supplying core system
#              identity, privilege guards, CLI dependency checks, package
#              manager auto-discovery, syslog auditing, and SQLite integrity
#              verification for standalone administrative tools and batch jobs.
# ==============================================================================
set -euo pipefail

# Ensure standard system umask for administrative & system tasks (drwxr-xr-x / -rw-r--r--)
umask 022

# ------------------------------------------------------------------------------
# 1. System Host Identity & Discovery
# ------------------------------------------------------------------------------
# Resolve canonical fully-qualified domain name (FQDN) and short hostname
SYS_HOSTNAME="${SYS_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
# shellcheck disable=SC2034 # Exported for sourcing scripts
SHORT_HOSTNAME="${SYS_HOSTNAME%%.*}"

# Primary Package Manager Discovery:
# Auto-detects native package manager binary across Enterprise Linux and Debian families.
# Priority: dnf (EL8/9/10, Fedora) -> yum (EL7/legacy) -> apt-get (Debian/Ubuntu) -> dnf
# shellcheck disable=SC2034 # Exported for sourcing scripts
PKG_MGR="$(command -v dnf 2>/dev/null || command -v yum 2>/dev/null || command -v apt-get 2>/dev/null || echo "dnf")"

# ------------------------------------------------------------------------------
# 2. Privilege & Dependency Guards
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: require_root
# Purpose:  Enforces superuser (root / UID 0) execution constraints.
# Arguments:
#   $1 (Optional) - Custom error message to emit to stderr before exiting.
# Returns:
#   0 if running as root; exits immediately with code 1 otherwise.
# ------------------------------------------------------------------------------
require_root() {
    local err_msg="${1:-This script must be executed as root (or via sudo).}"
    if [[ "${EUID}" -ne 0 ]]; then
        echo "[-] Error: ${err_msg}" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Function: verify_dependencies
# Purpose:  Validates that all specified binary executables exist in $PATH.
# Arguments:
#   $@ - List of executable names to verify (e.g. "grubby" "uname" "grep")
# Returns:
#   0 if all binaries are found; 1 if any binary is missing (outputs to stderr).
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 3. System Audit & Syslog Integration
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: log_audit
# Purpose:  Emits timestamped operational messages to system journal / syslog.
# Arguments:
#   $1 - Audit message string to log.
#   $2 (Optional) - Syslog identification tag (default: "system-audit").
# Returns:
#   0 (non-blocking; silently ignores failure if logger is missing).
# ------------------------------------------------------------------------------
log_audit() {
    local msg="$1"
    local tag="${2:-system-audit}"
    if command -v logger >/dev/null 2>&1; then
        logger -t "${tag}" "${msg}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 4. SQLite Database Integrity Engine
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: sqlite_integrity_check
# Purpose:  Inspects SQLite databases for internal corruption and WAL state.
# Arguments:
#   $1 - Absolute filesystem path to the SQLite database file.
# Returns:
#   0 - Database exists and PRAGMA integrity_check passed ("ok").
#   1 - Database reported corruption or PRAGMA check failed.
#   2 - The sqlite3 CLI binary is not installed on the host.
# ------------------------------------------------------------------------------
sqlite_integrity_check() {
    local db="$1"
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "[-] Error: 'sqlite3' CLI utility is not installed." >&2
        return 2
    fi
    if [[ ! -f "${db}" ]]; then
        echo "[-] Notice: Database [${db}] does not exist, skipping."
        return 0
    fi

    echo -n "    Checking integrity of [${db}]... "
    local result
    result="$(sqlite3 "${db}" 'PRAGMA integrity_check;' 2>&1 || true)"
    if [[ "${result}" == "ok" ]]; then
        echo "OK"
        if [[ -f "${db}-wal" ]]; then
            local wal_size
            wal_size="$(stat -c %s "${db}-wal" 2>/dev/null || stat -f %z "${db}-wal" 2>/dev/null || echo "unknown")"
            echo "    [i] Active WAL journal detected: [${db}-wal] (${wal_size} bytes)"
        fi
        return 0
    else
        echo "FAILED (${result})"
        return 1
    fi
}
