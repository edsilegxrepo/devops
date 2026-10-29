#!/bin/bash
# ==============================================================================
#  Central Build & Toolchain Configuration Include
#  File      : build.inc
#  Version   : 2.0.0
#  Date      : 2026-10-22
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Provides a centralized, single-source-of-truth configuration library and
#    shared utility engine sourced by both the multi-module orchestrator
#    (build_orchestrate.sh) and the individual module compiler engine (build_go.sh).
#
#  Core Components:
#    1. Granular Exit Codes: Standardized numeric codes for automated triage.
#    2. Host OS Detection: Automatic detection of Linux vs. Windows (Cygwin/MSYS2).
#    3. Corporate & Cryptographic Defaults: Maintainer, corporate URL, signing key
#       paths, and mandatory key generation parameters.
#    4. Workspace, Directory & Toolchain Defaults: Standard relative output paths
#       (../bin, ../distrib), entrypoint scripts, and Windows GCC search paths.
#    5. Application Metadata Defaults: Fallback definitions for build.json fields.
#    6. Template Sync & Git AutoSync Defaults: Configuration file paths and messages.
#    7. Packaging & Security Exclusions: Strict file exclusion filters for archives.
#    8. Artifact Cleaning & Temp Directory Tracking: Safe lifecycle cleaners.
#    9. Structured NDJSON Audit Logging: Machine-readable audit trails.
#   10. ANSI Colored Logging Primitives: Human-readable terminal telemetry.
#   11. Path Normalizers: Windows/Cygwin/MSYS2 path conversions.
#   12. Multi-Engine JSON Parser: Fallback chain (jq -> python3 -> python -> awk).
#   13. Packaging Metadata Sanitizers & Formatters: RPM spec, Debian control & RFC 822 changelogs.
#   14. SSH Code Signing Engine: Ed25519 key generation and path resolution.
#
#  Functionality & Data Flows:
#    - Sourced at startup by build_orchestrate.sh and build_go.sh via dynamic SCRIPT_DIR.
#    - Exports shared variables, environment variables, and helper functions.
#    - Input: Parent script configuration, CLI flags, build.json metadata.
#    - Output: Normalized paths, temporary stage folders, NDJSON log records,
#      cryptographic keys, sanitized control/spec strings.
#
#  Test Strategy Explanation:
#    - Standardized Diagnostic Exit Codes: Defines EXIT_TEST (6) and EXIT_AUDIT (5)
#      ensuring uniform CI/CD telemetry and automated test failure isolation across
#      both single-module builds (build_go.sh) and multi-module runs (build_orchestrate.sh).
#    - Safe Test Environment Isolation: Provides temporary directory tracking
#      primitives (make_temp_dir, cleanup_tracked_temp_dirs) to isolate intermediate
#      test artifacts and guarantee leak-free cleanup upon test completion or abort.
# ==============================================================================
# shellcheck disable=SC2034

# ------------------------------------------------------------------------------
# 1. Diagnostic Granular Exit Codes
# ------------------------------------------------------------------------------
export EXIT_SUCCESS=0
export EXIT_GENERAL=1
export EXIT_USAGE=2
export EXIT_CONFIG=3
export EXIT_DEPENDENCY=4
export EXIT_AUDIT=5
export EXIT_TEST=6
export EXIT_COMPILE=7
export EXIT_PACKAGE=8
export EXIT_SYNC=9

# ------------------------------------------------------------------------------
# 2. Host Operating System Detection
# ------------------------------------------------------------------------------
# Function: detect_host_os
# Objective: Determines whether the script is running under Linux or Windows
#            (native Windows_NT, Cygwin, MinGW, or MSYS2 environment).
# Outputs: Echoes "WIN" or "LINUX" to stdout.
detect_host_os() {
  if [ "${OS:-}" == "Windows_NT" ]; then
    echo "WIN"
    return
  fi
  case "$(uname -s 2> /dev/null)" in
    CYGWIN* | MINGW* | MSYS*)
      echo "WIN"
      ;;
    *)
      echo "LINUX"
      ;;
  esac
}
HOST_OS="$(detect_host_os)"
export HOST_OS

# ------------------------------------------------------------------------------
# 3. Corporate, Maintainer & Cryptographic Defaults
# ------------------------------------------------------------------------------
export DEFAULT_MAINTAINER="Mis Center <support@criticalsys.net>"
export DEFAULT_URL="https://criticalsys.net"
export DEFAULT_IDENTITY="mis@criticalsys.net"
export DEFAULT_COMMENT_PREFIX="Critical Systems Release Signing"
export DEFAULT_SIGN_KEY="${HOME}/.ssh/signing/release_key"

# Concurrency defaults
DEFAULT_PARALLEL_JOBS="$(nproc 2> /dev/null || echo 4)"
export DEFAULT_PARALLEL_JOBS

# ------------------------------------------------------------------------------
# 4. Workspace, Directory & Toolchain Search Defaults
# ------------------------------------------------------------------------------
# Resolve Code Home (3 levels above private/devops/build_tasks)
_BUILD_INC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CODE_HOME="$(cd "${_BUILD_INC_DIR}/../../.." &> /dev/null && pwd)"
export CODE_HOME
export BUILD_HOME="${CODE_HOME}"
export WORKSPACE_ROOT="${CODE_HOME}"

export DEFAULT_CODE_BASE="private"
DEFAULT_BIN_DIR="$(cd "${CODE_HOME}/../bin" 2> /dev/null && pwd || echo "${CODE_HOME}/../bin")"
export DEFAULT_BIN_DIR
DEFAULT_DIST_DIR="$(cd "${CODE_HOME}/../distrib" 2> /dev/null && pwd || echo "${CODE_HOME}/../distrib")"
export DEFAULT_DIST_DIR
export DEFAULT_BUILD_GO_SCRIPT="build_go.sh"
CODE_BASE="${DEFAULT_CODE_BASE}"
CODE_EXCLUDES=("devops")

# Windows host toolchain search paths
DEFAULT_MINGW_SEARCH_PATHS=(
  "d:/dev/mingw64/bin"
  "c:/msys64/mingw64/bin"
)
DEFAULT_GIT_SEARCH_PATHS=(
  "d:/dev/git/bin"
  "c:/Program Files/Git/bin"
)

