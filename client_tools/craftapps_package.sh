#!/usr/bin/env bash
# ==============================================================================
# craftapps_package.sh
#
# Check storytold GitHub releases for updates to craft applications.
# When a new version is detected:
#   1. Downloads the Linux (x86_64 tar.gz) and Windows (x86_64 zip) binaries.
#   2. Repackages both archives directly into a combined zip: <app>-<ver>-<suffix>.zip
#   3. Deletes the previous version from --source and replaces it with the new version.
#   4. Removes any prior version from --target and stages the new zip in --target.
#
# Designed for Cygwin, MSYS2 / Git Bash, and native Linux environments.
# ==============================================================================
#
# OBJECTIVES:
#   - Provide a safe, automated, table-driven packaging pipeline for storytold
#     desktop applications.
#   - Ensure high availability and transactional safety: never leave corrupt,
#     partial, or half-written packages in source libraries or target upload stages.
#   - Eliminate external script dependencies (pure bash, jq, curl, zip, unzip, tar).
#   - Enforce uniform cross-platform path standards across Cygwin, MSYS2, and Linux.
#
# CORE COMPONENTS:
#   1. Configuration & Argument Parser:
#      Processes CLI options, provides --help and --list-apps catalog tables,
#      validates package selection early, and supports external config files.
#   2. Path Normalization & Mount Translation:
#      Dual-layer path engine: enforce_drive_path for user display/logging,
#      and to_cygpath for internal POSIX filesystem calls and glob patterns.
#   3. Defensive Filesystem Controller:
#      safe_rm_rf and safe_rm_f wrappers preventing accidental deletions of
#      empty strings, filesystem roots, or system directories.
#   4. Workspace Lifecycle & Signal Trap Manager:
#      Auto-detects temporary root ($TMPDIR, $TEMP, $TMP, /tmp), creates isolated
#      per-execution and per-package workspaces, and ensures guaranteed cleanup
#      on EXIT, INT, TERM, or HUP signals.
#   5. GitHub API Discovery & JQ Asset Filter:
#      Queries GitHub Releases (with pre-release fallback), handles API rate limits
#      (leveraging gh auth token for 5,000 req/hr), and extracts matching x86_64
#      Linux (.tar.gz) and Windows (.zip) release assets.
#   6. Semantic Version Evaluator:
#      GNU sort -V based version comparator supporting semantic versioning.
#   7. Transactional Repackager & Atomic Stager:
#      Downloads to temp, verifies archive integrity (tar -tzf, unzip -tq),
#      bundles archives into combined zip, verifies output, moves to source library,
#      and atomically stages to target pending directory via .tmp rename.
#
# DATA FLOW:
#   [CLI / Env] ──► Parse Args & Auto-Detect GitHub Token ($GITHUB_TOKEN / gh)
#        │
#        ▼
#   [Temp Detection] ──► Detect Temp Root ($TMPDIR / $TEMP / $TMP / /tmp)
#        │
#        ▼
#   [Workspace Init] ──► Create Isolated Workspace: craftapps_exec_XXXXXX
#        │
#   [For each App in PACKAGES]:
#        ├─► Local Scan: Find current version in --source via regex glob
#        ├─► Remote Query: Fetch latest release JSON from GitHub API
#        ├─► Compare Versions: If remote > local (or missing locally):
#        │     ├─► Create App Temp Dir: craftapps_exec_XXXXXX/<app>_XXXXXX/
#        │     ├─► Download Linux tar.gz & Windows zip to Temp
#        │     ├─► Verify Download Integrity: tar -tzf & unzip -tq
#        │     ├─► Package into Combined Zip in Temp: zip -q
#        │     ├─► Verify Packaged Zip Integrity: unzip -tq
#        │     ├─► Update Source: Delete older versions, mv package to --source
#        │     ├─► Atomic Stage: Copy to --target as .tmp, chmod 644, mv -f
#        │     └─► Immediate Cleanup: safe_rm_rf app temp subfolder
#        ▼
#   [Execution Summary] ──► Output stats table, destroy root workspace, exit 0/1
# ==============================================================================

# Enable strict shell execution:
#   -e: Exit immediately if any command returns a non-zero exit code.
#   -o pipefail: Pipeline exit status reflects the rightmost non-zero exit command.
set -eo pipefail

# ------------------------------------------------------------------------------
# Section 1: Default Settings, Platform Detection & Execution State
# ------------------------------------------------------------------------------
# Platform Detection (Cygwin, MSYS2 / Git Bash, Native Linux, WSL):
PLATFORM="unknown"
case "$(uname -s 2>/dev/null || echo "$OSTYPE")" in
    CYGWIN*)
        PLATFORM="cygwin"
        ;;
    MSYS*|MINGW*)
        PLATFORM="msys2"
        ;;
    Linux*)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            PLATFORM="wsl"
        else
            PLATFORM="linux"
        fi
        ;;
    Darwin*)
        PLATFORM="macos"
        ;;
    *)
        if [[ "$OSTYPE" == "cygwin" ]]; then
            PLATFORM="cygwin"
        elif [[ "$OSTYPE" == "msys" ]]; then
            PLATFORM="msys2"
        else
            PLATFORM="linux"
        fi
        ;;
esac

# Standard repository roots and defaults:
#   DEFAULT_SOURCE : Primary public repository library containing existing releases.
#   DEFAULT_TARGET : Staging area where newly packaged bundles are deployed for upload.
#   DEFAULT_ORG    : GitHub organization namespace hosting application source/releases.
DEFAULT_ORG="storytold"

if [[ "$PLATFORM" == "linux" || "$PLATFORM" == "wsl" ]]; then
    if [[ -d "/mnt/n/softlib/software/public" ]]; then
        DEFAULT_SOURCE="/mnt/n/softlib/software/public"
    elif [[ -d "/media/n/softlib/software/public" ]]; then
        DEFAULT_SOURCE="/media/n/softlib/software/public"
    else
        DEFAULT_SOURCE="n:/softlib/software/public"
    fi

    if [[ -d "/mnt/f/stage/upload/pending" ]]; then
        DEFAULT_TARGET="/mnt/f/stage/upload/pending"
    elif [[ -d "/media/f/stage/upload/pending" ]]; then
        DEFAULT_TARGET="/media/f/stage/upload/pending"
    else
        DEFAULT_TARGET="f:/stage/upload/pending"
    fi
else
    DEFAULT_SOURCE="n:/softlib/software/public"
    DEFAULT_TARGET="f:/stage/upload/pending"
fi

# Active execution path and organization variables (overridable via CLI arguments)
SOURCE_PATH="$DEFAULT_SOURCE"
TARGET_PATH="$DEFAULT_TARGET"
GITHUB_ORG="$DEFAULT_ORG"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Auto-detect GitHub token if GitHub CLI (gh) is authenticated:
# Without authentication, GitHub API rate limits anonymous callers to 60 requests/hr.
# Authenticated callers receive 5,000 requests/hr. Probing the `gh` CLI credentials
# enables seamless high-capacity querying without manual token configuration.
if [[ -z "$GITHUB_TOKEN" ]] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi

