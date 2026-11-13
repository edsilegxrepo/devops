#!/usr/bin/env bash
# ==============================================================================
# vscode_package.sh
#
# Check Microsoft Visual Studio Code stable release channels for updates to:
#   1. VS Code CLI (vscode_cli) -> x64.zip, lnx.tar.xz
#   2. VS Code IDE (vscode)     -> x64.zip, lnx.tar.xz
#
# When new versions are detected:
#   1. Queries Microsoft's official update API for version, URL, and SHA-256.
#   2. Downloads upstream assets into an isolated workspace and verifies SHA-256.
#   3. Prunes redundant licensing artifacts, non-English Electron locales
#      (keeping en-US.pak), and non-English Windows ADMX policy templates
#      (keeping policies/en-us/).
#   4. Normalizes Linux root directory to vscode/ and recompresses via WSL/Linux
#      ext4 (/tmp) to preserve POSIX permissions (including chrome-sandbox setuid)
#      into high-compression .tar.xz (xz -9 -T0).
#   5. Atomically replaces prior versions in --source and stages VS Code IDE
#      archives to --target (vscode_cli archives remain in --source only).
#
# Designed for Cygwin, MSYS2 / Git Bash, WSL, and native Linux environments.
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# Source Shared Foundation Library
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/client_package_common.sh"
if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[ERROR] Missing required shared library: $COMMON_LIB" >&2
    exit 1
fi
# shellcheck source=client_package_common.sh
source "$COMMON_LIB"

# ------------------------------------------------------------------------------
# Section 1: Default Settings & Upstream Discovery Endpoints
# ------------------------------------------------------------------------------
DEFAULT_SOURCE="$(resolve_default_path "n" "softlib/software/public/devel/ide")"
DEFAULT_TARGET="$(resolve_default_path "f" "stage/upload/pending")"
UPDATE_API_BASE="https://update.code.visualstudio.com/api/update"
CHANNEL="stable"

SOURCE_PATH="$DEFAULT_SOURCE"
TARGET_PATH="$DEFAULT_TARGET"

SPECIFIC_APP=""
DRY_RUN=false
FORCE_REPACKAGE=false
UPDATE_SOURCE=true
VERBOSE=false
LOG_FILE=""

EXEC_WORKSPACE=""
CURRENT_BUILD_DIR=""

# ------------------------------------------------------------------------------
# Section 2: Help / Usage
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Checks Microsoft Visual Studio Code (${CHANNEL}) release channels, downloads
latest builds, verifies SHA-256 checksums, prunes packaging bloat, and
repackages into standardized archives:
  - vscode_cli (x64.zip, lnx.tar.xz)
  - vscode     (x64.zip, lnx.tar.xz)

Options:
  --app <cli|ide|all>  Process only a specific component (default: all)
  --name <name>        Alias for --app
  --source <path>      Software library destination (default: $DEFAULT_SOURCE)
  --target <path>      Upload staging pending directory (default: $DEFAULT_TARGET)
  --force              Force download and repackage even if local version is current
  --no-update-source   Do not update or delete files in --source (only write to --target)
  --dry-run            Check releases and show what would be done without modifying disk
  --log <file>         Save execution output to specified log file
  --verbose            Show detailed diagnostic and asset messages
  -h, --help           Show this help message and exit
EOF
}

# ------------------------------------------------------------------------------
# Section 3: CLI Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app | --name)
            require_opt_arg "$1" $#
            SPECIFIC_APP="${2,,}"
            shift 2
            ;;
        --source)
            require_opt_arg "$1" $#
            SOURCE_PATH="$2"
            shift 2
            ;;
        --target)
            require_opt_arg "$1" $#
            TARGET_PATH="$2"
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
        --log)
            require_opt_arg "$1" $#
            LOG_FILE="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

