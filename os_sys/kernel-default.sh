#!/usr/bin/env bash
# ==============================================================================
# Script: /opt/scripts/kernel-default.sh
# Version: 1.3.0  2026/10/02
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky Linux, CentOS)
# Standard: DRY Architecture Framework
# Description: Production-hardened GRUB boot kernel manager and cleanup utility.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Library Initialization
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_COMMON="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "${LIB_COMMON}" ]]; then
  # shellcheck source=/dev/null
  source "${LIB_COMMON}"
fi

# Ensure standard system umask for bootloader operations
umask 022

# Fallback definition if common.sh is missing or does not define require_root
if ! declare -f require_root > /dev/null 2>&1; then
  require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
      echo "[-] Error: This script must be executed as root (or via sudo)." >&2
      exit 1
    fi
  }
fi

# Fallback definition if common.sh is missing or does not define verify_dependencies
if ! declare -f verify_dependencies > /dev/null 2>&1; then
  verify_dependencies() {
    local missing=()
    for bin in "$@"; do
      if ! command -v "${bin}" > /dev/null 2>&1; then
        missing+=("${bin}")
      fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "[-] Error: Missing required CLI dependencies: ${missing[*]}" >&2
      return 1
    fi
    return 0
  }
fi

# Determine primary package manager binary (dnf on EL8/9/10, fallback to yum)
PKG_MGR="$(command -v dnf 2> /dev/null || command -v yum 2> /dev/null || echo "dnf")"

# ------------------------------------------------------------------------------
# 2. CLI Usage & Help
# ------------------------------------------------------------------------------
show_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTION | INDEX]

Options:
  --default       Display currently configured default boot kernel
  --report        List all available kernel entries and indexes
  --cleanup       Safely remove retired kernel packages (preserves running kernel)
  --latest        Assign latest kernel (index 0) as default
  <INDEX>         Non-negative integer index to assign as default (e.g. 0, 1)
  -h, --help      Display this help message and exit

Behavior:
  If no option or index is provided, defaults to index 0 (used by automated update hooks).

Compatibility:
  Enterprise Linux 8, 9, and 10 (UEFI and BIOS boot topologies).
EOF
}

# Allow non-root users to view help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_usage
  exit 0
fi

# Enforce single-argument constraint to prevent syntax ambiguity
if [[ $# -gt 1 ]]; then
  echo "[-] Error: Expected at most 1 argument, but received $# ($*)." >&2
  echo "" >&2
  show_usage >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 3. Privilege & Dependency Guards
# ------------------------------------------------------------------------------
require_root
verify_dependencies "grubby" "${PKG_MGR}" "grep" "uname"

# ------------------------------------------------------------------------------
# 4. Core Functions & Audit Logging
# ------------------------------------------------------------------------------
log_audit() {
  local msg="$1"
  if command -v logger > /dev/null 2>&1; then
    logger -t "kernel-default" "${msg}" 2> /dev/null || true
  fi
}

report_boot_kernel() {
  echo "Current Default Boot Kernel:"
  local title kernel index
  title="$(grubby --default-title 2> /dev/null || true)"
  kernel="$(grubby --default-kernel 2> /dev/null || true)"
  index="$(grubby --default-index 2> /dev/null || true)"

  [[ -n "${title}" ]] && echo "  Title : ${title}"
  [[ -n "${kernel}" ]] && echo "  Kernel: ${kernel}"
  [[ -n "${index}" ]] && echo "  Index : ${index}"
}

report_all_kernel_entries() {
  echo "Available GRUB Kernel Entries:"
  grubby --info=ALL 2> /dev/null | grep -E "^(index|kernel|title)=" || true
}

remove_old_kernels() {
  local current_kernel
  current_kernel="$(uname -r)"

  echo "[*] Inspecting installed kernel packages..."
  # Query installonly packages excluding the highest version across EL8/9/10
  mapfile -t old_pkgs < <("${PKG_MGR}" repoquery --installonly --latest-limit=-1 -q 2> /dev/null || true)

  if [[ ${#old_pkgs[@]} -eq 0 ]]; then
    echo "[+] No retired kernels found to remove."
    return 0
  fi

  # Filter out empty entries and packages matching the currently running kernel
  local safe_pkgs=()
  for pkg in "${old_pkgs[@]}"; do
    [[ -z "${pkg}" ]] && continue
    if [[ "${pkg}" == *"${current_kernel}"* ]]; then
      echo "[!] Skipping active running kernel: ${pkg}"
    else
      safe_pkgs+=("${pkg}")
    fi
  done

  if [[ ${#safe_pkgs[@]} -eq 0 ]]; then
    echo "[+] No eligible retired kernels to remove (active kernel is preserved)."
    return 0
  fi

  echo "[*] Removing retired kernel packages:"
  printf "  - %s\n" "${safe_pkgs[@]}"
  "${PKG_MGR}" remove -y "${safe_pkgs[@]}"
  log_audit "Removed retired kernel packages: ${safe_pkgs[*]}"
  echo "[+] Kernel cleanup completed successfully."
}

# Backward-compatibility aliases
reportBootKernel() { report_boot_kernel "$@"; }
reportAllkernelEntries() { report_all_kernel_entries "$@"; }
removeOldKernels() { remove_old_kernels "$@"; }

# ------------------------------------------------------------------------------
# 5. Argument Processing & Execution
# ------------------------------------------------------------------------------
ACTION="${1:-0}"

case "${ACTION}" in
  --default)
    report_boot_kernel
    exit 0
    ;;
  --report)
    report_all_kernel_entries
    exit 0
    ;;
  --cleanup)
    remove_old_kernels
    exit 0
    ;;
  --latest)
    KERNEL_INDEX=0
    ;;
  *)
    if [[ ! "${ACTION}" =~ ^[0-9]+$ ]]; then
      echo "[-] Error: Invalid argument '${ACTION}'." >&2
      echo "" >&2
      show_usage >&2
      exit 1
    fi
    KERNEL_INDEX="${ACTION}"
    ;;
esac

# Validate that requested index exists in GRUB (dual-checked for EL8/9/10 grubby compatibility)
if ! grubby --info="${KERNEL_INDEX}" > /dev/null 2>&1 && ! grubby --info=ALL 2> /dev/null | grep -q "^index=${KERNEL_INDEX}$"; then
  echo "[-] Error: GRUB index '${KERNEL_INDEX}' does not exist." >&2
  echo "" >&2
  report_all_kernel_entries >&2
  exit 1
fi

echo "[*] Assigning index '${KERNEL_INDEX}' to default kernel..."
report_all_kernel_entries
echo ""

if ! grubby --set-default-index="${KERNEL_INDEX}"; then
  echo "[-] Error: Failed to set default GRUB index (is /boot mounted read-only or full?)." >&2
  exit 1
fi

report_boot_kernel

# Verify post-assignment consistency
active_index="$(grubby --default-index 2> /dev/null || true)"
if [[ -n "${active_index}" && "${active_index}" != "${KERNEL_INDEX}" ]]; then
  echo "[!] Warning: Requested index was '${KERNEL_INDEX}', but GRUB reported default index '${active_index}'." >&2
  echo "[!] Ensure /etc/default/grub or saved_entry is not overriding index selection." >&2
fi

log_audit "Set default boot kernel to index ${KERNEL_INDEX}"
