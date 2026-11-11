#!/usr/bin/env bash
# ==============================================================================
# craftapps_package.sh
#
# Check storytold GitHub releases for updates to craft applications (--action build)
# or install/deploy application binaries from archives to a target directory (--action deploy).
#
# When packaging (--action build):
#   1. Downloads Linux (x86_64 tar.gz/tar.xz) and Windows (x86_64 zip) binaries.
#   2. Prunes packaging artifacts (LICENSE*, *LICENCE*, NOTICE*, ATTRIBUTION*, OFL-*.txt).
#   3. Decompresses Linux archive, deletes artifacts, and recompresses to .tar.xz.
#   4. Repackages both archives directly into a combined zip: <app>-<ver>-<suffix>.zip.
#   5. Deletes the previous version from --source and replaces it with the new version.
#   6. Removes any prior version from --target and stages the new zip in --target.
#
# When deploying (--action deploy):
#   1. Resolves archives from local folder (--source) or remote URL.
#   2. Auto-detects target OS (Windows vs Linux) and extracts the platform package.
#   3. Deploys binaries directly (--flatten) or preserves archive subdirectories.
#   4. Excludes companion CLI binaries if requested (--no-cli).
#   5. Safely purges source archives upon successful deployment if requested (--purge-source).
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
#   7. Transactional Repackager & Atomic Stager (--action build):
#      Downloads to temp, verifies archive integrity (tar -tzf, unzip -tq),
#      prunes packaging/licensing artifacts in-place, decompresses Linux tar.gz,
#      prunes artifacts, recompresses with xz -9 to .tar.xz, bundles archives into
#      combined zip, verifies output, moves to source library, and atomically stages
#      to target pending directory via .tmp rename.
#   8. Extraction & Installation Engine (--action deploy):
#      Discovers packages from local folders or remote URLs, auto-detects host OS,
#      extracts binaries, strips base folder, deploys flattened (executables only)
#      or structured hierarchy, filters CLI tools (--no-cli), and purges source.
#
# DATA FLOW:
#   [CLI / Env] ──► Parse Args & Validate Mandatory --action <build|deploy>
#        │
#   [Action Dispatch]:
#        ├─► --action build:
#        │     ├─► Detect Auth Token ($GITHUB_TOKEN / gh CLI) & Temp Root
#        │     ├─► Create Isolated Workspace: craftapps_exec_XXXXXX
#        │     └─► [For each App in PACKAGES]:
#        │           ├─► Local Scan: Find current version in --source
#        │           ├─► Remote Query: Fetch latest release JSON from GitHub API
#        │           ├─► Compare Versions: If remote > local (or missing locally):
#        │           │     ├─► Download Linux tar.gz & Windows zip to Temp
#        │           │     ├─► Verify Download Integrity: tar -tzf & unzip -tq
#        │           │     ├─► Prune Artifacts (LICENSE*, NOTICE*, ATTRIBUTION*, OFL-*)
#        │           │     ├─► Decompress Linux tar.gz, prune artifacts, recompress to .tar.xz
#        │           │     ├─► Package cleaned archives into Combined Zip: zip -q
#        │           │     ├─► Verify Packaged Zip Integrity: unzip -tq
#        │           │     ├─► Update Source: Delete older versions, mv package to --source
#        │           │     ├─► Atomic Stage: Copy to --target as .tmp, chmod 644, mv -f
#        │           │     └─► Immediate Cleanup: safe_rm_rf app temp subfolder
#        │
#        └─► --action deploy:
#              ├─► Auto-detect Target OS (Windows vs Linux) & Temp Root
#              ├─► Create Temp Workspace: craftapps_deploy_XXXXXX
#              ├─► Locate Archive: Local folder (--source) or remote URL
#              ├─► Extract OS Archive (Windows zip or Linux tar.xz/tar.gz)
#              ├─► Strip Base Directory
#              ├─► Deploy to --deploy-target:
#              │     ├─► --flatten: executables only (*.exe / ELF scripts)
#              │     └─► Structured: all files preserving directory hierarchy
#              ├─► Exclude CLI binaries if --no-cli (*-cli.exe / *-cli)
#              ├─► Purge Source Archive if --purge-source (local folders only)
#              └─► Cleanup workspace on completion
# ==============================================================================

