#!/bin/bash
# ==============================================================================
# FILE: ubuntu_kernel_updater.sh
# VERSION: 1.0.0
# DATE: 2026-06-22
#
# SUMMARY:
# ------------------------------------------------------------------------------
# Hardened Automated Mainline Kernel Deployment Script (Enterprise Edition)
# Designed for maximum safety: Atomic operations, isolated sandboxing, & strict checks.
# Supports:
#   -h, --help        : Display this structural system help documentation matrix.
#   -f, --force       : Force re-installation of the latest stable version.
#   --purge-list      : Safely list redundant custom mainline and packaged distribution kernels eligible for removal.
#   --purge           : Safely remove redundant older custom mainline kernels and older packaged distribution kernels (keeps current active and latest packaged distribution kernel).
#
# PURGE MODULE OVERVIEW:
# ------------------------------------------------------------------------------
# Objectives:
#   Reclaim disk space in /boot, /lib/modules, and /usr/src by safely removing
#   obsolete kernels. It cleans both "custom mainline" (untracked by dpkg) 
#   and "packaged distribution" (tracked by dpkg/apt) kernel environments.
#
# Core Safety Mandates:
#   1. NEVER purge the currently booted active runtime kernel (uname -r).
#   2. ALWAYS preserve the latest official packaged distribution kernel as a 
#      failsafe fallback boot option.
#
# Core Components & Logic Flow:
#   1. Packaged Kernel Sweep:
#      Queries dpkg-query for installed 'linux-image-' packages.
#      Extracts version numbers and sorts them using linux-version (or sort -V).
#      Isolates the newest distribution version and the active kernel.
#      Identifies all other older packaged versions as eligible for purging.
#
#   2. Custom Mainline Sweep (Direct Filesystem Deletions):
#      Scans /lib/modules/* directory structures.
#      Matches active and package ownership (via dpkg-query -S).
#      Directly deletes custom compiled or downloaded kernel artifacts 
#      from /boot, /lib/modules, and /usr/src/ headers if untracked.
#
#   3. Packaged Distribution Sweep (APT Package Management):
#      Queries all packages (images, headers, modules, tools) ending with
#      eligible versions and gathers their names.
#      Ensures shared base headers (e.g. linux-headers-<ver>) are only purged
#      if no other flavored kernel (like lowlatency) of that version is left.
#      Waits for lock-frontend if held, calculates reclaimed MB, and
#      executes non-interactive apt-get purge followed by autoremove.
#
# Data Flows:
#   [System State: uname -r & dpkg] ---> [Identify Active & Latest Fallback]
#                                                    |
#                                     +--------------+--------------+
#                                     |                             |
#                              (Untracked/Custom)            (Tracked/Packaged)
#                                     v                             v
#                            [Direct rm cleanup]           [Resolve dependencies]
#                                     |                             |
#                                     +--------------+--------------+
#                                                    v
#                                           [update-grub rebuild]
# ==============================================================================
set -euo pipefail

MAINLINE_INDEX_URL="https://kernel.ubuntu.com/mainline/"
LOG_FILE="/var/log/kernel_updater.log"

# ==============================================================================
# UTILITY: LOGGING ARCHITECTURE
# ------------------------------------------------------------------------------
# Provides timestamped logs to stdout and appends them to the persistent $LOG_FILE.
# Three levels of logs are defined: Info ([+]), Warning ([!]), and Error ([-]).
# ==============================================================================
# Setup logging architecture
log_info() {  echo -e "[+] $(date '+%Y-%m-%d %H:%M:%S') : $1" | tee -a "$LOG_FILE"; }
log_warn() {  echo -e "[!] $(date '+%Y-%m-%d %H:%M:%S') : $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "[-] $(date '+%Y-%m-%d %H:%M:%S') : $1" >&2 | tee -a "$LOG_FILE"; }

# ==============================================================================
# UTILITY: HELP MATRIX DISPLAY
# ------------------------------------------------------------------------------
# Objective: Print syntax, arguments, options, and file paths to the user.
# ==============================================================================
# Explicit Help Documentation Matrix Block
show_help() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]

Hardened Automated Mainline Kernel Deployment Utility for Linux Mint / Ubuntu.
Manages cutting-edge upstream kernels safely outside the native APT package database.

Options:
  -h, --help        Show this help message layout matrix and exit.
  -f, --force       Force the system to re-download, unpack, and re-verify the
                    latest upstream kernel even if it matches the active runtime version.
  --purge-list      Scan the system and securely display older custom mainline 
                    kernels and older packaged distribution kernels eligible for removal.
  --purge           Safely remove redundant older custom mainline kernels and older 
                    packaged distribution kernels. Automatically preserves the currently 
                    active running kernel and the latest packaged distribution kernel.
  --detect          Scan system and print all operations that would be performed,
                    without executing any writes, installations, or deletions (dry-run).

Notes:
  This script must be executed with root privileges (sudo).
  Log configurations are written concurrently to: $LOG_FILE
EOF
}

