#!/usr/bin/env bash
# ==============================================================================
# Script: /opt/scripts/dnf_check.sh
# Version: 1.4.0  2026/10/26
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky Linux, CentOS)
# Standard: DRY Architecture Framework
# Description: Production-hardened DNF wrapper with cross-version SQLite integrity
#              checks, safe cache clearing, and post-transaction kernel sync.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Library Initialization
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SYSTEM="${SCRIPT_DIR}/lib/system.sh"
if [[ -f "${LIB_SYSTEM}" ]]; then
  # shellcheck source=/dev/null
  source "${LIB_SYSTEM}"
fi

# Ensure standard system umask for package manager execution
umask 022

# Privilege & package manager discovery (inherits from system.sh or defines standalone fallbacks)
declare -f require_root > /dev/null 2>&1 || require_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "[-] Error: Root privileges are required to run dnf." >&2; exit 1; }
}
PKG_MGR="${PKG_MGR:-$(command -v dnf 2> /dev/null || command -v yum 2> /dev/null || echo "dnf")}"

# Common paths and relaxed dependency options
DNF_RELAX_OPTS=(--skip-broken --nobest)
DNF_BASE="/var/lib/dnf"
DNF_CACHE="/var/cache/dnf"

# ------------------------------------------------------------------------------
# 2. CLI Usage & Help
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: show_usage
# Purpose:  Displays command syntax, options, and operational behavior to stdout.
# Arguments:
#   None.
# Returns:
#   Outputs usage documentation.
# ------------------------------------------------------------------------------
show_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTION] | [DNF_COMMAND...]

Options:
  --sqlite-check      Verify SQLite database integrity for DNF caches and history
  --purge-cache       Safely purge DNF package and metadata cache via native clean
  --relax             Permit non-best packages and skip broken dependencies (--skip-broken --nobest)
  --auto-reboot       Automatically reboot the host if a new kernel is installed/upgraded
  -h, --help          Display this help message and exit

DNF Pass-Through:
  Any other arguments are passed directly to '${PKG_MGR}' (e.g. update, install, search).
  On successful mutating transactions (update, install, etc.), the default boot
  kernel is automatically synchronized via kernel-default.sh. If a kernel upgrade
  is detected, a reboot notification is displayed (or auto-reboot is performed if requested).

Compatibility:
  Enterprise Linux 8, 9, and 10 (UEFI and BIOS boot topologies).
EOF
}

# Allow non-root users to view help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  show_usage >&2
  exit 2
fi

# Privilege guard: all functional actions require root / sudo
require_root

# ------------------------------------------------------------------------------
# 3. Core Functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: sqliteWalCheck
# Purpose:  Verifies SQLite database integrity across DNF history and metadata
#           databases, reporting WAL journal presence or corruption.
# Arguments:
#   None.
# Returns:
#   0 if all databases are intact; 1 if any database fails integrity check or sqlite3 is missing.
# ------------------------------------------------------------------------------
sqliteWalCheck() {
  if ! command -v sqlite3 > /dev/null 2>&1; then
    echo "[-] Error: 'sqlite3' CLI utility is not installed." >&2
    return 1
  fi

  local databases=(
    "${DNF_CACHE}/packages.db"
    "${DNF_BASE}/history.sqlite"
  )

  local errors=0
  echo "[*] Checking integrity of DNF SQLite databases..."
  for db in "${databases[@]}"; do
    if declare -f sqlite_integrity_check > /dev/null 2>&1; then
      sqlite_integrity_check "${db}" || errors=$((errors + 1))
    else
      if ! command -v sqlite3 > /dev/null 2>&1; then
        echo "[-] Error: 'sqlite3' CLI utility is not installed." >&2
        return 1
      fi
      if [[ ! -f "${db}" ]]; then
        echo "[-] Notice: Database [${db}] does not exist, skipping."
        continue
      fi

      echo -n "    Checking integrity of [${db}]... "
      local result
      result="$(sqlite3 "${db}" 'PRAGMA integrity_check;' 2>&1 || true)"
      if [[ "${result}" == "ok" ]]; then
        echo "OK"
        if [[ -f "${db}-wal" ]]; then
          local wal_size
          wal_size="$(stat -c %s "${db}-wal" 2> /dev/null || stat -f %z "${db}-wal" 2> /dev/null || echo "unknown")"
          echo "    [i] Active WAL journal detected: [${db}-wal] (${wal_size} bytes)"
        fi
      else
        echo "FAILED (${result})"
        errors=$((errors + 1))
      fi
    fi
  done

  if [[ ${errors} -eq 0 ]]; then
    echo "[+] All DNF SQLite database integrity checks passed."
    return 0
  else
    echo "[-] Errors detected in ${errors} database(s)." >&2
    return 1
  fi
}

# Backward-compatibility aliases
# shellcheck disable=SC2329
sqlite_wal_check() { sqliteWalCheck "$@"; }
# shellcheck disable=SC2329
sqliteWalClean() { sqliteWalCheck "$@"; }

