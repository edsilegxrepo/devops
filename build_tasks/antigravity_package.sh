#!/usr/bin/env bash
# ==============================================================================
# antigravity_package.sh
#
# Check Google Antigravity release channels for updates to:
#   1. Antigravity CLI   (antigravity-cli)   -> w64.zip, lnx.tar.xz
#   2. Antigravity Agent (antigravity-agent) -> w64.zip, lnx.tar.xz
#   3. Antigravity IDE   (antigravity-ide)   -> w64.zip, lnx.tar.xz
#
# When new versions are detected:
#   1. Downloads upstream assets to an isolated temporary workspace.
#   2. Renames binaries and directories to match standardized library conventions.
#   3. Prunes packaging artifacts (licenses at root, non-English locales).
#   4. Re-packages into .zip (Windows) and high-compression .tar.xz (Linux xz -9 -T0).
#   5. Atomically replaces prior versions in the library (--source) and stages to --target.
#
# Designed for Cygwin, MSYS2 / Git Bash, WSL, and native Linux environments.
# ==============================================================================

# Enable strict shell execution (-E inherits ERR trap across functions/subshells)
set -Eeo pipefail

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

# Upstream discovery endpoints
DOWNLOAD_PAGE_URL="https://antigravity.google/download"
DOWNLOAD_PAGE_HTML=""
CLI_UPDATER_BASE="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"
HUB_UPDATER_BASE="https://antigravity-hub-auto-updater-974169037036.us-central1.run.app"
IDE_UPDATER_BASE="https://antigravity-ide-auto-updater-974169037036.us-central1.run.app"

# ------------------------------------------------------------------------------
# Section 2: Dynamic Upstream Endpoint Discovery
# ------------------------------------------------------------------------------
# _extract_first_match <ere_pattern> <text>
# Returns the first regex match safely under pipefail without early-close SIGPIPE.
_extract_first_match() {
    local pattern="$1"
    local input="$2"
    grep -oE "$pattern" <<< "$input" | sed -n '1p' || true
}

# _resolve_updater_url <label> <regex_pattern> <var_name>
# Updates <var_name> from DOWNLOAD_PAGE_HTML if matched, otherwise keeps its default.
_resolve_updater_url() {
    local label="$1"
    local pattern="$2"
    local var_name="$3"
    local discovered=""
    if [[ -n "$DOWNLOAD_PAGE_HTML" ]]; then
        discovered=$(_extract_first_match "$pattern" "$DOWNLOAD_PAGE_HTML")
    fi
    if [[ -n "$discovered" && "$discovered" =~ ^https?:// ]]; then
        printf -v "$var_name" '%s' "${discovered%/}"
        log_info "Discovered ${label}: ${!var_name}"
    else
        log_info "Using default ${label}: ${!var_name}"
    fi
}

# discover_endpoints
# Inspects https://antigravity.google/cli/install.sh and DOWNLOAD_PAGE_URL
# to discover active auto-updater services while falling back safely to defaults.
discover_endpoints() {
    log_info "Discovering release channels from https://antigravity.google..."

    local cli_script cli_discovered=""
    cli_script=$(fetch_text "https://antigravity.google/cli/install.sh" 10 || true)
    if [[ -n "$cli_script" ]]; then
        cli_discovered=$(sed -n 's/.*DOWNLOAD_BASE_URL="\([^"]*\)".*/\1/p' <<< "$cli_script" | sed -n '1p' || true)
    fi
    if [[ -n "$cli_discovered" && "$cli_discovered" =~ ^https?:// ]]; then
        CLI_UPDATER_BASE="${cli_discovered%/}"
        log_info "Discovered CLI updater  : $CLI_UPDATER_BASE"
    else
        log_info "Using default CLI updater: $CLI_UPDATER_BASE"
    fi

    DOWNLOAD_PAGE_HTML=$(fetch_text "$DOWNLOAD_PAGE_URL" 15 || true)
    _resolve_updater_url "Agent updater" 'https://antigravity-hub-auto-updater-[^`/ "'\''<>]+' "HUB_UPDATER_BASE"
    _resolve_updater_url "IDE updater  " 'https://antigravity-ide-auto-updater-[^`/ "'\''<>]+' "IDE_UPDATER_BASE"
}

# ------------------------------------------------------------------------------
# Section 3: Help / Usage
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Checks Google Antigravity release channels, downloads latest builds,
normalizes and prunes artifacts, and repackages into standardized archives:
  - antigravity-cli   (w64.zip, lnx.tar.xz)
  - antigravity-agent (w64.zip, lnx.tar.xz)
  - antigravity-ide   (w64.zip, lnx.tar.xz)

Options:
  --app <cli|agent|ide|all>  Process only a specific component (default: all)
  --name <name>              Alias for --app
  --source <path>            Software library destination (default: $DEFAULT_SOURCE)
  --target <path>            Upload staging pending directory (default: $DEFAULT_TARGET)
  --force                    Force download and repackage even if local version is current
  --no-update-source         Do not update or delete files in --source (only write to --target)
  --dry-run                  Check releases and show what would be done without modifying disk
  --log <file>               Save execution output to specified log file
  --verbose                  Show detailed diagnostic and asset messages
  -h, --help                 Show this help message and exit
EOF
}

# ------------------------------------------------------------------------------
# Section 4: CLI Argument Parsing
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

# Validate component filter if provided
case "$SPECIFIC_APP" in
    "" | "all" | "cli" | "agent" | "ide")
        ;;
    *)
        log_error "Invalid component '$SPECIFIC_APP'. Must be 'cli', 'agent', 'ide', or 'all'." >&2
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# Section 5: Prerequisite Verification
# ------------------------------------------------------------------------------
verify_required_tools curl zip unzip jq tar gzip xz