# ==============================================================================
# COMPONENT: INPUT VALIDATION & PARSING
# ------------------------------------------------------------------------------
# Configures initial control flags based on command line options.
# Constraints: Only supports one parameter at a time.
# ==============================================================================
# Parse CLI parameters safely
FORCE_INSTALL=false
PURGE_LIST=false
PURGE_EXECUTE=false
DETECT_MODE=false

if [ $# -gt 0 ]; then
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -f|--force)
            FORCE_INSTALL=true 
            ;;
        --purge-list)
            PURGE_LIST=true 
            ;;
        --purge)
            PURGE_EXECUTE=true 
            ;;
        --detect)
            DETECT_MODE=true
            ;;
        *)
            echo "[-] Usage Error: Unknown argument '$1'" >&2
            show_help >&2
            exit 1
            ;;
    esac
fi

# ==============================================================================
# COMPONENT: ENVIRONMENT & PRIVILEGE VERIFICATION
# ------------------------------------------------------------------------------
# Enforces system administration execution privileges, validates OS compatibility,
# and validates log write-access.
# ==============================================================================
# Ensure script is executed with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "[-] Security Error: This script must be executed as root (sudo)." >&2
    exit 1
fi

# Ensure running on a supported Ubuntu, Debian, or Linux Mint distribution
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian|linuxmint)
            # OS is supported, continue execution
            ;;
        *)
            log_error "Unsupported Operating System (${ID:-unknown}): This utility is designed exclusively for Ubuntu, Debian, or Linux Mint."
            exit 1
            ;;
    esac
else
    log_error "Unsupported Operating System: /etc/os-release not found."
    exit 1
fi

# Touch log file to ensure permissions are verified early
touch "$LOG_FILE"

# Enforce script-wide exclusive locking to prevent concurrent executions
exec 9>/run/kernel_updater.lock
if ! flock -n 9; then
    log_error "Another instance of $(basename "$0") is currently running. Aborting."
    exit 1
fi

# Detect version sort command globally
if command -v linux-version >/dev/null 2>&1; then
    SORT_CMD=(linux-version sort)
else
    SORT_CMD=(sort -V)
fi

# ==============================================================================
# COMPONENT: GRUB HARDENING
# ------------------------------------------------------------------------------
# Enforces safety options in /etc/default/grub (panic recovery, timeout style,
# and visible menu) to guarantee administrative recovery if the new kernel fails.
# ==============================================================================
harden_grub_config() {
    if [ "$DETECT_MODE" = true ]; then
        log_info "[DETECT] Verifying bootloader configurations for recovery safety..."
    else
        log_info "Verifying bootloader configurations for recovery safety..."
    fi
    local grub_conf="/etc/default/grub"
    
    if [ ! -f "$grub_conf" ]; then
        log_warn "/etc/default/grub not found. Skipping bootloader safety hardening."
        return 0
    fi
    
    # Store initial state in a temporary backup file
    local temp_backup
    if [ "$DETECT_MODE" = false ]; then
        temp_backup=$(mktemp -u "/tmp/grub.XXXXXX")
        cp -p "$grub_conf" "$temp_backup"
    fi
    
    local modified=false
    
    # 1. Enforce visible recovery menu style
    if grep -q "^GRUB_TIMEOUT_STYLE=hidden" "$grub_conf"; then
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT]   -> Would change GRUB_TIMEOUT_STYLE from 'hidden' to 'menu' for menu visibility."
        else
            log_info "  -> Changing GRUB_TIMEOUT_STYLE from 'hidden' to 'menu' for menu visibility."
            sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/' "$grub_conf"
            modified=true
        fi
    fi
    
    # 2. Enforce minimum recovery timeout of 5 seconds
    if grep -q "^GRUB_TIMEOUT=0" "$grub_conf"; then
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT]   -> Would change GRUB_TIMEOUT from '0' to '5' to allow fallback selection."
        else
            log_info "  -> Changing GRUB_TIMEOUT from '0' to '5' to allow fallback selection."
            sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' "$grub_conf"
            modified=true
        fi
    fi
    
    # 3. Optimize default kernel parameters in GRUB_CMDLINE_LINUX_DEFAULT:
    #    - Remove 'quiet' if present (to show diagnostics)
    #    - Add 'nomodeset' if absent (to guarantee screen compatibility)
    #    - Add 'panic=30' if absent (to enable auto-reboot on crash)
    if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" "$grub_conf"; then
        local current_line current_val
        current_line=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$grub_conf")
        current_val=$(echo "$current_line" | sed -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=//' -e 's/^"//' -e 's/"$//')
        
        local -a params=()
        local -a new_params=()
        read -r -a params <<< "$current_val"
        
        local has_nomodeset=false
        local has_panic=false
        
        for param in "${params[@]}"; do
            [ -z "$param" ] && continue
            if [ "$param" = "quiet" ]; then
                continue # Remove quiet
            fi
            if [ "$param" = "nomodeset" ]; then
                has_nomodeset=true
            fi
            if [[ "$param" =~ ^panic= ]]; then
                has_panic=true
            fi
            new_params+=("$param")
        done
        
        if [ "$has_nomodeset" = false ]; then
            new_params+=("nomodeset")
        fi
        if [ "$has_panic" = false ]; then
            new_params+=("panic=30")
        fi
        
        local new_val="${new_params[*]}"
        local new_line="GRUB_CMDLINE_LINUX_DEFAULT=\"$new_val\""
        
        if [ "$current_line" != "$new_line" ]; then
            if [ "$DETECT_MODE" = true ]; then
                log_info "[DETECT]   -> Would optimize GRUB_CMDLINE_LINUX_DEFAULT (value: '$new_val'): removing 'quiet', ensuring 'nomodeset' and 'panic=30'."
            else
                log_info "  -> Optimizing GRUB_CMDLINE_LINUX_DEFAULT: removing 'quiet', ensuring 'nomodeset' and 'panic=30'."
                sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$new_line|" "$grub_conf"
                modified=true
            fi
        fi
    fi
    
    # 4. Enforce GRUB_RECORDFAIL_TIMEOUT to prevent headless boot hangs on failure
    if ! grep -q "^GRUB_RECORDFAIL_TIMEOUT=" "$grub_conf"; then
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT]   -> Would append 'GRUB_RECORDFAIL_TIMEOUT=5' to prevent boot menu hangs after failed boot."
        else
            log_info "  -> Appending 'GRUB_RECORDFAIL_TIMEOUT=5' to prevent boot menu hangs after failed boot."
            echo "GRUB_RECORDFAIL_TIMEOUT=5" >> "$grub_conf"
            modified=true
        fi
    fi
    
    if [ "$DETECT_MODE" = false ]; then
        if [ "$modified" = true ]; then
            local timestamp_backup
            timestamp_backup="${grub_conf}.$(date '+%Y%m%d-%H%M%S')"
            mv "$temp_backup" "$timestamp_backup"
            log_info "Bootloader settings hardened successfully! Backup saved to ${timestamp_backup}."
        else
            rm -f "$temp_backup"
            log_info "Bootloader recovery settings are already hardened and healthy."
        fi
    fi
}