# ------------------------------------------------------------------------------
# Function: is_wsl
# Purpose:  Detects whether execution is occurring within Windows Subsystem for Linux.
# Arguments:
#   None.
# Returns:
#   0 if WSL; 1 otherwise.
# ------------------------------------------------------------------------------
is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || \
  [[ -n "${WSL_INTEROP:-}" ]] || \
  [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] || \
  [[ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]] || \
  grep -qi microsoft /proc/version 2>/dev/null
}

# ------------------------------------------------------------------------------
# Function: verify_kernel_upgrade
# Purpose:  Audits the installed default boot kernel against the currently active
#           running kernel. Emits warning to reboot and run kernel-default.sh --cleanup,
#           or triggers automated reboot if --auto-reboot was supplied.
# Arguments:
#   None.
# Returns:
#   0.
# ------------------------------------------------------------------------------
verify_kernel_upgrade() {
  if is_wsl; then
    echo "[i] WSL environment detected (kernel is managed by Windows host)."
    return 0
  fi

  local running_kernel
  running_kernel="$(uname -r)"

  local default_kernel=""
  local default_kernel_path=""

  if command -v grubby > /dev/null 2>&1; then
    default_kernel_path="$(grubby --default-kernel 2> /dev/null || true)"
    default_kernel="${default_kernel_path#/boot/vmlinuz-}"
  fi

  if [[ -z "${default_kernel}" ]]; then
    default_kernel="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2> /dev/null | sort -V | tail -n 1 || true)"
    if [[ -z "${default_kernel}" ]]; then
      default_kernel="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel 2> /dev/null | sort -V | tail -n 1 || true)"
    fi
  fi

  if [[ -n "${default_kernel}" && "${default_kernel}" != "${running_kernel}" ]]; then
    echo ""
    echo "=============================================================================="
    echo "[!] WARNING: System Kernel Upgrade Detected!"
    echo "------------------------------------------------------------------------------"
    echo "  Currently Running Kernel: ${running_kernel}"
    echo "  New Default Boot Kernel : ${default_kernel}"
    echo ""
    echo "  A system reboot is required to activate the newly deployed kernel."
    echo "  After rebooting, you may safely purge obsolete kernel packages by running:"
    echo "    sudo /opt/scripts/kernel-default.sh --cleanup"
    echo "=============================================================================="
    echo ""

    if declare -f log_audit > /dev/null 2>&1; then
      log_audit "Kernel upgrade detected: running ${running_kernel}, default ${default_kernel}" "dnf_check"
    fi

    if [[ ${auto_reboot} -eq 1 ]]; then
      echo "[*] Option --auto-reboot specified: Initiating automated system reboot in 5 seconds..."
      if declare -f log_audit > /dev/null 2>&1; then
        log_audit "Triggering automated reboot post-kernel upgrade via --auto-reboot" "dnf_check"
      fi
      sleep 5
      systemctl reboot 2> /dev/null || shutdown -r now 2> /dev/null || reboot
    fi
  fi
}

# ------------------------------------------------------------------------------
# 4. Command Dispatch
# ------------------------------------------------------------------------------
case "$1" in
  --sqlite-check | --sqlite-close)
    sqliteWalCheck
    exit $?
    ;;
  --purge-cache)
    echo "[*] Purging DNF cache via native package manager (${PKG_MGR})..."
    "${PKG_MGR}" clean all
    exit $?
    ;;
esac

# ------------------------------------------------------------------------------
# 5. DNF Execution & Post-Transaction Synchronization
# ------------------------------------------------------------------------------
# Parse arguments: extract wrapper-specific flags (--relax) and detect mutating commands
is_mutating=0
relax_deps=0
auto_reboot=0
dnf_args=()

for arg in "$@"; do
  case "${arg}" in
    --relax)
      relax_deps=1
      ;;
    --auto-reboot)
      auto_reboot=1
      ;;
    *)
      dnf_args+=("${arg}")
      case "${arg}" in
        update | upgrade | distro-sync | install | reinstall | remove | erase | upgrade-minimal)
          is_mutating=1
          ;;
      esac
      ;;
  esac
done

if [[ ${#dnf_args[@]} -eq 0 ]]; then
  show_usage >&2
  exit 2
fi

# Append relaxed dependency options if requested
if [[ ${relax_deps} -eq 1 ]]; then
  dnf_args+=("${DNF_RELAX_OPTS[@]}")
fi

# Execute package manager with exact arguments preserved
"${PKG_MGR}" "${dnf_args[@]}"
DNF_STATUS=$?

# If command failed, abort immediately and preserve its exit code
if [[ ${DNF_STATUS} -ne 0 ]]; then
  exit ${DNF_STATUS}
fi

# Conditionally synchronize boot kernel only on mutating transactions
if [[ ${is_mutating} -eq 1 ]]; then
  kernel_script="${SCRIPT_DIR}/kernel-default.sh"
  [[ ! -x "${kernel_script}" ]] && kernel_script="/opt/scripts/kernel-default.sh"
  if [[ -x "${kernel_script}" ]]; then
    echo "[*] Synchronizing default boot kernel post-transaction..."
    "${kernel_script}"
  fi

  # Audit if installed kernel differs from running kernel
  verify_kernel_upgrade
fi

exit ${DNF_STATUS}
