#!/bin/bash
# ==============================================================================
#  /opt/scripts/proxmox_kernel_cleanup.sh
#  v2.2.1  2026/11/25  XdG / MIS Center
#
#  OBJECTIVES
#  ----------
#  Safely reclaim disk space (notably in /boot and EFI System Partitions) by
#  purging obsolete Proxmox VE kernel and header packages, while guaranteeing:
#    - Bootable rollback targets always remain available.
#    - No cleanup occurs during a pending reboot or rollback boot state.
#    - Pinned kernels and Proxmox metapackage dependencies are never broken.
#    - No unintended reverse-dependency removals can ever cascade via apt.
#
#  RETENTION POLICY
#  ----------------
#    1. Current kernel family (major.minor):
#         - Running kernel (ALWAYS)
#         - Immediately previous kernel in the same family (if installed)
#    2. Immediately previous kernel family:
#         - Latest kernel in that family only (capped to 1 older family)
#    3. Safety overrides (always retained):
#         - Kernels pinned or manually selected via proxmox-boot-tool
#         - Kernels/headers required by proxmox-ve / proxmox-default-* metapackages
#    4. Matching headers follow the same retention set as their kernel version.
#
#  CORE COMPONENTS & FUNCTIONALITY
#  -------------------------------
#    - Section 1 (Configuration & CLI): Strict Bash mode, option parsing, root gate.
#    - Section 2 (Helpers): Family/version regex extractors & deduplicated reason tags.
#    - Section 3 (Discovery & Sorting): Machine-readable dpkg-query scan and
#      prefix-free version sorting.
#    - Section 4 (Safety Gate): Aborts if running kernel != latest installed kernel.
#    - Section 5 (Retention & Overrides): Evaluates family rules, boot-tool pins,
#      and metapackage dependency graph (BFS).
#    - Section 6 (Partitioning & Report): Splits packages into KEEP vs PURGE sets.
#    - Section 7 (APT Simulation Guard): Verifies via `apt-get -s purge` that no
#      outside packages would be installed, upgraded, removed, or purged.
#    - Section 8 (Execution & Bootloader): Non-interactive `apt-get purge -y`
#      (safe because Section 7 bounded the transaction) and proxmox-boot-tool /
#      GRUB synchronization.
#
#  DATA FLOW
#  ---------
#    [uname -r] -------------> RUNNING_VER / RUNNING_FAMILY
#    [dpkg-query] -----------> ALL_TARGET_PKGS, PKG_TO_VER, KERNEL_VER_SET
#                                 |
#                                 v  (sort -u -V on bare versions)
#                              SORTED_KERNEL_VERS -> Safety Gate (running == latest?)
#                                 |
#    [/etc/kernel/proxmox-*] -----+--> Retention Rules + Overrides -> KEEP_REASONS[ver]
#    [metapackage Depends] -------+
#                                 |
#                                 v  (partition ALL_TARGET_PKGS by KEEP_REASONS)
#                              KEEP_PKGS[]   &   PURGE_PKGS[]
#                                                   |
#                                                   v  (LC_ALL=C apt-get -s purge)
#                                                APT Simulation Guard
#                                                   |
#                                                   v  (--purge: non-interactive apt-get purge -y)
#                                                Bootloader Refresh (ESP / GRUB)
# ==============================================================================

# ==============================================================================
# SECTION 1: STRICT MODE, CLI ARGUMENT PARSING & PRIVILEGE CHECK
# ==============================================================================

# Exit immediately on command errors (-e), undefined variables (-u), or
# failures inside pipelines (-o pipefail) so errors never silently continue.
set -euo pipefail

# Ensure sbin directories are in PATH so cron/systemd runs always find
# proxmox-boot-tool and update-grub alongside dpkg-query and apt-get.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# Default execution mode is safe dry-run (no changes unless --purge is passed).
DRY_RUN=true

# Print CLI usage instructions to stdout (or stderr when invoked on bad args).
usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run | --purge | --help]

Safely purge old Proxmox VE kernel and header packages while retaining:
  - Current family: running kernel + previous kernel
  - Immediately previous family: latest kernel only
  - Any pinned/manual kernels and default metapackage dependencies