# Enable strict shell execution:
#   -e: Exit immediately if any command returns a non-zero exit code.
#   -o pipefail: Pipeline exit status reflects the rightmost non-zero exit command.
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
# Section 1: Default Settings & Execution State
# ------------------------------------------------------------------------------

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
#   ACTION          : Mandatory action mode ('build' or 'deploy').
#   DEPLOY_TARGET   : Path to deployment target installation directory.
#   FLATTEN         : When true, deploys only executable binaries directly into target (no subdirs).
#   NO_CLI          : When true, excludes companion CLI binaries from deployment.
#   PURGE_SOURCE    : When true, deletes source archive(s) upon successful deployment.
#   SOURCE_IS_URL   : Flags whether --source points to an HTTP/HTTPS URL.
#   DRY_RUN         : When true, inspects repositories and prints actions without disk modifications.
#   FORCE_REPACKAGE : When true, rebuilds and stages packages even if remote == local version.
#   UPDATE_SOURCE   : When true, removes old releases from --source and writes the new package there.
#   SPECIFIC_APP    : Filters processing to a single matching application name or repository.
#   LIST_APPS       : Exclusive mode flag to display the catalog table and exit immediately.
#   VERBOSE         : Displays extended diagnostic messages, asset lists, and HTTP details.
#   CONFIG_FILE     : Optional external package list to override or extend the internal table.
#   LOG_FILE        : Optional destination file for teeing standard output and errors.
ACTION=""
DEPLOY_TARGET=""
DEPLOY_TARGET_CYG=""
FLATTEN=false
NO_CLI=false
PURGE_SOURCE=false
SOURCE_IS_URL=false
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
# (Sections 2, 3, 4: Path Normalization, Defensive RM & Workspace Lifecycle
#  are provided by client_package_common.sh)
# ------------------------------------------------------------------------------

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
# (Terminal Formatting & Logging functions provided by client_package_common.sh)

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
    echo " To process an individual package: $(basename "$0") --action build --app <name> [--dry-run]"
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
Usage: $(basename "$0") --action <build|deploy> [OPTIONS]

Checks Storytold GitHub releases, packages multi-platform bundles,
or deploys application binaries directly to a target installation directory.

Actions (Mandatory):
  --action build          Monitor GitHub, download assets, clean artifacts,
                          convert Linux to .tar.xz, bundle, and stage packages.
  --action deploy         Deploy application binaries from local archives or a URL
                          directly to a target directory.

Common Options:
  --action <build|deploy> Action mode to execute (REQUIRED)
  --name, --app <name>    Process only a single specified app (e.g. --name figcraft)
  --source <path|url>     Source library or archive directory (or URL in deploy mode)
                          Build default: $DEFAULT_SOURCE
  --config <file>         Load package list from an external configuration file
  --log <file>            Save execution log output to specified file
  --list-apps             Display configured applications by category in a table
  --verbose               Show detailed debug messages and asset lists
  -h, --help              Show this help message and exit

Build Action Options (--action build):
  --target <path>         Path to upload staging directory (default: $DEFAULT_TARGET)
  --org <name>            GitHub organization name (default: $DEFAULT_ORG)
  --token <token>         GitHub Personal Access Token (can also use GITHUB_TOKEN env var)
  --force                 Force download and repackage even if local version is up-to-date
  --no-update-source      Do not update or delete files in --source (only write to --target)
  --dry-run               Check releases and show what would be done without modifying files

Deploy Action Options (--action deploy):
  --deploy-target <path>  Target installation directory (REQUIRED for deploy)
  --flatten               Deploy only executable binaries directly into target (no subdirs)
  --no-cli                Do not deploy companion CLI binaries (e.g. *-cli.exe or *-cli)
  --purge-source          Remove source archive(s) after successful deployment (folders only)

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
# (is_version_newer is provided by client_package_common.sh)

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
          select(.name | test("[.]tar[.](gz|xz)$"; "i")) |
          select(.name | test("source|src|debug|symbols"; "i") | not)
        ] | first // empty | "\(.name)\t\(.browser_download_url)"
    ')
    win_info=$(echo "$json" | jq -r '
        [ .assets[]? |
          select(.name | test("win"; "i")) |
          select(.name | test("x86_64|amd64|x64"; "i")) |
          select(.name | test("[.]zip$"; "i")) |
          select(.name | test("web|source|src|debug|symbols"; "i") | not)
        ] | first // empty | "\(.name)\t\(.browser_download_url)"
    ')
    printf '%s\n%s\n' "$linux_info" "$win_info"
}

# ------------------------------------------------------------------------------
# Section 8b: Artifact Cleanup & Recompression Engine
# ------------------------------------------------------------------------------
# (is_artifact_file and clean_zip_artifacts are provided by client_package_common.sh)