# Execution Control Flags:
#   DRY_RUN         : When true, inspects repositories and prints actions without disk modifications.
#   FORCE_REPACKAGE : When true, rebuilds and stages packages even if remote == local version.
#   UPDATE_SOURCE   : When true, removes old releases from --source and writes the new package there.
#   SPECIFIC_APP    : Filters processing to a single matching application name or repository.
#   LIST_APPS       : Exclusive mode flag to display the catalog table and exit immediately.
#   VERBOSE         : Displays extended diagnostic messages, asset lists, and HTTP details.
#   CONFIG_FILE     : Optional external package list to override or extend the internal table.
#   LOG_FILE        : Optional destination file for teeing standard output and errors.
DRY_RUN=false
FORCE_REPACKAGE=false
UPDATE_SOURCE=true
SPECIFIC_APP=""
LIST_APPS=false
VERBOSE=false
CONFIG_FILE=""
LOG_FILE=""

# Workspace & cleanup trackers:
# Tracked globally so the signal trap handler (cleanup_workspace) can reliably destroy
# in-flight temporary build directories and atomic staging files if interrupted.
#   EXEC_WORKSPACE     : Unique root folder created per execution in temp root.
#   CURRENT_BUILD_DIR  : Temporary subfolder allocated for the currently processing app.
#   CURRENT_TARGET_TMP : Path of .tmp file in target directory during atomic staging.
#   TEMP_ROOT_CYG      : Auto-detected base temp directory in POSIX mount format.
#   TEMP_ROOT_PATH     : Auto-detected base temp directory in normalized format.
EXEC_WORKSPACE=""
CURRENT_BUILD_DIR=""
CURRENT_TARGET_TMP=""
TEMP_ROOT_CYG=""
TEMP_ROOT_PATH=""

# ------------------------------------------------------------------------------
# Section 2: Path Normalization & Mount Translation
# ------------------------------------------------------------------------------
# enforce_drive_path <path>
# Normalizes any file or directory path into the canonical format:
#   - Windows (Cygwin/MSYS2): <drive>:/<subpath> (e.g. "c:/stage/upload", "n:/softlib")
#   - Linux: Standard POSIX format (/path/sub) unless a Windows drive path is passed.
#
# Arguments:
#   $1 - Raw path string (Windows backslash, POSIX /cygdrive or /c/, mixed, or relative)
# Outputs:
#   Normalized path string written to standard output.
# Key Behaviors:
#   - Empty input produces an empty string.
#   - Uses `cygpath -m` when available (Cygwin, MSYS2) for full mount resolution.
#   - Fallback converts backslashes to forward slashes.
#   - Resolves /cygdrive/<drive>/... (Cygwin), /<drive>/... (MSYS2), and /mnt/<drive>/... (WSL).
#   - Guarantees lowercase drive letters (e.g., "c:/" instead of "C:/").
#   - Strips trailing slashes while preserving root drive slashes (e.g. "c:/").
enforce_drive_path() {
    local p="$1"
    [[ -z "$p" ]] && { echo ""; return 0; }
    if command -v cygpath >/dev/null 2>&1; then
        p=$(cygpath -m "$p")
    else
        p="${p//\\//}"
        if [[ "$p" =~ ^/cygdrive/([a-zA-Z])/(.*) ]]; then
            local drive="${BASH_REMATCH[1],,}"
            p="${drive}:/${BASH_REMATCH[2]}"
        elif [[ "$PLATFORM" == "msys2" ]] && [[ "$p" =~ ^/([a-zA-Z])/(.*) ]]; then
            local drive="${BASH_REMATCH[1],,}"
            p="${drive}:/${BASH_REMATCH[2]}"
        elif [[ "$PLATFORM" == "wsl" ]] && [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*) ]]; then
            local drive="${BASH_REMATCH[1],,}"
            p="${drive}:/${BASH_REMATCH[2]}"
        fi
    fi
    # Normalize drive letter to lowercase and strip trailing slashes
    if [[ "$p" =~ ^([a-zA-Z]):/(.*) ]]; then
        local drive="${BASH_REMATCH[1],,}"
        local rest="${BASH_REMATCH[2]}"
        rest="${rest%/}"
        if [[ -n "$rest" ]]; then
            echo "${drive}:/${rest}"
        else
            echo "${drive}:/"
        fi
    else
        echo "${p%/}"
    fi
}

# to_posix_path <path> / to_cygpath <path>
# Converts an arbitrary path (Windows drive-letter or mixed format) to the native
# POSIX mount format for the host environment:
#   - Cygwin : /cygdrive/<drive>/...
#   - MSYS2  : /<drive>/...
#   - WSL    : /mnt/<drive>/...
#   - Linux  : Native POSIX path
#
# Arguments:
#   $1 - Path string in Windows drive, backslash, or relative format.
# Outputs:
#   POSIX mount path string written to standard output.
# Key Behaviors:
#   - Core utilities (rm, mv, cp, test, mkdir, find, mktemp) and bash globbing
#     require POSIX mount paths to locate filesystem items properly.
#   - Delegates to `cygpath -u` when running in Cygwin or MSYS2.
#   - Provides pure bash regex fallback if running under Git-Bash or standard Linux.
to_posix_path() {
    local p="$1"
    [[ -z "$p" ]] && { echo ""; return 0; }
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$p"
    else
        # Fallback if running on MSYS2/Git-Bash without cygpath, WSL, or native Linux
        p="${p//\\//}"
        if [[ "$p" =~ ^([a-zA-Z]):/(.*) ]]; then
            local drive="${BASH_REMATCH[1],,}"
            local rest="${BASH_REMATCH[2]}"
            if [[ "$PLATFORM" == "msys2" ]]; then
                echo "/${drive}/${rest}"
            elif [[ "$PLATFORM" == "wsl" ]] || [[ -d "/mnt/${drive}" ]]; then
                echo "/mnt/${drive}/${rest}"
            elif [[ -d "/cygdrive/${drive}" ]]; then
                echo "/cygdrive/${drive}/${rest}"
            else
                # Default POSIX mapping
                echo "/${drive}/${rest}"
            fi
        else
            echo "$p"
        fi
    fi
}

# Retain to_cygpath as backward-compatible wrapper
to_cygpath() {
    to_posix_path "$@"
}