Options (mutually exclusive; long options only; defaults to --dry-run):
  --dry-run   Preview retained/purged packages and verify via apt simulation (default)
  --purge     Commit permanent removal non-interactively after apt simulation (requires root)
  --help      Show this help message
EOF
}

# Enforce mutual exclusivity: at most one long option may be supplied.
if (( $# > 1 )); then
    echo "ERROR: Options are mutually exclusive; specify at most one option." >&2
    usage >&2
    exit 1
fi

# Parse single optional long flag; reject short flags and unknown arguments.
if (( $# == 1 )); then
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --purge)   DRY_RUN=false ;;
        --help)    usage; exit 0 ;;
        *)
            echo "ERROR: Unknown parameter passed: $1 (only long options are supported)." >&2
            usage >&2
            exit 1
            ;;
    esac
fi

# Ensure script runs as root unless doing a dry run
# (dpkg-query and apt-get -s work unprivileged; actual --purge and bootloader sync require UID 0).
if [[ "$EUID" -ne 0 && "$DRY_RUN" == false ]]; then
    echo "ERROR: --purge must be run as root (omit --purge or use --dry-run to preview)." >&2
    exit 1
fi

# ==============================================================================
# SECTION 2: HELPER FUNCTIONS & RETENTION TRACKING STATE
# ==============================================================================

# Extract major.minor family from a kernel version string (e.g., 7.3.5-2-pve -> 7.3)
# Input:  $1 = bare kernel version string (e.g., "7.3.6-1-pve")
# Output: prints "major.minor" to stdout, or nothing if the format does not match.
get_family() {
    local ver="$1"
    if [[ "$ver" =~ ^([0-9]+\.[0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

# Extract bare kernel version from a versioned Proxmox kernel or header package name
# Strictly matches concrete versioned packages (*-pve / *-pve-signed) while
# excluding unversioned metapackages (e.g., proxmox-kernel-7.0, proxmox-default-kernel).
# Input:  $1 = Debian package name (without :arch suffix)
# Output: prints bare version (e.g., "7.3.6-1-pve") to stdout, or empty if non-matching.
extract_pkg_ver() {
    local pkg="$1"
    if [[ "$pkg" =~ ^(proxmox-kernel-|pve-kernel-)([0-9]+\.[0-9]+[^[:space:]]*-pve)(-signed)?$ ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    elif [[ "$pkg" =~ ^(proxmox-headers-|pve-headers-)([0-9]+\.[0-9]+[^[:space:]]*-pve)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    fi
}

# Predicate returning 0 iff $1 is a concrete versioned Proxmox kernel package
# (distinguishes kernel images from header packages during family/version selection).
is_kernel_pkg() {
    local pkg="$1"
    [[ "$pkg" =~ ^(proxmox-kernel-|pve-kernel-)([0-9]+\.[0-9]+[^[:space:]]*-pve)(-signed)?$ ]]
}

# Associative map: bare kernel version -> comma-separated retention reasons
# Any version present as a key in KEEP_REASONS is protected (along with its headers).
declare -A KEEP_REASONS=()

# Record a retention reason for a kernel version, deduplicating repeated reason tags.
# Inputs: $1 = bare kernel version, $2 = human-readable retention reason tag.
mark_keep() {
    local ver="$1"
    local reason="$2"
    if [[ -z "$ver" ]]; then
        return
    fi
    if [[ -n "${KEEP_REASONS[$ver]:-}" ]]; then
        # Append reason only if this exact tag is not already recorded for $ver.
        if [[ ", ${KEEP_REASONS[$ver]}, " != *", $reason, "* ]]; then
            KEEP_REASONS["$ver"]="${KEEP_REASONS[$ver]}, $reason"
        fi
    else
        KEEP_REASONS["$ver"]="$reason"
    fi
}

# ==============================================================================
# SECTION 3: ENVIRONMENT DISCOVERY & VERSION SORTING
# ==============================================================================

# 1. Capture the exact running kernel version and family
RUNNING_VER="$(uname -r)"
RUNNING_FAMILY="$(get_family "$RUNNING_VER")"
if [[ -z "$RUNNING_FAMILY" ]]; then
    echo "ERROR: Could not parse major.minor family from running kernel: $RUNNING_VER" >&2
    exit 1
fi

# 2. Discover installed Proxmox kernel & header packages via machine-readable dpkg-query
# Data structures populated below:
#   ALL_TARGET_PKGS : list of all installed versioned kernel and header package names
#   PKG_TO_VER      : map of package name -> bare kernel version (e.g., 7.3.6-1-pve)
#   KERNEL_VER_SET  : set of bare versions that have an installed kernel image package
#   ALL_VER_SET     : set of bare versions present in any installed kernel OR header package
declare -a ALL_TARGET_PKGS=()
declare -A PKG_TO_VER=()
declare -A KERNEL_VER_SET=()
declare -A ALL_VER_SET=()

# Query dpkg directly instead of `dpkg -l` to avoid column-width truncation.
while IFS=$'\t' read -r status raw_pkg; do
    # Ignore deinstalled/residual-config ('rc') or half-installed packages.
    [[ "$status" == "install ok installed" ]] || continue
    # Strip optional multiarch qualifier (e.g., ":amd64") if present.
    pkg="${raw_pkg%%:*}"
    ver="$(extract_pkg_ver "$pkg")"
    if [[ -n "$ver" ]]; then
        ALL_TARGET_PKGS+=("$pkg")
        PKG_TO_VER["$pkg"]="$ver"
        ALL_VER_SET["$ver"]=1
        # Track kernel-image versions separately so orphaned headers do not
        # count as bootable kernels when evaluating retention rules.
        if is_kernel_pkg "$pkg"; then
            KERNEL_VER_SET["$ver"]=1
        fi
    fi
done < <(dpkg-query -W -f='${Status}\t${Package}\n' 2>/dev/null)

if (( ${#KERNEL_VER_SET[@]} == 0 )); then
    echo "ERROR: No installed Proxmox kernel packages were found." >&2
    exit 1
fi

# 3. Sort bare kernel version strings (avoids pve-kernel vs proxmox-kernel name-sort bug)
# Sorting package names directly would erroneously place legacy `pve-kernel-*`
# after newer `proxmox-kernel-*` because 'v' > 'r' lexicographically.
mapfile -t SORTED_KERNEL_VERS < <(printf '%s\n' "${!KERNEL_VER_SET[@]}" | sort -u -V)
LATEST_INSTALLED_VER="${SORTED_KERNEL_VERS[-1]}"

# Display high-level runtime context before running safety checks.
echo ""
echo "Running Kernel:            $RUNNING_VER (family $RUNNING_FAMILY)"
echo "Latest Installed Kernel:   $LATEST_INSTALLED_VER"
if [[ "$DRY_RUN" == true ]]; then
    echo "MODE:                      *** DRY RUN (No changes) ***"
else
    echo "MODE:                      *** PURGE (Live removal) ***"
fi
echo "------------------------------------------------------------"

# ==============================================================================
# SECTION 4: SAFETY GATE (PENDING REBOOT / ROLLBACK DETECTION)
# ==============================================================================

# 4. SAFETY GATE: Ensure we are booted into the latest installed kernel
# Protects against two failure modes:
#   (a) A newer kernel was just installed via apt, and the host has not rebooted yet.
#   (b) The administrator intentionally booted an older kernel to troubleshoot.
if [[ "$RUNNING_VER" != "$LATEST_INSTALLED_VER" ]]; then
    echo "CRITICAL: PENDING REBOOT OR NON-LATEST KERNEL DETECTED." >&2
    echo "Running kernel ($RUNNING_VER) does not match latest installed ($LATEST_INSTALLED_VER)." >&2
    echo "Aborting to avoid removing kernels before a verified reboot." >&2
    exit 1
fi

# ==============================================================================
# SECTION 5: RETENTION POLICY & SAFETY OVERRIDES
# ==============================================================================

# 5. APPLY RETENTION POLICY

# Rule 1a: Running kernel (ALWAYS)
mark_keep "$RUNNING_VER" "RUNNING"

# Rule 1b: Immediately previous kernel in the current family
# Iterate ascending through SORTED_KERNEL_VERS; the last version strictly older
# than RUNNING_VER within RUNNING_FAMILY is the immediately previous release.
PREV_IN_CURR_FAMILY=""
for ver in "${SORTED_KERNEL_VERS[@]}"; do
    if [[ "$(get_family "$ver")" == "$RUNNING_FAMILY" && "$ver" != "$RUNNING_VER" ]]; then
        if dpkg --compare-versions "$ver" lt "$RUNNING_VER"; then
            PREV_IN_CURR_FAMILY="$ver"
        fi
    fi
done
if [[ -n "$PREV_IN_CURR_FAMILY" ]]; then
    mark_keep "$PREV_IN_CURR_FAMILY" "CURRENT FAMILY PREV"
fi

# Rule 2: Latest kernel in the immediately previous family only
# First collect all unique installed families strictly older than RUNNING_FAMILY.
declare -A OLDER_FAMILY_SET=()
for ver in "${SORTED_KERNEL_VERS[@]}"; do
    fam="$(get_family "$ver")"
    if [[ -n "$fam" && "$fam" != "$RUNNING_FAMILY" ]]; then
        if dpkg --compare-versions "$fam" lt "$RUNNING_FAMILY"; then
            OLDER_FAMILY_SET["$fam"]=1
        fi
    fi
done

# Cap older-family retention to the single most recent older family (keeps total
# retained kernels bounded at <= 3 under normal conditions to protect ESP space).
if (( ${#OLDER_FAMILY_SET[@]} > 0 )); then
    mapfile -t SORTED_OLDER_FAMILIES < <(printf '%s\n' "${!OLDER_FAMILY_SET[@]}" | sort -u -V)
    PREV_FAMILY="${SORTED_OLDER_FAMILIES[-1]}"
    PREV_FAMILY_LATEST=""
    # Because SORTED_KERNEL_VERS is ascending, the last match in PREV_FAMILY is its latest.
    for ver in "${SORTED_KERNEL_VERS[@]}"; do
        if [[ "$(get_family "$ver")" == "$PREV_FAMILY" ]]; then
            PREV_FAMILY_LATEST="$ver"
        fi
    done
    if [[ -n "$PREV_FAMILY_LATEST" ]]; then
        mark_keep "$PREV_FAMILY_LATEST" "PREV FAMILY ($PREV_FAMILY) LATEST"
    fi
fi

# Safety Override A: Protect pinned / manually-selected kernels (proxmox-boot-tool)
# Inspect all Proxmox boot-tool state files so pinned or one-time next-boot
# kernels are never deleted out from under the bootloader configuration.
for pin_file in \
    /etc/kernel/proxmox-boot-pin \
    /etc/kernel/next-boot-pin \
    /etc/kernel/proxmox-boot-manual-kernels; do
    if [[ -e "$pin_file" ]]; then
        if [[ ! -r "$pin_file" ]]; then
            echo "WARNING: Cannot read $pin_file (re-run as root to verify pinned kernels)." >&2
            continue
        fi
        # Include `|| [[ -n "$line" ]]` so a final line without a trailing newline is read.
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Strip comments and leading/trailing whitespace
            line="${line%%#*}"
            line="$(printf '%s' "$line" | awk '{$1=$1; print}')"
            if [[ "$line" =~ ^([0-9]+\.[0-9]+[^[:space:]]*-pve)$ ]]; then
                pin_ver="${BASH_REMATCH[1]}"
                if [[ -n "${ALL_VER_SET[$pin_ver]:-}" ]]; then
                    mark_keep "$pin_ver" "PINNED/MANUAL"
                fi
            fi
        done < "$pin_file"
    fi
done

# Safety Override B: Protect kernels/headers required by Proxmox default metapackages
# Performs a breadth-first traversal (BFS) from top-level Proxmox metapackages
# (e.g., proxmox-ve -> proxmox-default-kernel -> proxmox-kernel-7.0 -> concrete -pve pkg).
# This prevents opting into a newer kernel series from purging the default series'
# dependency chain.
declare -a META_QUEUE=("proxmox-ve" "proxmox-default-kernel" "proxmox-default-headers")
declare -A META_VISITED=()
meta_idx=0
while (( meta_idx < ${#META_QUEUE[@]} )); do
    meta_pkg="${META_QUEUE[$meta_idx]}"
    meta_idx=$((meta_idx + 1))
    [[ -n "${META_VISITED[$meta_pkg]:-}" ]] && continue
    META_VISITED["$meta_pkg"]=1

    # Query Status and Depends; skip missing or non-installed metapackages.
    meta_info="$(dpkg-query -W -f='${Status}\t${Depends}\n' "$meta_pkg" 2>/dev/null || true)"
    IFS=$'\t' read -r meta_status dep_line <<< "$meta_info"
    [[ "$meta_status" == "install ok installed" && -n "$dep_line" ]] || continue

    # Split Depends on commas and pipes
    IFS=',|' read -ra raw_deps <<< "$dep_line"
    for dep in "${raw_deps[@]}"; do
        # Strip version constraints "(...)", architecture ":arch", and whitespace
        dep="${dep%%(*}"
        dep="${dep%%:*}"
        dep="$(printf '%s' "$dep" | awk '{$1=$1; print}')"
        [[ -z "$dep" ]] && continue

        dep_ver="$(extract_pkg_ver "$dep")"
        if [[ -n "$dep_ver" ]]; then
            # Leaf concrete kernel/header package found: protect its version if installed.
            if [[ -n "${ALL_VER_SET[$dep_ver]:-}" ]]; then
                mark_keep "$dep_ver" "DEFAULT-META DEP"
            fi
        elif [[ "$dep" =~ ^(proxmox-default-kernel|proxmox-default-headers|proxmox-kernel-[0-9]+\.[0-9]+|pve-kernel-[0-9]+\.[0-9]+|proxmox-headers-[0-9]+\.[0-9]+|pve-headers-[0-9]+\.[0-9]+)$ ]]; then
            # Intermediate series metapackage: enqueue for further dependency expansion.
            META_QUEUE+=("$dep")
        fi
    done
done

# ==============================================================================
# SECTION 6: PACKAGE PARTITIONING & AUDIT REPORT
# ==============================================================================

# 6. PARTITION PACKAGES INTO KEEP VS PURGE
# Matching headers automatically inherit their kernel version's KEEP_REASONS entry;
# orphaned headers whose kernel version is not kept are placed into PURGE_PKGS.
declare -a KEEP_PKGS=()
declare -a PURGE_PKGS=()
declare -A PURGE_PKG_SET=()

mapfile -t SORTED_TARGET_PKGS < <(printf '%s\n' "${ALL_TARGET_PKGS[@]}" | sort -u -V)

for pkg in "${SORTED_TARGET_PKGS[@]}"; do
    ver="${PKG_TO_VER[$pkg]}"
    if [[ -n "${KEEP_REASONS[$ver]:-}" ]]; then
        KEEP_PKGS+=("$pkg")
    else
        PURGE_PKGS+=("$pkg")
        PURGE_PKG_SET["$pkg"]=1
    fi
done

# Always print the retained set with justification tags for clear auditability.
echo "Retained packages:"
for pkg in "${KEEP_PKGS[@]}"; do
    ver="${PKG_TO_VER[$pkg]}"
    printf '  [KEEP]  %-45s (%s)\n' "$pkg" "${KEEP_REASONS[$ver]}"
done
echo "------------------------------------------------------------"

# Exit cleanly if nothing qualifies for removal.
if (( ${#PURGE_PKGS[@]} == 0 )); then
    echo "STATUS: No old kernels or headers to purge. System matches retention policy."
    exit 0
fi

echo "Packages marked for permanent removal:"
for pkg in "${PURGE_PKGS[@]}"; do
    echo "  -> $pkg"
done
echo "------------------------------------------------------------"

# ==============================================================================
# SECTION 7: APT SIMULATION GUARD (REVERSE-DEPENDENCY SAFETY NET)
# ==============================================================================

# 7. APT SIMULATION SAFETY CHECK (prevents cascade removal of metapackages/reverse-deps)
# Run `apt-get -s purge` under LC_ALL=C for deterministic English output markers
# ("Inst <pkg>", "Purg <pkg>", "Remv <pkg>"). Executed in BOTH dry-run and live modes
# so that non-interactive `apt-get purge -y` can only execute the exact verified purges.
SIM_OUTPUT=""
if ! SIM_OUTPUT="$(LC_ALL=C apt-get -s purge -- "${PURGE_PKGS[@]}" 2>&1)"; then
    echo "ERROR: apt-get simulation failed. Aborting." >&2
    echo "$SIM_OUTPUT" >&2
    exit 1
fi

# Collect any unexpected apt action:
#   - Any Inst action (unexpected package install or upgrade)
#   - Any Purg/Remv action targeting a package NOT in PURGE_PKG_SET
#     (e.g., proxmox-ve, proxmox-default-kernel, DKMS/third-party packages)
declare -a UNEXPECTED_ACTIONS=()
while IFS= read -r sim_line; do
    if [[ "$sim_line" =~ ^(Inst|Purg|Remv)[[:space:]]+([^[:space:]]+) ]]; then
        sim_action="${BASH_REMATCH[1]}"
        sim_pkg="${BASH_REMATCH[2]%%:*}"
        if [[ "$sim_action" == "Inst" || -z "${PURGE_PKG_SET[$sim_pkg]:-}" ]]; then
            UNEXPECTED_ACTIONS+=("${sim_action} ${sim_pkg}")
        fi
    fi
done <<< "$SIM_OUTPUT"

if (( ${#UNEXPECTED_ACTIONS[@]} > 0 )); then
    echo "CRITICAL: apt-get would perform unexpected package changes outside the purge list:" >&2
    for extra_action in "${UNEXPECTED_ACTIONS[@]}"; do
        echo "  !! $extra_action" >&2
    done
    echo "Aborting to prevent unintended package or metapackage changes." >&2
    exit 1
fi

echo "APT simulation verified: zero unexpected package changes or reverse-dependency removals."

# Stop here in dry-run mode now that policy + apt simulation are both verified.
if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run complete. No packages were removed."
    echo "Re-run with --purge as root to commit removal."
    exit 0
fi

# ==============================================================================
# SECTION 8: NON-INTERACTIVE PURGE & BOOTLOADER SYNCHRONIZATION
# ==============================================================================

# 8. EXECUTION PHASE (non-interactive; safe because --purge is explicit and Section 7
#    already verified zero unexpected installs, upgrades, or reverse-dependency removals)
echo "Purging packages..."
# DEBIAN_FRONTEND=noninteractive prevents debconf/postrm hooks from blocking on a TTY;
# `--` prevents package names starting with '-' from being parsed as options.
if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y -- "${PURGE_PKGS[@]}"; then
    echo "ERROR: apt-get purge failed. Bootloader refresh skipped." >&2
    exit 1
fi

# 9. AUTO-DETECT AND REFRESH BOOTLOADER
# Prefer proxmox-boot-tool when /etc/kernel/proxmox-boot-uuids is non-empty (-s),
# contains at least one active (non-comment, non-blank) UUID entry, and the
# binary is installed; otherwise fall back to update-grub.
echo "Refreshing bootloader configuration..."
if [[ -s /etc/kernel/proxmox-boot-uuids ]] \
    && command -v proxmox-boot-tool >/dev/null 2>&1 \
    && grep -Eq '^[[:space:]]*[^#[:space:]]' /etc/kernel/proxmox-boot-uuids; then
    echo "Detected active proxmox-boot-tool configuration. Syncing ESPs..."
    proxmox-boot-tool refresh
elif command -v update-grub >/dev/null 2>&1; then
    echo "Using update-grub..."
    update-grub
else
    echo "ERROR: Neither proxmox-boot-tool nor update-grub was found." >&2
    exit 1
fi

echo "Success. System cleaned."