case "$SPECIFIC_APP" in
    "" | "all" | "cli" | "ide")
        ;;
    *)
        log_error "Invalid component '$SPECIFIC_APP'. Must be 'cli', 'ide', or 'all'." >&2
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# Section 4: Prerequisite Verification & Workspace Setup
# ------------------------------------------------------------------------------
verify_required_tools curl zip unzip jq tar gzip xz
if is_windows_platform && [[ "$DRY_RUN" == false ]] && ! command -v wsl.exe > /dev/null 2>&1; then
    log_error "Required tool 'wsl.exe' not found. WSL is required on Windows to preserve Linux archive permissions."
    exit 1
fi

SOURCE_PATH=$(enforce_drive_path "$SOURCE_PATH")
SOURCE_CYG=$(to_cygpath "$SOURCE_PATH")
TARGET_PATH=$(enforce_drive_path "$TARGET_PATH")
TARGET_CYG=$(to_cygpath "$TARGET_PATH")

TEMP_ROOT_CYG=$(detect_temp_root)
TEMP_ROOT_PATH=$(enforce_drive_path "$TEMP_ROOT_CYG")

init_log_file "$LOG_FILE"

echo "=============================================================================="
echo " Microsoft Visual Studio Code Packaging Utility"
echo "=============================================================================="
echo " Platform       : $PLATFORM"
echo " Channel        : $CHANNEL"
echo " Source Library : $SOURCE_PATH"
echo " Target Pending : $TARGET_PATH"
echo " Dry Run        : $DRY_RUN"
echo " Force Repack   : $FORCE_REPACKAGE"
echo " Update Source  : $UPDATE_SOURCE"
echo " Temp Root Dir  : $TEMP_ROOT_PATH"
if [[ -n "$LOG_FILE" ]]; then
    echo " Log File       : $LOG_FILE"
fi
if [[ -n "$SPECIFIC_APP" && "$SPECIFIC_APP" != "all" ]]; then
    echo " Filter App     : $SPECIFIC_APP"
fi
echo "=============================================================================="

init_exec_workspace "vscode_exec_" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN" "$UPDATE_SOURCE"

# ------------------------------------------------------------------------------
# Section 5: Upstream Metadata & Archive Transformations
# ------------------------------------------------------------------------------
# _vscode_fetch_meta <target_id>
# Queries Microsoft's update API and prints "<productVersion>\t<url>\t<sha256>".
_vscode_fetch_meta() {
    local target_id="$1"
    local api_url="${UPDATE_API_BASE}/${target_id}/${CHANNEL}/latest"
    local json
    json=$(curl -fsSL --retry 3 --retry-delay 2 "$api_url" 2> /dev/null || true)
    if [[ -z "$json" ]]; then
        log_error "Failed to fetch VS Code metadata from $api_url"
        return 1
    fi

    local ver url sha256
    ver=$(echo "$json" | jq -r '.productVersion // empty')
    url=$(echo "$json" | jq -r '.url // empty')
    sha256=$(echo "$json" | jq -r '.sha256hash // empty')

    if [[ -z "$ver" || -z "$url" || -z "$sha256" ]]; then
        log_error "Incomplete metadata received for target '$target_id' from $api_url"
        return 1
    fi

    if [[ "$VERBOSE" == true ]]; then
        log_info "[$target_id] version=$ver sha256=$sha256 url=$url" >&2
    fi

    printf "%s\t%s\t%s\n" "$ver" "$url" "$sha256"
}

# Transform callbacks for run_dual_platform_package
# shellcheck disable=SC2329
_vscode_transform_win_cli() {
    local raw_file="$1" _build_dir="$2" out_zip="$3"
    if ! verify_zip_integrity "$raw_file"; then
        log_error "Downloaded Windows CLI zip failed integrity check"
        return 1
    fi
    if ! unzip -Z1 "$raw_file" 2> /dev/null | grep -qx "code.exe"; then
        log_error "Expected code.exe not found inside Windows CLI zip"
        return 1
    fi
    mv -f "$raw_file" "$out_zip"
}