# ------------------------------------------------------------------------------
# 5. Application & Packaging Metadata Defaults (build.json fallbacks)
# ------------------------------------------------------------------------------
export DEFAULT_CONFIG_FILE="build.json"
export DEFAULT_VERSION="0.1.0"
export DEFAULT_RELEASE="1"
export DEFAULT_CHANNEL="xg"
export DEFAULT_ENTRYPOINT="."
export DEFAULT_VERSION_PKG="main.version"
export DEFAULT_BUILD_PKG=""
export DEFAULT_LICENSE="MIT"
export DEFAULT_GROUP="Applications/System"
export DEFAULT_SECTION="utils"
export DEFAULT_PRIORITY="optional"
export DEFAULT_INSTALL_PATH="/usr/bin"
export DEFAULT_OS_VER="el9"
export DEFAULT_ARCH="amd64"
export DEFAULT_SUMMARY_SUFFIX="binary"
export DEFAULT_DESC_SUFFIX="command-line application written in Go."

# Go Toolchain & Compression Environment Defaults
export DEFAULT_GOPROXY="https://proxy.golang.org,direct"
export DEFAULT_XZ_OPT="-T0"
export DEFAULT_GO_LDFLAGS="-s -w"
export DEFAULT_LINUX_EXTRA_FLAGS="-buildmode=pie"

# Standard Documentation Files Included in Release Packages
DEFAULT_DOC_FILES=(
  "LICENSE"
  "README.md"
  "CHANGELOG.md"
)

# ------------------------------------------------------------------------------
# 6. Template Synchronization & Git Management Defaults (build_orchestrate.sh)
# ------------------------------------------------------------------------------
export DEFAULT_TEMPLATE_GITIGNORE="${CODE_HOME}/TMPL.gitignore"
export DEFAULT_TEMPLATE_SECURITY="${CODE_HOME}/SECURITY.md"
export DEFAULT_TEMPLATE_LICENSE="${CODE_HOME}/LICENSE"
export DEFAULT_GIT_AUTOSYNC_SCRIPT="${CODE_HOME}/private/devops/git_repomgr/git_autosync.sh"
export DEFAULT_GIT_SYNC_MESSAGE="Module Updates"

# ------------------------------------------------------------------------------
# 7. Packaging & Source Security Policy
# ------------------------------------------------------------------------------
# Strict exclusion patterns for source archives to prevent leakage of Git
# metadata, compilation binaries, tokens, private keys, or environment files.
DEFAULT_SOURCE_EXCLUDES=(
  "*.git*"
  "*bin/*"
  "*distrib/*"
  "*.token"
  ".env*"
  "*.key"
  "*.pem"
  "*.pfx"
  "*.crt"
  "*.local*"
  "*.tmp*"
  "*.bak"
  "*.log"
  "*.swp"
  "*~"
)