# Normalize directories
SOURCE_PATH=$(enforce_drive_path "$SOURCE_PATH")
SOURCE_CYG=$(to_posix_path "$SOURCE_PATH")
TARGET_PATH=$(enforce_drive_path "$TARGET_PATH")
TARGET_CYG=$(to_posix_path "$TARGET_PATH")

TEMP_ROOT_CYG=$(detect_temp_root)
TEMP_ROOT_PATH=$(enforce_drive_path "$TEMP_ROOT_CYG")

init_log_file "$LOG_FILE"

echo "=============================================================================="
echo " Google Antigravity Packaging Utility"
echo "=============================================================================="
echo " Platform       : $PLATFORM"
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

# Initialize workspace
init_exec_workspace "antigravity_exec_" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN" "$UPDATE_SOURCE"

# ------------------------------------------------------------------------------
# Section 6: Packaging Pipelines & Transformations
# ------------------------------------------------------------------------------

# Transform callbacks for run_dual_platform_package
# shellcheck disable=SC2329
_ag_transform_win_cli() {
    local raw_file="$1" build_dir="$2" out_zip="$3"
    mv "$raw_file" "${build_dir}/antigravity-cli.exe"
    chmod 755 "${build_dir}/antigravity-cli.exe" 2> /dev/null || true
    log_info "Creating zip archive: $(basename "$out_zip")..."
    (cd "$build_dir" && zip -q "$(basename "$out_zip")" "antigravity-cli.exe")
}

# shellcheck disable=SC2329
_ag_transform_lnx_cli() {
    local raw_file="$1" build_dir="$2" out_xz="$3"
    extract_archive "$raw_file" "$build_dir"
    if [[ -f "${build_dir}/antigravity" ]]; then
        mv "${build_dir}/antigravity" "${build_dir}/antigravity-cli"
    fi
    chmod 755 "${build_dir}/antigravity-cli"
    log_info "Recompressing binary to $(basename "$out_xz") (xz -9 -T0)..."
    recompress_folder_to_tar_xz "$build_dir" "antigravity-cli" "$out_xz"
}

# shellcheck disable=SC2329
_ag_transform_win_electron() {
    local raw_file="$1" build_dir="$2" out_zip="$3" ver="$4"
    local exe_name="${AG_APP_KEY}-${ver}-w64.exe"
    mv "$raw_file" "${build_dir}/${exe_name}"
    chmod 755 "${build_dir}/${exe_name}" 2> /dev/null || true
    log_info "Creating zip archive: $(basename "$out_zip")..."
    (cd "$build_dir" && zip -q "$(basename "$out_zip")" "$exe_name")
}

