#!/usr/bin/env bash
# ==============================================================================
# citools_package.sh
#
# Automated discovery, normalized packaging, and cross-platform deployment utility
# for CI/DevSecOps CLI tools and Java code analyzers targeting:
#   - Windows x86_64 (MSVC / 64-bit) -> normalized .zip  (<tool>-<ver>-w64.zip)
#   - Linux x86_64   (amd64)          -> normalized .tar.xz (<tool>-<ver>-lnx.tar.xz)
#                                        plus upstream .deb / .rpm when available
#   - Combined bundles in repository  -> <tool>-<ver>-win-lnx.zip / <tool>-<ver>-java.zip
#
# Actions:
#   1. --list     Display configured tools, classes, and local versions (offline).
#   2. --detect   Query GitHub releases vs local library; show upgrades and all
#                 already-packaged versions grouped by tool class.
#   3. --package  Download new/forced releases, verify SHA-256 checksums,
#                 normalize assets, bundle into <tool>-<ver>-<suffix>.zip,
#                 atomically update --source, and stage to --target.
#   4. --deploy   Deploy tools from --source to a common folder
#                 (default: d:\dev\ci-tools on Windows, /u01/tools on Linux).
#
# Designed for MSYS2 / Git Bash, Cygwin, WSL, and native Linux environments.
# ==============================================================================

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
# Section 1: Default Settings & Execution State
# ------------------------------------------------------------------------------
DEFAULT_SOURCE="$(resolve_default_path "n" "softlib/software/public")"
DEFAULT_TARGET="$(resolve_default_path "f" "stage/upload/pending")"
if is_windows_platform; then
    DEFAULT_DEPLOY="d:/dev/ci-tools"
else
    DEFAULT_DEPLOY="/u01/tools"
fi

SOURCE_PATH="$DEFAULT_SOURCE"
TARGET_PATH="$DEFAULT_TARGET"
DEPLOY_TARGET="$DEFAULT_DEPLOY"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$GITHUB_TOKEN" ]] && command -v gh > /dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2> /dev/null || true)
fi

ACTION=""
FILTER_TOOL=""
FILTER_CLASS=""
DRY_RUN=false
FORCE_REPACKAGE=false
UPDATE_SOURCE=true
FLATTEN_SOURCE=false
VERBOSE=false
LOG_FILE=""

SOURCE_CYG=""
TARGET_CYG=""
DEPLOY_TARGET_CYG=""
TEMP_ROOT_CYG=""
TEMP_ROOT_PATH=""
EXEC_WORKSPACE=""
CURRENT_BUILD_DIR=""
CURRENT_TARGET_TMP=""

# ------------------------------------------------------------------------------
# Section 2: Tool Catalog Definition (Grouped by Class)
# ------------------------------------------------------------------------------
# Schema (semicolon-delimited):
#   CLASS_ID;TOOL_KEY;REL_DIR;GH_REPO;TAG_PREFIX;OUT_SUFFIX;LOCAL_REGEX;DEPLOY_MODE;DEPLOY_SUBDIR;BINS
#
#   CLASS_ID     : Category ID mapped via get_class_label()
#   TOOL_KEY     : Canonical tool identifier & normalized bundle base name
#   REL_DIR      : Category subdirectory relative to --source
#   GH_REPO      : Upstream owner/repo on GitHub
#   TAG_PREFIX   : Optional tag filter prefix (monorepos / custom release tags)
#   OUT_SUFFIX   : Normalized outer zip suffix ("win-lnx" or "java")
#   LOCAL_REGEX  : Accepted suffixes when locating/purging local archives
#                  (Note: docker-compose & kompose intentionally exclude '-lnx'
#                   so custom *-lnx.zip RPM/spec bundles remain untouched)
#   DEPLOY_MODE  : flat | dir | jar
#   DEPLOY_SUBDIR: Folder name under --deploy-target ('dir') or jar name ('jar')
#   BINS         : Canonical binary / jar identifier(s)
PACKAGES=(
    # Python Tooling
    "python;uv;devel/python/tools;astral-sh/uv;;win-lnx;win-lnx|lnx-win;flat;;uv,uvx,uvw"
    "python;ruff;devel/python/tools;astral-sh/ruff;;win-lnx;win-lnx|lnx-win;flat;;ruff"

    # JS / Web Linters & Formatters
    "js;biome;devel/nodejs/linters;biomejs/biome;@biomejs/biome@;win-lnx;win-lnx|lnx-win;flat;;biome"
    "js;oxfmt;devel/nodejs/linters;oxc-project/oxc;oxfmt_v;win-lnx;win-lnx|lnx-win;flat;;oxfmt"
    "js;oxlint;devel/nodejs/linters;oxc-project/oxc;oxlint_v;win-lnx;win-lnx|lnx-win;flat;;oxlint"
    "js;dart-sass;devel/js;sass/dart-sass;;win-lnx;win-lnx|lnx-win;dir;dart-sass;sass"

    # Code Search & Static Sites
    "devtools;astgrep;devel/regexp;ast-grep/ast-grep;;win-lnx;win-lnx|lnx-win;flat;;ast-grep,sg"
    "devtools;hugo;devel/html/generators;gohugoio/hugo;;win-lnx;win-lnx|lnx-win;flat;;hugo"

    # Build Systems & SCM
    "build_scm;bazel;devel/setup/build;bazelbuild/bazel;;win-lnx;win-lnx|lnx-win;flat;;bazel"
    "build_scm;gh;devel/setup/scm/git;cli/cli;;win-lnx;win-lnx|lnx-w64;flat;;gh"

    # Java Code Analyzers
    "java;checkstyle;devel/java/profiler;checkstyle/checkstyle;checkstyle-;java;java;jar;checkstyle.jar;checkstyle"
    "java;pmd-codeanalyzer;devel/java/profiler;pmd/pmd;pmd_releases/;java;java;dir;pmd;pmd"
    "java;spotbugs;devel/java/profiler;spotbugs/spotbugs;;java;java;dir;spotbugs;spotbugs"

    # Containers & Kubernetes
    "containers;docker-compose;system/admin/virtualization/docker-lxc;docker/compose;;win-lnx;win-lnx|bin|lnx-win;flat;;docker-compose"
    "containers;kompose;system/admin/virtualization/docker-lxc;kubernetes/kompose;;win-lnx;win-lnx|bin|lnx-win;flat;;kompose"

    # Security, Signing & Vulnerability Scanners
    "security;cosign;system/secure/crypto/codesign;sigstore/cosign;;win-lnx;win-lnx|lnx-win;flat;;cosign"
    "security;grype;net/netadmin/security/penetration;anchore/grype;;win-lnx;win-lnx;flat;;grype"
    "security;syft;net/netadmin/security/penetration;anchore/syft;;win-lnx;win-lnx;flat;;syft"
    "security;trivy;system/secure/vulnscan;aquasecurity/trivy;;win-lnx;win-lnx;flat;;trivy"
    "security;trufflehog;system/secure/vulnscan;trufflesecurity/trufflehog;;win-lnx;win-lnx;flat;;trufflehog"
)

CLASS_ORDER=(
    "python"
    "js"
    "devtools"
    "build_scm"
    "java"
    "containers"
    "security"
)

get_class_label() {
    case "$1" in
        python) echo "Python Tooling" ;;
        js) echo "JS / Web Linters & Formatters" ;;
        devtools) echo "Code Search & Static Sites" ;;
        build_scm) echo "Build Systems & SCM" ;;
        java) echo "Java Code Analyzers" ;;
        containers) echo "Containers & Kubernetes" ;;
        security) echo "Security, Signing & Vulnerability Scanners" ;;
        *) echo "$1" ;;
    esac
}

# _parse_pkg_entry <line>
_parse_pkg_entry() {
    IFS=';' read -r \
        E_CLASS E_TOOL E_REL_DIR E_REPO E_TAG_PREFIX \
        E_OUT_SUFFIX E_LOCAL_REGEX E_DEPLOY_MODE E_DEPLOY_SUBDIR E_BINS <<< "$1"
}