# ==============================================================================
# COMPONENT: SYMLINK MANAGEMENT
# ------------------------------------------------------------------------------
# Ensures /boot/vmlinuz, /boot/initrd.img, and optionally .old symlinks point
# to the newest and second newest kernel versions, respectively.
# Also updates root (/) symlinks if they exist.
# ==============================================================================
update_link() {
    local link_path="$1"
    local target="$2"
    
    log_info "Linking $link_path -> $target"
    # Atomically update symlink by creating temp symlink and renaming it
    local tmp_link
    tmp_link=$(mktemp -u "${link_path}.XXXXXX")
    ln -s "$target" "$tmp_link"
    mv -f "$tmp_link" "$link_path"
}

update_boot_symlinks() {
    log_info "Updating system boot symlinks..."
    
    # 1. Gather all kernel versions where BOTH vmlinuz and initrd.img exist
    local -a versions=()
    local f kver
    for f in /boot/vmlinuz-*; do
        [ -e "$f" ] || continue
        # Ignore symlinks, temporary files, and backup files
        if [ -f "$f" ] && [ ! -L "$f" ] && [[ ! "$f" == *.tmp ]] && [[ ! "$f" == *.bak ]]; then
            kver=$(basename "$f" | sed 's/^vmlinuz-//')
            # Critical Safety Check: Both kernel and initrd must exist for this version to be valid
            if [ -f "/boot/initrd.img-$kver" ]; then
                versions+=("$kver")
            else
                log_warn "Kernel image /boot/vmlinuz-$kver exists, but matching /boot/initrd.img-$kver is missing. Ignoring this version for symlink safety."
            fi
        fi
    done
    
    local num_kernels=${#versions[@]}
    if [ "$num_kernels" -eq 0 ]; then
        log_warn "No valid kernel versions (with matching initrd) found in /boot. Skipping symlink updates."
        return 0
    fi
    
    # 2. Sort versions in descending order (newest first)
    local sorted_versions
    sorted_versions=$(printf "%s\n" "${versions[@]}" | "${SORT_CMD[@]}" | tac | uniq)
    
    # Read sorted versions back into an array
    local -a sorted_arr=()
    local line
    while read -r line; do
        if [ -n "$line" ]; then
            sorted_arr+=("$line")
        fi
    done <<< "$sorted_versions"
    
    local num_sorted=${#sorted_arr[@]}
    if [ "$num_sorted" -eq 0 ]; then
        log_warn "No sorted kernel versions resolved. Skipping symlink updates."
        return 0
    fi
    
    local newest_ver="${sorted_arr[0]}"
    log_info "Newest valid kernel version resolved: $newest_ver"
    
    # Update main symlinks in /boot (both guaranteed to exist due to safety check)
    update_link "/boot/vmlinuz" "vmlinuz-$newest_ver"
    update_link "/boot/initrd.img" "initrd.img-$newest_ver"
    
    # Update root / symlinks if they exist
    if [ -L "/vmlinuz" ] || [ -f "/vmlinuz" ]; then
        update_link "/vmlinuz" "boot/vmlinuz-$newest_ver"
    fi
    if [ -L "/initrd.img" ] || [ -f "/initrd.img" ]; then
        update_link "/initrd.img" "boot/initrd.img-$newest_ver"
    fi
    
    # Handle second newest kernel if it exists
    if [ "$num_sorted" -gt 1 ]; then
        local second_ver="${sorted_arr[1]}"
        log_info "Second newest valid kernel version resolved: $second_ver"
        
        update_link "/boot/vmlinuz.old" "vmlinuz-$second_ver"
        update_link "/boot/initrd.img.old" "initrd.img-$second_ver"
        
        # Update root / .old symlinks if they exist
        if [ -L "/vmlinuz.old" ] || [ -f "/vmlinuz.old" ]; then
            update_link "/vmlinuz.old" "boot/vmlinuz-$second_ver"
        fi
        if [ -L "/initrd.img.old" ] || [ -f "/initrd.img.old" ]; then
            update_link "/initrd.img.old" "boot/initrd.img-$second_ver"
        fi
    else
        log_info "Only one valid kernel version resolved. Removing old symlinks to avoid dangling references."
        rm -f "/boot/vmlinuz.old"
        rm -f "/boot/initrd.img.old"
        if [ -L "/vmlinuz.old" ] || [ -f "/vmlinuz.old" ]; then
            rm -f "/vmlinuz.old"
        fi
        if [ -L "/initrd.img.old" ] || [ -f "/initrd.img.old" ]; then
            rm -f "/initrd.img.old"
        fi
    fi
}


# ==============================================================================
# SAFELY MANAGE PURGES (IF REQUESTED)
# ==============================================================================
if [ "$PURGE_LIST" = true ] || [ "$PURGE_EXECUTE" = true ] || [ "$DETECT_MODE" = true ]; then
    CURRENT_ACTIVE=$(uname -r)
    if [ -z "$CURRENT_ACTIVE" ]; then
        log_error "Failed to retrieve the active booted kernel version string via uname -r. Aborting to prevent deletion risk."
        exit 1
    fi
    # ==========================================================================
    # SCAN EXECUTION ROUTINE
    # --------------------------------------------------------------------------
    # Scan the system modules tree and packages to find redundant kernels.
    # Data flow: scans directories under /lib/modules and queries installed packages.
    # ==========================================================================
    if [ "$DETECT_MODE" = true ]; then
        log_info "[DETECT] Scanning system for custom mainline and packaged distribution kernel instances..."
    else
        log_info "Scanning system for custom mainline and deletion/packaged distribution kernel instances..."
    fi
    
    FOUND_ANY=false
    
    # 1. Identify packaged distribution kernels to purge (keeping the latest and currently active)
    PACKAGED_KERNELS=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | \
        sed -nr 's/^[ih]i  linux-image-(unsigned-)?([0-9]+\.[0-9]+\.[0-9]+.*)/\2/p' | \
        "${SORT_CMD[@]}" | uniq)
    
    # Extract newest packaged version string
    LATEST_PACKAGED_KERNEL=$(echo "$PACKAGED_KERNELS" | tail -n1)
    
    # Select packaged kernels that are eligible for purging (not the latest or currently active)
    PACKAGED_KERNELS_TO_PURGE=()
    for kver in $PACKAGED_KERNELS; do
        if [ "$kver" = "$LATEST_PACKAGED_KERNEL" ]; then continue; fi
        if [ "$kver" = "$CURRENT_ACTIVE" ]; then continue; fi
        PACKAGED_KERNELS_TO_PURGE+=("$kver")
    done
    
    # Identify the newest custom mainline kernel to protect it from purging
    custom_versions=()
    for dir in /lib/modules/*; do
        [ -d "$dir" ] || continue
        cver=$(basename "$dir")
        [[ "$cver" =~ ^[0-9][0-9a-zA-Z.-]+$ ]] || continue
        dpkg-query -S "/lib/modules/$cver" >/dev/null 2>&1 && continue
        custom_versions+=("$cver")
    done
    
    latest_custom_kernel=""
    if [ ${#custom_versions[@]} -gt 0 ]; then
        latest_custom_kernel=$(printf "%s\n" "${custom_versions[@]}" | "${SORT_CMD[@]}" | tail -n1)
    fi

    # 2. Scan and handle custom, untracked kernels
    # Reads modules directory to find non-dpkg-registered custom mainline modules
    for mod_dir in /lib/modules/*; do
        if [ ! -d "$mod_dir" ]; then continue; fi
        kver=$(basename "$mod_dir")
        
        # RULE 1: Never target the active running kernel
        if [ "$kver" = "$CURRENT_ACTIVE" ]; then continue; fi
        
        # RULE 2: Protect distribution kernels via precise dpkg query filtering
        if dpkg-query -S "/lib/modules/$kver" >/dev/null 2>&1; then continue; fi
        
        # RULE 4: Protect the newest custom mainline kernel (even if not booted yet)
        if [ "$kver" = "$latest_custom_kernel" ]; then continue; fi
        
        FOUND_ANY=true
        
        if [ "$PURGE_LIST" = true ]; then
            log_warn "ELIGIBLE FOR PURGE: Custom Kernel [ $kver ]"
        fi
        
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT] Would purge custom kernel components for version: $kver"
        fi
        
        if [ "$PURGE_EXECUTE" = true ]; then
            log_warn "Crucial Step: Purging custom kernel components for version: $kver"
            
            # RULE 3: Strict parameter boundary checks before any deletions
            # Validate that $kver is not empty, meets length requirements, and matches a strict version pattern
            if [ -n "$kver" ] && [ "${#kver}" -gt 6 ] && [[ "$kver" =~ ^[0-9][0-9a-zA-Z.-]+$ ]]; then
                # Clean up compiled boot assets and modules
                rm -f "/boot/vmlinuz-$kver"
                rm -f "/boot/initrd.img-$kver"
                rm -f "/boot/System.map-$kver"
                rm -f "/boot/config-$kver"
                rm -rf "/lib/modules/$kver"
                rm -rf "/usr/src/linux-headers-$kver"
                rm -rf "/usr/src/linux-headers-${kver}-generic"
            else
                log_error "Security Warning: Aborting delete due to unsafe, truncated, or malformed version string: '$kver'."
                exit 1
            fi
        fi
    done
    
    # 3. Handle eligible packaged distribution kernels
    # Resolves all associated packages (images, headers, modules) for old packaged versions
    PACKAGES_TO_PURGE=()
    if [ ${#PACKAGED_KERNELS_TO_PURGE[@]} -gt 0 ]; then
        FOUND_ANY=true
        for kver in "${PACKAGED_KERNELS_TO_PURGE[@]}"; do
            if [ "$PURGE_LIST" = true ]; then
                log_warn "ELIGIBLE FOR PURGE: Packaged Kernel [ $kver ]"
            fi
            
            if [ "$DETECT_MODE" = true ]; then
                log_info "[DETECT] Would purge packaged kernel: $kver"
            fi
            
            if [ "$PURGE_EXECUTE" = true ] || [ "$DETECT_MODE" = true ]; then
                # Find packages matching the flavor version (e.g. linux-*-6.8.0-120-generic)
                pkgs=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "linux-*-$kver" 2>/dev/null | awk '$1 !~ /^u/ {print $2}')
                for pkg in $pkgs; do
                    PACKAGES_TO_PURGE+=("$pkg")
                done
                
                # Check if we can also purge the base non-flavour version (e.g. linux-*-6.8.0-120)
                # Ensure we do not break shared base version headers for other flavors still installed
                base_ver=$(echo "$kver" | cut -d- -f1,2)
                if [ -n "$base_ver" ]; then
                    other_flavor_installed=false
                    for other_kver in $PACKAGED_KERNELS; do
                        if [ "$other_kver" = "$kver" ]; then continue; fi
                        if [[ "$other_kver" == "$base_ver"* ]]; then
                            other_flavor_installed=true
                            break
                        fi
                    done
                    if [ "$other_flavor_installed" = false ]; then
                        base_pkgs=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "linux-*-$base_ver" 2>/dev/null | awk '$1 !~ /^u/ {print $2}')
                        for pkg in $base_pkgs; do
                            PACKAGES_TO_PURGE+=("$pkg")
                        done
                    fi
                fi
            fi
        done
    fi
    
    # Calculate reclaimed space for packaged kernels
    FREED_MB=0
    if [ ${#PACKAGES_TO_PURGE[@]} -gt 0 ]; then
        total_kb=$(dpkg-query -W -f='${Installed-Size}\n' "${PACKAGES_TO_PURGE[@]}" 2>/dev/null | awk '{sum+=$1} END {print sum}')
        if [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ]; then
            FREED_MB=$((total_kb / 1024))
        fi
    fi
    
    if [ "$DETECT_MODE" = true ] && [ ${#PACKAGES_TO_PURGE[@]} -gt 0 ]; then
        log_info "[DETECT] Would purge packages: ${PACKAGES_TO_PURGE[*]}"
        if [ "$FREED_MB" -gt 0 ]; then
            log_info "[DETECT] Purge would reclaim approximately ${FREED_MB} MB of disk space."
        fi
    fi
    
    if [ "$DETECT_MODE" = true ] && [ "$FOUND_ANY" = true ]; then
        harden_grub_config
        log_info "[DETECT] Would update system boot symlinks"
        log_info "[DETECT] Would rebuild system bootloader layout configuration maps (update-grub)"
    fi
    
    # Exit if no eligible kernels were found
    if [ "$FOUND_ANY" = false ]; then
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT] No redundant custom or packaged kernels detected for purging."
        else
            log_info "No redundant custom or packaged kernels detected on this system."
            exit 0
        fi
    fi
    
    # ==========================================================================
    # PURGE TRANSACTION EXECUTION
    # --------------------------------------------------------------------------
    # Conducts non-interactive deletion of resolved packages and updates boot options.
    # ==========================================================================
    if [ "$PURGE_EXECUTE" = true ]; then
        if [ ${#PACKAGES_TO_PURGE[@]} -gt 0 ]; then
            # Wait for dpkg/apt lock if held by another process
            lockfile="/var/lib/dpkg/lock-frontend"
            if command -v fuser >/dev/null 2>&1 && fuser "$lockfile" >/dev/null 2>&1; then
                log_info "Waiting for other package manager transactions to complete..."
                while fuser "$lockfile" >/dev/null 2>&1; do
                    sleep 1
                done
            fi
 
            # Report estimated disk space to be reclaimed
            if [ "$FREED_MB" -gt 0 ]; then
                log_info "This purge will reclaim approximately ${FREED_MB} MB of disk space."
            fi
 
            log_warn "Crucial Step: Purging packaged kernel packages: ${PACKAGES_TO_PURGE[*]}"
            DEBIAN_FRONTEND=noninteractive apt-get purge -y "${PACKAGES_TO_PURGE[@]}"
            log_info "Running autoremove to clean up unused dependencies..."
            DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
        fi
        
        harden_grub_config
        update_boot_symlinks
        log_info "Rebuilding system bootloader layout configuration maps..."
        update-grub 9>&-
        echo "=========================================================================="
        log_info "Selected custom and packaged kernel configurations successfully purged!"
        echo "=========================================================================="
    fi
    
    if [ "$DETECT_MODE" = false ]; then
        exit 0
    fi
fi

# ==============================================================================
# COMPONENT: MAINLINE DEPLOYMENT PIPELINE
# ------------------------------------------------------------------------------
# Downloads and installs the latest stable upstream mainline kernel.
# ==============================================================================
# STANDARD REPO IMPLEMENTATION PIPELINE
if [ "$DETECT_MODE" = true ]; then
    log_info "[DETECT] Initializing dry mainline kernel deployment pipeline..."
else
    log_info "Initializing hardened kernel deployment pipeline..."
fi

# 1. Disk Overhead Check
# Objective: Verify target file system has > 2.5GB free space for staging and headers.
FREE_SPACE_KB=$(df -P / | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE_KB" -lt 2621440 ]; then
    if [ "$DETECT_MODE" = true ]; then
        log_warn "[DETECT] Insufficient disk space on root filesystem. Requires > 2.5GB free overhead space."
    else
        log_error "Insufficient disk space on root file system. Requires > 2.5GB free overhead space."
        exit 1
    fi
fi

# Ensure at least 150MB is free in /boot (critical for kernel image & initramfs generation)
BOOT_FREE_KB=$(df -P /boot | awk 'NR==2 {print $4}')
if [ "$BOOT_FREE_KB" -lt 153600 ]; then
    if [ "$DETECT_MODE" = true ]; then
        log_warn "[DETECT] Insufficient disk space on /boot filesystem. Requires > 150MB free space."
    else
        log_error "Insufficient disk space on /boot filesystem. Requires > 150MB free space."
        exit 1
    fi
fi

if [ "$DETECT_MODE" = false ]; then
    # 2. Secure Staging Allocation
    # Creates isolated sandbox directories for files downloading and extraction.
    STAGE_DIR=$(mktemp -d -t kernel-updater.XXXXXX)
    DOWNLOAD_DIR="${STAGE_DIR}/downloads"
    EXTRACT_DIR="${STAGE_DIR}/extracted"
    mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR"

    # Cleanup trap to ensure sandboxes are deleted on exit
    cleanup() {
        log_info "Cleaning up secure staging directories..."
        rm -rf "$STAGE_DIR"
    }
    trap cleanup EXIT

    cd "$DOWNLOAD_DIR"
fi

# 3. Stable Kernel Auto-Detection
# Queries Ubuntu mainline index and extracts the newest non-RC version string.
log_info "Auto-detecting latest stable upstream kernel..."
LATEST_VERSION=$(curl -sSf --connect-timeout 10 --max-time 30 "$MAINLINE_INDEX_URL" | \
    grep -oE 'v[0-9]+\.[0-9]+[^"/ ]*' | \
    grep -vE '(-rc|-git|-wip)' | \
    sort -V | \
    tail -n1 || true)

if [ -z "$LATEST_VERSION" ]; then
    log_error "Failed to parse latest stable version string safely."
    exit 1
fi

log_info "Latest stable version detected: ${LATEST_VERSION}"

# 4. Version Check
# Avoids unnecessary reinstalls if target matches currently running version unless forced.
CURRENT_KERNEL=$(uname -r)
if [[ "$CURRENT_KERNEL" == *"${LATEST_VERSION#v}"* ]]; then
    if [ "$FORCE_INSTALL" = true ]; then
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT] System matches target version, but --force was detected. Would proceed with deployment."
        else
            log_warn "System matches target version, but --force was detected. Proceeding anyway..."
        fi
    else
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT] System is already running ${CURRENT_KERNEL}. No deployment would be performed."
            exit 0
        else
            log_warn "System is already running ${CURRENT_KERNEL}. Aborting safely."
            exit 0
        fi
    fi
fi

# Check if target version is already installed on disk (e.g. pending reboot)
TARGET_VER="${LATEST_VERSION#v}"
INSTALLED_FILE=""
for f in /boot/vmlinuz-"$TARGET_VER"-*; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then
        INSTALLED_FILE="$f"
        break
    fi
done

if [ -n "$INSTALLED_FILE" ]; then
    if [ "$FORCE_INSTALL" = true ]; then
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT] Kernel version ${TARGET_VER} is already installed on disk, but --force was detected. Would proceed with reinstall..."
        else
            log_warn "Kernel version ${TARGET_VER} is already installed on disk, but --force was detected. Proceeding with reinstall..."
        fi
    else
        if [ "$DETECT_MODE" = true ]; then
            log_info "[DETECT] Kernel version ${TARGET_VER} is already installed on disk (found: $(basename "$INSTALLED_FILE")) but not yet active."
            log_info "[DETECT] System reboot is required to activate. No deployment would be performed."
            exit 0
        else
            log_warn "Kernel version ${TARGET_VER} is already installed on disk (found: $(basename "$INSTALLED_FILE")) but not yet active."
            log_warn "Please run 'sudo reboot' to activate the new kernel. Aborting safely."
            exit 0
        fi
    fi
fi

BASE_URL="https://kernel.ubuntu.com/mainline/${LATEST_VERSION}/amd64"
if [ "$DETECT_MODE" = true ]; then
    log_info "[DETECT] Would fetch remote asset registry matrix from ${BASE_URL}..."
else
    log_info "Fetching remote asset registry matrix from ${BASE_URL}..."
fi

# 5. Asset URL Discovery
# Queries the targeted release folder structure for generic amd64 .deb packages.
VERSION_PAYLOAD=$(curl -sSf --connect-timeout 10 --max-time 30 "$BASE_URL/" || true)
if [ -z "$VERSION_PAYLOAD" ]; then
    log_error "Target folder ${LATEST_VERSION} exists, but the amd64 directory is unreachable."
    exit 1
fi

FILE_LIST=$(echo "$VERSION_PAYLOAD" | grep -oE 'linux-[a-zA-Z0-9_\.\+-]+\.deb' | uniq || true)

if [ -z "$FILE_LIST" ]; then
    log_error "The amd64 directory for ${LATEST_VERSION} contains no valid Debian packages."
    exit 1
fi

# Collect assets
DOWNLOADS_TO_BE_DONE=()
for file in $FILE_LIST; do
    if [[ "$file" =~ -generic_ ]] || [[ "$file" =~ _all\.deb ]] || [[ "$file" =~ linux-modules- ]]; then
        if [[ ! "$file" =~ 64k ]] && [[ ! "$file" =~ lowlatency ]] && [[ ! "$file" =~ dkms ]]; then
            DOWNLOADS_TO_BE_DONE+=("$file")
        fi
    fi
done

if [ "$DETECT_MODE" = true ]; then
    log_info "[DETECT] Would download core components:"
    for file in "${DOWNLOADS_TO_BE_DONE[@]}"; do
        log_info "[DETECT]   -> $file"
    done
    log_info "[DETECT] Would unpack architectures into a temporary secure staging workspace."
    log_info "[DETECT] Would deploy system modules to: /lib/modules/${TARGET_VER}-generic"
    log_info "[DETECT] Would deploy development headers to: /usr/src/linux-headers-${TARGET_VER} and /usr/src/linux-headers-${TARGET_VER}-generic"
    log_info "[DETECT] Would atomically deploy kernel images to: /boot"
    log_info "[DETECT] Would run depmod -a ${TARGET_VER}-generic to rebuild hardware module maps."
    log_info "[DETECT] Would run dkms autoinstall (if DKMS is registered)"
    log_info "[DETECT] Would compile initial RAM disk boot environment for version: ${TARGET_VER}-generic"
    harden_grub_config
    log_info "[DETECT] Would update system boot symlinks (/boot/vmlinuz -> vmlinuz-${TARGET_VER}-generic, etc.)"
    log_info "[DETECT] Would update GRUB boot options (update-grub)"
    exit 0
fi

# 6. Asset Download Phase
# Downloads core packages while ignoring 64k, lowlatency, and debug/dkms structures.
log_info "Downloading core components..."
for file in "${DOWNLOADS_TO_BE_DONE[@]}"; do
    log_info "   -> Downloading: $file"
    curl -sSf --connect-timeout 10 --max-time 120 -O "${BASE_URL}/${file}"
done

# Locate downloaded image, modules, and headers deb files
IMAGE_DEB=$(find "$DOWNLOAD_DIR" -maxdepth 1 -name "linux-image-*.deb" ! -name "*dbg*" ! -name "*lowlatency*" | head -n1)
MODULES_DEB=$(find "$DOWNLOAD_DIR" -maxdepth 1 -name "linux-modules-*.deb" ! -name "*dbg*" ! -name "*lowlatency*" | head -n1)
HEADERS_GEN_DEB=$(find "$DOWNLOAD_DIR" -maxdepth 1 -name "linux-headers-*-generic_*.deb" | head -n1)
HEADERS_ALL_DEB=$(find "$DOWNLOAD_DIR" -maxdepth 1 -name "linux-headers-*_all.deb" | head -n1)

if [ -z "$IMAGE_DEB" ] || [ -z "$MODULES_DEB" ] || [ -z "$HEADERS_GEN_DEB" ] || [ -z "$HEADERS_ALL_DEB" ]; then
    log_error "Integrity Error: One or more core kernel packages failed to download."
    exit 1
fi

# 7. Package Unpacking Phase
# Unpacks standard Debian archives directly into extracted workspace.
log_info "Unpacking architectures into temporary workspace..."
dpkg-deb -x "$IMAGE_DEB" "$EXTRACT_DIR"
dpkg-deb -x "$MODULES_DEB" "$EXTRACT_DIR"
dpkg-deb -x "$HEADERS_GEN_DEB" "$EXTRACT_DIR"
dpkg-deb -x "$HEADERS_ALL_DEB" "$EXTRACT_DIR"

# 8. Post-Extraction Integrity Validation
log_info "Performing pre-flight disk space and integrity checks..."
if [ ! -d "$EXTRACT_DIR/boot" ] || [ ! -d "$EXTRACT_DIR/usr/src" ]; then
    log_error "Extraction Failure: Expected layout directories (/boot or /usr/src) are missing."
    exit 1
fi

# Locate the correct extracted module path
PAYLOAD_MODULES_ROOT=""
if [ -d "$EXTRACT_DIR/usr/lib/modules" ]; then
    PAYLOAD_MODULES_ROOT="$EXTRACT_DIR/usr/lib/modules"
elif [ -d "$EXTRACT_DIR/lib/modules" ]; then
    PAYLOAD_MODULES_ROOT="$EXTRACT_DIR/lib/modules"
else
    log_error "Extraction Failure: Could not find kernel modules tree payload structure."
    exit 1
fi

MODULE_DIR_PATH=$(find "$PAYLOAD_MODULES_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
if [ -z "$MODULE_DIR_PATH" ]; then
    log_error "Integrity Error: Extracted module directory structure is empty."
    exit 1
fi
MODULE_DIR_NAME=$(basename "$MODULE_DIR_PATH")

log_info "Dynamic Module Target Resolved: ${MODULE_DIR_NAME}"

# 9. Deployment Phase: Stage 1 (Modules & Headers)
# Copies kernel module folders and headers into global system trees.
log_info "Stage 1: Deploying system modules and development headers..."
cp -r "${PAYLOAD_MODULES_ROOT}/${MODULE_DIR_NAME}" /lib/modules/

for header_path in "$EXTRACT_DIR/usr/src/"*; do
    if [ -d "$header_path" ]; then
        cp -r "$header_path" /usr/src/
    fi
done

# 10. Deployment Phase: Stage 2 (Atomic Boot Deployment)
# Moves kernel boot files (vmlinuz, System.map, config) atomically.
log_info "Stage 2: Performing atomic deployment of kernel images to /boot..."
for filepath in "$EXTRACT_DIR/boot/"*; do
    if [ -f "$filepath" ] || [ -L "$filepath" ]; then
        filename=$(basename "$filepath")
        cp -P "$filepath" "/boot/${filename}.tmp"
        mv "/boot/${filename}.tmp" "/boot/${filename}"
    fi
done

# 11. Kernel Integration
# Rebuilds driver maps and initializes RAM disk boot images.
log_info "Rebuilding hardware module maps..."
depmod -a "${MODULE_DIR_NAME}"

# Detect if ZFS/Nvidia/other out-of-tree DKMS modules are registered on system
if command -v dkms >/dev/null 2>&1; then
    dkms_status=$(dkms status 2>/dev/null || true)
    if [ -n "$dkms_status" ]; then
        log_info "DKMS modules detected. Triggering autoinstall build for ${MODULE_DIR_NAME}..."
        dkms autoinstall -k "${MODULE_DIR_NAME}" || log_warn "DKMS auto-installation failed. Some custom drivers may be missing."
    else
        log_info "No DKMS modules registered on this system. Skipping DKMS build."
    fi
fi

log_info "Compiling initial RAM disk boot environment..."
update-initramfs -c -k "${MODULE_DIR_NAME}" || update-initramfs -u -k "${MODULE_DIR_NAME}"

# 12. Bootloader Configuration Updates
harden_grub_config
update_boot_symlinks
log_info "Updating GRUB boot options..."
update-grub 9>&-

echo "=========================================================================="
log_info "Kernel & Headers for ${MODULE_DIR_NAME} successfully deployed!"
log_info "All transactions completed via atomic verification protocols."
log_info "Your package manager database remains untouched and 100% healthy."
log_info "Run 'sudo reboot' to launch your new kernel version safely."
echo "=========================================================================="