# clean_and_recompress_linux_archive <archive_path>
# Decompresses Linux tar.gz or tar.xz, removes matching artifacts (e.g. in root
# or share/doc/<app>), and recompresses using xz -9, producing <archive>.tar.xz.
# Outputs the new archive filename to standard output.
clean_and_recompress_linux_archive() {
    local archive_path="$1"
    [[ -f "$archive_path" ]] || return 1

    local dir
    dir=$(dirname "$archive_path")
    local fname
    fname=$(basename "$archive_path")

    local tar_file=""
    if [[ "$fname" =~ \.tar\.gz$ ]]; then
        log_info "Decompressing gzip archive: $fname..." >&2
        gzip -d -f "$archive_path"
        tar_file="${dir}/${fname%.gz}"
    elif [[ "$fname" =~ \.tar\.xz$ ]]; then
        log_info "Decompressing xz archive: $fname..." >&2
        xz -d -f "$archive_path"
        tar_file="${dir}/${fname%.xz}"
    elif [[ "$fname" =~ \.tar$ ]]; then
        tar_file="$archive_path"
    else
        echo "$fname"
        return 0
    fi

    if [[ ! -f "$tar_file" ]]; then
        log_error "Failed to produce uncompressed tar file: $tar_file" >&2
        return 1
    fi

    # Inspect tar members for artifacts
    local tar_entries_to_remove=()
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        local base="${entry##*/}"
        if is_artifact_file "$base"; then
            tar_entries_to_remove+=("$entry")
        fi
    done < <(tar --force-local -tf "$tar_file" 2>/dev/null || true)

    if [[ ${#tar_entries_to_remove[@]} -gt 0 ]]; then
        log_info "Removing ${#tar_entries_to_remove[@]} artifact file(s) from $(basename "$tar_file")..." >&2
        tar --force-local --delete -f "$tar_file" "${tar_entries_to_remove[@]}" 2>/dev/null || true
    else
        log_info "No matching artifact files found in $(basename "$tar_file")." >&2
    fi

    # Recompress with xz -9
    log_info "Compressing tar to xz: $(basename "$tar_file").xz..." >&2
    xz -9 -f "$tar_file"
    local xz_file="${tar_file}.xz"

    if [[ ! -f "$xz_file" ]]; then
        log_error "Failed to recompress tar to xz: $xz_file" >&2
        return 1
    fi

    echo "$(basename "$xz_file")"
}

# ------------------------------------------------------------------------------
# Section 8c: Application Deployment Pipeline (--action deploy)
# ------------------------------------------------------------------------------
# run_deploy_pipeline
# Executes the install and deploy workflow:
#   1. Validates deploy target directory.
#   2. Auto-detects target OS (Windows vs Linux).
#   3. Discovers packages from local directory or remote URL.
#   4. Extracts platform-specific archive from combined or standalone packages.
#   5. Deploys binaries directly (--flatten) or preserves archive subdirectories.
#   6. Excludes companion CLI binaries if requested (--no-cli).
#   7. Purges source archives if requested and deployment succeeded (--purge-source).
run_deploy_pipeline() {
    log_step "Starting Craft Apps Deployment..."

    # Ensure deployment target directory exists
    DEPLOY_TARGET_CYG=$(to_cygpath "$DEPLOY_TARGET")
    if [[ ! -d "$DEPLOY_TARGET_CYG" ]]; then
        log_info "Creating deployment target directory: $(enforce_drive_path "$DEPLOY_TARGET_CYG")"
        if ! mkdir -p "$DEPLOY_TARGET_CYG"; then
            log_error "Failed to create deployment target directory: $DEPLOY_TARGET"
            return 1
        fi
    fi

    # Determine target operating system
    local target_os
    target_os=$(get_target_os)
    log_info "Target platform : $PLATFORM (OS: $target_os)"
    log_info "Deploy target   : $(enforce_drive_path "$DEPLOY_TARGET_CYG")"
    log_info "Flatten mode    : $FLATTEN"
    log_info "Exclude CLI     : $NO_CLI"
    log_info "Purge source    : $PURGE_SOURCE"

    # Validate source directory early if local path
    if [[ "$SOURCE_IS_URL" == false ]]; then
        local source_test_cyg
        source_test_cyg=$(to_cygpath "$SOURCE_PATH")
        if [[ ! -d "$source_test_cyg" ]]; then
            log_error "Source directory not found: $SOURCE_PATH ($source_test_cyg)"
            return 1
        fi
        if [[ "$PURGE_SOURCE" == true && "$source_test_cyg" == "$DEPLOY_TARGET_CYG" ]]; then
            log_error "--deploy-target cannot be identical to --source when --purge-source is active."
            return 1
        fi
    fi

    # Execution Workspace
    EXEC_WORKSPACE=$(mktemp -d "${TEMP_ROOT_CYG}/craftapps_deploy_XXXXXX")
    if [[ -z "$EXEC_WORKSPACE" || ! -d "$EXEC_WORKSPACE" ]]; then
        log_error "Failed to create deployment execution workspace in $TEMP_ROOT_PATH"
        return 1
    fi
    log_info "Deployment workspace initialized: $(enforce_drive_path "$EXEC_WORKSPACE")"

    local total_checked=0
    local deployed_count=0
    local skipped_count=0
    local error_count=0

    # If source is URL, fetch directory index
    local url_index_html=""
    if [[ "$SOURCE_IS_URL" == true ]]; then
        log_info "Fetching remote directory index from $SOURCE_PATH..."
        url_index_html=$(curl -sSL --connect-timeout 10 --max-time 30 "$SOURCE_PATH" 2>/dev/null || true)
        if [[ -z "$url_index_html" ]]; then
            log_error "Failed to retrieve directory index from URL: $SOURCE_PATH"
            return 1
        fi
    fi

    for entry in "${PACKAGES[@]}"; do
        [[ -z "$entry" || "$entry" =~ ^[[:space:]]*# ]] && continue
        read -r rel_dir app_name suffix repo <<< "$entry"
        suffix="${suffix:-win-lnx}"
        repo="${repo:-$app_name}"

        # Filter by specific application if --name / --app was requested
        if [[ -n "$SPECIFIC_APP" && "$app_name" != "$SPECIFIC_APP" && "$repo" != "$SPECIFIC_APP" ]]; then
            continue
        fi

        total_checked=$((total_checked + 1))
        echo ""
        log_step "Deploying [$app_name]..."

        CURRENT_BUILD_DIR=$(mktemp -d "${EXEC_WORKSPACE}/${app_name}_XXXXXX")

        local archive_file=""
        local archive_to_purge=""

        if [[ "$SOURCE_IS_URL" == true ]]; then
            # Find matching zip in remote HTML index with delimiter boundary
            local remote_filename
            remote_filename=$(echo "$url_index_html" | grep -o -i -E "(^|[\"'/>< ])(${app_name}-[0-9][^\"'<> ]*\.zip)" | sed -E "s|^[\"'/>< ]||" | sort -V | tail -n1)
            if [[ -z "$remote_filename" ]]; then
                log_warn "No archive found at URL for $app_name."
                skipped_count=$((skipped_count + 1))
                safe_rm_rf "$CURRENT_BUILD_DIR"
                CURRENT_BUILD_DIR=""
                continue
            fi

            local download_url="${SOURCE_PATH%/}/${remote_filename}"
            log_info "Downloading $remote_filename from $download_url..."
            if ! curl -f -sSL --retry 3 --retry-delay 2 -o "${CURRENT_BUILD_DIR}/${remote_filename}" "$download_url"; then
                log_error "Failed to download $download_url"
                error_count=$((error_count + 1))
                safe_rm_rf "$CURRENT_BUILD_DIR"
                CURRENT_BUILD_DIR=""
                continue
            fi
            archive_file="${CURRENT_BUILD_DIR}/${remote_filename}"
        else
            # Flat directory lookup in source folder
            local source_cyg
            source_cyg=$(to_cygpath "$SOURCE_PATH")
            shopt -s nullglob
            local candidate_files=("${source_cyg}/${app_name}-"*.zip)
            shopt -u nullglob

            # Fallback to category path if flat lookup had no matches
            if [[ ${#candidate_files[@]} -eq 0 && -d "${source_cyg}/${rel_dir}" ]]; then
                shopt -s nullglob
                candidate_files=("${source_cyg}/${rel_dir}/${app_name}-"*.zip)
                shopt -u nullglob
            fi

            if [[ ${#candidate_files[@]} -eq 0 ]]; then
                log_warn "No archive found in source for $app_name."
                skipped_count=$((skipped_count + 1))
                safe_rm_rf "$CURRENT_BUILD_DIR"
                CURRENT_BUILD_DIR=""
                continue
            fi

            # Select latest version
            local best_file=""
            local best_ver="none"
            for cf in "${candidate_files[@]}"; do
                local bname
                bname=$(basename "$cf")
                if [[ "$bname" =~ ^${app_name}-([0-9]+(\.[0-9]+)*([a-zA-Z0-9._-]*))(\.zip|-) ]]; then
                    local ver="${BASH_REMATCH[1]}"
                    if [[ "$best_ver" == "none" ]] || is_version_newer "$ver" "$best_ver"; then
                        best_ver="$ver"
                        best_file="$cf"
                    fi
                elif [[ -z "$best_file" ]]; then
                    best_file="$cf"
                fi
            done

            archive_file="$best_file"
            archive_to_purge="$best_file"
            log_info "Located source archive: $(enforce_drive_path "$archive_file")"
        fi

        # Determine if archive_file is a combined zip or platform package
        local platform_pkg=""
        local inner_files=()
        while IFS= read -r l || [[ -n "$l" ]]; do
            [[ -n "$l" ]] && inner_files+=("$l")
        done < <(unzip -Z1 "$archive_file" 2>/dev/null || true)

        if [[ "$target_os" == "windows" ]]; then
            local win_inner=""
            for inf in "${inner_files[@]}"; do
                local inf_lower="${inf,,}"
                if [[ "$inf_lower" =~ (win|windows).*\.zip$ ]]; then
                    win_inner="$inf"
                    break
                fi
            done
            if [[ -n "$win_inner" ]]; then
                log_info "Extracting inner Windows archive: $win_inner..."
                unzip -q -j "$archive_file" "$win_inner" -d "$CURRENT_BUILD_DIR"
                platform_pkg="${CURRENT_BUILD_DIR}/$(basename "$win_inner")"
            else
                platform_pkg="$archive_file"
            fi
        else
            local lnx_inner=""
            for inf in "${inner_files[@]}"; do
                local inf_lower="${inf,,}"
                if [[ "$inf_lower" =~ (linux|lnx).*\.tar\.(xz|gz)$ ]]; then
                    lnx_inner="$inf"
                    break
                fi
            done
            if [[ -n "$lnx_inner" ]]; then
                log_info "Extracting inner Linux archive: $lnx_inner..."
                unzip -q -j "$archive_file" "$lnx_inner" -d "$CURRENT_BUILD_DIR"
                platform_pkg="${CURRENT_BUILD_DIR}/$(basename "$lnx_inner")"
            else
                platform_pkg="$archive_file"
            fi
        fi

        if [[ -z "$platform_pkg" || ! -f "$platform_pkg" ]]; then
            log_error "Could not resolve platform archive for $app_name ($target_os)"
            error_count=$((error_count + 1))
            safe_rm_rf "$CURRENT_BUILD_DIR"
            CURRENT_BUILD_DIR=""
            continue
        fi

        # Extract platform archive into staging directory
        local extract_dir="${CURRENT_BUILD_DIR}/extracted"
        mkdir -p "$extract_dir"

        if ! extract_archive "$platform_pkg" "$extract_dir"; then
            log_error "Failed to unpack platform archive: $(basename "$platform_pkg")"
            error_count=$((error_count + 1))
            safe_rm_rf "$CURRENT_BUILD_DIR"
            CURRENT_BUILD_DIR=""
            continue
        fi

        # Detect single base directory to strip
        local content_root="$extract_dir"
        shopt -s nullglob
        local top_items=("${extract_dir}"/*)
        shopt -u nullglob
        if [[ ${#top_items[@]} -eq 1 && -d "${top_items[0]}" ]]; then
            content_root="${top_items[0]}"
            log_info "Stripping base folder: $(basename "$content_root")"
        fi

        # Perform deployment
        local deploy_success=false
        if [[ "$FLATTEN" == true ]]; then
            log_info "Deploying binaries in flattened mode..."
            local deployed_bins=0
            if [[ "$target_os" == "windows" ]]; then
                while IFS= read -r -d '' exe_file; do
                    local bname
                    bname=$(basename "$exe_file")
                    local bname_lower="${bname,,}"
                    if [[ "$NO_CLI" == true && ( "$bname_lower" == *-cli.exe || "$bname_lower" == *-cli ) ]]; then
                        log_info "Excluding CLI binary (--no-cli): $bname"
                        continue
                    fi
                    cp -f "$exe_file" "${DEPLOY_TARGET_CYG}/${bname}"
                    chmod 755 "${DEPLOY_TARGET_CYG}/${bname}" 2>/dev/null || true
                    deployed_bins=$((deployed_bins + 1))
                done < <(find "$content_root" -type f -iname "*.exe" -print0)
            else
                while IFS= read -r -d '' bin_file; do
                    local bname
                    bname=$(basename "$bin_file")
                    local bname_lower="${bname,,}"
                    # Exclude shared libraries in flatten mode
                    if [[ "$bname_lower" =~ \.so(\.[0-9]+)*$ ]]; then
                        continue
                    fi
                    if [[ "$NO_CLI" == true && ( "$bname_lower" == *-cli.exe || "$bname_lower" == *-cli ) ]]; then
                        log_info "Excluding CLI binary (--no-cli): $bname"
                        continue
                    fi
                    if [[ -x "$bin_file" ]] || file "$bin_file" 2>/dev/null | grep -qi "elf"; then
                        cp -f "$bin_file" "${DEPLOY_TARGET_CYG}/${bname}"
                        chmod 755 "${DEPLOY_TARGET_CYG}/${bname}" 2>/dev/null || true
                        deployed_bins=$((deployed_bins + 1))
                    fi
                done < <(find "$content_root" -type f -print0)
            fi

            if [[ $deployed_bins -gt 0 ]]; then
                deploy_success=true
                log_ok "Deployed $deployed_bins binary file(s) for $app_name."
            else
                log_warn "No matching binary files found to deploy for $app_name."
            fi
        else
            # Non-flattened deployment: copy all files preserving structure, excluding CLI if --no-cli
            if [[ "$NO_CLI" == true ]]; then
                log_info "Removing CLI binaries before deployment (--no-cli)..."
                find "$content_root" -type f \( -iname "*-cli.exe" -o -name "*-cli" \) -exec rm -f {} + 2>/dev/null || true
            fi
            log_info "Deploying archive contents to $(enforce_drive_path "$DEPLOY_TARGET_CYG")..."
            cp -rf "$content_root"/. "$DEPLOY_TARGET_CYG/"
            chmod -R a+rX "$DEPLOY_TARGET_CYG" 2>/dev/null || true
            deploy_success=true
            log_ok "Deployed contents for $app_name."
        fi

        # Purge source if requested and deployment succeeded
        if [[ "$deploy_success" == true ]]; then
            deployed_count=$((deployed_count + 1))
            if [[ "$PURGE_SOURCE" == true ]]; then
                if [[ "$SOURCE_IS_URL" == true ]]; then
                    log_info "--purge-source skipped: remote URL source cannot be purged."
                elif [[ -n "$archive_to_purge" && -f "$archive_to_purge" ]]; then
                    log_info "Purging source archive: $(enforce_drive_path "$archive_to_purge")"
                    safe_rm_f "$archive_to_purge"
                fi
            fi
        else
            error_count=$((error_count + 1))
        fi

        # Clean app temp directory
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
    done

    # Clean execution workspace
    if [[ -n "$EXEC_WORKSPACE" ]]; then
        safe_rm_rf "$EXEC_WORKSPACE"
        EXEC_WORKSPACE=""
    fi

    echo ""
    echo "=============================================================================="
    echo " Deployment Summary"
    echo "=============================================================================="
    echo " Action                 : deploy"
    echo " Target OS              : $target_os ($PLATFORM)"
    echo " Deploy Target          : $(enforce_drive_path "$DEPLOY_TARGET_CYG")"
    echo " Total packages checked : $total_checked"
    echo " Deployed successfully  : $deployed_count"
    echo " Skipped / Not found    : $skipped_count"
    echo " Errors                 : $error_count"
    echo "=============================================================================="

    if [[ $error_count -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Section 9: CLI Argument Parsing & Early Dispatchers
# ------------------------------------------------------------------------------
# Process command-line flags and parameters.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --action)
            ACTION="$2"
            shift 2
            ;;
        --source)
            if [[ "$2" =~ ^https?:// ]]; then
                SOURCE_PATH="$2"
                SOURCE_IS_URL=true
            else
                SOURCE_PATH=$(enforce_drive_path "$2")
                SOURCE_IS_URL=false
            fi
            shift 2
            ;;
        --target)
            TARGET_PATH=$(enforce_drive_path "$2")
            shift 2
            ;;
        --deploy-target)
            DEPLOY_TARGET=$(enforce_drive_path "$2")
            shift 2
            ;;
        --flatten)
            FLATTEN=true
            shift
            ;;
        --no-cli)
            NO_CLI=true
            shift
            ;;
        --purge-source)
            PURGE_SOURCE=true
            shift
            ;;
        --org)
            GITHUB_ORG="$2"
            shift 2
            ;;
        --token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        --name|--app)
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
# Action Mode Validation (Mandatory: --action build or --action deploy)
# ------------------------------------------------------------------------------
if [[ -z "$ACTION" ]]; then
    log_error "Missing mandatory option: --action <build|deploy>"
    echo "Run '$(basename "$0") --help' for usage." >&2
    exit 1
fi

case "$ACTION" in
    build|deploy)
        ;;
    *)
        log_error "Invalid action '$ACTION'. Must be 'build' or 'deploy'."
        echo "Run '$(basename "$0") --help' for usage." >&2
        exit 1
        ;;
esac

# Validate deploy mode requirements
if [[ "$ACTION" == "deploy" ]]; then
    if [[ -z "$DEPLOY_TARGET" ]]; then
        log_error "Option --deploy-target <path> is required when --action is deploy."
        exit 1
    fi
    if [[ -z "$SOURCE_PATH" ]]; then
        log_error "Option --source <path|url> is required when --action is deploy."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Prerequisite Verification (Ensures required tools are present)
# Checks for curl (HTTP), zip & unzip (archive packaging), jq (JSON parser),
# tar, gzip, and xz (Linux archive compression and verification).
# ------------------------------------------------------------------------------
for tool in curl zip unzip jq tar gzip xz; do
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
if [[ "$SOURCE_IS_URL" == false ]]; then
    SOURCE_PATH=$(enforce_drive_path "$SOURCE_PATH")
    SOURCE_CYG=$(to_cygpath "$SOURCE_PATH")
else
    SOURCE_CYG="$SOURCE_PATH"
fi
TARGET_PATH=$(enforce_drive_path "$TARGET_PATH")
TARGET_CYG=$(to_cygpath "$TARGET_PATH")

if [[ -n "$DEPLOY_TARGET" ]]; then
    DEPLOY_TARGET=$(enforce_drive_path "$DEPLOY_TARGET")
    DEPLOY_TARGET_CYG=$(to_cygpath "$DEPLOY_TARGET")
fi

# Automatically detect the root of the temp folder (TMP -> TEMP -> TMPDIR -> /tmp)
TEMP_ROOT_CYG=$(detect_temp_root)
TEMP_ROOT_PATH=$(enforce_drive_path "$TEMP_ROOT_CYG")

# Setup optional file logging (tee all stdout/stderr to specified log file)
if [[ -n "$LOG_FILE" ]]; then
    LOG_CYG=$(to_cygpath "$LOG_FILE")
    mkdir -p "$(dirname "$LOG_CYG")"
    exec > >(tee -a "$LOG_CYG") 2>&1
fi

echo "=============================================================================="
echo " Storytold Craft Apps Packaging & Deployment Utility"
echo "=============================================================================="
echo " Action         : $ACTION"
echo " Platform       : $PLATFORM"
if [[ "$ACTION" == "build" ]]; then
    echo " Source Library : $SOURCE_PATH"
    echo " Target Pending : $TARGET_PATH"
    echo " Organization   : https://github.com/$GITHUB_ORG/"
    if [[ -n "$GITHUB_TOKEN" ]]; then
        echo " GitHub Auth    : Authenticated (API token active)"
    else
        echo " GitHub Auth    : Unauthenticated (60 req/hr rate limit)"
    fi
    echo " Dry Run        : $DRY_RUN"
    echo " Force Repack   : $FORCE_REPACKAGE"
    echo " Update Source  : $UPDATE_SOURCE"
else
    echo " Source Archives: $SOURCE_PATH"
    echo " Deploy Target  : $DEPLOY_TARGET"
    echo " Flatten        : $FLATTEN"
    echo " Exclude CLI    : $NO_CLI"
    echo " Purge Source   : $PURGE_SOURCE"
fi
echo " Temp Root Dir  : $TEMP_ROOT_PATH"
if [[ -n "$LOG_FILE" ]]; then
    echo " Log File       : $LOG_FILE"
fi
if [[ -n "$SPECIFIC_APP" ]]; then
    echo " Filter App     : $SPECIFIC_APP"
fi
echo "=============================================================================="

# If running deployment, execute deploy pipeline and terminate
if [[ "$ACTION" == "deploy" ]]; then
    run_deploy_pipeline
    exit $?
fi

# Ensure directories exist and initialize unique execution workspace for build
if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$TARGET_CYG"
    if [[ "$UPDATE_SOURCE" == true ]]; then
        mkdir -p "$SOURCE_CYG"
    fi
    mkdir -p "$TEMP_ROOT_CYG"

    # Prune any stale craftapps temporary workspaces older than 1 day
    if [[ -d "$TEMP_ROOT_CYG" && "$TEMP_ROOT_CYG" != "/" && ! "$TEMP_ROOT_CYG" =~ ^(/cygdrive/|/mnt/|/)[a-zA-Z]$ ]]; then
        find "$TEMP_ROOT_CYG" -maxdepth 1 -type d -name "craftapps_exec_*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
        find "$TEMP_ROOT_CYG" -maxdepth 1 -type d -name "craftapps_deploy_*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
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
        log_ok "[DRY-RUN] Would prune artifact files (LICENSE*, NOTICE*, etc.) from $win_name"
        log_ok "[DRY-RUN] Would prune artifacts from $linux_name and recompress to .tar.xz"
        log_ok "[DRY-RUN] Would package both into $NEW_ZIP_NAME in tmp"
        log_ok "[DRY-RUN] Would verify package integrity in tmp"
        local_target_dir=""
        if [[ "$UPDATE_SOURCE" == true ]]; then
            local_target_dir="${SOURCE_CYG}/${rel_dir}"
        fi
        atomic_stage_package "" "$NEW_ZIP_NAME" "$app_name" "$suffix" "$local_target_dir" "$TARGET_CYG" true
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
    if ! download_asset "$linux_url" "${CURRENT_BUILD_DIR}/${linux_name}"; then
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5b: Verify Linux asset integrity in tmp (tar -tzf or tar -tJf)
    log_info "Verifying Linux archive integrity in tmp..."
    lnx_ok=false
    if [[ "$linux_name" =~ \.tar\.xz$ ]]; then
        verify_tar_xz_integrity "${CURRENT_BUILD_DIR}/${linux_name}" && lnx_ok=true
    else
        tar --force-local -tzf "${CURRENT_BUILD_DIR}/${linux_name}" >/dev/null 2>&1 && lnx_ok=true
    fi
    if [[ "$lnx_ok" == false ]]; then
        log_error "Corrupted or invalid Linux archive downloaded: $linux_name"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5c: Download Windows asset to tmp
    log_info "Downloading Windows asset to tmp: $win_name..."
    if ! download_asset "$win_url" "${CURRENT_BUILD_DIR}/${win_name}"; then
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5d: Verify Windows asset integrity in tmp (unzip -tq)
    log_info "Verifying Windows archive integrity in tmp..."
    if ! verify_zip_integrity "${CURRENT_BUILD_DIR}/${win_name}"; then
        log_error "Corrupted or invalid Windows zip archive downloaded: $win_name"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5e: Prune Packaging Artifacts & Recompress Linux tarball to xz
    log_step "Cleaning artifact files and converting Linux archive to xz for $app_name..."

    # Prune artifacts from Windows zip directly
    clean_zip_artifacts "${CURRENT_BUILD_DIR}/${win_name}"
    if ! verify_zip_integrity "${CURRENT_BUILD_DIR}/${win_name}"; then
        log_error "Windows zip failed integrity check after artifact cleanup: $win_name"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Decompress Linux archive, delete matching artifacts, and recompress to .tar.xz
    cleaned_linux_name=$(clean_and_recompress_linux_archive "${CURRENT_BUILD_DIR}/${linux_name}")
    if [[ -z "$cleaned_linux_name" || ! -s "${CURRENT_BUILD_DIR}/${cleaned_linux_name}" ]] || ! verify_tar_xz_integrity "${CURRENT_BUILD_DIR}/${cleaned_linux_name}"; then
        log_error "Linux xz archive failed integrity check after recompression: $cleaned_linux_name"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    linux_name="$cleaned_linux_name"

    # Step 5f: Repackage combined zip in tmp
    # Packages the Linux tar.xz and Windows zip together into <app>-<ver>-<suffix>.zip.
    log_info "Packaging archives into $NEW_ZIP_NAME in tmp..."
    if ! (cd "$CURRENT_BUILD_DIR" && zip -q "$NEW_ZIP_NAME" "$linux_name" "$win_name"); then
        log_error "Failed to create repackaged zip in tmp: $NEW_ZIP_NAME"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 5g: Verify repackaged zip integrity in tmp (unzip -tq & non-empty check)
    log_info "Verifying repackaged zip integrity in tmp..."
    if [[ ! -s "${CURRENT_BUILD_DIR}/${NEW_ZIP_NAME}" ]] || ! verify_zip_integrity "${CURRENT_BUILD_DIR}/${NEW_ZIP_NAME}"; then
        log_error "Repackaged zip failed integrity verification in tmp: ${NEW_ZIP_NAME}"
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 6 & 7: Transactional Staging to Source Library & Target Directory
    local_target_dir=""
    if [[ "$UPDATE_SOURCE" == true ]]; then
        local_target_dir="${SOURCE_CYG}/${rel_dir}"
    fi

    if ! atomic_stage_package "${CURRENT_BUILD_DIR}/${NEW_ZIP_NAME}" "$NEW_ZIP_NAME" "$app_name" "$suffix" "$local_target_dir" "$TARGET_CYG" "$DRY_RUN"; then
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