# _matches_filters <class_id> <tool_key> <repo>
_matches_filters() {
    local cid="$1" tool="$2" repo="$3"
    if [[ -n "$FILTER_CLASS" && "${cid,,}" != "${FILTER_CLASS,,}" ]]; then
        return 1
    fi
    if [[ -n "$FILTER_TOOL" ]]; then
        local repo_leaf="${repo#*/}"
        if [[ "${tool,,}" != "${FILTER_TOOL,,}" && "${repo,,}" != "${FILTER_TOOL,,}" && "${repo_leaf,,}" != "${FILTER_TOOL,,}" ]]; then
            return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Section 3: Usage & CLI Parsing
# ------------------------------------------------------------------------------
show_help() {
    local classes_pipe
    classes_pipe=$(IFS='|'; echo "${CLASS_ORDER[*]}")
    cat << EOF
Usage: $(basename "$0") <ACTION> [OPTIONS]

Checks GitHub releases for ${#PACKAGES[@]} CI/DevSecOps tools, normalizes multi-platform
archives (Windows x86_64 .zip, Linux x86_64 .tar.xz + .deb/.rpm when present,
and Java analyzers), updates the software library, and deploys tools locally.

Actions (Choose one):
  --detect                Check upstream GitHub releases vs local library; show
                          all packaged versions and available upgrades by class.
  --package               Download new/forced releases, verify SHA-256, normalize
                          archives, bundle into <tool>-<ver>-<win-lnx|java>.zip,
                          update --source, and stage to --target.
  --deploy                Deploy packaged tools from --source into --deploy-target.
  --list, --list-tools    Show configured tool catalog and local versions (offline).
  --action <name>         Alternate syntax: detect | package | deploy | list

Filters & Paths:
  --app, --name, --tool <name>
                          Process only one tool (e.g. --tool ruff, ast-grep, oxfmt)
  --class <id>            Filter by class ($classes_pipe)
  --source <path>         Software library root (default: $DEFAULT_SOURCE)
  --target <path>         Upload pending stage dir (default: $DEFAULT_TARGET)
  --deploy-target <path>  Common deploy folder (default: $DEFAULT_DEPLOY)
  --flatten               Search/write bundles directly in --source without category subdirs

Execution Options:
  --token <pat>           GitHub Personal Access Token (or set GITHUB_TOKEN env var)
  --force                 Force download and repackage even if local version is current
  --no-update-source      In --package mode, stage to --target without modifying --source
  --dry-run               Preview actions without downloading/modifying files on disk
  --log <file>            Save execution output to specified log file
  --verbose               Show detailed asset URLs, hashes, and diagnostic messages
  -h, --help              Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --detect | --package | --deploy | --list)
            ACTION="${1#--}"
            shift
            ;;
        --list-tools)
            ACTION="list"
            shift
            ;;
        --action)
            require_opt_arg "$1" $#
            ACTION="${2,,}"
            shift 2
            ;;
        --app | --name | --tool)
            require_opt_arg "$1" $#
            FILTER_TOOL="$2"
            shift 2
            ;;
        --class)
            require_opt_arg "$1" $#
            FILTER_CLASS="${2,,}"
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
        --deploy-target)
            require_opt_arg "$1" $#
            DEPLOY_TARGET="$2"
            shift 2
            ;;
        --token)
            require_opt_arg "$1" $#
            GITHUB_TOKEN="$2"
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
        --flatten)
            FLATTEN_SOURCE=true
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

case "$ACTION" in
    detect | package | deploy | list)
        ;;
    "")
        log_error "Missing mandatory action (--detect, --package, --deploy, or --list)."
        echo "Run '$(basename "$0") --help' for usage." >&2
        exit 1
        ;;
    *)
        log_error "Invalid action '$ACTION'. Must be detect, package, deploy, or list."
        echo "Run '$(basename "$0") --help' for usage." >&2
        exit 1
        ;;
esac

if [[ -n "$FILTER_CLASS" ]]; then
    _valid_class=false
    for _cid in "${CLASS_ORDER[@]}"; do
        if [[ "$_cid" == "$FILTER_CLASS" ]]; then
            _valid_class=true
            break
        fi
    done
    if [[ "$_valid_class" == false ]]; then
        log_error "Invalid class '$FILTER_CLASS'. Valid classes: ${CLASS_ORDER[*]}"
        exit 1
    fi
fi

# Validate filter yields at least one configured tool
_filter_hits=0
for entry in "${PACKAGES[@]}"; do
    _parse_pkg_entry "$entry"
    if _matches_filters "$E_CLASS" "$E_TOOL" "$E_REPO"; then
        _filter_hits=$((_filter_hits + 1))
    fi
done
if [[ $_filter_hits -eq 0 ]]; then
    log_error "No configured tools matched filter (tool='${FILTER_TOOL:-*}', class='${FILTER_CLASS:-*}')."
    exit 1
fi

# ------------------------------------------------------------------------------
# Section 4: Path Normalization & Environment Checks
# ------------------------------------------------------------------------------
SOURCE_PATH=$(enforce_drive_path "$SOURCE_PATH")
SOURCE_CYG=$(to_posix_path "$SOURCE_PATH")
TARGET_PATH=$(enforce_drive_path "$TARGET_PATH")
TARGET_CYG=$(to_posix_path "$TARGET_PATH")
DEPLOY_TARGET=$(enforce_drive_path "$DEPLOY_TARGET")
DEPLOY_TARGET_CYG=$(to_posix_path "$DEPLOY_TARGET")

TEMP_ROOT_CYG=$(detect_temp_root)
TEMP_ROOT_PATH=$(enforce_drive_path "$TEMP_ROOT_CYG")

init_log_file "$LOG_FILE"

case "$ACTION" in
    detect)
        verify_required_tools curl jq
        ;;
    package)
        verify_required_tools curl zip unzip jq tar gzip xz
        ;;
    deploy)
        verify_required_tools unzip tar xz gzip
        ;;
esac

