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
#   4. Re-packages into .zip (Windows) and high-compression .tar.xz (Linux xz -9).
#   5. Atomically replaces prior versions in the library (--source) and stages to --target.
#
# Designed for Cygwin, MSYS2 / Git Bash, WSL, and native Linux environments.
# ==============================================================================

# Enable strict shell execution
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
DEFAULT_SOURCE="n:/softlib/software/public/devel/ide"
DEFAULT_TARGET="f:/stage/upload/pending"

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
CLI_UPDATER_BASE="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"
HUB_UPDATER_BASE="https://antigravity-hub-auto-updater-974169037036.us-central1.run.app"
IDE_UPDATER_BASE="https://antigravity-ide-auto-updater-974169037036.us-central1.run.app"



# ------------------------------------------------------------------------------
# Section 7: Dynamic Upstream Endpoint Discovery
# ------------------------------------------------------------------------------
# discover_endpoints
# Inspects https://antigravity.google/cli/install.sh and https://antigravity.google/download
# to dynamically discover active auto-updater services, falling back to known URLs.
discover_endpoints() {
    log_info "Discovering release channels from https://antigravity.google..."

    # 1. Discover CLI updater base from install.sh
    local cli_discovered
    cli_discovered=$(curl -sSL --max-time 10 "https://antigravity.google/cli/install.sh" 2>/dev/null | \
        sed -n 's/.*DOWNLOAD_BASE_URL="\([^"]*\)".*/\1/p' | head -n1)
    if [[ -n "$cli_discovered" && "$cli_discovered" =~ ^https?:// ]]; then
        CLI_UPDATER_BASE="${cli_discovered%/}"
        log_info "Discovered CLI updater  : $CLI_UPDATER_BASE"
    else
        log_info "Using default CLI updater: $CLI_UPDATER_BASE"
    fi

    # 2. Discover Hub and IDE updater bases from download page
    local page_html
    page_html=$(curl -sSL --max-time 15 "https://antigravity.google/download" 2>/dev/null || true)
    if [[ -n "$page_html" ]]; then
        local hub_discovered
        hub_discovered=$(echo "$page_html" | grep -o 'https://antigravity-hub-auto-updater-[^`/ "]*' | head -n1)
        if [[ -n "$hub_discovered" && "$hub_discovered" =~ ^https?:// ]]; then
            HUB_UPDATER_BASE="${hub_discovered%/}"
            log_info "Discovered Agent updater: $HUB_UPDATER_BASE"
        else
            log_info "Using default Agent updater: $HUB_UPDATER_BASE"
        fi

        local ide_discovered
        ide_discovered=$(echo "$page_html" | grep -o 'https://antigravity-ide-auto-updater-[^`/ "]*' | head -n1)
        if [[ -n "$ide_discovered" && "$ide_discovered" =~ ^https?:// ]]; then
            IDE_UPDATER_BASE="${ide_discovered%/}"
            log_info "Discovered IDE updater  : $IDE_UPDATER_BASE"
        else
            log_info "Using default IDE updater  : $IDE_UPDATER_BASE"
        fi
    else
        log_info "Using default Agent updater: $HUB_UPDATER_BASE"
        log_info "Using default IDE updater  : $IDE_UPDATER_BASE"
    fi
}

# ------------------------------------------------------------------------------
# Section 7: Local Version Discovery
# ------------------------------------------------------------------------------
# find_local_version <source_dir> <app_key> <platform_suffix>
# e.g.: find_local_version "$SOURCE_CYG" "antigravity-cli" "w64" -> finds antigravity-cli-*-w64.zip
find_local_version() {
    local search_dir="$1"
    local app_key="$2"
    local platform_suffix="$3"

    if [[ ! -d "$search_dir" ]]; then
        echo "none" ""
        return 0
    fi

    shopt -s nullglob
    local files=()
    if [[ "$platform_suffix" == "w64" ]]; then
        files=("${search_dir}/${app_key}"-*-w64.zip)
    else
        files=("${search_dir}/${app_key}"-*-lnx.tar.xz)
    fi
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "none" ""
        return 0
    fi

    local latest_ver="none"
    local latest_file=""

    for f in "${files[@]}"; do
        local bname
        bname=$(basename "$f")
        local ver=""
        if [[ "$platform_suffix" == "w64" ]]; then
            if [[ "$bname" =~ ^${app_key}-([0-9]+\.[0-9]+(\.[0-9]+)?)-w64\.zip$ ]]; then
                ver="${BASH_REMATCH[1]}"
            fi
        else
            if [[ "$bname" =~ ^${app_key}-([0-9]+\.[0-9]+(\.[0-9]+)?)-lnx\.tar\.xz$ ]]; then
                ver="${BASH_REMATCH[1]}"
            fi
        fi

        if [[ -n "$ver" ]]; then
            if [[ "$latest_ver" == "none" ]] || is_version_newer "$ver" "$latest_ver"; then
                latest_ver="$ver"
                latest_file="$f"
            fi
        fi
    done

    echo "$latest_ver" "$latest_file"
}

# ------------------------------------------------------------------------------
# Section 8: Help / Usage
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
# Section 9: CLI Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app|--name)
            SPECIFIC_APP="${2,,}"
            shift 2
            ;;
        --source)
            SOURCE_PATH="$2"
            shift 2
            ;;
        --target)
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
            LOG_FILE="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
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
    ""|"all"|"cli"|"agent"|"ide")
        ;;
    *)
        log_error "Invalid component '$SPECIFIC_APP'. Must be 'cli', 'agent', 'ide', or 'all'." >&2
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# Section 10: Prerequisite Verification
# ------------------------------------------------------------------------------
for tool in curl zip unzip jq tar gzip xz; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "Required tool '$tool' not found. Please install it and ensure it is in PATH." >&2
        exit 1
    fi
done

# Normalize directories
SOURCE_PATH=$(enforce_drive_path "$SOURCE_PATH")
SOURCE_CYG=$(to_cygpath "$SOURCE_PATH")
TARGET_PATH=$(enforce_drive_path "$TARGET_PATH")
TARGET_CYG=$(to_cygpath "$TARGET_PATH")

TEMP_ROOT_CYG=$(detect_temp_root)
TEMP_ROOT_PATH=$(enforce_drive_path "$TEMP_ROOT_CYG")

if [[ -n "$LOG_FILE" ]]; then
    LOG_CYG=$(to_cygpath "$LOG_FILE")
    mkdir -p "$(dirname "$LOG_CYG")"
    exec > >(tee -a "$LOG_CYG") 2>&1
fi

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
if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$TARGET_CYG"
    if [[ "$UPDATE_SOURCE" == true ]]; then
        mkdir -p "$SOURCE_CYG"
    fi
    mkdir -p "$TEMP_ROOT_CYG"

    # Prune stale workspaces older than 1 day
    find "$TEMP_ROOT_CYG" -maxdepth 1 -type d -name "antigravity_exec_*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true

    EXEC_WORKSPACE=$(mktemp -d "${TEMP_ROOT_CYG}/antigravity_exec_XXXXXX")
    if [[ -z "$EXEC_WORKSPACE" || ! -d "$EXEC_WORKSPACE" ]]; then
        log_error "Failed to create temporary workspace in $TEMP_ROOT_PATH"
        exit 1
    fi
    log_info "Execution workspace initialized: $(enforce_drive_path "$EXEC_WORKSPACE")"
fi

# ------------------------------------------------------------------------------
# Section 11: Transactional Package Staging Adapter
# ------------------------------------------------------------------------------
# stage_package <source_file> <package_name> <app_key> <platform_suffix>
stage_package() {
    local src_file="$1"
    local pkg_name="$2"
    local app_key="$3"
    local platform_suffix="$4"

    atomic_stage_package "$src_file" "$pkg_name" "$app_key" "$platform_suffix" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN"
}

# ------------------------------------------------------------------------------
# Section 12: Packaging Pipelines
# ------------------------------------------------------------------------------

# Package Antigravity CLI
package_cli() {
    log_step "Checking Antigravity CLI (antigravity-cli)..."

    # Query Windows manifest
    local win_manifest_url="${CLI_UPDATER_BASE}/manifests/windows_amd64.json"
    local win_manifest
    win_manifest=$(curl -fsSL "$win_manifest_url" 2>/dev/null || true)
    if [[ -z "$win_manifest" ]]; then
        log_error "Failed to fetch Windows CLI manifest from $win_manifest_url"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    local cli_ver win_url win_sha512
    cli_ver=$(echo "$win_manifest" | jq -r '.version // empty')
    win_url=$(echo "$win_manifest" | jq -r '.url // empty')
    win_sha512=$(echo "$win_manifest" | jq -r '.sha512 // empty')

    # Query Linux manifest
    local lnx_manifest_url="${CLI_UPDATER_BASE}/manifests/linux_amd64.json"
    local lnx_manifest
    lnx_manifest=$(curl -fsSL "$lnx_manifest_url" 2>/dev/null || true)
    if [[ -z "$lnx_manifest" ]]; then
        log_error "Failed to fetch Linux CLI manifest from $lnx_manifest_url"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    local lnx_url lnx_sha512
    lnx_url=$(echo "$lnx_manifest" | jq -r '.url // empty')
    lnx_sha512=$(echo "$lnx_manifest" | jq -r '.sha512 // empty')

    log_info "Remote latest version: ${C_BOLD}${cli_ver}${C_RESET}"

    # Check Windows package
    read -r win_local_ver win_local_file < <(find_local_version "$SOURCE_CYG" "antigravity-cli" "w64")
    log_info "Local Windows version: ${win_local_ver} (${win_local_file:-none})"

    local build_win=false
    if [[ "$FORCE_REPACKAGE" == true ]] || is_version_newer "$cli_ver" "$win_local_ver"; then
        build_win=true
    fi

    # Check Linux package
    read -r lnx_local_ver lnx_local_file < <(find_local_version "$SOURCE_CYG" "antigravity-cli" "lnx")
    log_info "Local Linux version  : ${lnx_local_ver} (${lnx_local_file:-none})"

    local build_lnx=false
    if [[ "$FORCE_REPACKAGE" == true ]] || is_version_newer "$cli_ver" "$lnx_local_ver"; then
        build_lnx=true
    fi

    if [[ "$build_win" == false && "$build_lnx" == false ]]; then
        log_info "Antigravity CLI is up to date."
        if [[ -n "$win_local_file" ]]; then
            purge_obsolete_packages "antigravity-cli" "w64" "$(basename "$win_local_file")"
        fi
        if [[ -n "$lnx_local_file" ]]; then
            purge_obsolete_packages "antigravity-cli" "lnx" "$(basename "$lnx_local_file")"
        fi
        SKIPPED_COUNT=$((SKIPPED_COUNT + 2))
        return 0
    fi

    local build_dir=""
    if [[ "$DRY_RUN" == false ]]; then
        build_dir=$(mktemp -d "${EXEC_WORKSPACE}/cli_XXXXXX")
    fi

    # Build Windows package
    if [[ "$build_win" == true ]]; then
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        local pkg_name="antigravity-cli-${cli_ver}-w64.zip"
        log_info "Processing Windows package: $pkg_name"
        if [[ "$DRY_RUN" == true ]]; then
            log_ok "[DRY-RUN] Would download: $win_url"
            log_ok "[DRY-RUN] Would rename binary to antigravity-cli.exe"
            log_ok "[DRY-RUN] Would create zip: $pkg_name"
            stage_package "" "$pkg_name" "antigravity-cli" "w64"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
        else
            log_info "Downloading Windows CLI binary..."
            if ! download_asset "$win_url" "${build_dir}/cli_windows_x64.exe" "$win_sha512" "sha512"; then
                safe_rm_rf "$build_dir"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            fi

            mv "${build_dir}/cli_windows_x64.exe" "${build_dir}/antigravity-cli.exe"
            chmod 755 "${build_dir}/antigravity-cli.exe" 2>/dev/null || true

            log_info "Creating zip archive: $pkg_name..."
            (cd "$build_dir" && zip -q "$pkg_name" "antigravity-cli.exe")
            if ! verify_zip_integrity "${build_dir}/${pkg_name}"; then
                log_error "Corrupted zip archive generated: $pkg_name"
                safe_rm_rf "$build_dir"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            fi

            if stage_package "${build_dir}/${pkg_name}" "$pkg_name" "antigravity-cli" "w64"; then
                UPDATED_COUNT=$((UPDATED_COUNT + 1))
            else
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        fi
    else
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        if [[ -n "$win_local_file" ]]; then
            purge_obsolete_packages "antigravity-cli" "w64" "$(basename "$win_local_file")"
        fi
    fi

    # Build Linux package
    if [[ "$build_lnx" == true ]]; then
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        local pkg_name="antigravity-cli-${cli_ver}-lnx.tar.xz"
        log_info "Processing Linux package: $pkg_name"
        if [[ "$DRY_RUN" == true ]]; then
            log_ok "[DRY-RUN] Would download: $lnx_url"
            log_ok "[DRY-RUN] Would extract and rename binary to antigravity-cli"
            log_ok "[DRY-RUN] Would create xz archive: $pkg_name"
            stage_package "" "$pkg_name" "antigravity-cli" "lnx"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
        else
            log_info "Downloading Linux CLI archive..."
            if ! download_asset "$lnx_url" "${build_dir}/cli_linux_x64.tar.gz" "$lnx_sha512" "sha512"; then
                safe_rm_rf "$build_dir"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            fi

            extract_archive "${build_dir}/cli_linux_x64.tar.gz" "$build_dir"
            if [[ -f "${build_dir}/antigravity" ]]; then
                mv "${build_dir}/antigravity" "${build_dir}/antigravity-cli"
            fi
            chmod 755 "${build_dir}/antigravity-cli"

            log_info "Recompressing binary to $pkg_name (xz -9)..."
            if ! recompress_folder_to_tar_xz "$build_dir" "antigravity-cli" "${build_dir}/${pkg_name}"; then
                safe_rm_rf "$build_dir"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            fi

            if stage_package "${build_dir}/${pkg_name}" "$pkg_name" "antigravity-cli" "lnx"; then
                UPDATED_COUNT=$((UPDATED_COUNT + 1))
            else
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        fi
    else
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        if [[ -n "$lnx_local_file" ]]; then
            purge_obsolete_packages "antigravity-cli" "lnx" "$(basename "$lnx_local_file")"
        fi
    fi

    if [[ -n "$build_dir" && -d "$build_dir" ]]; then
        safe_rm_rf "$build_dir"
    fi
}

# Unified packaging helper for Electron-based Antigravity applications (Agent, IDE)
# package_electron_component <display_name> <app_key> <releases_url> <win_url_template> <lnx_url_template> <raw_folder_name> <final_folder_name>
package_electron_component() {
    local display_name="$1"
    local app_key="$2"
    local releases_url="$3"
    local win_template="$4"
    local lnx_template="$5"
    local raw_folder_name="$6"
    local final_folder_name="$7"

    log_step "Checking ${display_name} (${app_key})..."

    local releases_json
    releases_json=$(curl -fsSL "$releases_url" 2>/dev/null || true)
    if [[ -z "$releases_json" ]]; then
        log_error "Failed to fetch ${display_name} releases from $releases_url"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    local app_ver exec_id
    app_ver=$(echo "$releases_json" | jq -r '.[0].version // empty')
    exec_id=$(echo "$releases_json" | jq -r '.[0].execution_id // empty')

    if [[ -z "$app_ver" || -z "$exec_id" ]]; then
        log_error "Could not parse latest version or execution_id for ${display_name}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    log_info "Remote latest version: ${C_BOLD}${app_ver}${C_RESET} (exec_id: ${exec_id})"

    local win_url="${win_template//__VER__/$app_ver}"
    win_url="${win_url//__EXEC__/$exec_id}"
    local lnx_url="${lnx_template//__VER__/$app_ver}"
    lnx_url="${lnx_url//__EXEC__/$exec_id}"

    # Check Windows package
    read -r win_local_ver win_local_file < <(find_local_version "$SOURCE_CYG" "$app_key" "w64")
    log_info "Local Windows version: ${win_local_ver} (${win_local_file:-none})"

    local build_win=false
    if [[ "$FORCE_REPACKAGE" == true ]] || is_version_newer "$app_ver" "$win_local_ver"; then
        build_win=true
    fi

    # Check Linux package
    read -r lnx_local_ver lnx_local_file < <(find_local_version "$SOURCE_CYG" "$app_key" "lnx")
    log_info "Local Linux version  : ${lnx_local_ver} (${lnx_local_file:-none})"

    local build_lnx=false
    if [[ "$FORCE_REPACKAGE" == true ]] || is_version_newer "$app_ver" "$lnx_local_ver"; then
        build_lnx=true
    fi

    if [[ "$build_win" == false && "$build_lnx" == false ]]; then
        log_info "${display_name} is up to date."
        if [[ -n "$win_local_file" ]]; then
            purge_obsolete_packages "$app_key" "w64" "$(basename "$win_local_file")"
        fi
        if [[ -n "$lnx_local_file" ]]; then
            purge_obsolete_packages "$app_key" "lnx" "$(basename "$lnx_local_file")"
        fi
        SKIPPED_COUNT=$((SKIPPED_COUNT + 2))
        return 0
    fi

    local build_dir=""
    if [[ "$DRY_RUN" == false ]]; then
        build_dir=$(mktemp -d "${EXEC_WORKSPACE}/${app_key}_XXXXXX")
    fi

    # Build Windows package
    if [[ "$build_win" == true ]]; then
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        local pkg_name="${app_key}-${app_ver}-w64.zip"
        local exe_name="${app_key}-${app_ver}-w64.exe"
        log_info "Processing Windows package: $pkg_name"
        if [[ "$DRY_RUN" == true ]]; then
            log_ok "[DRY-RUN] Would download: $win_url"
            log_ok "[DRY-RUN] Would rename binary to $exe_name"
            log_ok "[DRY-RUN] Would create zip: $pkg_name"
            stage_package "" "$pkg_name" "$app_key" "w64"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
        else
            log_info "Downloading Windows executable..."
            local raw_win_exe="${build_dir}/downloaded_raw.exe"
            if ! download_asset "$win_url" "$raw_win_exe"; then
                safe_rm_rf "$build_dir"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            fi

            mv "$raw_win_exe" "${build_dir}/${exe_name}"
            chmod 755 "${build_dir}/${exe_name}" 2>/dev/null || true

            log_info "Creating zip archive: $pkg_name..."
            (cd "$build_dir" && zip -q "$pkg_name" "$exe_name")
            if ! verify_zip_integrity "${build_dir}/${pkg_name}"; then
                log_error "Corrupted zip archive generated: $pkg_name"
                safe_rm_rf "$build_dir"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            fi

            if stage_package "${build_dir}/${pkg_name}" "$pkg_name" "$app_key" "w64"; then
                UPDATED_COUNT=$((UPDATED_COUNT + 1))
            else
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        fi
    else
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        if [[ -n "$win_local_file" ]]; then
            purge_obsolete_packages "$app_key" "w64" "$(basename "$win_local_file")"
        fi
    fi

    # Build Linux package
    if [[ "$build_lnx" == true ]]; then
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        local pkg_name="${app_key}-${app_ver}-lnx.tar.xz"
        log_info "Processing Linux package: $pkg_name"
        if [[ "$DRY_RUN" == true ]]; then
            log_ok "[DRY-RUN] Would download: $lnx_url"
            log_ok "[DRY-RUN] Would rename top folder to ${final_folder_name}/"
            log_ok "[DRY-RUN] Would prune root licenses and unused locales"
            log_ok "[DRY-RUN] Would recompress with xz -9: $pkg_name"
            stage_package "" "$pkg_name" "$app_key" "lnx"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
        else
            log_info "Downloading Linux tarball..."
            local raw_lnx_tar="${build_dir}/downloaded_raw.tar.gz"
            if ! download_asset "$lnx_url" "$raw_lnx_tar"; then
                safe_rm_rf "$build_dir"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            fi

            log_info "Extracting Linux tarball..."
            mkdir -p "${build_dir}/staging"
            extract_archive "$raw_lnx_tar" "${build_dir}/staging"

            # Rename top folder if needed
            if [[ -d "${build_dir}/staging/${raw_folder_name}" ]]; then
                mv "${build_dir}/staging/${raw_folder_name}" "${build_dir}/staging/${final_folder_name}"
            fi

            # Prune licenses from root
            prune_root_licenses "${build_dir}/staging/${final_folder_name}"

            # Prune locales (keep only en-US.pak)
            prune_electron_locales "${build_dir}/staging/${final_folder_name}/locales" "en-US.pak"

            log_info "Recompressing to $pkg_name (xz -9)..."
            if ! recompress_folder_to_tar_xz "${build_dir}/staging" "$final_folder_name" "${build_dir}/${pkg_name}"; then
                safe_rm_rf "$build_dir"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                return 1
            fi

            if stage_package "${build_dir}/${pkg_name}" "$pkg_name" "$app_key" "lnx"; then
                UPDATED_COUNT=$((UPDATED_COUNT + 1))
            else
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        fi
    else
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        if [[ -n "$lnx_local_file" ]]; then
            purge_obsolete_packages "$app_key" "lnx" "$(basename "$lnx_local_file")"
        fi
    fi

    if [[ -n "$build_dir" && -d "$build_dir" ]]; then
        safe_rm_rf "$build_dir"
    fi
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
        "antigravity"
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
        "antigravity-ide"
}

# ------------------------------------------------------------------------------
# Section 14: Main Processing Loop
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

echo ""
echo "=============================================================================="
echo " Packaging Summary"
echo "=============================================================================="
echo " Total packages targeted: $TOTAL_COUNT"
echo " Updated & Packaged     : $UPDATED_COUNT"
echo " Up to date (Skipped)   : $SKIPPED_COUNT"
echo " Errors / Warnings      : $ERROR_COUNT"
echo "=============================================================================="

if [[ $ERROR_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