# shellcheck disable=SC2329
_vscode_transform_lnx_cli() {
    local raw_file="$1" _build_dir="$2" out_xz="$3"
    log_info "Recompressing Linux CLI binary to $(basename "$out_xz") via WSL/Linux (xz -9 -T0)..."
    repack_tar_gz_to_xz_preserving_perms "$raw_file" "$out_xz" "code" ""
}

# shellcheck disable=SC2329
_vscode_transform_win_ide() {
    local raw_file="$1" _build_dir="$2" out_zip="$3"
    if ! verify_zip_integrity "$raw_file"; then
        log_error "Downloaded Windows IDE zip failed integrity check"
        return 1
    fi
    mv -f "$raw_file" "$out_zip"

    # Prune redundant root licenses, non-English Chromium locales, app RTF/licenses,
    # and non-English Windows policy templates in-place without disturbing CRCs.
    local entries_to_remove=()
    local entry base lower_entry
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        # Leave extension and node_modules licenses untouched
        if [[ "$entry" == *"/resources/app/extensions/"* || "$entry" == *"/resources/app/node_modules"* ]]; then
            continue
        fi

        lower_entry="${entry,,}"
        base="${entry##*/}"

        if [[ "$entry" =~ ^([^/]+/)?(LICENSE|LICENSES\.chromium\.html)$ ]]; then
            entries_to_remove+=("$entry")
        elif [[ "$entry" =~ ^([^/]+/)?locales/.+\.pak$ && "$base" != "en-US.pak" ]]; then
            entries_to_remove+=("$entry")
        elif [[ "$entry" =~ ^([^/]+/)?resources/app/(LICENSE\.rtf|ThirdPartyNotices\.txt)$ ]]; then
            entries_to_remove+=("$entry")
        elif [[ "$entry" =~ ^([^/]+/)?resources/app/licenses(/.*)?$ ]]; then
            entries_to_remove+=("$entry")
        elif [[ "$lower_entry" =~ ^policies/([^/]+)/.*$ && "${BASH_REMATCH[1]}" != "en-us" ]]; then
            entries_to_remove+=("$entry")
        fi
    done < <(unzip -Z1 "$out_zip" 2> /dev/null || true)

    if [[ ${#entries_to_remove[@]} -gt 0 ]]; then
        log_info "Pruning ${#entries_to_remove[@]} redundant artifact/locale/policy entries from $(basename "$out_zip")..."
        zip -q -d "$out_zip" "${entries_to_remove[@]}" > /dev/null
    fi
}

# shellcheck disable=SC2329
_vscode_transform_lnx_ide() {
    local raw_file="$1" _build_dir="$2" out_xz="$3"
    log_info "Normalizing, pruning, and recompressing Linux IDE to $(basename "$out_xz") via WSL/Linux (xz -9 -T0)..."
    # shellcheck disable=SC2016
    local lnx_transform='
if [[ -d "VSCode-linux-x64" ]]; then
    mv "VSCode-linux-x64" "vscode"
else
    shopt -s nullglob
    dirs=(*)
    shopt -u nullglob
    if [[ ${#dirs[@]} -eq 1 && -d "${dirs[0]}" && "${dirs[0]}" != "vscode" ]]; then
        mv "${dirs[0]}" "vscode"
    fi
fi
rm -f vscode/LICENSE* vscode/LICENSES*
if [[ -d vscode/locales ]]; then
    find vscode/locales -maxdepth 1 -type f -name "*.pak" ! -name "en-US.pak" -delete
fi
rm -f vscode/resources/app/LICENSE.rtf vscode/resources/app/ThirdPartyNotices.txt
rm -rf vscode/resources/app/licenses
'
    repack_tar_gz_to_xz_preserving_perms "$raw_file" "$out_xz" "vscode" "$lnx_transform"
}

# ------------------------------------------------------------------------------
# Section 6: Component Packaging Pipelines
# ------------------------------------------------------------------------------
_package_vscode_component() {
    local display_name="$1"
    local app_key="$2"
    local win_target="$3"
    local lnx_target="$4"
    local win_raw_name="$5"
    local win_transform_fn="$6"
    local win_dry_msg="$7"
    local lnx_raw_name="$8"
    local lnx_transform_fn="$9"
    local lnx_dry_msg="${10}"

    log_step "Checking ${display_name} (${app_key})..."

    local win_meta lnx_meta
    if ! win_meta=$(_vscode_fetch_meta "$win_target"); then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi
    if ! lnx_meta=$(_vscode_fetch_meta "$lnx_target"); then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    local win_ver win_url win_sha256 lnx_ver lnx_url lnx_sha256
    IFS=$'\t' read -r win_ver win_url win_sha256 <<< "$win_meta"
    IFS=$'\t' read -r lnx_ver lnx_url lnx_sha256 <<< "$lnx_meta"

    if [[ "$win_ver" != "$lnx_ver" ]]; then
        log_warn "Upstream version mismatch between Windows (${win_ver}) and Linux (${lnx_ver}); using ${win_ver}."
    fi

    log_info "Remote latest version: ${C_BOLD}${win_ver}${C_RESET}"

    run_dual_platform_package \
        "$display_name" "$app_key" "$win_ver" \
        "x64" "$win_url" "$win_sha256" "sha256" "$win_raw_name" "$win_transform_fn" "$win_dry_msg" \
        "lnx" "$lnx_url" "$lnx_sha256" "sha256" "$lnx_raw_name" "$lnx_transform_fn" "$lnx_dry_msg"
}

package_vscode_cli() {
    # VS Code CLI archives are stored in --source only (never staged to --target).
    local prev_target_cyg="$TARGET_CYG"
    TARGET_CYG=""
    local rc=0
    _package_vscode_component \
        "VS Code CLI" "vscode_cli" \
        "cli-win32-x64" "cli-alpine-x64" \
        "vscode_cli_win32_x64.zip" "_vscode_transform_win_cli" "Would verify code.exe inside zip and store as vscode_cli-<ver>-x64.zip (--source only)" \
        "vscode_cli_alpine_x64.tar.gz" "_vscode_transform_lnx_cli" "Would transcode cli-alpine-x64 .tar.gz to .tar.xz via WSL/Linux preserving permissions (--source only)" || rc=$?
    TARGET_CYG="$prev_target_cyg"
    return "$rc"
}

package_vscode_ide() {
    _package_vscode_component \
        "VS Code IDE" "vscode" \
        "win32-x64-archive" "linux-x64" \
        "vscode_win32_x64.zip" "_vscode_transform_win_ide" "Would prune root/app licenses, non-English locales/*.pak, and non-English policies/ in-place" \
        "vscode_linux_x64.tar.gz" "_vscode_transform_lnx_ide" "Would rename VSCode-linux-x64/ -> vscode/, prune licenses and locales, and recompress via WSL/Linux (xz -9 -T0)"
}

# ------------------------------------------------------------------------------
# Section 7: Main Processing Loop
# ------------------------------------------------------------------------------
TOTAL_COUNT=0
UPDATED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

case "$SPECIFIC_APP" in
    "cli")
        echo ""
        package_vscode_cli || true
        ;;
    "ide")
        echo ""
        package_vscode_ide || true
        ;;
    *)
        echo ""
        package_vscode_cli || true
        echo ""
        package_vscode_ide || true
        ;;
esac

if [[ -n "$EXEC_WORKSPACE" && -d "$EXEC_WORKSPACE" ]]; then
    safe_rm_rf "$EXEC_WORKSPACE"
    EXEC_WORKSPACE=""
fi

print_packaging_summary "Packaging Summary" "$TOTAL_COUNT" "$UPDATED_COUNT" "$SKIPPED_COUNT" "$ERROR_COUNT"

if [[ $ERROR_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