# ------------------------------------------------------------------------------
# Section 5: Upstream Asset Selection Policy
# ------------------------------------------------------------------------------
# _select_tool_assets <tool_key> <release_json>
# Sets:
#   A_WIN_NAME A_WIN_URL A_WIN_DIGEST
#   A_LNX_NAME A_LNX_URL A_LNX_DIGEST
#   A_DEB_NAME A_DEB_URL A_DEB_DIGEST
#   A_RPM_NAME A_RPM_URL A_RPM_DIGEST
#   A_JAVA_NAME A_JAVA_URL A_JAVA_DIGEST
_select_tool_assets() {
    local tool="$1" rel="$2"
    A_WIN_NAME="" A_WIN_URL="" A_WIN_DIGEST=""
    A_LNX_NAME="" A_LNX_URL="" A_LNX_DIGEST=""
    A_DEB_NAME="" A_DEB_URL="" A_DEB_DIGEST=""
    A_RPM_NAME="" A_RPM_URL="" A_RPM_DIGEST=""
    A_JAVA_NAME="" A_JAVA_URL="" A_JAVA_DIGEST=""

    local win_row="" lnx_row="" deb_row="" rpm_row="" java_row=""
    local std_arch_exc='arm|aarch64|darwin|macos|osx|s390|ppc64|riscv|386|i686|i386|loong|freebsd|netbsd|openbsd|dragonfly|solaris|android|musl'

    case "$tool" in
        uv | ruff | oxfmt | oxlint)
            win_row=$(gh_find_asset "$rel" "^${tool}-x86_64-pc-windows-msvc[.]zip$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^${tool}-x86_64-unknown-linux-gnu[.]tar[.](gz|xz)$" "$std_arch_exc")
            ;;
        biome)
            win_row=$(gh_find_asset "$rel" "^biome-win32-x64[.]exe$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^biome-linux-x64$" "$std_arch_exc")
            ;;
        dart-sass)
            win_row=$(gh_find_asset "$rel" "^dart-sass-.*windows-x64[.]zip$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^dart-sass-.*linux-x64[.]tar[.]gz$" "$std_arch_exc")
            ;;
        astgrep)
            win_row=$(gh_find_asset "$rel" "^app-x86_64-pc-windows-msvc[.]zip$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^app-x86_64-unknown-linux-gnu[.]zip$" "$std_arch_exc")
            ;;
        hugo)
            # Match standard Hugo release (exclude hugo_extended / hugo_withdeploy)
            win_row=$(gh_find_asset "$rel" "^hugo_[0-9].*windows-amd64[.]zip$" "extended|withdeploy|${std_arch_exc}")
            lnx_row=$(gh_find_asset "$rel" "^hugo_[0-9].*linux-amd64[.]tar[.]gz$" "extended|withdeploy|${std_arch_exc}")
            deb_row=$(gh_find_asset "$rel" "^hugo_[0-9].*linux-amd64[.]deb$" "extended|withdeploy|${std_arch_exc}")
            ;;
        bazel)
            win_row=$(gh_find_asset "$rel" "^bazel-.*-windows-x86_64[.]zip$" "$std_arch_exc")
            [[ -n "$win_row" ]] || win_row=$(gh_find_asset "$rel" "^bazel-.*-windows-x86_64[.]exe$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^bazel-[0-9].*-linux-x86_64$" "installer|${std_arch_exc}")
            deb_row=$(gh_find_asset "$rel" "^bazel_.*-linux-x86_64[.]deb$" "$std_arch_exc")
            ;;
        gh | grype | syft)
            win_row=$(gh_find_asset "$rel" "^${tool}_.*_windows_amd64[.]zip$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^${tool}_.*_linux_amd64[.]tar[.]gz$" "$std_arch_exc")
            deb_row=$(gh_find_asset "$rel" "^${tool}_.*_linux_amd64[.]deb$" "$std_arch_exc")
            rpm_row=$(gh_find_asset "$rel" "^${tool}_.*_linux_amd64[.]rpm$" "$std_arch_exc")
            ;;
        checkstyle)
            java_row=$(gh_find_asset "$rel" "^checkstyle-.*-all[.]jar$" "$std_arch_exc")
            ;;
        pmd-codeanalyzer)
            java_row=$(gh_find_asset "$rel" "^pmd-dist-.*-bin[.]zip$" "$std_arch_exc")
            ;;
        spotbugs)
            java_row=$(gh_find_asset "$rel" "^spotbugs-[0-9].*[.]zip$" "source|eclipse")
            ;;
        docker-compose)
            win_row=$(gh_find_asset "$rel" "^docker-compose-windows-x86_64[.]exe$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^docker-compose-linux-x86_64$" "$std_arch_exc")
            ;;
        kompose)
            win_row=$(gh_find_asset "$rel" "^kompose-windows-amd64[.]exe$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^kompose-linux-amd64[.]tar[.]gz$" "$std_arch_exc")
            [[ -n "$lnx_row" ]] || lnx_row=$(gh_find_asset "$rel" "^kompose-linux-amd64$" "$std_arch_exc")
            ;;
        cosign)
            win_row=$(gh_find_asset "$rel" "^cosign-windows-amd64[.]exe$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^cosign-linux-amd64$" "$std_arch_exc")
            deb_row=$(gh_find_asset "$rel" "^cosign_.*_amd64[.]deb$" "$std_arch_exc")
            rpm_row=$(gh_find_asset "$rel" "^cosign-.*[.]x86_64[.]rpm$" "$std_arch_exc")
            ;;
        trivy)
            win_row=$(gh_find_asset "$rel" "^trivy_.*_windows-64bit[.]zip$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^trivy_.*_Linux-64bit[.]tar[.]gz$" "$std_arch_exc")
            deb_row=$(gh_find_asset "$rel" "^trivy_.*_Linux-64bit[.]deb$" "$std_arch_exc")
            rpm_row=$(gh_find_asset "$rel" "^trivy_.*_Linux-64bit[.]rpm$" "$std_arch_exc")
            ;;
        trufflehog)
            win_row=$(gh_find_asset "$rel" "^trufflehog_.*_windows_amd64[.]tar[.]gz$" "$std_arch_exc")
            lnx_row=$(gh_find_asset "$rel" "^trufflehog_.*_linux_amd64[.]tar[.]gz$" "$std_arch_exc")
            ;;
    esac

    [[ -n "$win_row" ]] && IFS=$'\t' read -r A_WIN_NAME A_WIN_URL A_WIN_DIGEST <<< "$win_row"
    [[ -n "$lnx_row" ]] && IFS=$'\t' read -r A_LNX_NAME A_LNX_URL A_LNX_DIGEST <<< "$lnx_row"
    [[ -n "$deb_row" ]] && IFS=$'\t' read -r A_DEB_NAME A_DEB_URL A_DEB_DIGEST <<< "$deb_row"
    [[ -n "$rpm_row" ]] && IFS=$'\t' read -r A_RPM_NAME A_RPM_URL A_RPM_DIGEST <<< "$rpm_row"
    [[ -n "$java_row" ]] && IFS=$'\t' read -r A_JAVA_NAME A_JAVA_URL A_JAVA_DIGEST <<< "$java_row"
    return 0
}

# ------------------------------------------------------------------------------
# Section 6: Normalization & Packaging Helpers
# ------------------------------------------------------------------------------
# _canonical_bin_name <tool_key> <os: win|lnx>
_canonical_bin_name() {
    local tool="$1" os="$2"
    local base="$tool"
    case "$tool" in
        astgrep) base="ast-grep" ;;
    esac
    if [[ "$os" == "win" ]]; then
        echo "${base}.exe"
    else
        echo "${base}"
    fi
}