# ------------------------------------------------------------------------------
# Section 3: Defensive Removal Wrappers (Guards against empty/root/invalid paths)
# ------------------------------------------------------------------------------
# safe_rm_rf <target_directory>
# Provides strict blast-radius containment for recursive directory deletions.
# Prevents catastrophic accidental filesystem deletion if variables evaluate
# to empty, whitespace, root, drive root, or critical operating system paths.
#
# Arguments:
#   $1 - Directory path to delete recursively.
# Safety Checks:
#   1. Rejects empty, unset, or whitespace-only targets silently (returns 0).
#   2. Normalizes target to POSIX format via to_cygpath and strips trailing slashes.
#   3. Explicitly rejects dangerous system paths: "", "/", ".", "..", "/tmp", "/var/tmp", "/cygdrive", "/mnt".
#   4. Rejects drive roots across all environments:
#      - Cygwin : /cygdrive/[a-zA-Z]
#      - MSYS2  : /[a-zA-Z]
#      - WSL    : /mnt/[a-zA-Z]
#   5. Rejects system root trees: /bin, /usr, /usr/bin, /etc, /lib, /lib64, /sbin, /home, /root, /boot, /dev, /proc, /sys, /opt, /srv.
#   6. Confirms directory or symlink existence before executing `rm -rf`.
safe_rm_rf() {
    local target="$1"

    # Reject empty, unset, or whitespace-only target
    [[ -z "${target// /}" ]] && return 0

    local norm
    norm=$(to_cygpath "$target")

    # Strip trailing slashes
    while [[ "$norm" != "/" && "$norm" =~ /$ ]]; do
        norm="${norm%/}"
    done

    # Refuse removal of dangerous system or root paths
    case "$norm" in
        ""|"/"|"."|".."|"/tmp"|"/var/tmp"|"/cygdrive"|"/mnt")
            echo "[WARN] Refusing unsafe directory deletion: '$norm'" >&2
            return 1
            ;;
        /cygdrive/[a-zA-Z]|/mnt/[a-zA-Z]|/[a-zA-Z])
            echo "[WARN] Refusing unsafe drive root deletion: '$norm'" >&2
            return 1
            ;;
        /bin|/usr|/usr/bin|/etc|/lib|/lib64|/sbin|/home|/root|/boot|/dev|/proc|/sys|/opt|/srv)
            echo "[WARN] Refusing unsafe system directory deletion: '$norm'" >&2
            return 1
            ;;
    esac

    if [[ -d "$norm" || -L "$norm" ]]; then
        rm -rf "$norm" 2>/dev/null || true
    fi
}

# safe_rm_f <target_file>
# Provides defensive single-file removal with bounds checking.
#
# Arguments:
#   $1 - File path to remove.
# Safety Checks:
#   1. Rejects empty, unset, or whitespace-only targets silently (returns 0).
#   2. Normalizes target to POSIX format via to_cygpath.
#   3. Rejects dangerous root or drive paths across Cygwin, MSYS2, WSL, and Linux.
#   4. Verifies regular file or symlink existence before invoking `rm -f`.
safe_rm_f() {
    local target="$1"

    # Reject empty, unset, or whitespace-only target
    [[ -z "${target// /}" ]] && return 0

    local norm
    norm=$(to_cygpath "$target")

    case "$norm" in
        ""|"/"|"."|".."|"/cygdrive"|"/mnt"|/cygdrive/[a-zA-Z]|/mnt/[a-zA-Z]|/[a-zA-Z])
            return 1
            ;;
    esac

    if [[ -f "$norm" || -L "$norm" ]]; then
        rm -f "$norm" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Section 4: Temp Root Directory Auto-Detection & Trap Cleanup Handler
# ------------------------------------------------------------------------------
# detect_temp_root
# Inspects system environment variables to identify an accessible, writable
# temporary root directory across Cygwin, Windows, and POSIX environments.
#
# Evaluation Priority:
#   1. $TMPDIR
#   2. $TEMP
#   3. $TMP
#   4. Fallback: /tmp
#   5. Final fallback: . (current working directory)
#
# Outputs:
#   Writes the resolved POSIX path of the temporary directory to stdout.
detect_temp_root() {
    local detected=""

    for candidate in "${TMPDIR:-}" "${TEMP:-}" "${TMP:-}"; do
        if [[ -n "$candidate" ]]; then
            local cyg_path
            cyg_path=$(to_cygpath "$candidate")
            if [[ -d "$cyg_path" && -w "$cyg_path" ]]; then
                detected="$cyg_path"
                break
            fi
        fi
    done

    # Fallback to /tmp if neither TMPDIR, TEMP, nor TMP is valid/writable
    if [[ -z "$detected" ]]; then
        if [[ -d "/tmp" && -w "/tmp" ]]; then
            detected="/tmp"
        else
            detected="."
        fi
    fi

    echo "$detected"
}

# cleanup_workspace
# Global exit and signal trap handler. Guarantees that neither incomplete temporary
# build directories nor partial target upload staging files remain on disk when
# the script exits, whether by normal completion, error, or external interruption.
#
# Trapped Signals:
#   - EXIT : Normal script termination or early exit due to `set -e`.
#   - INT  : Interrupt signal (e.g. user presses Ctrl+C).
#   - TERM : Termination signal (e.g. process killed by OS or supervisor).
#   - HUP  : Hangup signal (e.g. terminal or SSH connection closed).
#
# Actions:
#   1. Deletes the active application build directory ($CURRENT_BUILD_DIR) if set.
#   2. Deletes the active target staging file ($CURRENT_TARGET_TMP) if set.
#   3. Deletes the per-run unique workspace directory ($EXEC_WORKSPACE) if set.
cleanup_workspace() {
    # 1. Clean current package temporary build directory if active
    if [[ -n "$CURRENT_BUILD_DIR" ]]; then
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
    fi
    # 2. Clean in-flight target staging file if active
    if [[ -n "$CURRENT_TARGET_TMP" ]]; then
        safe_rm_f "$CURRENT_TARGET_TMP"
        CURRENT_TARGET_TMP=""
    fi
    # 3. Destroy unique execution workspace at exit or abort
    if [[ -n "$EXEC_WORKSPACE" ]]; then
        safe_rm_rf "$EXEC_WORKSPACE"
        EXEC_WORKSPACE=""
    fi
}
trap cleanup_workspace EXIT INT TERM HUP

# ------------------------------------------------------------------------------
# Section 5: Package Configuration Table
# ------------------------------------------------------------------------------
# Default application catalog for storytold desktop software.
# Easily add or remove packages below (or load via --config <file>).
#
# Column Schema: "REL_DIR   APP_NAME   [SUFFIX]   [GITHUB_REPO]"
#   - REL_DIR     : Relative subdirectory in source library (e.g., "apps/audio")
#   - APP_NAME    : Base application identifier used in filenames and commands
#   - SUFFIX      : Package bundle suffix (standardized to "win-lnx")
#   - GITHUB_REPO : Upstream repository name under storytold/ (defaults to APP_NAME)
# ------------------------------------------------------------------------------
PACKAGES=(
    "apps/audio              soundcraft      win-lnx"
    "apps/imaging/cad        cadcraft        win-lnx"
    "apps/imaging/draw       designcraft     win-lnx"
    "apps/imaging/draw       photocraft      win-lnx"
    "apps/imaging/draw       vectorcraft     win-lnx"
    "apps/imaging/video      effectcraft     win-lnx"
    "apps/imaging/video      filmcraft       win-lnx"
    "apps/imaging/video      lightcraft      win-lnx"
    "apps/office             deckcraft       win-lnx"
    "apps/office             gridcraft       win-lnx"
    "apps/office             wordcraft       win-lnx"
    "apps/text/pdf/editor    pdfcraft        win-lnx"
    "devel/ux                craftanything   win-lnx"
    "devel/ux                figcraft        win-lnx"
)