# ------------------------------------------------------------------------------
# 8. Artifact Cleaners & Temp Directory Tracking
# ------------------------------------------------------------------------------
# Function: clean_workspace_artifacts
# Objective: Purges all compiled binaries and distribution archives across the workspace.
# Arguments:
#   $1 - Binary directory path (optional, defaults to DEFAULT_BIN_DIR)
#   $2 - Distribution directory path (optional, defaults to DEFAULT_DIST_DIR)
clean_workspace_artifacts() {
  local bin_dir="${1:-${DEFAULT_BIN_DIR}}"
  local dist_dir="${2:-${DEFAULT_DIST_DIR}}"

  log_info "Cleaning workspace artifacts in '${bin_dir}' and '${dist_dir}'..."
  if [ -d "${bin_dir}" ]; then
    rm -rf "${bin_dir:?}"/* 2> /dev/null || true
    log_success "Cleaned binary directory: ${bin_dir}"
  fi
  mkdir -p "${bin_dir}" 2> /dev/null || true
  if [ -d "${dist_dir}" ]; then
    rm -rf "${dist_dir:?}"/* 2> /dev/null || true
    log_success "Cleaned distribution directory: ${dist_dir}"
  fi
  mkdir -p "${dist_dir}" 2> /dev/null || true
}

# Function: clean_module_artifacts
# Objective: Safely purges only the built artifacts belonging to a specific module,
#            leaving other modules' compiled outputs intact.
# Arguments:
#   $1 - Module name (application name)
#   $2 - Binary directory path (optional)
#   $3 - Distribution directory path (optional)
clean_module_artifacts() {
  local app_name="${1:-}"
  local bin_dir="${2:-${DEFAULT_BIN_DIR}}"
  local dist_dir="${3:-${DEFAULT_DIST_DIR}}"

  if [ -z "${app_name}" ]; then
    clean_workspace_artifacts "${bin_dir}" "${dist_dir}"
    return
  fi

  log_info "Cleaning artifacts for module '${app_name}'..."
  if [ -d "${bin_dir}" ]; then
    rm -f "${bin_dir}/${app_name}" "${bin_dir}/${app_name}.exe" "${bin_dir}/${app_name}.tmp."* 2> /dev/null || true
    log_success "Cleaned binary artifacts for '${app_name}' in: ${bin_dir}"
  fi
  if [ -d "${dist_dir}" ]; then
    rm -f "${dist_dir}/${app_name}-"* 2> /dev/null || true
    log_success "Cleaned distribution artifacts for '${app_name}' in: ${dist_dir}"
  fi
}

TRACKED_TEMP_DIRS=()

# Function: make_temp_dir
# Objective: Creates a temporary directory with guaranteed cleanup registration.
# Arguments:
#   $1 - Directory name prefix (optional, defaults to "tmp_build")
# Outputs: Echoes the absolute path of the created temporary directory.
make_temp_dir() {
  local prefix="${1:-tmp_build}"
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")"
  TRACKED_TEMP_DIRS+=("${temp_dir}")
  echo "${temp_dir}"
}

# Function: cleanup_tracked_temp_dirs
# Objective: Recursively removes all tracked temporary directories registered during execution.
cleanup_tracked_temp_dirs() {
  if [ ${#TRACKED_TEMP_DIRS[@]} -gt 0 ]; then
    for d in "${TRACKED_TEMP_DIRS[@]}"; do
      [ -d "${d}" ] && rm -rf "${d}" 2> /dev/null || true
    done
  fi
}

# ------------------------------------------------------------------------------
# 9. NDJSON Audit Logging & Escaping Helpers
# ------------------------------------------------------------------------------
NDJSON_LOG_FILE=""

# Function: json_escape
# Objective: Sanitizes raw strings for RFC 8259 JSON embedding (escapes backslashes,
#            quotes, and replaces newlines/carriage returns/tabs with spaces).
# Arguments:
#   $1 - Raw text string
# Outputs: Prints escaped text string to stdout.
json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="$(printf '%s' "${s}" | tr '\n' ' ' | tr '\r' ' ' | tr '\t' ' ')"
  printf '%s' "${s}"
}

# Function: log_ndjson
# Objective: Appends structured NDJSON audit entries to the file defined by NDJSON_LOG_FILE.
# Arguments:
#   $1 - Severity level (INFO, SUCCESS, WARN, ERROR)
#   $2 - Event name (e.g., "log", "start", "finish", "abort")
#   $3 - Log message text
#   $4 - Optional extra JSON details object (e.g., '{"exit_code":0}')
log_ndjson() {
  local level="$1"
  local event="$2"
  local msg="$3"
  local extra="${4:-}"

  [ -z "${NDJSON_LOG_FILE:-}" ] && return 0

  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2> /dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
  local esc_module esc_level esc_event esc_msg
  esc_module="$(json_escape "${APP_NAME:-$(basename "$(pwd)")}")"
  esc_level="$(json_escape "${level}")"
  esc_event="$(json_escape "${event}")"
  esc_msg="$(json_escape "${msg}")"

  local line="{\"timestamp\":\"${timestamp}\",\"module\":\"${esc_module}\",\"level\":\"${esc_level}\",\"event\":\"${esc_event}\",\"message\":\"${esc_msg}\""
  if [ -n "${extra}" ]; then
    line="${line},\"details\":${extra}}"
  else
    line="${line}}"
  fi

  printf '%s\n' "${line}" >> "${NDJSON_LOG_FILE}" 2> /dev/null || true
}

# ------------------------------------------------------------------------------
# 10. Standardized Logging Helpers (ANSI formatting with NDJSON audit capture)
# ------------------------------------------------------------------------------
COLOR_BLUE="\033[1;34m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_RESET="\033[0m"

# Function: log_info
# Objective: Prints an informational message to stdout (blue indicator on TTY)
#            and records an INFO entry in the NDJSON audit log.
log_info() {
  if [ -t 1 ]; then
    echo -e "${COLOR_BLUE}>>${COLOR_RESET} $*"
  else
    echo ">> $*"
  fi
  log_ndjson "INFO" "log" "$*"
}

# Function: log_success
# Objective: Prints an operation success message to stdout (green indicator on TTY)
#            and records a SUCCESS entry in the NDJSON audit log.
log_success() {
  if [ -t 1 ]; then
    echo -e "${COLOR_GREEN}   [OK]${COLOR_RESET} $*"
  else
    echo "   [OK] $*"
  fi
  log_ndjson "SUCCESS" "log" "$*"
}

# Function: log_warn
# Objective: Prints a warning message to stderr (yellow indicator on TTY)
#            and records a WARN entry in the NDJSON audit log.
log_warn() {
  if [ -t 2 ]; then
    echo -e "${COLOR_YELLOW}   [WARN]${COLOR_RESET} $*" >&2
  else
    echo "   [WARN] $*" >&2
  fi
  log_ndjson "WARN" "log" "$*"
}

# Function: log_error
# Objective: Prints an error message to stderr (red indicator on TTY)
#            and records an ERROR entry in the NDJSON audit log.
log_error() {
  if [ -t 2 ]; then
    echo -e "${COLOR_RED}   [ERROR]${COLOR_RESET} $*" >&2
  else
    echo "   [ERROR] $*" >&2
  fi
  log_ndjson "ERROR" "log" "$*"
}

# ------------------------------------------------------------------------------
# 11. Path & Environment Normalizers
# ------------------------------------------------------------------------------
# Function: normalize_to_mixed_path
# Objective: Converts any path (Windows C:\, Cygwin /cygdrive/c, MSYS /c)
#            into canonical mixed path format: drive:/path/sub with forward slashes.
# Arguments:
#   $1 - Path to normalize
# Outputs: Prints normalized mixed path (drive:/path/sub) to stdout.
normalize_to_mixed_path() {
  local p="${1:-}"
  [ -z "$p" ] && return
  if [ "${HOST_OS:-}" != "WIN" ]; then
    echo "$p"
    return
  fi
  if [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*) ]]; then
    echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
  elif [[ "$p" =~ ^/cygdrive/([a-zA-Z])/(.*) ]]; then
    echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
  elif [[ "$p" =~ ^/([a-zA-Z])/(.*) ]]; then
    echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
  elif [[ "$p" =~ ^([a-zA-Z]):[/\\](.*) ]]; then
    echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]//\\//}"
  elif command -v cygpath &> /dev/null; then
    cygpath -m "$p"
  else
    echo "$p"
  fi
}

# Function: mixed_to_wsl_path
# Objective: Transforms a mixed path (drive:/path/sub) into standard WSL mount path (/mnt/drive/path/sub).
# Arguments:
#   $1 - Path to convert
# Outputs: Prints resolved WSL mount path to stdout.
mixed_to_wsl_path() {
  local p="${1:-}"
  [ -z "$p" ] && return
  if [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*) ]]; then
    echo "$p"
    return
  fi
  local mixed
  mixed="$(normalize_to_mixed_path "$p")"
  if [[ "$mixed" =~ ^([a-zA-Z]):/(.*) ]]; then
    echo "/mnt/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
  else
    echo "$mixed"
  fi
}

# Function: check_wsl_available
# Objective: Verifies whether the WSL CLI tool is available on the Windows host.
# Returns: 0 if wsl/wsl.exe is available, 1 otherwise.
check_wsl_available() {
  command -v wsl &> /dev/null || command -v wsl.exe &> /dev/null
}

# Function: run_in_wsl
# Objective: Executes commands inside the default WSL Linux distribution
#            using an interactive login shell (bash -lc) in the converted target directory.
# Arguments:
#   $1 - Target working directory (Windows, MSYS, or mixed format)
#   $2..@ - Command arguments to execute in WSL
# Returns: Propagates the exit code from WSL.
run_in_wsl() {
  local target_dir="$1"
  shift
  local wsl_cwd
  wsl_cwd="$(mixed_to_wsl_path "${target_dir}")"

  local cmd
  cmd="$(printf '%q ' "$@")"
  wsl --cd / bash -lc "cd \"${wsl_cwd}\" && ${cmd}"
}

# Function: normalize_and_add_to_path
# Objective: Converts Windows drive-letter paths to POSIX paths (using cygpath
#            or bash regex substitution) and prepends them to $PATH.
# Arguments:
#   $1 - Target directory path
# Returns: 0 if directory exists and was added to PATH, 1 otherwise.
normalize_and_add_to_path() {
  local target_dir="${1:-}"
  [ -z "${target_dir}" ] && return 1

  if [ -d "${target_dir}" ]; then
    if command -v cygpath &> /dev/null; then
      target_dir="$(cygpath -u "${target_dir}")"
    elif [[ "${target_dir}" =~ ^([a-zA-Z]):[/\\](.*) ]]; then
      target_dir="/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]//\\//}"
    fi
    export PATH="${target_dir}:${PATH:-}"
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# 12. JSON Field Parser
# ------------------------------------------------------------------------------
# Function: parse_json_field
# Objective: Robust multi-engine JSON value extractor with a 4-tier fallback:
#            1. jq (fastest, full JSON parser)
#            2. python3 (standard python JSON library)
#            3. python (python 2/3 fallback)
#            4. awk (pure POSIX regex key-value extraction)
# Arguments:
#   $1 - Path to JSON file
#   $2 - Key name to extract
#   $3 - Default fallback value if key is not found
# Outputs: Prints extracted string value to stdout.
parse_json_field() {
  local json_file="${1:-}"
  local key="${2:-}"
  local default_val="${3:-}"
  local result=""

  if [ ! -f "${json_file}" ]; then
    echo "${default_val}"
    return
  fi

  if command -v jq &> /dev/null; then
    result=$(jq -r ".${key} // empty" "${json_file}" 2> /dev/null || true)
  elif command -v python3 &> /dev/null; then
    result=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2], ''); print(v if v is not None else '')" "${json_file}" "${key}" 2> /dev/null || true)
  elif command -v python &> /dev/null; then
    result=$(python -c "import json, sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2], ''); print(v if v is not None else '')" "${json_file}" "${key}" 2> /dev/null || true)
  else
    result=$(awk -v k="\"$key\"" '
      $0 ~ k {
        sub(/^[^:]*:[[:space:]]*/, "");
        sub(/,[[:space:]]*$/, "");
        sub(/^"/, "");
        sub(/"$/, "");
        print;
        exit;
      }
    ' "${json_file}" 2> /dev/null || true)
  fi

  if [ -n "${result}" ] && [ "${result}" != "null" ]; then
    echo "${result}"
  else
    echo "${default_val}"
  fi
}