# _select_flat_bins_in_dir <src_dir> <dest_dir> <os: win|lnx> <canon_name> <bins_csv>
# Self-contained helper (reused both locally and injected into WSL via declare -f) that
# filters doc/non-executable files, selects matching binary executable(s), and moves
# them cleanly into <dest_dir>. For single-binary tools, prefers name matches over alphabetical fallback.
_select_flat_bins_in_dir() {
    local src_dir="$1" dest_dir="$2" os="$3" canon_name="$4" bins_csv="$5"
    mkdir -p "$dest_dir" || return 1

    local expected=()
    IFS=',' read -r -a expected <<< "$bins_csv"

    local cands=() f bn low
    while IFS= read -r -d '' f; do
        bn=$(basename "$f")
        low="${bn,,}"
        if [[ "$os" == "win" ]]; then
            [[ "$low" == *.exe ]] || continue
        else
            [[ "$low" =~ \.(txt|md|json|yml|yaml|deb|rpm|1|bash|zsh|fish|ps1|bat|cmd|sh|png|svg)$ || "$low" =~ \.so(\.[0-9]+)*$ ]] && continue
            [[ "$low" =~ ^(license|licence|readme|changelog|changes|notice|copying|authors|credits|security|contributing)(\..*)?$ ]] && continue
            [[ -x "$f" ]] || { command -v file > /dev/null 2>&1 && grep -qi "elf" <<< "$(file "$f" 2> /dev/null || true)"; } || continue
        fi
        cands+=("$f")
    done < <(find "$src_dir" -type f -print0 | LC_ALL=C sort -z)

    [[ ${#cands[@]} -gt 0 ]] || return 1

    if [[ ${#expected[@]} -eq 1 ]]; then
        local exp_low="${expected[0],,}" ext="" chosen=""
        [[ "$os" == "win" ]] && ext=".exe"
        # Pass 1: exact or prefixed match on expected binary name
        for f in "${cands[@]}"; do
            low="$(basename "$f")"
            low="${low,,}"
            if [[ "$low" == "${exp_low}${ext}" ]] || [[ "$low" =~ ^${exp_low}[-_.0-9] ]]; then
                chosen="$f"
                break
            fi
        done
        # Pass 2: fallback only when archive uses an alternate upstream filename (e.g. app.exe)
        [[ -n "$chosen" ]] || chosen="${cands[0]}"
        mv -f "$chosen" "${dest_dir}/${canon_name}" || return 1
        chmod 755 "${dest_dir}/${canon_name}" 2> /dev/null || true
        return 0
    fi

    local matched=false exp ext=""
    [[ "$os" == "win" ]] && ext=".exe"
    for f in "${cands[@]}"; do
        low="$(basename "$f")"
        low="${low,,}"
        for exp in "${expected[@]}"; do
            local exp_low="${exp,,}"
            if [[ "$low" == "${exp_low}${ext}" ]] || [[ "$low" =~ ^${exp_low}[-_]([0-9]|linux|lnx|windows|win|x86_64|amd64) ]]; then
                mv -f "$f" "${dest_dir}/${exp}${ext}" || return 1
                chmod 755 "${dest_dir}/${exp}${ext}" 2> /dev/null || true
                matched=true
                break
            fi
        done
    done
    [[ "$matched" == true ]]
}

# _finalize_flat_stage <stage_dir> <tool> <os: win|lnx> <bins_csv>
_finalize_flat_stage() {
    local stage_dir="$1" tool="$2" os="$3" bins_csv="$4"
    local clean_dir="${stage_dir}_clean" canon_name
    canon_name=$(_canonical_bin_name "$tool" "$os")
    safe_rm_rf "$clean_dir"

    if ! _select_flat_bins_in_dir "$stage_dir" "$clean_dir" "$os" "$canon_name" "$bins_csv"; then
        safe_rm_rf "$clean_dir"
        log_error "No ${os} executables found while finalizing ${tool} package"
        return 1
    fi

    safe_rm_rf "$stage_dir"
    mv -f "$clean_dir" "$stage_dir" || return 1
}

# _finalize_stage_dir <stage_dir> <tool> <os: win|lnx> <deploy_mode> <bins_csv>
_finalize_stage_dir() {
    local stage_dir="$1" tool="$2" os="$3" deploy_mode="$4" bins_csv="$5"
    if [[ "$deploy_mode" == "dir" ]]; then
        prune_doc_clutter "$stage_dir"
        return 0
    fi
    _finalize_flat_stage "$stage_dir" "$tool" "$os" "$bins_csv"
}

# _normalize_win_to_zip <raw_file> <tool> <dest_zip> <build_dir> <deploy_mode> <bins_csv>
_normalize_win_to_zip() {
    local raw_file="$1" tool="$2" dest_zip="$3" build_dir="$4" deploy_mode="$5" bins_csv="$6"
    local stage="${build_dir}/win_stage" rc=0
    safe_rm_rf "$stage"
    mkdir -p "$stage" || return 1

    case "${raw_file,,}" in
        *.exe)
            mv -f "$raw_file" "${stage}/$(_canonical_bin_name "$tool" "win")" || rc=1
            ;;
        *.zip | *.tar.gz | *.tgz | *.tar.xz)
            if extract_archive "$raw_file" "$stage"; then
                safe_rm_f "$raw_file"
                strip_base_directory "$stage"
            else
                log_error "Failed to extract Windows archive for ${tool}: $(basename "$raw_file")"
                rc=1
            fi
            ;;
        *)
            log_error "Unsupported Windows asset format for ${tool}: $(basename "$raw_file")"
            rc=1
            ;;
    esac

    if [[ $rc -eq 0 ]]; then
        _finalize_stage_dir "$stage" "$tool" "win" "$deploy_mode" "$bins_csv" || rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        repack_directory_to_zip "$stage" "$dest_zip" || rc=$?
    fi
    safe_rm_rf "$stage"
    return $rc
}

# _normalize_lnx_to_xz <raw_file> <tool> <dest_xz> <build_dir> <deploy_mode> <bins_csv>
_normalize_lnx_to_xz() {
    local raw_file="$1" tool="$2" dest_xz="$3" build_dir="$4" deploy_mode="$5" bins_csv="$6"
    local stage="${build_dir}/lnx_stage" rc=0
    safe_rm_rf "$stage"
    mkdir -p "$stage" || return 1

    local canon_lnx
    canon_lnx=$(_canonical_bin_name "$tool" "lnx")

    case "${raw_file,,}" in
        *.tar.gz | *.tgz)
            # When using WSL, preserve exact upstream POSIX permissions directly from .tar.gz
            if ! is_windows_platform || command -v wsl.exe > /dev/null 2>&1; then
                local q_mode q_bins q_canon fn_defs
                printf -v q_mode '%q' "$deploy_mode"
                printf -v q_bins '%q' "$bins_csv"
                printf -v q_canon '%q' "$canon_lnx"
                fn_defs=$(declare -f prune_doc_clutter _select_flat_bins_in_dir)
                # shellcheck disable=SC2016
                local tcmd="${fn_defs}"$'\n'"_dmode=${q_mode}"$'\n'"_bins_csv=${q_bins}"$'\n'"_canon=${q_canon}"$'\n''
shopt -s nullglob dotglob
top=(*)
shopt -u nullglob dotglob
if [[ ${#top[@]} -eq 1 && -d "${top[0]}" ]]; then
    mv "${top[0]}" ../_stripped_dir
    rm -rf ./* ./.[!.]* ..?* 2>/dev/null || true
    mv ../_stripped_dir/* ../_stripped_dir/.[!.]* . 2>/dev/null || true
    rmdir ../_stripped_dir 2>/dev/null || true
fi
if [[ "$_dmode" == "dir" ]]; then
    prune_doc_clutter "."
else
    _select_flat_bins_in_dir "." "../_clean_bins" "lnx" "$_canon" "$_bins_csv"
    rm -rf ./* ./.[!.]* ..?* 2>/dev/null || true
    mv ../_clean_bins/* .
    rmdir ../_clean_bins 2>/dev/null || true
fi
find . -depth \( -type f -o -type d \) -exec touch {} + 2>/dev/null || true
'
                if repack_tar_gz_to_xz_preserving_perms "$raw_file" "$dest_xz" "." "$tcmd"; then
                    safe_rm_f "$raw_file"
                    safe_rm_rf "$stage"
                    return 0
                fi
            fi
            if extract_archive "$raw_file" "$stage"; then
                safe_rm_f "$raw_file"
            else
                log_error "Failed to extract Linux archive for ${tool}: $(basename "$raw_file")"
                rc=1
            fi
            ;;
        *.tar.xz | *.zip)
            if extract_archive "$raw_file" "$stage"; then
                safe_rm_f "$raw_file"
            else
                log_error "Failed to extract Linux archive for ${tool}: $(basename "$raw_file")"
                rc=1
            fi
            ;;
        *)
            # Raw ELF binary (e.g. biome-linux-x64, cosign-linux-amd64, docker-compose-linux-x86_64, bazel)
            if mv -f "$raw_file" "${stage}/${canon_lnx}"; then
                chmod 755 "${stage}/${canon_lnx}" 2> /dev/null || true
            else
                rc=1
            fi
            ;;
    esac

    if [[ $rc -eq 0 ]]; then
        local strip_flag=true
        [[ "$deploy_mode" == "dir" ]] && strip_base_directory "$stage"
        _finalize_stage_dir "$stage" "$tool" "lnx" "$deploy_mode" "$bins_csv" || rc=$?
        [[ "$deploy_mode" == "flat" ]] && strip_flag=false
        if [[ $rc -eq 0 ]]; then
            repack_directory_to_tar_xz_preserving_perms "$stage" "$dest_xz" "$strip_flag" || rc=$?
        fi
    fi
    safe_rm_rf "$stage"
    return $rc
}

# ------------------------------------------------------------------------------
# Section 7: Action 1 — List Configured Catalog (--list)
# ------------------------------------------------------------------------------
_resolve_tool_source_dir() {
    local rel_dir="$1"
    if [[ "$FLATTEN_SOURCE" == true || -z "$rel_dir" ]]; then
        printf '%s' "$SOURCE_CYG"
    else
        printf '%s/%s' "$SOURCE_CYG" "$rel_dir"
    fi
}

_source_layout_tag() {
    [[ "$FLATTEN_SOURCE" == true ]] && echo "${SOURCE_PATH}, flat" || echo "$SOURCE_PATH"
}

run_list_action() {
    echo ""
    echo "============================================================================================================"
    echo -e " ${C_BOLD}CI Tools Catalog (--source: $(_source_layout_tag))${C_RESET}"
    echo "============================================================================================================"
    printf " %-18s %-12s %-34s %-26s %s\n" "TOOL" "LOCAL VER" "STANDARD BUNDLE" "GITHUB REPO" "DEPLOY LAYOUT"
    echo "------------------------------------------------------------------------------------------------------------"

    local total=0 local_found=0
    for cid in "${CLASS_ORDER[@]}"; do
        local class_rows=()
        for entry in "${PACKAGES[@]}"; do
            _parse_pkg_entry "$entry"
            [[ "$E_CLASS" == "$cid" ]] || continue
            _matches_filters "$E_CLASS" "$E_TOOL" "$E_REPO" || continue

            local lver lfile
            read -r lver lfile < <(find_local_version "$(_resolve_tool_source_dir "$E_REL_DIR")" "$E_TOOL" "$E_LOCAL_REGEX" "zip")
            [[ "$lver" != "none" ]] && local_found=$((local_found + 1))

            local deploy_desc="${E_BINS} (flat)"
            [[ "$E_DEPLOY_MODE" == "dir" ]] && deploy_desc="${E_DEPLOY_SUBDIR}/ (dir)"
            [[ "$E_DEPLOY_MODE" == "jar" ]] && deploy_desc="${E_DEPLOY_SUBDIR} (jar)"

            class_rows+=("${E_TOOL}|${lver}|${E_TOOL}-<ver>-${E_OUT_SUFFIX}.zip|${E_REPO}|${deploy_desc}")
            total=$((total + 1))
        done

        [[ ${#class_rows[@]} -gt 0 ]] || continue
        echo ""
        echo -e " ${C_CYAN}${C_BOLD}[$(get_class_label "$cid")]${C_RESET}"
        for row in "${class_rows[@]}"; do
            local t lv bn rp dl
            IFS='|' read -r t lv bn rp dl <<< "$row"
            local lv_color="$lv"
            [[ "$lv" == "none" ]] && lv_color="(none)"
            printf " ${C_BOLD}%-18s${C_RESET} %-12s %-34s %-26s %s\n" "$t" "$lv_color" "$bn" "$rp" "$dl"
        done
    done

    echo ""
    echo "============================================================================================================"
    echo -e " Configured tools: ${C_BOLD}${total}${C_RESET}  |  Present in local library: ${C_BOLD}${local_found}${C_RESET}  |  Deploy root: ${DEPLOY_TARGET}"
    echo "============================================================================================================"
}

# ------------------------------------------------------------------------------
# Section 8: Action 2 — Detect Upgrades (--detect)
# ------------------------------------------------------------------------------
run_detect_action() {
    echo ""
    echo "============================================================================================================"
    echo -e " ${C_BOLD}CI Tools Release Detection (--source: $(_source_layout_tag))${C_RESET}"
    echo "============================================================================================================"
    if [[ -n "$GITHUB_TOKEN" ]]; then
        log_info "GitHub API authentication: active (5,000 req/hr)"
    else
        log_warn "GitHub API authentication: anonymous (60 req/hr limit)"
    fi
    echo ""
    printf " %-18s %-12s %-12s %-22s %s\n" "TOOL" "LOCAL VER" "REMOTE VER" "STATUS" "PACKAGED ARCHIVE"
    echo "------------------------------------------------------------------------------------------------------------"

    local total=0 upgrades=0 missing=0 uptodate=0 errors=0
    local upgrade_list=()

    for cid in "${CLASS_ORDER[@]}"; do
        local class_printed=false
        for entry in "${PACKAGES[@]}"; do
            _parse_pkg_entry "$entry"
            [[ "$E_CLASS" == "$cid" ]] || continue
            _matches_filters "$E_CLASS" "$E_TOOL" "$E_REPO" || continue

            if [[ "$class_printed" == false ]]; then
                echo ""
                echo -e " ${C_CYAN}${C_BOLD}[$(get_class_label "$cid")]${C_RESET}"
                class_printed=true
            fi

            total=$((total + 1))
            local lver lfile
            read -r lver lfile < <(find_local_version "$(_resolve_tool_source_dir "$E_REL_DIR")" "$E_TOOL" "$E_LOCAL_REGEX" "zip")
            local lbase="-"
            [[ -n "$lfile" ]] && lbase=$(basename "$lfile")

            local rel_info="" rc=0
            rel_info=$(gh_resolve_release "$E_REPO" "$E_TOOL" "$E_TAG_PREFIX") || rc=$?
            if [[ $rc -ne 0 || -z "$rel_info" ]]; then
                errors=$((errors + 1))
                printf " ${C_BOLD}%-18s${C_RESET} %-12s %-12s ${C_RED}%-22s${C_RESET} %s\n" \
                    "$E_TOOL" "$lver" "?" "ERROR" "$lbase"
                [[ $rc -eq 2 ]] && break 2
                continue
            fi

            local rver rtag
            IFS=$'\t' read -r rver rtag _ <<< "$rel_info"

            local status_txt status_color
            if [[ "$lver" == "none" ]]; then
                status_txt="MISSING LOCAL"
                status_color="$C_CYAN"
                missing=$((missing + 1))
                upgrade_list+=("${E_TOOL}|none|${rver}|MISSING LOCAL|$(get_class_label "$cid")")
            elif is_version_newer "$rver" "$lver"; then
                status_txt="UPGRADE AVAILABLE"
                status_color="$C_YELLOW"
                upgrades=$((upgrades + 1))
                upgrade_list+=("${E_TOOL}|${lver}|${rver}|UPGRADE AVAILABLE|$(get_class_label "$cid")")
            else
                status_txt="UP TO DATE"
                status_color="$C_GREEN"
                uptodate=$((uptodate + 1))
            fi

            printf " ${C_BOLD}%-18s${C_RESET} %-12s %-12s ${status_color}%-22s${C_RESET} %s\n" \
                "$E_TOOL" "$lver" "$rver" "$status_txt" "$lbase"
        done
    done

    echo ""
    echo "======================================================================================================"
    echo " Detection Summary"
    echo "======================================================================================================"
    echo " Total checked     : $total"
    echo " Upgrades available: $upgrades"
    echo " Missing locally   : $missing"
    echo " Up to date        : $uptodate"
    echo " Errors            : $errors"
    echo "======================================================================================================"

    if [[ ${#upgrade_list[@]} -gt 0 ]]; then
        echo ""
        echo -e " ${C_BOLD}Pending Additions / Upgrades (${#upgrade_list[@]}):${C_RESET}"
        for item in "${upgrade_list[@]}"; do
            local t lv rv st cl
            IFS='|' read -r t lv rv st cl <<< "$item"
            printf "   - %-18s %s -> %s [%s] (%s)\n" "$t" "$lv" "$rv" "$st" "$cl"
        done
        echo ""
        echo " Run '$(basename "$0") --package' to download and package pending updates."
    fi

    [[ $errors -eq 0 ]]
}

# _stage_ci_bundle <src_zip_or_empty> <bundle_name> <tool> <out_suffix> <local_regex> <src_dir> <tgt_dir> <dry_run>
_stage_ci_bundle() {
    local src_zip="$1" bundle_name="$2" tool="$3" out_suffix="$4"
    local local_regex="$5" src_dir="$6" tgt_dir="$7" dry_run="$8"

    atomic_stage_package "$src_zip" "$bundle_name" "$tool" "$out_suffix" "$src_dir" "$tgt_dir" "$dry_run" || return 1

    local purged_src=false
    if [[ -n "$src_dir" ]]; then
        purge_legacy_suffix_packages "$src_dir" "source" "$tool" "$out_suffix" "$local_regex" "$bundle_name" "$dry_run"
        purged_src=true
    fi
    if [[ -n "$tgt_dir" ]] && { [[ "$purged_src" != true ]] || ! _paths_same_dir "$src_dir" "$tgt_dir"; }; then
        purge_legacy_suffix_packages "$tgt_dir" "target" "$tool" "$out_suffix" "$local_regex" "$bundle_name" "$dry_run"
    fi
}

_fail_tool_step() {
    cleanup_current_build_dir
    ERROR_COUNT=$((ERROR_COUNT + 1))
    return 1
}

_print_ci_banner() {
    local title="$1"
    shift
    local extra=()
    [[ "$FLATTEN_SOURCE" == true ]] && extra+=("Flatten Source" "true")
    [[ -n "$FILTER_CLASS" ]] && extra+=("Filter Class" "$FILTER_CLASS")
    [[ -n "$FILTER_TOOL" ]] && extra+=("Filter Tool" "$FILTER_TOOL")
    print_action_banner "$title" "$@" "Temp Root Dir" "$TEMP_ROOT_PATH" "${extra[@]}"
}

# ------------------------------------------------------------------------------
# Section 9: Action 3 — Package Tools (--package)
# ------------------------------------------------------------------------------
_package_single_tool() {
    local entry="$1"
    _parse_pkg_entry "$entry"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    echo ""
    log_step "Processing [${E_TOOL}] ($(get_class_label "$E_CLASS") — repo: ${E_REPO})..."

    local lib_dir
    lib_dir=$(_resolve_tool_source_dir "$E_REL_DIR")
    local lver lfile
    read -r lver lfile < <(find_local_version "$lib_dir" "$E_TOOL" "$E_LOCAL_REGEX" "zip")
    log_info "Local version  : ${C_BOLD}${lver}${C_RESET} (${lfile:-none})"

    local rel_info rc=0
    rel_info=$(gh_resolve_release "$E_REPO" "$E_TOOL" "$E_TAG_PREFIX") || rc=$?
    if [[ $rc -ne 0 || -z "$rel_info" ]]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        [[ $rc -eq 2 ]] && return 2
        return 1
    fi

    local rver rtag rel_json
    IFS=$'\t' read -r rver rtag rel_json <<< "$rel_info"
    log_info "Remote version : ${C_BOLD}${rver}${C_RESET} (tag: ${rtag})"

    local need_pkg=false
    if [[ "$FORCE_REPACKAGE" == true ]]; then
        log_info "Forcing repackage as requested by --force."
        need_pkg=true
    elif [[ "$lver" == "none" ]]; then
        log_info "Local archive absent; creating new package."
        need_pkg=true
    elif is_version_newer "$rver" "$lver"; then
        log_ok "Upgrade detected: ${lver} -> ${C_GREEN}${rver}${C_RESET}"
        need_pkg=true
    else
        log_info "Up to date (${lver} >= ${rver})."
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
    fi

    [[ "$need_pkg" == true ]] || return 0

    _select_tool_assets "$E_TOOL" "$rel_json"

    if [[ "$E_OUT_SUFFIX" == "java" ]]; then
        if [[ -z "$A_JAVA_URL" ]]; then
            log_error "No matching Java asset found for ${E_TOOL} v${rver}!"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            return 1
        fi
    else
        if [[ -z "$A_WIN_URL" || -z "$A_LNX_URL" ]]; then
            log_error "Missing required x86_64 assets for ${E_TOOL} v${rver} (win='${A_WIN_NAME:-MISSING}', lnx='${A_LNX_NAME:-MISSING}')"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            return 1
        fi
    fi

    local new_bundle="${E_TOOL}-${rver}-${E_OUT_SUFFIX}.zip"
    log_info "Target bundle  : ${C_BOLD}${new_bundle}${C_RESET}"

    if [[ "$VERBOSE" == true ]]; then
        [[ -n "$A_WIN_URL" ]] && log_info "  Win asset : $A_WIN_NAME ($A_WIN_URL)"
        [[ -n "$A_LNX_URL" ]] && log_info "  Lnx asset : $A_LNX_NAME ($A_LNX_URL)"
        [[ -n "$A_DEB_URL" ]] && log_info "  Deb asset : $A_DEB_NAME ($A_DEB_URL)"
        [[ -n "$A_RPM_URL" ]] && log_info "  Rpm asset : $A_RPM_NAME ($A_RPM_URL)"
        [[ -n "$A_JAVA_URL" ]] && log_info "  Java asset: $A_JAVA_NAME ($A_JAVA_URL)"
    fi

    local dest_src_dir=""
    [[ "$UPDATE_SOURCE" == true ]] && dest_src_dir="$lib_dir"

    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$E_OUT_SUFFIX" == "java" ]]; then
            log_ok "[DRY-RUN] Would download: $A_JAVA_NAME -> bundle into $new_bundle"
        else
            log_ok "[DRY-RUN] Would download: $A_WIN_NAME -> ${E_TOOL}-${rver}-w64.zip"
            log_ok "[DRY-RUN] Would download: $A_LNX_NAME -> ${E_TOOL}-${rver}-lnx.tar.xz (xz -9 -T0)"
            [[ -n "$A_DEB_NAME" ]] && log_ok "[DRY-RUN] Would include deb: $A_DEB_NAME"
            [[ -n "$A_RPM_NAME" ]] && log_ok "[DRY-RUN] Would include rpm: $A_RPM_NAME"
        fi
        _stage_ci_bundle "" "$new_bundle" "$E_TOOL" "$E_OUT_SUFFIX" "$E_LOCAL_REGEX" "$dest_src_dir" "$TARGET_CYG" true
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        return 0
    fi

    CURRENT_BUILD_DIR=$(mktemp -d "${EXEC_WORKSPACE}/${E_TOOL}_XXXXXX")
    local bundle_staging="${CURRENT_BUILD_DIR}/bundle_out"
    mkdir -p "$bundle_staging"

    if [[ "$E_OUT_SUFFIX" == "java" ]]; then
        local java_raw="${CURRENT_BUILD_DIR}/${A_JAVA_NAME}"
        if ! gh_download_verified_asset "$rel_json" "Java asset" "$A_JAVA_NAME" "$A_JAVA_URL" "$A_JAVA_DIGEST" "$java_raw" "$CURRENT_BUILD_DIR"; then
            _fail_tool_step
            return 1
        fi
        if [[ "${A_JAVA_NAME,,}" == *.zip ]]; then
            if ! verify_zip_integrity "$java_raw"; then
                log_error "Downloaded Java zip failed integrity check: $A_JAVA_NAME"
                _fail_tool_step
                return 1
            fi
            # Unpack, prune doc/license clutter, and repack so epoch timestamps (e.g. 1980-02-01) are normalized.
            local java_norm="${CURRENT_BUILD_DIR}/java_norm"
            if ! extract_archive "$java_raw" "$java_norm"; then
                log_error "Failed extracting Java zip for normalization: $A_JAVA_NAME"
                _fail_tool_step
                return 1
            fi
            prune_doc_clutter "$java_norm"
            if ! repack_directory_to_zip "$java_norm" "${bundle_staging}/${A_JAVA_NAME}"; then
                log_error "Failed normalizing Java zip: $A_JAVA_NAME"
                _fail_tool_step
                return 1
            fi
            safe_rm_f "$java_raw"
            safe_rm_rf "$java_norm"
        else
            touch "$java_raw" 2> /dev/null || true
            if ! mv -f "$java_raw" "${bundle_staging}/${A_JAVA_NAME}"; then
                log_error "Failed staging Java asset: $A_JAVA_NAME"
                _fail_tool_step
                return 1
            fi
        fi
    else
        # 1. Download & normalize Windows asset -> <tool>-<ver>-w64.zip
        local win_raw="${CURRENT_BUILD_DIR}/${A_WIN_NAME}"
        local win_norm_zip="${bundle_staging}/${E_TOOL}-${rver}-w64.zip"
        if ! gh_download_verified_asset "$rel_json" "Windows asset" "$A_WIN_NAME" "$A_WIN_URL" "$A_WIN_DIGEST" "$win_raw" "$CURRENT_BUILD_DIR" ||
            ! _normalize_win_to_zip "$win_raw" "$E_TOOL" "$win_norm_zip" "$CURRENT_BUILD_DIR" "$E_DEPLOY_MODE" "$E_BINS"; then
            _fail_tool_step
            return 1
        fi

        # 2. Download & normalize Linux asset -> <tool>-<ver>-lnx.tar.xz
        local lnx_raw="${CURRENT_BUILD_DIR}/${A_LNX_NAME}"
        local lnx_norm_xz="${bundle_staging}/${E_TOOL}-${rver}-lnx.tar.xz"
        if ! gh_download_verified_asset "$rel_json" "Linux asset" "$A_LNX_NAME" "$A_LNX_URL" "$A_LNX_DIGEST" "$lnx_raw" "$CURRENT_BUILD_DIR" ||
            ! _normalize_lnx_to_xz "$lnx_raw" "$E_TOOL" "$lnx_norm_xz" "$CURRENT_BUILD_DIR" "$E_DEPLOY_MODE" "$E_BINS"; then
            _fail_tool_step
            return 1
        fi

        # 3. Download optional .deb / .rpm when provided upstream
        local pkg_spec pkg_label pkg_name pkg_url pkg_digest
        for pkg_spec in \
            "DEB package|${A_DEB_NAME}|${A_DEB_URL}|${A_DEB_DIGEST}" \
            "RPM package|${A_RPM_NAME}|${A_RPM_URL}|${A_RPM_DIGEST}"; do
            IFS='|' read -r pkg_label pkg_name pkg_url pkg_digest <<< "$pkg_spec"
            [[ -n "$pkg_url" ]] || continue
            if ! gh_download_verified_asset "$rel_json" "$pkg_label" "$pkg_name" "$pkg_url" "$pkg_digest" "${bundle_staging}/${pkg_name}" "$CURRENT_BUILD_DIR"; then
                _fail_tool_step
                return 1
            fi
        done
    fi

    # 4. Pack combined bundle zip & atomically stage to --source + --target
    local out_bundle="${CURRENT_BUILD_DIR}/${new_bundle}"
    log_info "Creating normalized bundle archive: ${new_bundle}..."
    if ! repack_directory_to_zip "$bundle_staging" "$out_bundle" ||
        ! _stage_ci_bundle "$out_bundle" "$new_bundle" "$E_TOOL" "$E_OUT_SUFFIX" "$E_LOCAL_REGEX" "$dest_src_dir" "$TARGET_CYG" false; then
        _fail_tool_step
        return 1
    fi

    cleanup_current_build_dir
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
    log_ok "Packaged and staged: ${new_bundle}"
    return 0
}

run_package_action() {
    _print_ci_banner "CI Tools Normalized Packaging Utility" \
        "Platform" "$PLATFORM" \
        "Source Library" "$SOURCE_PATH" \
        "Target Pending" "$TARGET_PATH" \
        "Dry Run" "$DRY_RUN" \
        "Force Repack" "$FORCE_REPACKAGE" \
        "Update Source" "$UPDATE_SOURCE"

    init_exec_workspace "citools_pkg_" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN" "$UPDATE_SOURCE"

    TOTAL_COUNT=0
    UPDATED_COUNT=0
    SKIPPED_COUNT=0
    ERROR_COUNT=0

    for entry in "${PACKAGES[@]}"; do
        _parse_pkg_entry "$entry"
        _matches_filters "$E_CLASS" "$E_TOOL" "$E_REPO" || continue
        local prc=0
        _package_single_tool "$entry" || prc=$?
        if [[ $prc -eq 2 ]]; then
            log_warn "Stopping remaining checks due to GitHub API rate limit."
            break
        fi
    done

    cleanup_exec_workspace
    print_packaging_summary "CI Tools Packaging Summary" "$TOTAL_COUNT" "$UPDATED_COUNT" "$SKIPPED_COUNT" "$ERROR_COUNT"
    [[ $ERROR_COUNT -eq 0 ]]
}

# ------------------------------------------------------------------------------
# Section 10: Action 4 — Deploy Tools to Common Folder (--deploy)
# ------------------------------------------------------------------------------
# _find_inner_payloads <zip_file> <target_os>
# Handles both newly normalized (-w64.zip / -lnx.tar.xz) and legacy repository bundles.
_find_inner_payloads() {
    local bundle_zip="$1" os="$2"
    local entries=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] && entries+=("$line")
    done < <(unzip -Z1 "$bundle_zip" 2> /dev/null || true)

    local e low
    # Priority 1: normalized -w64.zip or -lnx.tar.xz
    for e in "${entries[@]}"; do
        low="${e,,}"
        if [[ "$os" == "windows" && "$low" =~ (^|/)[^/]+-w64\.zip$ ]]; then
            echo "$e"
            return 0
        elif [[ "$os" == "linux" && "$low" =~ (^|/)[^/]+-lnx\.tar\.xz$ ]]; then
            echo "$e"
            return 0
        fi
    done

    # Priority 2: legacy Windows archives/exes or Linux archives/bins (skip .deb/.rpm/src)
    for e in "${entries[@]}"; do
        low="${e,,}"
        [[ "$low" =~ \.deb$|\.rpm$|^src/ ]] && continue
        if [[ "$os" == "windows" ]]; then
            if [[ "$low" =~ (win|windows|w64|w32).*\.(zip|tar\.xz|tar\.gz|exe|exe\.xz|xz)$ ]]; then
                echo "$e"
                return 0
            fi
        else
            if [[ "$low" =~ (linux|lnx|lnx64).*\.(tar\.xz|tar\.gz|tgz|zip|bin|xz)$ ]] ||
                [[ "$low" =~ -linux-x86_64$|-linux-amd64$ ]]; then
                echo "$e"
                return 0
            fi
        fi
    done
    return 1
}

# _unpack_any_payload <file_path> <dest_dir> <tool> <os>
_unpack_any_payload() {
    local payload="$1" dest_dir="$2" tool="$3" os="$4"
    mkdir -p "$dest_dir" || return 1
    local low="${payload,,}"
    local bname win_bin lnx_bin
    bname=$(basename "$payload")
    win_bin=$(_canonical_bin_name "$tool" "win")
    lnx_bin=$(_canonical_bin_name "$tool" "lnx")

    case "$low" in
        *.zip | *.tar.gz | *.tgz | *.tar.xz | *.tar)
            extract_archive "$payload" "$dest_dir"
            ;;
        *.exe.xz)
            xz -dc "$payload" > "${dest_dir}/${win_bin}" || return 1
            ;;
        *.xz)
            local out_name="${bname%.xz}"
            if [[ "$os" == "windows" && "${out_name,,}" != *.exe ]]; then
                out_name="$win_bin"
            elif [[ "$os" == "linux" ]]; then
                out_name="$lnx_bin"
            fi
            xz -dc "$payload" > "${dest_dir}/${out_name}" || return 1
            chmod 755 "${dest_dir}/${out_name}" 2> /dev/null || true
            ;;
        *.exe)
            cp -f "$payload" "${dest_dir}/${win_bin}" || return 1
            ;;
        *.bin | *)
            if [[ "$os" == "windows" ]]; then
                cp -f "$payload" "${dest_dir}/${win_bin}" || return 1
            else
                cp -f "$payload" "${dest_dir}/${lnx_bin}" || return 1
                chmod 755 "${dest_dir}/${lnx_bin}" 2> /dev/null || true
            fi
            ;;
    esac
}

# _deploy_sync_dir <stage_dir> <subdir> <ver>
_deploy_sync_dir() {
    local stage_dir="$1" subdir="$2" ver="$3"
    if [[ -z $(find "$stage_dir" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null) ]]; then
        log_error "Refusing to replace ${subdir}/ with empty staging directory"
        return 1
    fi

    local dst_sub="${DEPLOY_TARGET_CYG}/${subdir}"
    local tmp_sub="${dst_sub}.tmp.$$"
    safe_rm_rf "$tmp_sub"
    mkdir -p "$tmp_sub" || return 1
    if ! cp -Rf "${stage_dir}/." "${tmp_sub}/"; then
        safe_rm_rf "$tmp_sub"
        log_error "Failed copying staged files for ${subdir}/"
        return 1
    fi
    chmod -R a+rX "$tmp_sub" 2> /dev/null || true
    if ! safe_rm_rf "$dst_sub" || ! mv -f "$tmp_sub" "$dst_sub"; then
        safe_rm_rf "$tmp_sub"
        log_error "Failed replacing deployment directory ${subdir}/"
        return 1
    fi
    log_ok "Deployed directory ${subdir}/ (v${ver})"
}

_deploy_single_tool() {
    local entry="$1" target_os="$2"
    _parse_pkg_entry "$entry"

    local lib_dir
    lib_dir=$(_resolve_tool_source_dir "$E_REL_DIR")
    local lver lfile
    read -r lver lfile < <(find_local_version "$lib_dir" "$E_TOOL" "$E_LOCAL_REGEX" "zip")
    if [[ "$lver" == "none" || -z "$lfile" ]]; then
        log_warn "Skipping ${E_TOOL}: no archive found in ${lib_dir}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
    fi

    local lfile_cyg
    lfile_cyg=$(to_posix_path "$lfile")
    log_step "Deploying [${E_TOOL}] v${lver} from $(basename "$lfile")..."

    if [[ "$DRY_RUN" == true ]]; then
        case "$E_DEPLOY_MODE" in
            jar) log_ok "[DRY-RUN] Would deploy JAR to ${DEPLOY_TARGET}/${E_DEPLOY_SUBDIR}" ;;
            dir) log_ok "[DRY-RUN] Would sync directory to ${DEPLOY_TARGET}/${E_DEPLOY_SUBDIR}/" ;;
            flat) log_ok "[DRY-RUN] Would deploy binaries (${E_BINS}) cleanly to ${DEPLOY_TARGET}/" ;;
        esac
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        return 0
    fi

    CURRENT_BUILD_DIR=$(mktemp -d "${EXEC_WORKSPACE}/deploy_${E_TOOL}_XXXXXX")
    local stage="${CURRENT_BUILD_DIR}/stage"
    mkdir -p "$stage"

    if [[ "$E_OUT_SUFFIX" == "java" ]]; then
        case "$E_DEPLOY_MODE" in
            jar)
                local jar_entry jar_file
                jar_entry=$(unzip -Z1 "$lfile_cyg" 2> /dev/null | grep -iE '\.jar$' | head -n 1 || true)
                if [[ -z "$jar_entry" ]]; then
                    log_error "No .jar entry found inside $(basename "$lfile_cyg")"
                    _fail_tool_step
                    return 1
                fi
                jar_file="${stage}/$(basename "$jar_entry")"
                if ! unzip -q -j "$lfile_cyg" "$jar_entry" -d "$stage" || [[ ! -f "$jar_file" ]]; then
                    log_error "Failed extracting JAR ${E_DEPLOY_SUBDIR} from $(basename "$lfile_cyg")"
                    _fail_tool_step
                    return 1
                fi
                touch "$jar_file" 2> /dev/null || true
                if ! cp -f "$jar_file" "${DEPLOY_TARGET_CYG}/${E_DEPLOY_SUBDIR}"; then
                    log_error "Failed deploying JAR ${E_DEPLOY_SUBDIR} from $(basename "$lfile_cyg")"
                    _fail_tool_step
                    return 1
                fi
                chmod 644 "${DEPLOY_TARGET_CYG}/${E_DEPLOY_SUBDIR}" 2> /dev/null || true
                log_ok "Deployed ${E_DEPLOY_SUBDIR} (v${lver})"
                ;;
            dir)
                # Anchor to top-level inner archives so nested library/doc .zips are not misdetected.
                local inner_zip
                inner_zip=$(unzip -Z1 "$lfile_cyg" 2> /dev/null | grep -iE '^[^/]+\.(zip|tar\.gz|tgz|tar\.xz)$' | head -n 1 || true)
                if [[ -n "$inner_zip" ]]; then
                    if ! unzip -q -j "$lfile_cyg" "$inner_zip" -d "${CURRENT_BUILD_DIR}/inner" ||
                        ! extract_archive "${CURRENT_BUILD_DIR}/inner/$(basename "$inner_zip")" "$stage"; then
                        log_error "Failed extracting Java bundle ${E_TOOL}: $(basename "$inner_zip")"
                        _fail_tool_step
                        return 1
                    fi
                elif ! extract_archive "$lfile_cyg" "$stage"; then
                    log_error "Failed extracting Java bundle ${E_TOOL}: $(basename "$lfile_cyg")"
                    _fail_tool_step
                    return 1
                fi
                strip_base_directory "$stage"
                prune_doc_clutter "$stage"
                normalize_directory_timestamps "$stage"
                if ! _deploy_sync_dir "$stage" "$E_DEPLOY_SUBDIR" "$lver"; then
                    _fail_tool_step
                    return 1
                fi
                ;;
        esac
    else
        local inner_entry inner_file
        if ! inner_entry=$(_find_inner_payloads "$lfile_cyg" "$target_os"); then
            log_warn "No ${target_os} payload inside $(basename "$lfile_cyg"); skipping ${E_TOOL}"
            cleanup_current_build_dir
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            return 0
        fi

        inner_file="${CURRENT_BUILD_DIR}/inner/$(basename "$inner_entry")"
        if ! unzip -q -j "$lfile_cyg" "$inner_entry" -d "${CURRENT_BUILD_DIR}/inner" ||
            ! _unpack_any_payload "$inner_file" "$stage" "$E_TOOL" "$target_os"; then
            log_error "Failed unpacking ${target_os} payload for ${E_TOOL}"
            _fail_tool_step
            return 1
        fi
        strip_base_directory "$stage"

        if [[ "$E_DEPLOY_MODE" == "dir" ]]; then
            prune_doc_clutter "$stage"
            normalize_directory_timestamps "$stage"
            if ! _deploy_sync_dir "$stage" "$E_DEPLOY_SUBDIR" "$lver"; then
                _fail_tool_step
                return 1
            fi
        else
            local deploy_os_tag="lnx"
            [[ "$target_os" == "windows" ]] && deploy_os_tag="win"
            if ! _finalize_flat_stage "$stage" "$E_TOOL" "$deploy_os_tag" "$E_BINS"; then
                _fail_tool_step
                return 1
            fi
            normalize_directory_timestamps "$stage"

            local installed_bins=() bf bname
            while IFS= read -r -d '' bf; do
                bname=$(basename "$bf")
                if ! cp -f "$bf" "${DEPLOY_TARGET_CYG}/${bname}"; then
                    log_error "Failed copying ${bname} to ${DEPLOY_TARGET}/ (file may be locked)"
                    _fail_tool_step
                    return 1
                fi
                chmod 755 "${DEPLOY_TARGET_CYG}/${bname}" 2> /dev/null || true
                installed_bins+=("$bname")
            done < <(find "$stage" -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)

            if [[ ${#installed_bins[@]} -eq 0 ]]; then
                log_error "No ${target_os} executables found inside ${E_TOOL} v${lver} archive!"
                _fail_tool_step
                return 1
            fi
            log_ok "Deployed: ${installed_bins[*]} (v${lver})"
        fi
    fi

    cleanup_current_build_dir
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
    return 0
}

run_deploy_action() {
    local target_os
    target_os=$(get_target_os)

    _print_ci_banner "CI Tools Deployment Utility" \
        "Platform" "${PLATFORM} (target OS: ${target_os})" \
        "Source Library" "$SOURCE_PATH" \
        "Deploy Target" "$DEPLOY_TARGET" \
        "Dry Run" "$DRY_RUN"

    if [[ ! -d "$SOURCE_CYG" ]]; then
        log_error "Source library directory not found: $SOURCE_PATH ($SOURCE_CYG)"
        return 1
    fi

    init_exec_workspace "citools_deploy_" "" "$DEPLOY_TARGET_CYG" "$DRY_RUN" false

    TOTAL_COUNT=0
    UPDATED_COUNT=0
    SKIPPED_COUNT=0
    ERROR_COUNT=0

    for entry in "${PACKAGES[@]}"; do
        _parse_pkg_entry "$entry"
        _matches_filters "$E_CLASS" "$E_TOOL" "$E_REPO" || continue
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        _deploy_single_tool "$entry" "$target_os" || true
    done

    cleanup_exec_workspace

    print_packaging_summary "CI Tools Deployment Summary" "$TOTAL_COUNT" "$UPDATED_COUNT" "$SKIPPED_COUNT" "$ERROR_COUNT"
    [[ $ERROR_COUNT -eq 0 ]]
}

# ------------------------------------------------------------------------------
# Section 11: Main Dispatch
# ------------------------------------------------------------------------------
case "$ACTION" in
    list)
        run_list_action
        ;;
    detect)
        run_detect_action
        ;;
    package)
        run_package_action
        ;;
    deploy)
        run_deploy_action
        ;;
esac