# ------------------------------------------------------------------------------
# Section 6: Terminal Formatting, Category Mapping & Catalogs
# ------------------------------------------------------------------------------
# ANSI Color Palettes:
# Configures terminal escape codes when connected to an interactive TTY ($stdout is a terminal).
# If stdout is redirected to a file or piped, color sequences are disabled.
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_RED="\033[1;31m"
    C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"
    C_BLUE="\033[1;34m"
    C_CYAN="\033[1;36m"
    C_BOLD="\033[1m"
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_BOLD=""
fi

# Standardized Console Logging Functions:
#   log_info  : General operational notices with cyan [INFO] tag.
#   log_ok    : Confirmation of successful actions with green [OK] tag.
#   log_warn  : Non-fatal issues or skipped items with yellow [WARN] tag (emitted to stderr).
#   log_error : Critical errors or verification failures with red [ERROR] tag (emitted to stderr).
#   log_step  : High-level stage transition banner with bold blue ==> marker.
log_info()    { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_ok()      { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_error()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_step()    { echo -e "${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }

# ------------------------------------------------------------------------------
# Category Label Helper & Application Table Formatter
# ------------------------------------------------------------------------------
# get_category_label <relative_directory>
# Maps a relative source subdirectory to a user-facing hierarchical category label.
#
# Arguments:
#   $1 - Relative directory path (e.g. "apps/audio", "apps/imaging/cad", "devel/ux")
# Outputs:
#   Prints human-readable category string (e.g. "Audio", "Imaging > CAD", "Development > UX").
get_category_label() {
    case "$1" in
        apps/audio)              echo "Audio" ;;
        apps/imaging/cad)        echo "Imaging > CAD" ;;
        apps/imaging/draw)       echo "Imaging > Draw" ;;
        apps/imaging/video)      echo "Imaging > Video" ;;
        apps/office)             echo "Office" ;;
        apps/text/pdf/editor)    echo "Text > PDF Editor" ;;
        devel/ux)                echo "Development > UX" ;;
        *)
            local clean="${1#apps/}"
            clean="${clean//\// > }"
            echo "${clean^}"
            ;;
    esac
}