# shellcheck disable=SC2329
_ag_transform_lnx_electron() {
    local raw_file="$1" build_dir="$2" out_xz="$3"
    log_info "Extracting Linux tarball..."
    mkdir -p "${build_dir}/staging"
    extract_archive "$raw_file" "${build_dir}/staging"
    if [[ -d "${build_dir}/staging/${AG_RAW_FOLDER}" ]]; then
        mv "${build_dir}/staging/${AG_RAW_FOLDER}" "${build_dir}/staging/${AG_FINAL_FOLDER}"
    fi
    prune_root_licenses "${build_dir}/staging/${AG_FINAL_FOLDER}"
    prune_electron_locales "${build_dir}/staging/${AG_FINAL_FOLDER}/locales" "en-US.pak"
    log_info "Recompressing to $(basename "$out_xz") (xz -9 -T0)..."
    recompress_folder_to_tar_xz "${build_dir}/staging" "$AG_FINAL_FOLDER" "$out_xz"
}

# Package Antigravity CLI
package_cli() {
    log_step "Checking Antigravity CLI (antigravity-cli)..."

    local win_manifest_url="${CLI_UPDATER_BASE}/manifests/windows_amd64.json"
    local win_manifest
    win_manifest=$(fetch_text "$win_manifest_url" || true)
    if [[ -z "$win_manifest" ]]; then
        log_error "Failed to fetch Windows CLI manifest from $win_manifest_url"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    local cli_ver win_url win_sha512
    cli_ver=$(jq -r '.version // empty' <<< "$win_manifest" 2> /dev/null || true)
    win_url=$(jq -r '.url // empty' <<< "$win_manifest" 2> /dev/null || true)
    win_sha512=$(jq -r '.sha512 // empty' <<< "$win_manifest" 2> /dev/null || true)

    local lnx_manifest_url="${CLI_UPDATER_BASE}/manifests/linux_amd64.json"
    local lnx_manifest
    lnx_manifest=$(fetch_text "$lnx_manifest_url" || true)
    if [[ -z "$lnx_manifest" ]]; then
        log_error "Failed to fetch Linux CLI manifest from $lnx_manifest_url"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    local lnx_url lnx_sha512
    lnx_url=$(jq -r '.url // empty' <<< "$lnx_manifest" 2> /dev/null || true)
    lnx_sha512=$(jq -r '.sha512 // empty' <<< "$lnx_manifest" 2> /dev/null || true)

    if [[ -z "$cli_ver" || ! "$win_url" =~ ^https?:// || ! "$lnx_url" =~ ^https?:// ]]; then
        log_error "Invalid or incomplete CLI manifest fields (ver='${cli_ver}', win_url='${win_url}', lnx_url='${lnx_url}')"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    log_info "Remote latest version: ${C_BOLD}${cli_ver}${C_RESET}"
    if [[ "$VERBOSE" == true ]]; then
        log_info "Windows CLI URL: $win_url"
        log_info "Linux CLI URL  : $lnx_url"
    fi

    run_dual_platform_package \
        "Antigravity CLI" "antigravity-cli" "$cli_ver" \
        "w64" "$win_url" "$win_sha512" "sha512" "cli_windows_x64.exe" "_ag_transform_win_cli" "Would rename binary to antigravity-cli.exe and create zip" \
        "lnx" "$lnx_url" "$lnx_sha512" "sha512" "cli_linux_x64.tar.gz" "_ag_transform_lnx_cli" "Would extract, rename binary to antigravity-cli, and create xz archive"
}

# Unified packaging helper for Electron-based Antigravity applications (Agent, IDE)
# package_electron_component <display_name> <app_key> <releases_url> <win_url_template> <lnx_url_template> <raw_folder_name> <final_folder_name> <html_prefix_regex>
package_electron_component() {
    local display_name="$1"
    local app_key="$2"
    local releases_url="$3"
    local win_template="$4"
    local lnx_template="$5"
    local raw_folder_name="$6"
    local final_folder_name="$7"
    local html_prefix_regex="${8:-}"

    log_step "Checking ${display_name} (${app_key})..."

    local app_ver="" exec_id="" releases_json=""
    releases_json=$(fetch_text "$releases_url" || true)
    if [[ -n "$releases_json" ]]; then
        app_ver=$(jq -r '.[0].version // empty' <<< "$releases_json" 2> /dev/null || true)
        exec_id=$(jq -r '.[0].execution_id // empty' <<< "$releases_json" 2> /dev/null || true)
    fi

    if [[ -z "$app_ver" || -z "$exec_id" ]] && [[ -n "$html_prefix_regex" && -n "$DOWNLOAD_PAGE_HTML" ]]; then
        local html_tag
        html_tag=$(_extract_first_match "${html_prefix_regex}[0-9]+(\.[0-9]+)+-[0-9]+" "$DOWNLOAD_PAGE_HTML")
        if [[ "$html_tag" =~ ([0-9]+(\.[0-9]+)+)-([0-9]+)$ ]]; then
            app_ver="${BASH_REMATCH[1]}"
            exec_id="${BASH_REMATCH[3]}"
            log_warn "Using fallback release metadata from ${DOWNLOAD_PAGE_URL} for ${display_name}"
        fi
    fi

    if [[ -z "$app_ver" || -z "$exec_id" ]]; then
        log_error "Could not resolve latest version or execution_id for ${display_name} from $releases_url"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    log_info "Remote latest version: ${C_BOLD}${app_ver}${C_RESET} (exec_id: ${exec_id})"

    local win_url="${win_template//__VER__/$app_ver}"
    win_url="${win_url//__EXEC__/$exec_id}"
    local lnx_url="${lnx_template//__VER__/$app_ver}"
    lnx_url="${lnx_url//__EXEC__/$exec_id}"

    AG_APP_KEY="$app_key"
    AG_RAW_FOLDER="$raw_folder_name"
    AG_FINAL_FOLDER="$final_folder_name"

    run_dual_platform_package \
        "$display_name" "$app_key" "$app_ver" \
        "w64" "$win_url" "" "" "downloaded_raw.exe" "_ag_transform_win_electron" "Would rename binary to ${app_key}-${app_ver}-w64.exe and create zip" \
        "lnx" "$lnx_url" "" "" "downloaded_raw.tar.gz" "_ag_transform_lnx_electron" "Would rename top folder to ${final_folder_name}/, prune root licenses and unused locales, and recompress with xz -9 -T0"
}

# Package Antigravity Agent (Hub)
package_agent() {
    package_electron_component \
        "Antigravity Agent" \
        "antigravity-agent" \
        "${HUB_UPDATER_BASE}/releases" \
        "https://storage.googleapis.com/antigravity-public/antigravity-hub/__VER__-__EXEC__/windows-x64/Antigravity-x64.exe" \
        "https://storage.googleapis.com/antigravity-public/antigravity-hub/__VER__-__EXEC__/linux-x64/Antigravity.tar.gz" \
        "Antigravity-x64" \
        "antigravity" \
        "antigravity-public/antigravity-hub/"
}

# Package Antigravity IDE
package_ide() {
    package_electron_component \
        "Antigravity IDE" \
        "antigravity-ide" \
        "${IDE_UPDATER_BASE}/releases" \
        "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/__VER__-__EXEC__/windows-x64/Antigravity%20IDE.exe" \
        "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/__VER__-__EXEC__/linux-x64/Antigravity%20IDE.tar.gz" \
        "Antigravity IDE" \
        "antigravity-ide" \
        "antigravity/stable/"
}

# ------------------------------------------------------------------------------
# Section 7: Main Processing Loop
# ------------------------------------------------------------------------------
TOTAL_COUNT=0
UPDATED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

echo ""
discover_endpoints

case "$SPECIFIC_APP" in
    "cli")
        echo ""
        package_cli || true
        ;;
    "agent")
        echo ""
        package_agent || true
        ;;
    "ide")
        echo ""
        package_ide || true
        ;;
    *)
        echo ""
        package_cli || true
        echo ""
        package_agent || true
        echo ""
        package_ide || true
        ;;
esac

# Cleanup workspace
if [[ -n "$EXEC_WORKSPACE" && -d "$EXEC_WORKSPACE" ]]; then
    safe_rm_rf "$EXEC_WORKSPACE"
    EXEC_WORKSPACE=""
fi

print_packaging_summary "Packaging Summary" "$TOTAL_COUNT" "$UPDATED_COUNT" "$SKIPPED_COUNT" "$ERROR_COUNT"

if [[ $ERROR_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
