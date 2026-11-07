#!/usr/bin/env bash
# ==============================================================================
# Library:     /opt/scripts/lib/rhel_sys.sh
# Version:     2.0.0  2026/11/06
# Standard:    DRY Architecture Framework (Enterprise Linux Domain Layer)
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky, CentOS)
# Description: Production-hardened Enterprise Linux domain library building upon
#              lib/system.sh. Supplies native package manager auto-discovery
#              (DNF/YUM), SQLite database integrity checking and WAL vacuuming,
#              and backward-compatible boot capacity helpers.
# ==============================================================================
set -euo pipefail
umask 022

# ------------------------------------------------------------------------------
# 1. Include Guard & System Foundation Assertion
# ------------------------------------------------------------------------------
# Enterprise Linux domain layer must only be loaded via lib/system.sh auto-router
[[ -n "${_RHEL_SYS_LOADED:-}" ]] && return 0
_RHEL_SYS_LOADED=1

if [[ -z "${_SYSTEM_SH_LOADED:-}" ]]; then
    echo "[-] Fatal Error: rhel_sys.sh must not be sourced directly. Source lib/system.sh instead." >&2
    return 1 2>/dev/null || exit 1
fi

# ------------------------------------------------------------------------------
# 2. Operating System Validation
# ------------------------------------------------------------------------------
validate_rhel_os() {
    validate_os "rhel"
}

# ------------------------------------------------------------------------------
# 3. Package Manager Discovery & Metadata
# ------------------------------------------------------------------------------
# Auto-detects native package manager binary across Enterprise Linux families.
# Priority: dnf (EL8/9/10, Fedora) -> yum (EL7/legacy) -> dnf
# shellcheck disable=SC2034 # Exported for sourcing scripts
PKG_MGR="$(command -v dnf 2>/dev/null || command -v yum 2>/dev/null || echo "dnf")"

# ------------------------------------------------------------------------------
# Function: get_pkg_mgr_info
# Purpose:  Discovers the active package manager executable and primary version string.
# Arguments:
#   None.
# Returns:
#   Outputs formatted package manager string (e.g. "dnf (4.14.0)").
# ------------------------------------------------------------------------------
get_pkg_mgr_info() {
    local mgr="${PKG_MGR:-dnf}"
    local ver
    ver="$("${mgr}" --version 2>/dev/null | head -n 1 || echo "Package Manager")"
    echo "${mgr} (${ver})"
}

# ------------------------------------------------------------------------------
# 3. SQLite Database Integrity Engine (RPM & DNF Databases)
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

# ------------------------------------------------------------------------------
# Function: sqlite_vacuum_db
# Purpose:  Checkpoints WAL journal and vacuums the target SQLite database to
#           reclaim disk space and prevent journal bloat.
# Arguments:
#   $1 - Absolute filesystem path to the SQLite database file.
# Returns:
#   0 on success; 1 on failure.
# ------------------------------------------------------------------------------
sqlite_vacuum_db() {
    local db="$1"
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "[-] Error: 'sqlite3' CLI utility is not installed." >&2
        return 2
    fi
    if [[ ! -f "${db}" ]]; then
        echo "[-] Notice: Database [${db}] does not exist, skipping."
        return 0
    fi

    echo -n "    Optimizing / vacuuming [${db}]... "
    local jmode
    jmode="$(sqlite3 "${db}" 'PRAGMA journal_mode;' 2>/dev/null || echo "unknown")"
    if [[ "${jmode}" == "wal" ]]; then
        sqlite3 "${db}" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1 || true
    fi

    local result
    result="$(sqlite3 "${db}" 'PRAGMA vacuum;' 2>&1 || true)"
    if [[ -z "${result}" ]]; then
        echo "OK"
        return 0
    else
        echo "FAILED (${result})"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 4. Backward Compatibility Storage Helper
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Function: check_boot_capacity
# Purpose:  Verifies available storage space on /boot to prevent ENOSPC during
#           kernel installations and dracut initramfs generation.
# Arguments:
#   $1 (Optional) - Minimum threshold in megabytes (default: 100).
# Returns:
#   0 if space >= threshold; 1 if space < threshold.
# ------------------------------------------------------------------------------
check_boot_capacity() {
    local min_free_mb="${1:-100}"
    local boot_path="/boot"
    [[ -d "${boot_path}" ]] || boot_path="/"

    local free_mb
    free_mb="$(get_free_mb "${boot_path}")"

    if [[ "${free_mb}" =~ ^[0-9]+$ ]] && [[ ${free_mb} -lt ${min_free_mb} ]]; then
        echo "[!] WARNING: ${boot_path} filesystem has only ${free_mb} MB free (minimum recommended: ${min_free_mb} MB)!" >&2
        echo "    Low storage on ${boot_path} may cause initramfs generation to fail during kernel transactions." >&2
        return 1
    fi
    return 0
}