# display_apps_table
# Formats and renders the entire configured application directory as an aligned,
# readable table organized with category hierarchy, short relative path,
# application name, package suffix, and upstream GitHub repository.
# Triggered exclusively via `--list-apps`.
display_apps_table() {
    local total=0
    echo "===================================================================================================="
    echo -e " ${C_BOLD}Storytold Craft Applications Directory${C_RESET}"
    echo "===================================================================================================="
    printf " %-20s %-23s %-16s %-10s %s\n" "CATEGORY" "SHORT PATH" "APPLICATION" "SUFFIX" "GITHUB REPO"
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────"
    for entry in "${PACKAGES[@]}"; do
        [[ -z "$entry" || "$entry" =~ ^[[:space:]]*# ]] && continue
        read -r rel_dir app_name suffix repo <<< "$entry"
        suffix="${suffix:-win-lnx}"
        repo="${repo:-$app_name}"
        local cat_label
        cat_label=$(get_category_label "$rel_dir")
        printf " %-20s %-23s ${C_BOLD}%-16s${C_RESET} %-10s %s/%s\n" \
            "$cat_label" "$rel_dir" "$app_name" "$suffix" "$GITHUB_ORG" "$repo"
        total=$((total + 1))
    done
    echo "===================================================================================================="
    echo -e " Total: ${C_BOLD}${total}${C_RESET} packages configured."
    echo " To process an individual package: $(basename "$0") --app <name> [--dry-run]"
    echo "===================================================================================================="
}

# ------------------------------------------------------------------------------
# Help / Usage
# ------------------------------------------------------------------------------
# show_help
# Prints complete command-line usage instructions, detailed parameter definitions,
# execution options, and the list of configured software packages to stdout.
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Checks GitHub (https://github.com/storytold/) for new versions of craft packages.
If a newer release exists:
  - Downloads Linux x86_64 (.tar.gz) and Windows x86_64 (.zip)
  - Packages both into a single combined zip
  - Deletes the old version from --source and places the new zip into --source
  - Removes prior versions from --target and copies the new zip into --target

Options:
  --source <path>     Path to local software library (default: $DEFAULT_SOURCE)
  --target <path>     Path to upload staging directory (default: $DEFAULT_TARGET)
  --org <name>        GitHub organization name (default: $DEFAULT_ORG)
  --token <token>     GitHub Personal Access Token (can also use GITHUB_TOKEN env var)
  --app <name>        Process only a single specified app (e.g. --app soundcraft)
  --list-apps         Display all configured applications by category in a formatted table
  --config <file>     Load package list from an external configuration file
  --log <file>        Save execution log output to specified file
  --force             Force download and repackage even if local version is up-to-date
  --no-update-source  Do not update or delete files in --source (only write to --target)
  --dry-run           Check releases and show what would be done without modifying files
  --verbose           Show detailed debug messages and raw asset lists
  -h, --help          Show this help message and exit

Configured Packages (${#PACKAGES[@]}):
EOF
    for line in "${PACKAGES[@]}"; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        read -r rel_dir app_name suffix repo <<< "$line"
        suffix="${suffix:-win-lnx}"
        repo="${repo:-$app_name}"
        printf "  - %-15s (repo: %-15s suffix: %-8s dir: %s)\n" "$app_name" "$repo" "$suffix" "$rel_dir"
    done
}

# ------------------------------------------------------------------------------
# Section 7: Version Evaluation & Local Discovery
# ------------------------------------------------------------------------------
# is_version_newer <candidate_version> <reference_version>
# Compares two version strings using GNU semantic version comparison (sort -V).
#
# Arguments:
#   $1 - Candidate version string (e.g. remote release version "1.4.2")
#   $2 - Reference version string (e.g. local library version "1.4.0" or "none")
# Returns:
#   0 (true)  - Candidate version is strictly newer than reference version.
#   1 (false) - Candidate version is equal, older, or candidate is empty.
# Notes:
#   - Empty candidate returns 1 (false).
#   - Empty or "none" reference returns 0 (true), triggering a fresh package build.
#   - Exact string equality returns 1 (false) to avoid unnecessary processing.
is_version_newer() {
    local v1="$1"
    local v2="$2"
    [[ -n "$v1" ]] || return 1
    [[ -z "$v2" || "$v2" == "none" ]] && return 0
    [[ "$v1" == "$v2" ]] && return 1

    local highest
    highest=$(printf "%s\n%s\n" "$v1" "$v2" | sort -V | tail -n1)
    [[ "$highest" == "$v1" ]]
}

# ------------------------------------------------------------------------------
# Find Local Package Version in Source Directory
# ------------------------------------------------------------------------------
# find_local_version <base_dir> <rel_dir> <app_name> <suffix>
# Scans the local source library folder for existing package archives matching
# the specified application name and suffix patterns.
#
# Arguments:
#   $1 - Base source library directory (POSIX cygpath format)
#   $2 - Relative directory under source (e.g. "apps/audio")
#   $3 - Application name (e.g. "soundcraft")
#   $4 - Package suffix (e.g. "win-lnx")
# Outputs:
#   Prints two space-separated values: "<latest_version> <canonical_file_path>"
#   Returns "none" and an empty string if no matching archive exists.
# Key Behaviors:
#   - Filename regex captures versions matching both "win-lnx" and legacy "lnx-win"
#     so existing historical packages in the library are correctly identified.
#   - If multiple matching zips exist, iterates through all and selects the
#     highest version determined by is_version_newer.
#   - Normalizes the returned file path to canonical drive:/path/sub format.
find_local_version() {
    local base_dir="$1"
    local rel_dir="$2"
    local app_name="$3"
    local suffix="$4"

    local search_dir="${base_dir}/${rel_dir}"
    if [[ ! -d "$search_dir" ]]; then
        echo "none" ""
        return 0
    fi

    # Find matching zip files
    local latest_ver="none"
    local latest_file=""

    shopt -s nullglob
    local files=("${search_dir}/${app_name}-"*.zip)
    shopt -u nullglob

    for f in "${files[@]}"; do
        local fname
        fname=$(basename "$f")
        # Extract version: <app_name>-<version>-<suffix>.zip
        if [[ "$fname" =~ ^${app_name}-([0-9]+(\.[0-9]+)*([a-zA-Z0-9._-]*))-(${suffix}|win-lnx|lnx-win)\.zip$ ]]; then
            local ver="${BASH_REMATCH[1]}"
            if [[ "$latest_ver" == "none" ]] || is_version_newer "$ver" "$latest_ver"; then
                latest_ver="$ver"
                latest_file="$f"
            fi
        fi
    done

    if [[ -n "$latest_file" ]]; then
        latest_file=$(enforce_drive_path "$latest_file")
    fi

    echo "$latest_ver" "$latest_file"
}

# ------------------------------------------------------------------------------
# Section 8: GitHub API Discovery & Asset Extraction Engine
# ------------------------------------------------------------------------------
# fetch_github_release <org> <repo> [token]
# Queries the GitHub Releases API to retrieve the latest release metadata in JSON.
#
# Arguments:
#   $1 - GitHub organization namespace (e.g., "storytold")
#   $2 - Repository name (e.g., "soundcraft")
#   $3 - Optional personal access token for Bearer authentication
# Outputs:
#   Raw JSON response from the GitHub API.
# Resilience & Fallback:
#   - Connect timeout: 10s; transfer timeout: 30s.
#   - If /releases/latest returns 404 "Not Found" or empty (common when a release
#     is flagged as pre-release or draft), falls back to querying `/releases?per_page=1`
#     and extracts the first release object using jq.
fetch_github_release() {
    local org="$1"
    local repo="$2"
    local token="${3:-}"

    local url="https://api.github.com/repos/${org}/${repo}/releases/latest"
    local auth_header=()
    if [[ -n "$token" ]]; then
        auth_header=(-H "Authorization: Bearer ${token}")
    fi

    local response
    response=$(curl -sSL --connect-timeout 10 --max-time 30 "${auth_header[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: craftapps-packager" \
        "$url" 2>/dev/null || true)

    # Fallback to /releases?per_page=1 if /releases/latest returns Not Found (e.g. pre-releases)
    if [[ "$response" == *"Not Found"* ]] || [[ -z "$response" ]]; then
        local fallback_url="https://api.github.com/repos/${org}/${repo}/releases?per_page=1"
        local fallback_resp
        fallback_resp=$(curl -sSL --connect-timeout 10 --max-time 30 "${auth_header[@]}" \
            -H "Accept: application/vnd.github+json" \
            -H "User-Agent: craftapps-packager" \
            "$fallback_url" 2>/dev/null || true)
        if [[ "$fallback_resp" =~ ^[[:space:]]*\[ ]]; then
            local first_rel
            first_rel=$(echo "$fallback_resp" | jq '.[0] // empty' 2>/dev/null)
            [[ -n "$first_rel" && "$first_rel" != "null" ]] && response="$first_rel"
        fi
    fi

    echo "$response"
}

# ------------------------------------------------------------------------------
# Parse Release Asset URLs (Linux x86_64 tar.gz & Windows x86_64 zip)
# ------------------------------------------------------------------------------
# extract_asset_urls <release_json>
# Parses GitHub release JSON using jq to locate the two required binary archives:
#   1. Linux 64-bit archive: *.tar.gz matching x86_64, amd64, or x64.
#   2. Windows 64-bit archive: *.zip matching win, x86_64, amd64, or x64.
#
# Arguments:
#   $1 - GitHub release JSON payload.
# Outputs:
#   Prints two tab-delimited lines to stdout:
#     Line 1: <linux_asset_filename>\t<linux_download_url>
#     Line 2: <windows_asset_filename>\t<windows_download_url>
# Filtering Heuristics:
#   - Case-insensitive matching for platform and architecture.
#   - Negative filters exclude source bundles, debug symbol archives, and web assets.
extract_asset_urls() {
    local json="$1"

    local linux_info win_info
    linux_info=$(echo "$json" | jq -r '
        [ .assets[]? |
          select(.name | test("linux"; "i")) |
          select(.name | test("x86_64|amd64|x64"; "i")) |
          select(.name | test("\\.tar\\.gz$"; "i")) |
          select(.name | test("source|src|debug|symbols"; "i") | not)
        ] | first // empty | "\(.name)\t\(.browser_download_url)"
    ')
    win_info=$(echo "$json" | jq -r '
        [ .assets[]? |
          select(.name | test("win"; "i")) |
          select(.name | test("x86_64|amd64|x64"; "i")) |
          select(.name | test("\\.zip$"; "i")) |
          select(.name | test("web|source|src|debug|symbols"; "i") | not)
        ] | first // empty | "\(.name)\t\(.browser_download_url)"
    ')
    printf '%s\n%s\n' "$linux_info" "$win_info"
}

# ------------------------------------------------------------------------------
# Section 9: CLI Argument Parsing & Early Dispatchers
# ------------------------------------------------------------------------------
# Process command-line flags and parameters.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            SOURCE_PATH=$(enforce_drive_path "$2")
            shift 2
            ;;
        --target)
            TARGET_PATH=$(enforce_drive_path "$2")
            shift 2
            ;;
        --org)
            GITHUB_ORG="$2"
            shift 2
            ;;
        --token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        --app)
            SPECIFIC_APP="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE=$(enforce_drive_path "$2")
            shift 2
            ;;
        --log)
            LOG_FILE=$(enforce_drive_path "$2")
            shift 2
            ;;
        --force)
            FORCE_REPACKAGE=true
            shift
            ;;
        --no-update-source)
            UPDATE_SOURCE=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --list-apps)
            LIST_APPS=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Run '$(basename "$0") --help' for usage."
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Optional Configuration File Loading
# Reads custom application lists from an external file to override defaults.
# Format per line: "REL_DIR APP_NAME [SUFFIX] [GITHUB_REPO]"
# ------------------------------------------------------------------------------
if [[ -n "$CONFIG_FILE" ]]; then
    CONFIG_CYG=$(to_cygpath "$CONFIG_FILE")
    if [[ ! -f "$CONFIG_CYG" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE ($CONFIG_CYG)"
        exit 1
    fi
    log_info "Loading packages from config file: $CONFIG_FILE"
    PACKAGES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignore comments and blank lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        PACKAGES+=("$line")
    done < "$CONFIG_CYG"
fi

# ------------------------------------------------------------------------------
# Exclusive Command: --list-apps (Display table by category and exit immediately)
# ------------------------------------------------------------------------------
if [[ "$LIST_APPS" == true ]]; then
    display_apps_table
    exit 0
fi

# ------------------------------------------------------------------------------
# Prerequisite Verification (Ensures required tools are present)
# Checks for curl (HTTP), zip & unzip (archive packaging), jq (JSON parser),
# and tar (Linux archive verification).
# ------------------------------------------------------------------------------
for tool in curl zip unzip jq tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        case "$PLATFORM" in
            cygwin)
                log_error "Required tool '$tool' not found. Please install it via Cygwin setup."
                ;;
            msys2)
                log_error "Required tool '$tool' not found. Please install it via 'pacman -S $tool'."
                ;;
            linux|wsl)
                log_error "Required tool '$tool' not found. Please install it via your system package manager (e.g. apt/dnf/pacman)."
                ;;
            *)
                log_error "Required tool '$tool' not found. Please install it and ensure it is in PATH."
                ;;
        esac
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Validate Specific App (Fail early if specified app is not in package table)
# Prevents initializing workspaces or network connections for invalid inputs.
# ------------------------------------------------------------------------------
if [[ -n "$SPECIFIC_APP" ]]; then
    app_found=false
    available_apps=()
    for entry in "${PACKAGES[@]}"; do
        [[ -z "$entry" || "$entry" =~ ^[[:space:]]*# ]] && continue
        read -r rel_dir app_name suffix repo <<< "$entry"
        repo="${repo:-$app_name}"
        available_apps+=("$app_name")
        if [[ "$app_name" == "$SPECIFIC_APP" || "$repo" == "$SPECIFIC_APP" ]]; then
            app_found=true
        fi
    done

    if [[ "$app_found" == false ]]; then
        log_error "Application '$SPECIFIC_APP' not found in configured packages."
        echo "" >&2
        echo "Available applications (${#available_apps[@]}):" >&2
        for a in "${available_apps[@]}"; do
            echo "  - $a" >&2
        done
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Section 10: Path Normalization, Temp Initialization & Workspace Setup
# ------------------------------------------------------------------------------
# Enforce canonical drive:/path/sub format for user display and logs
SOURCE_PATH=$(enforce_drive_path "$SOURCE_PATH")
TARGET_PATH=$(enforce_drive_path "$TARGET_PATH")

# Resolve POSIX mount paths for filesystem calls
SOURCE_CYG=$(to_cygpath "$SOURCE_PATH")
TARGET_CYG=$(to_cygpath "$TARGET_PATH")

# Automatically detect the root of the temp folder (TMPDIR -> TEMP -> TMP -> /tmp)
TEMP_ROOT_CYG=$(detect_temp_root)
TEMP_ROOT_PATH=$(enforce_drive_path "$TEMP_ROOT_CYG")

# Setup optional file logging (tee all stdout/stderr to specified log file)
if [[ -n "$LOG_FILE" ]]; then
    LOG_CYG=$(to_cygpath "$LOG_FILE")
    mkdir -p "$(dirname "$LOG_CYG")"
    exec > >(tee -a "$LOG_CYG") 2>&1
fi

echo "=============================================================================="
echo " Storytold Craft Apps Packaging Utility"
echo "=============================================================================="
echo " Platform       : $PLATFORM"
echo " Source Library : $SOURCE_PATH"
echo " Target Pending : $TARGET_PATH"
echo " Temp Root Dir  : $TEMP_ROOT_PATH"
if [[ -n "$LOG_FILE" ]]; then
echo " Log File       : $LOG_FILE"
fi
echo " Organization   : https://github.com/$GITHUB_ORG/"
if [[ -n "$GITHUB_TOKEN" ]]; then
echo " GitHub Auth    : Authenticated (API token active)"
else
echo " GitHub Auth    : Unauthenticated (60 req/hr rate limit)"
fi
echo " Dry Run        : $DRY_RUN"
echo " Force Repack   : $FORCE_REPACKAGE"
echo " Update Source  : $UPDATE_SOURCE"
if [[ -n "$SPECIFIC_APP" ]]; then
    echo " Filter App     : $SPECIFIC_APP"
fi
echo "=============================================================================="

# Ensure directories exist and initialize unique execution workspace
if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$TARGET_CYG"
    if [[ "$UPDATE_SOURCE" == true ]]; then
        mkdir -p "$SOURCE_CYG"
    fi
    mkdir -p "$TEMP_ROOT_CYG"

    # Prune any stale craftapps temporary workspaces older than 1 day
    if [[ -d "$TEMP_ROOT_CYG" && "$TEMP_ROOT_CYG" != "/" && ! "$TEMP_ROOT_CYG" =~ ^(/cygdrive/|/mnt/|/)[a-zA-Z]$ ]]; then
        find "$TEMP_ROOT_CYG" -maxdepth 1 -type d -name "craftapps_exec_*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
    fi

    # Initialize a unique, isolated workspace for this execution
    EXEC_WORKSPACE=$(mktemp -d "${TEMP_ROOT_CYG}/craftapps_exec_XXXXXX")
    if [[ -z "$EXEC_WORKSPACE" || ! -d "$EXEC_WORKSPACE" ]]; then
        log_error "Failed to create unique execution workspace in $TEMP_ROOT_PATH"
        exit 1
    fi
    log_info "Unique execution workspace initialized: $(enforce_drive_path "$EXEC_WORKSPACE")"
fi

# Execution Counters
TOTAL_COUNT=0
UPDATED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

# ------------------------------------------------------------------------------
# Section 11: Main Processing Loop (Transactional Packaging Engine)
# ------------------------------------------------------------------------------
# Iterates through all configured applications, evaluates local vs remote versions,
# and executes the end-to-end transactional repackaging workflow.
for entry in "${PACKAGES[@]}"; do
    [[ -z "$entry" || "$entry" =~ ^[[:space:]]*# ]] && continue
    read -r rel_dir app_name suffix repo <<< "$entry"
    suffix="${suffix:-win-lnx}"
    repo="${repo:-$app_name}"

    # Filter by specific application if --app was requested
    if [[ -n "$SPECIFIC_APP" && "$app_name" != "$SPECIFIC_APP" && "$repo" != "$SPECIFIC_APP" ]]; then
        continue
    fi

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    echo ""
    log_step "Checking [$app_name] (repo: $GITHUB_ORG/$repo)..."

    # Step 1: Determine local version in source library
    read -r local_ver local_file < <(find_local_version "$SOURCE_CYG" "$rel_dir" "$app_name" "$suffix")
    log_info "Local version  : ${C_BOLD}${local_ver}${C_RESET} (${local_file:-none found})"

    # Step 2: Query GitHub API for latest release metadata
    release_json=$(fetch_github_release "$GITHUB_ORG" "$repo" "$GITHUB_TOKEN")

    # Check for GitHub errors / rate limits
    gh_message=$(echo "$release_json" | jq -r '.message // empty' 2>/dev/null)

    if [[ -n "$gh_message" ]]; then
        if [[ "$gh_message" == *"API rate limit exceeded"* ]]; then
            log_error "GitHub API rate limit exceeded. Please wait or provide --token <github_pat>."
            ERROR_COUNT=$((ERROR_COUNT + 1))
            log_warn "Halting further checks to avoid repeated rate-limit rejections."
            break
        elif [[ "$gh_message" == *"Not Found"* ]]; then
            log_warn "Repository or release not found: https://github.com/$GITHUB_ORG/$repo"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        else
            log_warn "GitHub API message for $app_name: $gh_message"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        fi
    fi

    # Extract tag_name from release JSON
    tag_name=$(echo "$release_json" | jq -r '.tag_name // empty' 2>/dev/null)

    if [[ -z "$tag_name" || "$tag_name" == "null" ]]; then
        log_warn "No published releases found for $app_name."
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    # Normalize remote version (strip leading v/V)
    remote_ver="${tag_name#v}"
    remote_ver="${remote_ver#V}"
    log_info "Remote version : ${C_BOLD}${remote_ver}${C_RESET} (tag: $tag_name)"

    # Step 3: Check if update or repackage is needed
    NEEDS_UPDATE=false
    if [[ "$FORCE_REPACKAGE" == true ]]; then
        log_info "Forcing repackage as requested by --force."
        NEEDS_UPDATE=true
    elif [[ "$local_ver" == "none" ]]; then
        log_info "Package not found locally in source. New package will be created."
        NEEDS_UPDATE=true
    elif is_version_newer "$remote_ver" "$local_ver"; then
        log_ok "New version available: ${local_ver} -> ${C_GREEN}${remote_ver}${C_RESET}"
        NEEDS_UPDATE=true
    else
        log_info "Up to date. (${local_ver} >= ${remote_ver})"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    # Step 4: Extract required asset URLs (Linux x86_64 .tar.gz & Windows x86_64 .zip)
    asset_info=$(extract_asset_urls "$release_json")
    linux_name=$(echo "$asset_info" | sed -n '1p' | cut -f1)
    linux_url=$(echo "$asset_info"  | sed -n '1p' | cut -f2)
    win_name=$(echo "$asset_info"   | sed -n '2p' | cut -f1)
    win_url=$(echo "$asset_info"    | sed -n '2p' | cut -f2)

    if [[ "$VERBOSE" == true ]]; then
        log_info "Linux asset   : ${linux_name:-NOT FOUND}"
        log_info "Windows asset : ${win_name:-NOT FOUND}"
    fi

    if [[ -z "$linux_url" || -z "$win_url" ]]; then
        log_error "Missing required x86_64 assets for $app_name v$remote_ver!"
        [[ -z "$linux_url" ]] && log_error "  - Linux .tar.gz (x86_64) not found in release"
        [[ -z "$win_url" ]]   && log_error "  - Windows .zip (x86_64) not found in release"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Target repackaged zip filename
    NEW_ZIP_NAME="${app_name}-${remote_ver}-${suffix}.zip"
    log_info "Repackage target: ${C_BOLD}${NEW_ZIP_NAME}${C_RESET}"

    if [[ "$DRY_RUN" == true ]]; then
        log_ok "[DRY-RUN] Would download to tmp:"
        echo "   - $linux_name ($linux_url)"
        echo "   - $win_name ($win_url)"
        log_ok "[DRY-RUN] Would verify archive integrity in tmp"
        log_ok "[DRY-RUN] Would package both into $NEW_ZIP_NAME in tmp"
        log_ok "[DRY-RUN] Would verify package integrity in tmp"
        if [[ -n "$local_file" && "$UPDATE_SOURCE" == true ]]; then
            log_ok "[DRY-RUN] Would delete old version from source library: $local_file"
            log_ok "[DRY-RUN] Would move $NEW_ZIP_NAME from tmp to source: ${SOURCE_PATH}/${rel_dir}/${NEW_ZIP_NAME}"
        fi
        log_ok "[DRY-RUN] Would remove prior versions from target: ${TARGET_PATH}/${app_name}-*.zip"
        log_ok "[DRY-RUN] Would copy $NEW_ZIP_NAME from source to target: ${TARGET_PATH}/${NEW_ZIP_NAME}"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        continue
    fi

    # Step 5: Isolated Packaging in Workspace Subfolder
    # Allocates a dedicated directory inside the execution workspace to isolate
    # temporary downloaded archives and packaging artifacts.
    if [[ -z "$EXEC_WORKSPACE" || ! -d "$EXEC_WORKSPACE" ]]; then
        log_error "Execution workspace is not initialized for $app_name."
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    CURRENT_BUILD_DIR=$(mktemp -d "${EXEC_WORKSPACE}/${app_name}_XXXXXX")
    if [[ -z "$CURRENT_BUILD_DIR" || ! -d "$CURRENT_BUILD_DIR" ]]; then
        log_error "Failed to create temporary build directory for $app_name."
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5a: Download Linux asset to tmp
    log_info "Downloading Linux asset to tmp: $linux_name..."
    if ! curl -f -sSL --retry 3 --retry-delay 2 -o "${CURRENT_BUILD_DIR}/${linux_name}" "$linux_url"; then
        log_error "Failed to download Linux asset: $linux_url"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5b: Verify Linux asset integrity in tmp (tar -tzf)
    log_info "Verifying Linux archive integrity in tmp..."
    if ! tar -tzf "${CURRENT_BUILD_DIR}/${linux_name}" >/dev/null 2>&1; then
        log_error "Corrupted or invalid Linux archive downloaded: $linux_name"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5c: Download Windows asset to tmp
    log_info "Downloading Windows asset to tmp: $win_name..."
    if ! curl -f -sSL --retry 3 --retry-delay 2 -o "${CURRENT_BUILD_DIR}/${win_name}" "$win_url"; then
        log_error "Failed to download Windows asset: $win_url"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5d: Verify Windows asset integrity in tmp (unzip -tq)
    log_info "Verifying Windows archive integrity in tmp..."
    if ! unzip -tq "${CURRENT_BUILD_DIR}/${win_name}" >/dev/null 2>&1; then
        log_error "Corrupted or invalid Windows zip archive downloaded: $win_name"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5e: Repackage combined zip in tmp
    # Packages the Linux tar.gz and Windows zip together into <app>-<ver>-<suffix>.zip.
    log_info "Packaging archives into $NEW_ZIP_NAME in tmp..."
    if ! (cd "$CURRENT_BUILD_DIR" && zip -q "$NEW_ZIP_NAME" "$linux_name" "$win_name"); then
        log_error "Failed to create repackaged zip in tmp: $NEW_ZIP_NAME"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5f: Verify repackaged zip integrity in tmp (unzip -tq & non-empty check)
    log_info "Verifying repackaged zip integrity in tmp..."
    if [[ ! -s "${CURRENT_BUILD_DIR}/${NEW_ZIP_NAME}" ]] || ! unzip -tq "${CURRENT_BUILD_DIR}/${NEW_ZIP_NAME}" >/dev/null 2>&1; then
        log_error "Repackaged zip failed integrity verification in tmp: ${NEW_ZIP_NAME}"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 6: Move to the Source Library (if enabled)
    # Deletes any older versions of the app in --source, moves the new archive
    # from temp into the library, and verifies arrival.
    SOURCE_PACKAGE_LOCATION=""
    if [[ "$UPDATE_SOURCE" == true ]]; then
        local_target_dir="${SOURCE_CYG}/${rel_dir}"
        if ! mkdir -p "$local_target_dir"; then
            log_error "Failed to create source library directory: $local_target_dir"
            safe_rm_rf "$CURRENT_BUILD_DIR"
            CURRENT_BUILD_DIR=""
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        fi

        # Remove all prior versions of this app from source
        if [[ -n "$local_target_dir" && -d "$local_target_dir" && -n "$app_name" ]]; then
            shopt -s nullglob
            old_source_files=("${local_target_dir}/${app_name}-"*.zip)
            shopt -u nullglob
            for osf in "${old_source_files[@]}"; do
                if [[ -f "$osf" && "$(basename "$osf")" != "$NEW_ZIP_NAME" ]]; then
                    log_info "Removing old source version: $(enforce_drive_path "$osf")"
                    safe_rm_f "$osf"
                fi
            done
        fi

        # Move the newly packaged zip from tmp to source
        log_info "Moving $NEW_ZIP_NAME from tmp to source: ${SOURCE_PATH}/${rel_dir}/${NEW_ZIP_NAME}..."
        if ! mv -f "${CURRENT_BUILD_DIR}/${NEW_ZIP_NAME}" "${local_target_dir}/${NEW_ZIP_NAME}"; then
            log_error "Failed to move $NEW_ZIP_NAME to source library directory."
            safe_rm_rf "$CURRENT_BUILD_DIR"
            CURRENT_BUILD_DIR=""
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        fi

        # Verify the file arrived safely in source and is non-empty
        if [[ ! -s "${local_target_dir}/${NEW_ZIP_NAME}" ]]; then
            log_error "Verification failed after moving to source: ${local_target_dir}/${NEW_ZIP_NAME}"
            safe_rm_rf "$CURRENT_BUILD_DIR"
            CURRENT_BUILD_DIR=""
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        fi

        chmod 644 "${local_target_dir}/${NEW_ZIP_NAME}" 2>/dev/null || true
        SOURCE_PACKAGE_LOCATION="${local_target_dir}/${NEW_ZIP_NAME}"
    else
        SOURCE_PACKAGE_LOCATION="${CURRENT_BUILD_DIR}/${NEW_ZIP_NAME}"
    fi

    # Step 7: Copy to Target (Pending Upload) Directory
    # Uses atomic .tmp staging so background uploaders or watchers never read
    # partially copied files.
    if ! mkdir -p "$TARGET_CYG"; then
        log_error "Failed to create target pending directory: $TARGET_CYG"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Remove any older/prior version of this app from target
    if [[ -n "$TARGET_CYG" && -d "$TARGET_CYG" && -n "$app_name" ]]; then
        shopt -s nullglob
        old_target_files=("${TARGET_CYG}/${app_name}-"*.zip)
        shopt -u nullglob
        for otf in "${old_target_files[@]}"; do
            if [[ -f "$otf" && "$(basename "$otf")" != "$NEW_ZIP_NAME" ]]; then
                log_info "Removing older version from target: $(enforce_drive_path "$otf")"
                safe_rm_f "$otf"
            fi
        done
    fi

    # Copy new zip to target atomically to protect upload watchers
    CURRENT_TARGET_TMP="${TARGET_CYG}/${NEW_ZIP_NAME}.tmp"
    log_info "Copying $NEW_ZIP_NAME from source to target: ${TARGET_PATH}/${NEW_ZIP_NAME}..."
    if ! cp "$SOURCE_PACKAGE_LOCATION" "$CURRENT_TARGET_TMP"; then
        log_error "Failed to copy $NEW_ZIP_NAME to target staging directory."
        safe_rm_f "$CURRENT_TARGET_TMP"
        CURRENT_TARGET_TMP=""
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    chmod 644 "$CURRENT_TARGET_TMP" 2>/dev/null || true

    if ! mv -f "$CURRENT_TARGET_TMP" "${TARGET_CYG}/${NEW_ZIP_NAME}"; then
        log_error "Failed to finalize atomic staging in target: ${NEW_ZIP_NAME}"
        safe_rm_f "$CURRENT_TARGET_TMP"
        CURRENT_TARGET_TMP=""
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    CURRENT_TARGET_TMP=""

    # Verify target file is present and non-empty
    if [[ ! -s "${TARGET_CYG}/${NEW_ZIP_NAME}" ]]; then
        log_error "Verification failed for target staged file: ${TARGET_CYG}/${NEW_ZIP_NAME}"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 8: Cleanup Package Workspace Immediately After Execution
    # Immediately reclaims temporary build space so disk usage does not accumulate.
    safe_rm_rf "$CURRENT_BUILD_DIR"
    CURRENT_BUILD_DIR=""
    log_info "Cleaned package temporary workspace for $app_name."

    log_ok "Successfully updated, moved to source, and staged in target: $NEW_ZIP_NAME"
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
done

# ------------------------------------------------------------------------------
# Section 12: Summary & Workspace Destruction
# ------------------------------------------------------------------------------
# Destroys the unique execution workspace in temp root and displays metrics table.
if [[ -n "$EXEC_WORKSPACE" ]]; then
    cleaned_path=$(enforce_drive_path "$EXEC_WORKSPACE")
    safe_rm_rf "$EXEC_WORKSPACE"
    EXEC_WORKSPACE=""
    log_ok "Unique execution workspace destroyed: $cleaned_path"
fi
echo ""
echo "=============================================================================="
echo " Execution Summary"
echo "=============================================================================="
echo " Total packages checked : $TOTAL_COUNT"
echo " Updated & Packaged     : $UPDATED_COUNT"
echo " Up to date (Skipped)   : $SKIPPED_COUNT"
echo " Errors / Warnings      : $ERROR_COUNT"
echo "=============================================================================="

# Exit with non-zero code if any package experienced an error or rate limit
if [[ "$ERROR_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