# Function: parse_json_history
# Objective: Extracts changelog history records from build.json supporting either
#            a JSON array of string entries or a multi-line string.
#            Employs a 4-tier engine fallback: jq -> python3 -> python -> awk.
# Arguments:
#   $1 - Path to JSON configuration file
# Outputs: Prints extracted history records line by line to stdout.
parse_json_history() {
  local json_file="${1:-}"
  [ ! -f "${json_file}" ] && return

  local result=""
  if command -v jq &> /dev/null; then
    result=$(jq -r 'if .history == null then empty elif (.history | type) == "array" then .history[] elif (.history | type) == "string" then .history else empty end' "${json_file}" 2> /dev/null || true)
  elif command -v python3 &> /dev/null; then
    result=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1], encoding='utf-8')); h=d.get('history'); (sys.stdout.write('\n'.join(h) + '\n') if isinstance(h, list) else sys.stdout.write(str(h) + '\n')) if h else None" "${json_file}" 2> /dev/null || true)
  elif command -v python &> /dev/null; then
    result=$(python -c "import json, sys; d=json.load(open(sys.argv[1], encoding='utf-8')); h=d.get('history'); (sys.stdout.write('\n'.join(h) + '\n') if isinstance(h, list) else sys.stdout.write(str(h) + '\n')) if h else None" "${json_file}" 2> /dev/null || true)
  else
    result=$(awk '
      BEGIN { in_arr = 0; }
      /"history"[[:space:]]*:[[:space:]]*\[/ {
        in_arr = 1;
        next;
      }
      in_arr {
        if ($0 ~ /\]/) {
          in_arr = 0;
          next;
        }
        line = $0;
        sub(/^[[:space:]]*"/, "", line);
        sub(/",?[[:space:]]*$/, "", line);
        gsub(/\\"/, "\"", line);
        print line;
        next;
      }
      /"history"[[:space:]]*:[[:space:]]*"/ {
        line = $0;
        sub(/^[^:]*:[[:space:]]*"/, "", line);
        sub(/"[[:space:]]*,?[[:space:]]*$/, "", line);
        gsub(/\\n/, "\n", line);
        gsub(/\\"/, "\"", line);
        print line;
      }
    ' "${json_file}" 2> /dev/null || true)
  fi

  echo "${result}"
}

# ------------------------------------------------------------------------------
# 13. Packaging Metadata Sanitizers & Changelog Formatters
# ------------------------------------------------------------------------------
# Function: sanitize_rpm_spec_string
# Objective: Escapes percent signs (%) to %% to prevent RPM spec macro expansions.
# Arguments:
#   $1 - Raw string value
# Outputs: Prints sanitized string to stdout.
sanitize_rpm_spec_string() {
  local val="${1:-}"
  echo "${val//%/%%}"
}

# Function: sanitize_deb_description
# Objective: Formats multi-line description text for Debian RFC 822 control file compliance
#            (indents lines with leading spaces, replaces blank lines with ' .').
# Arguments:
#   $1 - Raw description string
# Outputs: Prints formatted multi-line description to stdout.
sanitize_deb_description() {
  echo "$1" | awk '
    {
      if (NF == 0) {
        print " ."
      } else {
        sub(/^[[:space:]]+/, "");
        print " " $0
      }
    }
  '
}

# Function: format_rpm_changelog
# Objective: Formats history records for RPM spec file %changelog compliance.
#            Substitutes <version> and <release> tokens with actual module values,
#            retaining strictly ${VERSION}-${RELEASE} (e.g. 0.2.1-1 without OS/dist tags).
#            Escapes percent signs (%) to %% for spec macro safety.
# Arguments:
#   $1 - Raw history text (from parse_json_history)
#   $2 - Package version (${VERSION})
#   $3 - Package release number (${RELEASE})
#   $4 - Package maintainer string (${RPM_SPEC_MAINT})
#   $5 - (Optional) Current date string (Day Mon DD YYYY)
# Outputs: Prints formatted RPM spec changelog to stdout.
format_rpm_changelog() {
  local raw_history="${1:-}"
  local version="${2:-}"
  local release="${3:-}"
  local maintainer="${4:-}"
  local date_str="${5:-$(LC_ALL=C date +"%a %b %d %Y")}"

  if [ -z "${raw_history//[[:space:]]/}" ]; then
    cat << EOF
* ${date_str} ${maintainer} - ${version}-${release}
- Static binary package for universal Linux distribution
EOF
    return
  fi

  local substituted
  substituted="$(echo "${raw_history}" | sed \
    -e "s/<version>/${version}/g" \
    -e "s/<release>/${release}/g" \
    -e "s/\${VERSION}/${version}/g" \
    -e "s/\${RELEASE}/${release}/g")"

  echo "${substituted//%/%%}"
}

# Function: format_deb_changelog
# Objective: Formats history records into Debian RFC 822 changelog format
#            (/usr/share/doc/<app>/changelog.Debian.gz).
#            Converts RPM-style header lines into Debian stanzas, standardizes
#            item indentation, substitutes <version> and <release> (strictly ${VERSION}-${RELEASE}),
#            and converts dates to RFC 2822 format (e.g., 'Wed, 21 Oct 2026 00:00:00 -0500').
# Arguments:
#   $1 - Application name (${APP_NAME})
#   $2 - Raw history text (from parse_json_history)
#   $3 - Package version (${VERSION})
#   $4 - Package release number (${RELEASE})
#   $5 - Distribution / channel (${CHANNEL:-stable})
#   $6 - Maintainer string (${RAW_MAINTAINER})
# Outputs: Prints formatted Debian RFC 822 changelog to stdout.
format_deb_changelog() {
  local app_name="${1:-app}"
  local raw_history="${2:-}"
  local version="${3:-0.1.0}"
  local release="${4:-1}"
  local channel="${5:-stable}"
  local maintainer="${6:-Mis Center <support@criticalsys.net>}"
  local default_rfc_date
  default_rfc_date="$(LC_ALL=C date -R 2> /dev/null || date)"

  if [ -z "${raw_history//[[:space:]]/}" ]; then
    cat << EOF
${app_name} (${version}-${release}) ${channel}; urgency=low

  * Static binary package for universal Linux distribution

 -- ${maintainer}  ${default_rfc_date}
EOF
    return
  fi

  local substituted
  substituted="$(echo "${raw_history}" | sed \
    -e "s/<version>/${version}/g" \
    -e "s/<release>/${release}/g" \
    -e "s/\${VERSION}/${version}/g" \
    -e "s/\${RELEASE}/${release}/g")"

  local has_rpm_header=false
  while IFS= read -r line || [ -n "${line}" ]; do
    if [[ "${line}" =~ ^\*[[:space:]]+(.*[0-9]{4})[[:space:]]+(.*\<.*\>)[[:space:]]*-[[:space:]]*(.*)$ ]]; then
      has_rpm_header=true
      break
    fi
  done <<< "${substituted}"

  if [ "${has_rpm_header}" = false ]; then
    echo "${app_name} (${version}-${release}) ${channel}; urgency=low"
    echo ""
    while IFS= read -r line || [ -n "${line}" ]; do
      local trimmed="${line#"${line%%[![:space:]]*}"}"
      [ -z "${trimmed}" ] && continue
      if [[ "${trimmed}" =~ ^[-*][[:space:]]*(.*)$ ]]; then
        echo "  * ${BASH_REMATCH[1]}"
      else
        echo "  * ${trimmed}"
      fi
    done <<< "${substituted}"
    echo ""
    echo " -- ${maintainer}  ${default_rfc_date}"
    return
  fi

  local current_maint=""
  local current_rfc_date=""
  local in_stanza=false

  while IFS= read -r line || [ -n "${line}" ]; do
    if [[ "${line}" =~ ^\*[[:space:]]+(.*[0-9]{4})[[:space:]]+(.*\<.*\>)[[:space:]]*-[[:space:]]*(.*)$ ]]; then
      local entry_date="${BASH_REMATCH[1]}"
      local entry_maint="${BASH_REMATCH[2]}"
      local entry_ver="${BASH_REMATCH[3]}"

      entry_date="${entry_date#"${entry_date%%[![:space:]]*}"}"
      entry_date="${entry_date%"${entry_date##*[![:space:]]}"}"
      entry_maint="${entry_maint#"${entry_maint%%[![:space:]]*}"}"
      entry_maint="${entry_maint%"${entry_maint##*[![:space:]]}"}"
      entry_ver="${entry_ver#"${entry_ver%%[![:space:]]*}"}"
      entry_ver="${entry_ver%"${entry_ver##*[![:space:]]}"}"

      if [ "${in_stanza}" = true ]; then
        echo ""
        echo " -- ${current_maint}  ${current_rfc_date}"
        echo ""
      fi

      current_maint="${entry_maint:-${maintainer}}"
      current_rfc_date="$(LC_ALL=C date -d "${entry_date}" -R 2> /dev/null || echo "${default_rfc_date}")"
      echo "${app_name} (${entry_ver}) ${channel}; urgency=low"
      echo ""
      in_stanza=true
    elif [ "${in_stanza}" = true ]; then
      local trimmed="${line#"${line%%[![:space:]]*}"}"
      [ -z "${trimmed}" ] && continue
      if [[ "${trimmed}" =~ ^[-*][[:space:]]*(.*)$ ]]; then
        echo "  * ${BASH_REMATCH[1]}"
      else
        echo "  * ${trimmed}"
      fi
    fi
  done <<< "${substituted}"

  if [ "${in_stanza}" = true ]; then
    echo ""
    echo " -- ${current_maint}  ${current_rfc_date}"
  fi
}

# ------------------------------------------------------------------------------
# 14. SSH Code Signing Key Resolution & Generation Engine
# ------------------------------------------------------------------------------
# Function: resolve_signing_key_path
# Objective: Canonicalizes SSH private key paths by expanding tildes (~),
#            resolving directories to <dir>/release_key, and converting
#            relative paths to absolute paths.
# Arguments:
#   $1 - Key path or directory (optional, defaults to DEFAULT_SIGN_KEY)
# Outputs: Prints resolved canonical key path to stdout.
resolve_signing_key_path() {
  local p="${1:-${DEFAULT_SIGN_KEY}}"
  p="${p/#\~/$HOME}"
  if [ -z "${p}" ]; then
    p="${DEFAULT_SIGN_KEY}"
  elif [ -d "${p}" ] || [[ "${p}" == */ ]] || { [ "$(basename "${p}")" = "signing" ] && [ ! -f "${p}" ]; }; then
    p="${p%/}/release_key"
  fi
  local p_dir
  p_dir="$(dirname "${p}")"
  if [ -d "${p_dir}" ]; then
    local abs_dir
    abs_dir="$(cd "${p_dir}" 2> /dev/null && pwd)"
    if [ "${abs_dir}" = "/" ]; then
      p="/$(basename "${p}")"
    else
      p="${abs_dir}/$(basename "${p}")"
    fi
  fi
  echo "${p}"
}

# Function: generate_signing_key
# Objective: Interactively or autonomously generates an isolated Ed25519 SSH
#            signing key pair with mandatory identity binding and hardened
#            directory/file permissions (0700 dir, 0600 private key, 0644 pub key).
# Arguments:
#   $1 - Target private key path
#   $2 - Mandatory identity email/name (e.g., "mis@criticalsys.net")
#   $3 - Optional comment (defaults to DEFAULT_COMMENT_PREFIX <identity>)
generate_signing_key() {
  local key_path
  key_path="$(resolve_signing_key_path "${1:-${DEFAULT_SIGN_KEY}}")"
  local key_identity="${2:-}"
  local key_comment="${3:-}"

  if [ -z "${key_identity}" ]; then
    log_error "--identity=<id> is MANDATORY when generating a signing key."
    log_error "Example: --genkey --identity=${DEFAULT_IDENTITY}"
    exit "${EXIT_USAGE}"
  fi

  if [ -z "${key_comment}" ]; then
    key_comment="${DEFAULT_COMMENT_PREFIX} <${key_identity}>"
  fi

  if [ -f "${key_path}" ]; then
    log_error "Key file already exists at '${key_path}'. Refusing to overwrite."
    exit "${EXIT_CONFIG}"
  fi

  if ! command -v ssh-keygen &> /dev/null; then
    log_error "ssh-keygen not found. Cannot generate SSH key."
    exit "${EXIT_DEPENDENCY}"
  fi

  local key_dir
  key_dir="$(dirname "${key_path}")"
  mkdir -p "${key_dir}" 2> /dev/null || true
  chmod 700 "${key_dir}" 2> /dev/null || true

  log_info "Generating Ed25519 SSH signing key pair at '${key_path}'..."
  log_info "  Identity : ${key_identity}"
  log_info "  Comment  : ${key_comment}"
  if ! ssh-keygen -t ed25519 -N "" -C "${key_comment}" -f "${key_path}" > /dev/null 2>&1; then
    log_error "ssh-keygen failed to generate key pair."
    exit "${EXIT_GENERAL}"
  fi

  chmod 600 "${key_path}"
  chmod 644 "${key_path}.pub"

  local pub_content
  pub_content="$(cat "${key_path}.pub")"

  echo "================================================================================"
  log_success "SSH Signing Key Pair Created Successfully!"
  echo "  Identity    : ${key_identity}"
  echo "  Comment     : ${key_comment}"
  echo "  Private Key : ${key_path}"
  echo "  Public Key  : ${key_path}.pub"
  echo "--------------------------------------------------------------------------------"
  echo "To configure signature verification, create an 'allowed_signers' file with:"
  echo "  ${key_identity} namespaces=\"file\" ${pub_content}"
  echo ""
  echo "To sign builds with this key, pass:"
  if [ "${key_path}" = "${DEFAULT_SIGN_KEY}" ]; then
    echo "  --sign"
  else
    echo "  --sign=${key_path}"
  fi
  echo "================================================================================"
  exit "${EXIT_SUCCESS}"
}

# ------------------------------------------------------------------------------
# 15. Package Artifact Verification Engine
# ------------------------------------------------------------------------------
# Function: verify_package_artifacts
# Objective: Inspects generated release packages in dist_dir against metadata in build.json.
#            Validates SHA256 checksums, RPM spec metadata (via WSL on Windows),
#            Debian control fields (via WSL on Windows), and archive integrity.
# Arguments:
#   $1 - Module name (app_name)
#   $2 - Path to build.json config file
#   $3 - Distribution directory path (optional, defaults to DEFAULT_DIST_DIR)
# Returns: 0 on full verification success, 1 on any discrepancy or integrity failure.
verify_package_artifacts() {
  local app_name="${1:-}"
  local config_file="${2:-${DEFAULT_CONFIG_FILE}}"
  local dist_dir="${3:-${DEFAULT_DIST_DIR}}"

  if [ "${HOST_OS}" == "WIN" ]; then
    dist_dir="$(normalize_to_mixed_path "${dist_dir}")"
  fi

  if [ -z "${app_name}" ]; then
    log_error "verify_package_artifacts requires a module name as argument 1."
    return 1
  fi

  if [ ! -f "${config_file}" ]; then
    log_error "Configuration file '${config_file}' not found for verification."
    return 1
  fi

  if [ ! -d "${dist_dir}" ]; then
    log_warn "Distribution directory '${dist_dir}' does not exist. Nothing to verify."
    return 0
  fi

  local exp_version exp_release exp_group exp_section exp_priority exp_license
  exp_version="$(parse_json_field "${config_file}" "version" "${DEFAULT_VERSION}")"
  exp_release="$(parse_json_field "${config_file}" "release" "${DEFAULT_RELEASE}")"
  exp_group="$(parse_json_field "${config_file}" "group" "${DEFAULT_GROUP}")"
  exp_section="$(parse_json_field "${config_file}" "section" "${DEFAULT_SECTION}")"
  exp_priority="$(parse_json_field "${config_file}" "priority" "${DEFAULT_PRIORITY}")"
  exp_license="$(parse_json_field "${config_file}" "license" "${DEFAULT_LICENSE}")"

  log_info "Verifying packages for '${app_name}' in '${dist_dir}' against '${config_file}'..."

  local pkg_count=0
  local errors=0

  # 1. Verify SHA256 Checksums
  local sha_files=()
  shopt -s nullglob
  sha_files=("${dist_dir}/${app_name}-"*.[sS][hH][aA]256)
  shopt -u nullglob

  for sha_file in "${sha_files[@]}"; do
    [ -f "${sha_file}" ] || continue
    pkg_count=$((pkg_count + 1))
    local sha_base
    sha_base="$(basename "${sha_file}")"
    local sha_target="${sha_file%.*}"
    if [ ! -f "${sha_target}" ]; then
      log_error "Orphan checksum file: ${sha_base} (target archive missing)"
      errors=$((errors + 1))
      continue
    fi

    local check_ok=false
    if (cd "${dist_dir}" && { command -v sha256sum &> /dev/null && sha256sum -c "${sha_base}" > /dev/null 2>&1; } || { command -v shasum &> /dev/null && shasum -a 256 -c "${sha_base}" > /dev/null 2>&1; }); then
      check_ok=true
    fi

    if [ "${check_ok}" = true ]; then
      log_success "Checksum verified: ${sha_base}"
    else
      log_error "Checksum verification FAILED: ${sha_base}"
      errors=$((errors + 1))
    fi
  done

  # 2. Verify RPM Packages (*.rpm)
  local rpm_files=()
  shopt -s nullglob
  rpm_files=("${dist_dir}/${app_name}-"*.rpm)
  shopt -u nullglob

  for rpm_file in "${rpm_files[@]}"; do
    [ -f "${rpm_file}" ] || continue
    pkg_count=$((pkg_count + 1))
    local rpm_base
    rpm_base="$(basename "${rpm_file}")"
    local rpm_meta=""

    local has_rpm_tool=false
    if [ "${HOST_OS}" == "WIN" ] && ! command -v rpm &> /dev/null; then
      if check_wsl_available; then
        has_rpm_tool=true
        local wsl_rpm
        wsl_rpm="$(mixed_to_wsl_path "${rpm_file}")"
        rpm_meta="$(wsl --cd / bash -lc "rpm -qp --queryformat '%{NAME}|%{VERSION}|%{RELEASE}|%{GROUP}|%{LICENSE}\n' \"${wsl_rpm}\" 2> /dev/null || true" | tr -d '\r')"
      fi
    elif command -v rpm &> /dev/null; then
      has_rpm_tool=true
      rpm_meta="$(rpm -qp --queryformat '%{NAME}|%{VERSION}|%{RELEASE}|%{GROUP}|%{LICENSE}\n' "${rpm_file}" 2> /dev/null || true)"
    fi

    if [ "${has_rpm_tool}" = false ]; then
      log_warn "Skipped RPM metadata check for ${rpm_base} (rpm tool not found)."
    elif [ -z "${rpm_meta}" ]; then
      log_error "RPM package integrity test FAILED: ${rpm_base} (corrupted package or query failed)"
      errors=$((errors + 1))
    else
      IFS='|' read -r act_name act_ver act_rel act_grp act_lic <<< "${rpm_meta}"
      local rpm_match=true
      if [ "${act_name}" != "${app_name}" ]; then
        log_error "RPM Name mismatch in ${rpm_base}: expected '${app_name}', found '${act_name}'"
        rpm_match=false
      fi
      if [ "${act_ver}" != "${exp_version}" ]; then
        log_error "RPM Version mismatch in ${rpm_base}: expected '${exp_version}', found '${act_ver}'"
        rpm_match=false
      fi
      if [ "${act_rel}" != "${exp_release}" ]; then
        log_error "RPM Release mismatch in ${rpm_base}: expected '${exp_release}', found '${act_rel}'"
        rpm_match=false
      fi
      if [ "${act_grp}" != "${exp_group}" ]; then
        log_error "RPM Group mismatch in ${rpm_base}: expected '${exp_group}', found '${act_grp}'"
        rpm_match=false
      fi
      if [ "${act_lic}" != "${exp_license}" ]; then
        log_error "RPM License mismatch in ${rpm_base}: expected '${exp_license}', found '${act_lic}'"
        rpm_match=false
      fi

      if [ "${rpm_match}" = true ]; then
        log_success "Verified RPM metadata: ${rpm_base} (Group: ${act_grp}, Version: ${act_ver}, Release: ${act_rel})"
      else
        errors=$((errors + 1))
      fi
    fi
  done

  # 3. Verify Debian Packages (*.deb)
  local deb_files=()
  shopt -s nullglob
  deb_files=("${dist_dir}/${app_name}-"*.deb)
  shopt -u nullglob

  for deb_file in "${deb_files[@]}"; do
    [ -f "${deb_file}" ] || continue
    pkg_count=$((pkg_count + 1))
    local deb_base
    deb_base="$(basename "${deb_file}")"
    local deb_info=""

    local has_dpkg_tool=false
    if [ "${HOST_OS}" == "WIN" ] && ! command -v dpkg-deb &> /dev/null; then
      if check_wsl_available; then
        has_dpkg_tool=true
        local wsl_deb
        wsl_deb="$(mixed_to_wsl_path "${deb_file}")"
        deb_info="$(wsl --cd / bash -lc "dpkg-deb -I \"${wsl_deb}\" 2> /dev/null || true" | tr -d '\r')"
      fi
    elif command -v dpkg-deb &> /dev/null; then
      has_dpkg_tool=true
      deb_info="$(dpkg-deb -I "${deb_file}" 2> /dev/null || true)"
    fi

    if [ "${has_dpkg_tool}" = false ]; then
      log_warn "Skipped DEB metadata check for ${deb_base} (dpkg-deb tool not found)."
    elif [ -z "${deb_info}" ]; then
      log_error "DEB package integrity test FAILED: ${deb_base} (corrupted package or query failed)"
      errors=$((errors + 1))
    else
      local act_deb_pkg act_deb_ver act_deb_sec act_deb_prio
      act_deb_pkg="$(echo "${deb_info}" | awk -F': ' '/Package:/{print $2; exit}' | tr -d '\r')"
      act_deb_ver="$(echo "${deb_info}" | awk -F': ' '/Version:/{print $2; exit}' | tr -d '\r')"
      act_deb_sec="$(echo "${deb_info}" | awk -F': ' '/Section:/{print $2; exit}' | tr -d '\r')"
      act_deb_prio="$(echo "${deb_info}" | awk -F': ' '/Priority:/{print $2; exit}' | tr -d '\r')"

      local deb_match=true
      if [ "${act_deb_pkg}" != "${app_name}" ]; then
        log_error "DEB Package mismatch in ${deb_base}: expected '${app_name}', found '${act_deb_pkg}'"
        deb_match=false
      fi
      local exp_deb_ver="${exp_version}-${exp_release}"
      if [ "${act_deb_ver}" != "${exp_deb_ver}" ]; then
        log_error "DEB Version mismatch in ${deb_base}: expected '${exp_deb_ver}', found '${act_deb_ver}'"
        deb_match=false
      fi
      if [ "${act_deb_sec}" != "${exp_section}" ]; then
        log_error "DEB Section mismatch in ${deb_base}: expected '${exp_section}', found '${act_deb_sec}'"
        deb_match=false
      fi
      if [ "${act_deb_prio}" != "${exp_priority}" ]; then
        log_error "DEB Priority mismatch in ${deb_base}: expected '${exp_priority}', found '${act_deb_prio}'"
        deb_match=false
      fi

      if [ "${deb_match}" = true ]; then
        log_success "Verified DEB metadata: ${deb_base} (Version: ${act_deb_ver}, Section: ${act_deb_sec}, Priority: ${act_deb_prio})"
      else
        errors=$((errors + 1))
      fi
    fi
  done

  # 4. Verify Windows Zipball Packages (*.zip)
  local zip_files=()
  shopt -s nullglob
  zip_files=("${dist_dir}/${app_name}-"*.zip)
  shopt -u nullglob

  for zip_file in "${zip_files[@]}"; do
    [ -f "${zip_file}" ] || continue
    pkg_count=$((pkg_count + 1))
    local zip_base
    zip_base="$(basename "${zip_file}")"
    if command -v unzip &> /dev/null; then
      if unzip -tq "${zip_file}" > /dev/null 2>&1; then
        if [[ "${zip_base}" == *"-src.zip"* ]]; then
          log_success "Verified Source Zipball integrity: ${zip_base}"
        elif unzip -l "${zip_file}" | grep -q "${app_name}.exe"; then
          log_success "Verified Windows Zipball integrity: ${zip_base} (contains ${app_name}.exe)"
        else
          log_error "Windows Zipball missing expected executable: ${zip_base}"
          errors=$((errors + 1))
        fi
      else
        log_error "Windows Zipball integrity test FAILED: ${zip_base}"
        errors=$((errors + 1))
      fi
    else
      log_warn "Skipped Windows Zipball integrity check for ${zip_base} (unzip tool not found)."
    fi
  done

  # 5. Verify Linux Tarball Archives (*.tar.xz)
  local tar_files=()
  shopt -s nullglob
  tar_files=("${dist_dir}/${app_name}-"*.tar.xz)
  shopt -u nullglob

  for tar_file in "${tar_files[@]}"; do
    [ -f "${tar_file}" ] || continue
    pkg_count=$((pkg_count + 1))
    local tar_base
    tar_base="$(basename "${tar_file}")"
    local tar_contents=""
    local has_tar_tool=false
    if command -v tar &> /dev/null; then
      has_tar_tool=true
      tar_contents="$(tar --force-local -tf "${tar_file}" 2> /dev/null || tar -tf "${tar_file}" 2> /dev/null || true)"
    fi
    if [ -z "${tar_contents}" ] && [ "${HOST_OS}" == "WIN" ] && check_wsl_available; then
      has_tar_tool=true
      local wsl_tar
      wsl_tar="$(mixed_to_wsl_path "${tar_file}")"
      tar_contents="$(wsl --cd / bash -lc "tar -tf \"${wsl_tar}\" 2> /dev/null || true")"
    fi

    if [ "${has_tar_tool}" = false ]; then
      log_warn "Skipped Tarball integrity check for ${tar_base} (tar tool not found)."
    elif [ -z "${tar_contents}" ]; then
      log_error "Linux Tarball integrity test FAILED: ${tar_base} (corrupted archive or extraction error)"
      errors=$((errors + 1))
    else
      if [[ "${tar_base}" == *"-src.tar.xz"* ]]; then
        log_success "Verified Source Tarball integrity: ${tar_base}"
      elif echo "${tar_contents}" | grep -q "${app_name}"; then
        log_success "Verified Linux Tarball integrity: ${tar_base} (contains ${app_name})"
      else
        log_error "Linux Tarball missing expected binary: ${tar_base}"
        errors=$((errors + 1))
      fi
    fi
  done

  if [ ${pkg_count} -eq 0 ]; then
    log_warn "No package artifacts found in '${dist_dir}' matching '${app_name}-*'."
    return 0
  fi

  if [ ${errors} -gt 0 ]; then
    log_error "Package verification encountered ${errors} error(s) for '${app_name}'."
    return 1
  fi

  log_success "Package verification passed successfully for '${app_name}' (${pkg_count} checks)."
  return 0
}
