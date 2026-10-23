#!/bin/bash
# ==============================================================================
#  Go Compilation & Quality Pipeline Engine
#  File      : build_go.sh
#  Version   : 2.2.0
#  Date      : 2026-10-22
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Hardened, cross-platform Go build and quality assurance engine with
#    orthogonal target platform and packaging controls. Compiles 100% static
#    binaries (CGO_ENABLED=0) for universal Linux compatibility across release
#    Tarballs, RPMs, and DEB packages, and builds Windows executables and Zip
#    archives under Cygwin/MSYS2 environments. Generates parallel-safe per-archive
#    .sha256 checksums and optional Ed25519 SSH digital signatures.
#
#  Core Components:
#    1. Environment & Prerequisite Validator: Enforces fail-fast verification of Go,
#       archive utilities, packaging tools (dpkg-deb, rpmbuild), and SSH signers.
#    2. Metadata & Configuration Extractor: Dynamically extracts application settings,
#       semantic versions, Git commit hashes, and maintainer metadata from build.json.
#    3. Quality Assurance & Test Engine: Executes automated Go unit tests, code coverage
#       analysis, static inspection (vet, gofumpt), and vulnerability/security gates.
#    4. Static Compilation Engine: Compiles cross-platform, dependency-free static
#       binaries with trimmed symbol paths and embedded build/version stamping.
#    5. Multi-Format Distribution Packager: Builds standardized Linux tarballs (.tar.xz),
#       Windows zipballs (.zip), Debian packages (.deb), and Red Hat packages (.rpm).
#    6. Source Archive Generator: Creates sanitized source archives (.tar.xz / .zip)
#       with strict exclusions for credentials, keys, environment files, and build artifacts.
#    7. Checksum & SSH Signature Engine: Generates parallel-safe SHA256 checksums and
#       cryptographic SSH signatures for all generated distribution artifacts.
#    8. Artifact Lifecycle Cleaner: Safely wipes previously built module binaries and
#       packages (--clean) and cleans up intermediate compilation staging folders.
#
#  Functionality & Data Flows:
#    - Initialization: Sources build.inc, installs exit/abort signal traps, detects host OS.
#    - Argument Resolution: Parses orthogonal platform, packaging, clean, and quality flags.
#    - Metadata Loading: Extracts configuration from local build.json (with fallback defaults).
#    - Test & Quality Gate: If enabled, runs go test (-cover) or linters (vet, golangci-lint,
#      govulncheck, gosec); halts execution on gate failures unless overridden.
#    - Binary Compilation: Compiles static binaries into ../bin with version ldflags.
#    - Release Packaging: If packaging flags are active, constructs release archives, RPMs,
#      and DEBs into ../distrib/ with doc files and sanitized metadata.
#    - Artifact Finalization: Generates .sha256 hashes and .sig signatures for all artifacts.
#    - Cleanup: Intermediate binaries in ../bin are purged if full packaging was performed.
#
#  Test Strategy Explanation:
#    - Automated Unit & Coverage Testing: Invoked via '--testsuite', this phase executes
#      'go test -v -cover ./...' to assert functional correctness and calculate code coverage
#      across all module packages. Exits immediately with EXIT_SUCCESS (0) on passing tests
#      or EXIT_TEST (6) on assertion failures, preventing invalid artifacts from building.
#    - Static Code Analysis: Verifies structural safety using 'go vet' to detect subtle bugs,
#      unreachable code, and incorrect format strings before compilation.
#    - Code Style & Canonical Formatting: Optional execution of 'gofumpt' ensures strict
#      compliance with Go formatting standards without altering code semantics.
#    - Multi-Linter Static Auditing: Integrates 'golangci-lint' with an explicit timeout,
#      evaluating codebase against cyclomatic complexity, dead code, and style rules.
#    - Vulnerability & AST Security Auditing: Employs 'govulncheck' against the official Go
#      Vulnerability Database (known CVEs) and 'gosec' for AST security inspection (detecting
#      tainted inputs, hardcoded secrets, weak crypto, or insecure file permissions).
#    - Quality Gate Policy: Failures in vet, linters, or security audits trigger an immediate
#      build abort with EXIT_AUDIT (5) unless explicitly bypassed via '--ignore-audit' or
#      '--compile-only'.
#
#  Syntax:
#    ./build_go.sh [--windows] [--linux] [--all-platform]
#                  [--archive] [--rpm] [--deb] [--all-pkg]
#                  [--clean] [--compile-only] [--lint-only] [--ignore-audit] [--testsuite]
#                  [--sign[=<key>]] [--genkey[=<path>]] [--identity=<id>]
#                  [--update-modules] [--vendor] [--main-path=<path>] [--log=<file>]
# ==============================================================================


set -euo pipefail

# Resolve directory of build engine
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Load central build include (constants, exit codes, defaults, and shared utilities)
if [ ! -f "${SCRIPT_DIR}/build.inc" ]; then
  echo "ERROR: Required configuration file '${SCRIPT_DIR}/build.inc' not found." >&2
  exit 4
fi
# shellcheck source=./build.inc disable=SC1091
source "${SCRIPT_DIR}/build.inc"

# ------------------------------------------------------------------------------
# Temp Directory Tracking & Cleanup Trap
# ------------------------------------------------------------------------------
# Function: cleanup_temp_dirs
# Objective: Trap handler invoked automatically on EXIT, INT, or TERM signals.
#            Purges all tracked temporary directories and emits an NDJSON abort
#            event if the script terminates with a non-zero exit status.
# Arguments: None (inspects $? for exit code).
# Outputs  : Emits NDJSON abort telemetry on non-zero exit status.
# ------------------------------------------------------------------------------
# shellcheck disable=SC2329
cleanup_temp_dirs() {
  local exit_status=$?
  cleanup_tracked_temp_dirs
  if [ "${exit_status}" -ne 0 ]; then
    log_ndjson "ERROR" "abort" "Build execution terminated with error" "{\"exit_code\":${exit_status}}"
  fi
  exit "${exit_status}"
}
trap cleanup_temp_dirs EXIT INT TERM

# ------------------------------------------------------------------------------
# Artifact Finalization & Per-Archive .sha256 Checksum Generator
# ------------------------------------------------------------------------------
# Function: finalize_artifact
# Objective: Finalizes a distribution artifact by calculating its SHA256 checksum
#            in a parallel-safe per-archive file (<artifact>.sha256) and optionally
#            creating an OpenSSH cryptographic signature (<artifact>.sig).
# Arguments:
#   $1 - Absolute or relative path to the artifact file.
# Outputs  : Creates <artifact>.sha256 and <artifact>.sig alongside the artifact.
# Exit Code: Halts with EXIT_PACKAGE (8) if SSH signature creation fails.
# ------------------------------------------------------------------------------
finalize_artifact() {
  local artifact_path="$1"
  if [ -f "${artifact_path}" ]; then
    local dir_name base_name
    dir_name="$(dirname "${artifact_path}")"
    base_name="$(basename "${artifact_path}")"
    (
      cd "${dir_name}"
      if command -v sha256sum &> /dev/null; then
        sha256sum "${base_name}" > "${base_name}.sha256"
      elif command -v shasum &> /dev/null; then
        shasum -a 256 "${base_name}" > "${base_name}.sha256"
      fi
    )
    log_success "Created: ${artifact_path}"
    log_success "Checksum created: ${artifact_path}.sha256"

    if [ "${DO_SIGN}" = true ]; then
      (
        cd "${dir_name}"
        rm -f "${base_name}.sig"
        if ssh-keygen -Y sign -f "${SIGN_KEY}" -n file "${base_name}" >/dev/null 2>&1; then
          log_success "Signature created: ${artifact_path}.sig"
        else
          log_error "Failed to create SSH signature for ${artifact_path}"
          exit "${EXIT_PACKAGE}"
        fi
      )
    fi
  fi
}

# ------------------------------------------------------------------------------
# Function: check_dependencies
# Objective: Pre-flight fail-fast validation for all required CLI tools.
#            Verifies core build utilities, packaging tools (tar, xz, zip, dpkg-deb,
#            rpmbuild), and OpenSSH signing binaries based on active CLI flags.
# Arguments: None (inspects DO_ARCHIVE, DO_RPM, DO_DEB, DO_SIGN, TARGET_WIN, TARGET_LINUX).
# Exit Code: Halts with EXIT_DEPENDENCY (4) if any required tool is missing, or
#            EXIT_CONFIG (3) if SSH signing is enabled but the private key is missing.
# ------------------------------------------------------------------------------
check_dependencies() {
  local missing=()

  # Core build and parsing tools
  for tool in go awk; do
    if ! command -v "${tool}" &> /dev/null; then
      missing+=("${tool}")
    fi
  done

  # Checksum generator utility (for any artifact generation)
  if [ "${HAS_PACKAGING}" = true ]; then
    if ! command -v sha256sum &> /dev/null && ! command -v shasum &> /dev/null; then
      missing+=("sha256sum (or shasum)")
    fi
  fi

  # Release archives
  if [ "${DO_ARCHIVE}" = true ]; then
    if [ "${TARGET_LINUX}" = true ]; then
      for tool in tar xz; do
        if ! command -v "${tool}" &> /dev/null; then
          missing+=("${tool}")
        fi
      done
    fi
    if [ "${TARGET_WIN}" = true ]; then
      if ! command -v zip &> /dev/null; then
        missing+=("zip")
      fi
    fi
  fi

  # Native Linux package managers
  if [ "${TARGET_LINUX}" = true ]; then
    if [ "${DO_DEB}" = true ] && ! command -v dpkg-deb &> /dev/null; then
      missing+=("dpkg-deb")
    fi
    if [ "${DO_RPM}" = true ] && ! command -v rpmbuild &> /dev/null; then
      missing+=("rpmbuild")
    fi
  fi

  # SSH code signing tools and key verification
  if [ "${DO_SIGN}" = true ]; then
    if ! command -v ssh-keygen &> /dev/null; then
      missing+=("ssh-keygen (OpenSSH)")
    fi
    if [ ! -f "${SIGN_KEY}" ]; then
      log_error "SSH signing key not found at '${SIGN_KEY}'. Run '--genkey' to create one."
      exit "${EXIT_CONFIG}"
    fi
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing required CLI build tool(s): ${missing[*]}"
    exit "${EXIT_DEPENDENCY}"
  fi
}

# ------------------------------------------------------------------------------
# Function: usage
# Objective: Displays standard CLI manual, operational options, target platforms,
#            packaging controls, and diagnostic exit code reference.
# Arguments:
#   $1 - (Optional) Exit code to terminate with. Defaults to 0 (EXIT_SUCCESS).
# ------------------------------------------------------------------------------
usage() {
  cat << EOF
Usage: $0 [platforms...] [packaging...] [options...]

Target Platforms:
  --windows           Target Windows (builds ../bin/<name>.exe; default on Windows)
  --linux             Target Linux (builds static ../bin/<name>; default on Linux)
  --all-platform      Target both Windows and Linux

Packaging Actions:
  --archive           Build release archive (.zip for Windows, .tar.xz for Linux)
                      plus source archive and dedicated .sha256 hash files
  --rpm               Build RPM package in ../distrib/ (Linux target only)
  --deb               Build DEB package in ../distrib/ (Linux target only)
  --all-pkg           Build all release artifacts (--archive --rpm --deb on Linux)
  --sign              Sign release archives with default SSH key (~/.ssh/signing/release_key)
  --sign=<path>       Sign release archives with specified SSH private key
  --genkey            Generate Ed25519 signing key pair at ~/.ssh/signing/release_key and exit (requires --identity=<id>)
  --genkey=<path>     Generate a new Ed25519 SSH signing key pair at <path> and exit (requires --identity=<id>)
  --identity=<id>     Signer identity email/name (mandatory with --genkey, e.g. mis@criticalsys.net)
  --comment=<text>    Custom key comment (optional, defaults to 'Critical Systems Release Signing <<id>>')

Operational Options:
  --clean             Clean previously built artifacts for this module (additive or standalone)
  --compile-only      Skip code quality checks, tests, and linters
  --lint-only         Run quality checks and linters, then exit
  --ignore-audit      Do not abort build if linters/vulnerability checks fail
  --testsuite         Execute Go test suite with coverage
  --update-modules    Force update of Go modules (go get -u -t ./...)
  --vendor            Synchronize vendor directory (go mod vendor)
  --main-path=<path>  Override entrypoint path defined in build.json
  --log=<file>        Append all operations to an NDJSON audit log file
  --help              Show this help message

Behavior:
  - If neither --windows nor --linux is passed, defaults to the current host OS.
  - If no packaging flag (--archive, --rpm, --deb) is passed, only builds binary in ../bin.
  - Generates parallel-safe per-archive checksums (<archive>.sha256).

Exit Codes:
  0 = Success
  1 = General Error
  2 = Usage / CLI Syntax Error
  3 = Configuration / build.json Error
  4 = Missing Prerequisite Host Tool
  5 = Code Quality / Audit Failure
  6 = Test Suite Failure
  7 = Compilation Failure
  8 = Packaging / Archiving Failure
EOF
  exit "${1:-0}"
}

# ------------------------------------------------------------------------------
# Host Environment & Toolchain Detection
# ------------------------------------------------------------------------------
if [ "${HOST_OS}" == "WIN" ]; then
  # Windows toolchain path normalization
  if [ -n "${CC:-}" ] && [[ "${CC}" == *[/\\]* ]]; then
    normalize_and_add_to_path "$(dirname "${CC}")" || true
  elif [ -n "${MINGW_HOME:-}" ]; then
    normalize_and_add_to_path "${MINGW_HOME}/bin" || true
  else
    for p in "${DEFAULT_MINGW_SEARCH_PATHS[@]}"; do
      normalize_and_add_to_path "${p}" && break || true
    done
  fi

  if [ -n "${GIT_BASE:-}" ]; then
    normalize_and_add_to_path "${GIT_BASE}/bin" || normalize_and_add_to_path "${GIT_BASE}" || true
  elif [ -n "${GIT_HOME:-}" ]; then
    normalize_and_add_to_path "${GIT_HOME}/bin" || true
  else
    for p in "${DEFAULT_GIT_SEARCH_PATHS[@]}"; do
      normalize_and_add_to_path "${p}" && break || true
    done
  fi
fi

# Directory Resolution
BINDIR="${BIN_DIR:-${DEFAULT_BIN_DIR}}"
DISTDIR="${DIST_DIR:-${DEFAULT_DIST_DIR}}"

if [ "${HOST_OS}" == "WIN" ] && command -v cygpath &> /dev/null; then
  BINDIR="$(cygpath -m "${BINDIR}")"
  DISTDIR="$(cygpath -m "${DISTDIR}")"
fi

mkdir -p "${BINDIR}" "${DISTDIR}"

# ------------------------------------------------------------------------------
# Parse Command-Line Arguments
# ------------------------------------------------------------------------------
TARGET_WIN=false
TARGET_LINUX=false

DO_ARCHIVE=false
DO_RPM=false
DO_DEB=false
DO_SIGN=false
SIGN_KEY=""
GENERATE_KEY=false
GENERATE_KEY_PATH=""
KEY_IDENTITY=""
KEY_COMMENT=""

COMPILE_ONLY=false
LINT_ONLY=false
IGNORE_AUDIT=false
RUN_TESTSUITE=false
UPDATE_MODULES=false
SYNC_VENDOR=false
MAIN_PATH_OVERRIDE=""
DO_CLEAN=false
HAS_ACTION=false

while [ $# -gt 0 ]; do
  case "$1" in
    --clean)
      DO_CLEAN=true
      shift
      ;;
    --windows)
      TARGET_WIN=true
      HAS_ACTION=true
      shift
      ;;
    --linux)
      TARGET_LINUX=true
      HAS_ACTION=true
      shift
      ;;
    --all-platform)
      TARGET_WIN=true
      TARGET_LINUX=true
      HAS_ACTION=true
      shift
      ;;
    --archive)
      DO_ARCHIVE=true
      HAS_ACTION=true
      shift
      ;;
    --rpm)
      DO_RPM=true
      HAS_ACTION=true
      shift
      ;;
    --deb)
      DO_DEB=true
      HAS_ACTION=true
      shift
      ;;
    --all-pkg|--all)
      DO_ARCHIVE=true
      HAS_ACTION=true
      if [ "${HOST_OS}" == "LINUX" ]; then
        DO_RPM=true
        DO_DEB=true
      fi
      shift
      ;;
    --compile-only)
      COMPILE_ONLY=true
      HAS_ACTION=true
      shift
      ;;
    --lint-only)
      LINT_ONLY=true
      HAS_ACTION=true
      shift
      ;;
    --ignore-audit)
      IGNORE_AUDIT=true
      shift
      ;;
    --testsuite)
      RUN_TESTSUITE=true
      HAS_ACTION=true
      shift
      ;;
    --update-modules)
      UPDATE_MODULES=true
      HAS_ACTION=true
      shift
      ;;
    --vendor)
      SYNC_VENDOR=true
      HAS_ACTION=true
      shift
      ;;
    --main-path=*)
      MAIN_PATH_OVERRIDE="${1#*=}"
      shift
      ;;
    --main-path)
      log_error "--main-path requires a path. Format: --main-path=<path>"
      usage "${EXIT_USAGE}"
      ;;
    --log=*)
      NDJSON_LOG_FILE="${1#*=}"
      shift
      ;;
    --log)
      log_error "--log requires a file path. Format: --log=<path>"
      usage "${EXIT_USAGE}"
      ;;
    --sign)
      DO_SIGN=true
      SIGN_KEY="${DEFAULT_SIGN_KEY}"
      shift
      ;;
    --sign=*)
      DO_SIGN=true
      SIGN_KEY="${1#*=}"
      shift
      ;;
    --identity=*)
      KEY_IDENTITY="${1#*=}"
      shift
      ;;
    --identity)
      log_error "--identity requires a value. Format: --identity=<email-or-id>"
      usage "${EXIT_USAGE}"
      ;;
    --comment=*)
      KEY_COMMENT="${1#*=}"
      shift
      ;;
    --comment)
      log_error "--comment requires a value. Format: --comment=<text>"
      usage "${EXIT_USAGE}"
      ;;
    --genkey|--generate-key)
      GENERATE_KEY=true
      GENERATE_KEY_PATH="${DEFAULT_SIGN_KEY}"
      shift
      ;;
    --genkey=*|--generate-key=*)
      GENERATE_KEY=true
      GENERATE_KEY_PATH="${1#*=}"
      shift
      ;;
    --help)
      usage "${EXIT_SUCCESS}"
      ;;
    *)
      log_error "Unknown option '$1'"
      usage "${EXIT_USAGE}"
      ;;
  esac
done

if [ "${GENERATE_KEY}" = true ]; then
  generate_signing_key "${GENERATE_KEY_PATH}" "${KEY_IDENTITY}" "${KEY_COMMENT}"
fi

if [ -n "${NDJSON_LOG_FILE}" ]; then
  LOG_DIR_PATH="$(mkdir -p "$(dirname "${NDJSON_LOG_FILE}")" 2>/dev/null && cd "$(dirname "${NDJSON_LOG_FILE}")" &>/dev/null && pwd)"
  NDJSON_LOG_FILE="${LOG_DIR_PATH}/$(basename "${NDJSON_LOG_FILE}")"
  touch "${NDJSON_LOG_FILE}" 2>/dev/null || true
fi

if [ "${DO_SIGN}" = true ]; then
  SIGN_KEY="$(resolve_signing_key_path "${SIGN_KEY}")"
fi

# If no target platform was specified, default to the current host OS
if [ "${TARGET_WIN}" = false ] && [ "${TARGET_LINUX}" = false ]; then
  if [ "${HOST_OS}" == "WIN" ]; then
    TARGET_WIN=true
  else
    TARGET_LINUX=true
  fi
fi

# ------------------------------------------------------------------------------
# Windows Host Handling (Cygwin / MSYS2 Environment Filter)
# ------------------------------------------------------------------------------
if [ "${HOST_OS}" == "WIN" ]; then
  # Inform and ignore native Linux package managers (RPM / DEB) on Windows
  if [ "${DO_RPM}" = true ]; then
    log_info "--rpm is ignored on Windows (native Linux package managers are unsupported on Windows hosts)."
    DO_RPM=false
  fi
  if [ "${DO_DEB}" = true ]; then
    log_info "--deb is ignored on Windows (native Linux package managers are unsupported on Windows hosts)."
    DO_DEB=false
  fi
fi

CONFIG_FILE="${CONFIG_FILE:-${DEFAULT_CONFIG_FILE}}"

# Clean Phase (additive or standalone)
if [ "${DO_CLEAN}" = true ]; then
  MODULE_NAME="$(parse_json_field "${CONFIG_FILE}" "name" "$(basename "$(pwd)")")"
  clean_module_artifacts "${MODULE_NAME}" "${BINDIR}" "${DISTDIR}"
  if [ "${HAS_ACTION}" = false ]; then
    exit "${EXIT_SUCCESS}"
  fi
fi

HAS_PACKAGING=false
if [ "${DO_ARCHIVE}" = true ] || [ "${DO_RPM}" = true ] || [ "${DO_DEB}" = true ]; then
  HAS_PACKAGING=true
fi

# Pre-Flight Dependency Validation (Fail-Fast)
check_dependencies

# ------------------------------------------------------------------------------
# Configuration & Metadata Extraction (from build.json)
# ------------------------------------------------------------------------------
if [ ! -f "${CONFIG_FILE}" ]; then
  CURRENT_DIR="$(pwd)"
  log_error "Configuration file '${CONFIG_FILE}' not found in ${CURRENT_DIR}."
  exit "${EXIT_CONFIG}"
fi

APP_NAME="$(parse_json_field "${CONFIG_FILE}" "name" "$(basename "$(pwd)")")"
VERSION="$(parse_json_field "${CONFIG_FILE}" "version" "${DEFAULT_VERSION}")"
RELEASE="$(parse_json_field "${CONFIG_FILE}" "release" "${DEFAULT_RELEASE}")"
CHANNEL="$(parse_json_field "${CONFIG_FILE}" "channel" "${DEFAULT_CHANNEL}")"
MAIN_PATH="$(parse_json_field "${CONFIG_FILE}" "entrypoint" "${DEFAULT_ENTRYPOINT}")"
VERSION_PKG="$(parse_json_field "${CONFIG_FILE}" "version_pkg" "${DEFAULT_VERSION_PKG}")"
BUILD_PKG="$(parse_json_field "${CONFIG_FILE}" "build_pkg" "${DEFAULT_BUILD_PKG}")"
RAW_SUMMARY="$(parse_json_field "${CONFIG_FILE}" "summary" "${APP_NAME} ${DEFAULT_SUMMARY_SUFFIX}")"
RAW_DESCRIPTION="$(parse_json_field "${CONFIG_FILE}" "description" "${APP_NAME} ${DEFAULT_DESC_SUFFIX}")"
RAW_MAINTAINER="$(parse_json_field "${CONFIG_FILE}" "maintainer" "${DEFAULT_MAINTAINER}")"
RAW_LICENSE="$(parse_json_field "${CONFIG_FILE}" "license" "${DEFAULT_LICENSE}")"
RAW_URL="$(parse_json_field "${CONFIG_FILE}" "url" "${DEFAULT_URL}")"
SECTION="$(parse_json_field "${CONFIG_FILE}" "section" "${DEFAULT_SECTION}")"
PRIORITY="$(parse_json_field "${CONFIG_FILE}" "priority" "${DEFAULT_PRIORITY}")"
INSTALL_PATH="$(parse_json_field "${CONFIG_FILE}" "install_path" "${DEFAULT_INSTALL_PATH}")"

if [ -n "${MAIN_PATH_OVERRIDE}" ]; then
  MAIN_PATH="${MAIN_PATH_OVERRIDE}"
fi

# Git Hash Resolution
GIT_HASH="unknown"
if command -v git &> /dev/null && git rev-parse --is-inside-work-tree &> /dev/null; then
  GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
fi

# Release & Distribution Tags
OS_VER="${DEFAULT_OS_VER}"
if [ -f /etc/distrib ]; then
  OS_VER="$(cat /etc/distrib 2>/dev/null || echo "${DEFAULT_OS_VER}")"
elif [ -f /etc/os-release ]; then
  OS_VER="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "${DEFAULT_OS_VER}")"
fi

RPM_RELEASE="${RELEASE}.${OS_VER}.${CHANNEL}"
DEB_VERSION="${VERSION}-${RELEASE}.${OS_VER}.${CHANNEL}"
DIST_BASE="${DISTDIR}/${APP_NAME}-${VERSION}"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo "${DEFAULT_ARCH}")"
[ -z "${ARCH}" ] && ARCH="${DEFAULT_ARCH}"

# Multi-threaded XZ compression & secure proxy
export GOPROXY="${DEFAULT_GOPROXY}"
export XZ_OPT="${DEFAULT_XZ_OPT}"

# ------------------------------------------------------------------------------
# Quality Assurance, Test Suite & Security Audit Phase
# (Skipped entirely if --compile-only is passed)
#
# Test Strategy Explanation:
#   1. Automated Unit & Coverage Testing (--testsuite):
#      - Executes 'go test -v -cover ./...' to assert correctness of business logic
#        and record per-package code coverage metrics.
#      - Operates in isolation: upon completing tests, exits immediately with
#        EXIT_SUCCESS (0) on full pass or EXIT_TEST (6) on any failure, preventing
#        flawed code from advancing to compilation or packaging.
#   2. Dependency Preparation & Synchronization:
#      - Downloads and verifies checksums for all required Go modules.
#      - Prunes unused dependencies (go mod tidy) and optionally updates (--update-modules)
#        or synchronizes the vendor directory (--vendor).
#   3. Code Formatting Gate:
#      - Invokes 'gofumpt' (if installed) to enforce strict formatting standards
#        without mutating program semantics.
#   4. Static Analysis Gate:
#      - Runs 'go vet' to identify subtle bugs, unkeyed struct literals, suspicious
#        constructs, and unreachable code. Sets LINT_ERR=1 upon failure.
#   5. Multi-Linter Static Auditing:
#      - Invokes 'golangci-lint' with a strict 5-minute timeout and disabled
#        per-repo config overrides, aggregating cyclomatic complexity, dead-code,
#        and styling checks.
#   6. Vulnerability & AST Security Auditing:
#      - Runs 'govulncheck' against the official Go Vulnerability Database (CVEs).
#      - Runs 'gosec' in quiet AST scanning mode to detect insecure cryptographic
#        primitives, tainted inputs, SQL injection patterns, or file permission flaws.
#   7. Quality Gate Enforcement:
#      - Evaluates LINT_ERR accumulator. If --lint-only is specified, outputs summary
#        and exits immediately. For standard compilation runs, halts with EXIT_AUDIT (5)
#        unless overridden by --ignore-audit.
# ------------------------------------------------------------------------------
if [ "${COMPILE_ONLY}" = false ]; then
  # 1. Automated Test Suite Execution (Unit Tests & Code Coverage)
  if [ "${RUN_TESTSUITE}" = true ]; then
    log_info "Running automated test suite"
    if ! go test -v -cover ./...; then
      log_error "Automated test suite failed."
      exit "${EXIT_TEST}"
    fi
    exit "${EXIT_SUCCESS}"
  fi

  # 2. Dependency Management & Vendor Synchronization
  log_info "Resolving Go dependencies"
  go mod download

  if [ "${UPDATE_MODULES}" = true ]; then
    log_info "Explicit module update requested: Updating modules to latest"
    go get -u -t ./...
  fi

  go mod tidy

  if [ -d "vendor" ] || [ "${SYNC_VENDOR}" = true ]; then
    log_info "Syncing vendor directory"
    go mod vendor
  fi

  # 3. Static Analysis, Formatting & Security Audits
  log_info "Linting and static analysis"
  LINT_ERR=0
  if command -v gofumpt &> /dev/null; then
    gofumpt -l -w -extra . 2>/dev/null || true
  fi

  if ! go vet ./...; then
    log_error "go vet detected issues."
    LINT_ERR=1
  fi

  # ----------------------------------------------------------------------------
  # Helper Function: run_optional_linter
  # Objective: Runs an optional external linter or security auditing CLI tool
  #            if installed on the host. Catches non-zero returns without an
  #            immediate exit so all linters can report diagnostic feedback.
  # Arguments:
  #   $1    - Command name to test in host PATH (e.g. golangci-lint, govulncheck, gosec).
  #   $2..@ - Command arguments to execute.
  # Sets:
  #   LINT_ERR=1 if the invoked tool exits with a non-zero status.
  # ----------------------------------------------------------------------------
  run_optional_linter() {
    local tool="$1"
    shift
    if command -v "${tool}" &> /dev/null; then
      if ! "$@"; then
        log_error "${tool} detected issues."
        LINT_ERR=1
      fi
    else
      log_warn "${tool} not installed. Skipping."
    fi
  }

  run_optional_linter "golangci-lint" golangci-lint run ./... --no-config --allow-parallel-runners --timeout=5m
  run_optional_linter "govulncheck" govulncheck ./...
  run_optional_linter "gosec" gosec -quiet ./...

  if [ "${LINT_ONLY}" = true ]; then
    if [ ${LINT_ERR} -ne 0 ]; then
      log_error "Code quality audit failed."
      exit "${EXIT_AUDIT}"
    fi
    log_success "All linting and quality checks passed."
    exit "${EXIT_SUCCESS}"
  fi

  # Quality Gate Enforcement
  if [ ${LINT_ERR} -ne 0 ]; then
    if [ "${IGNORE_AUDIT}" = true ]; then
      log_warn "Quality gate failed, but --ignore-audit was specified. Continuing build."
    else
      log_error "Code quality / security audit failed. Halting build (use --ignore-audit or --compile-only to bypass)."
      exit "${EXIT_AUDIT}"
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Compilation Phase
# All Linux binaries are 100% static (CGO_ENABLED=0) for single-binary parity
# across all distros, archives, RPMs, and DEBs.
# ------------------------------------------------------------------------------
LDFLAGS="${DEFAULT_GO_LDFLAGS} -X ${VERSION_PKG}=${VERSION}"
if [ -n "${BUILD_PKG}" ]; then
  LDFLAGS="${LDFLAGS} -X ${BUILD_PKG}=${GIT_HASH}"
fi

# ------------------------------------------------------------------------------
# Function: compile_target_binary
# Objective: Compiles a single static, cross-platform Go binary with embedded
#            version metadata, Git commit hash, and path trimming.
# Arguments:
#   $1 - Target operating system ('linux' or 'windows').
#   $2 - Target binary filename (e.g. '${APP_NAME}' or '${APP_NAME}.exe').
#   $3 - (Optional) Extra linker or compiler flags (e.g. '-tags netgo').
# Architecture & Security:
#   - Enforces CGO_ENABLED=0 to eliminate external glibc/musl dynamic runtime dependencies.
#   - Applies -trimpath to remove developer machine filesystem paths from binary stack traces.
#   - Injects semantic version and Git commit hash via -ldflags -X symbols.
#   - Compiles to a temporary file (${tmp_bin}) before atomically moving into ${BINDIR}.
# Exit Code: Halts with EXIT_COMPILE (7) if the Go compilation command fails.
# ------------------------------------------------------------------------------
compile_target_binary() {
  local target_os="$1"
  local bin_name="$2"
  local extra_flags="${3:-}"

  local target_desc="Static Linux Binary"
  local host_match="LINUX"
  if [ "${target_os}" == "windows" ]; then
    target_desc="Static Windows Binary"
    host_match="WIN"
  fi

  log_info "Compiling ${target_desc}: ${bin_name} (Version: ${VERSION}, Entrypoint: ${MAIN_PATH})"
  local bin_path="${BINDIR}/${bin_name}"
  local tmp_bin="${BINDIR}/${bin_name}.tmp.$$"

  local cmd=(go build -v -buildvcs=false -ldflags "${LDFLAGS}" -trimpath)
  [ -n "${extra_flags}" ] && cmd+=("${extra_flags}")
  cmd+=(-o "${tmp_bin}")
  [ -n "${MAIN_PATH}" ] && cmd+=("${MAIN_PATH}")

  if ! CGO_ENABLED=0 GOOS="${target_os}" GOARCH="${ARCH}" "${cmd[@]}"; then
    rm -f "${tmp_bin}" 2>/dev/null || true
    log_error "${target_desc} compilation failed."
    exit "${EXIT_COMPILE}"
  fi

  chmod 755 "${tmp_bin}"
  mv -f "${tmp_bin}" "${bin_path}"
  log_success "Compiled: ${bin_path}"

  if [ "${HOST_OS}" == "${host_match}" ]; then
    "${bin_path}" --version 2>/dev/null || true
  fi
}

# 1. Compile Static Linux Binary (Single binary reused across tarball, RPM, and DEB)
if [ "${TARGET_LINUX}" = true ]; then
  compile_target_binary "linux" "${APP_NAME}" "${DEFAULT_LINUX_EXTRA_FLAGS}"
fi

# 2. Compile Static Windows Binary (.exe)
if [ "${TARGET_WIN}" = true ]; then
  compile_target_binary "windows" "${APP_NAME}.exe"
fi

# ------------------------------------------------------------------------------
# Packaging Phase
# Builds distribution packages, release archives, and source bundles.
# All artifacts are emitted to ${DISTDIR} (${DEFAULT_DIST_DIR}), followed by
# generation of parallel-safe .sha256 hashes and optional SSH signatures (.sig).
# ------------------------------------------------------------------------------
DOC_FILES=()
for doc in "${DEFAULT_DOC_FILES[@]}"; do
  [ -f "${doc}" ] && DOC_FILES+=("${doc}")
done

# 1. Package Linux Tarball Archive (.tar.xz) if --archive passed for Linux target
if [ "${TARGET_LINUX}" = true ] && [ "${DO_ARCHIVE}" = true ]; then
  log_info "Packaging Linux Tarball Archive"
  STAGE_ARC="$(make_temp_dir "arc_${APP_NAME}")"
  mkdir -p "${STAGE_ARC}/doc"
  cp -af "${BINDIR}/${APP_NAME}" "${STAGE_ARC}/${APP_NAME}"
  for doc in "${DOC_FILES[@]}"; do
    cp -af "${doc}" "${STAGE_ARC}/doc/"
  done

  ARC_FILE="${DIST_BASE}-linux_${ARCH}.tar.xz"
  if ! tar -C "${STAGE_ARC}" -Jcf "${ARC_FILE}" "${APP_NAME}" doc; then
    log_error "Failed to create Linux tarball archive."
    exit "${EXIT_PACKAGE}"
  fi
  rm -rf "${STAGE_ARC}"
  finalize_artifact "${ARC_FILE}"
fi

# 2. Package Windows Zipball Archive (.zip) if --archive passed for Windows target
if [ "${TARGET_WIN}" = true ] && [ "${DO_ARCHIVE}" = true ]; then
  log_info "Packaging Windows Zip Archive"
  STAGE_WIN="$(make_temp_dir "win_${APP_NAME}")"
  mkdir -p "${STAGE_WIN}/doc"
  cp -af "${BINDIR}/${APP_NAME}.exe" "${STAGE_WIN}/${APP_NAME}.exe"
  for doc in "${DOC_FILES[@]}"; do
    cp -af "${doc}" "${STAGE_WIN}/doc/"
    if command -v unix2dos &> /dev/null; then
      unix2dos -k -q "${STAGE_WIN}/doc/$(basename "${doc}")" 2>/dev/null || true
    fi
  done

  WIN_ARC_FILE="${DIST_BASE}-windows_${ARCH}.zip"
  if ! (cd "${STAGE_WIN}" && zip -9rq "${WIN_ARC_FILE}" "${APP_NAME}.exe" doc); then
    log_error "Failed to create Windows zip archive."
    exit "${EXIT_PACKAGE}"
  fi
  rm -rf "${STAGE_WIN}"
  finalize_artifact "${WIN_ARC_FILE}"
fi

# 3. Package Debian .deb (Static binary + docs + md5sums + control)
if [ "${TARGET_LINUX}" = true ] && [ "${DO_DEB}" = true ]; then
  if ! command -v dpkg-deb &> /dev/null; then
    log_error "dpkg-deb not found. Cannot build Debian package."
    exit "${EXIT_DEPENDENCY}"
  fi

  log_info "Packaging Debian Package (.deb)"
  STAGE_DEB="$(make_temp_dir "deb_${APP_NAME}")"
  mkdir -p "${STAGE_DEB}/DEBIAN"
  mkdir -p "${STAGE_DEB}${INSTALL_PATH}"
  mkdir -p "${STAGE_DEB}/usr/share/doc/${APP_NAME}"

  cp -af "${BINDIR}/${APP_NAME}" "${STAGE_DEB}${INSTALL_PATH}/${APP_NAME}"
  chmod 0755 "${STAGE_DEB}${INSTALL_PATH}/${APP_NAME}"

  for doc in "${DOC_FILES[@]}"; do
    cp -af "${doc}" "${STAGE_DEB}/usr/share/doc/${APP_NAME}/"
  done

  INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "${STAGE_DEB}" | cut -f1)

  # Sanitize description for Debian RFC 822 requirements
  DEB_FORMATTED_DESC="$(sanitize_deb_description "${RAW_DESCRIPTION}")"

  cat << EOF > "${STAGE_DEB}/DEBIAN/control"
Package: ${APP_NAME}
Version: ${DEB_VERSION}
Architecture: ${ARCH}
Maintainer: ${RAW_MAINTAINER}
Installed-Size: ${INSTALLED_SIZE}
Section: ${SECTION}
Priority: ${PRIORITY}
Homepage: ${RAW_URL}
Description: ${RAW_SUMMARY}
${DEB_FORMATTED_DESC}
EOF

  (cd "${STAGE_DEB}" && find usr -type f -exec md5sum {} + > DEBIAN/md5sums 2>/dev/null || true)
  chmod 0644 "${STAGE_DEB}/DEBIAN/control" "${STAGE_DEB}/DEBIAN/md5sums" 2>/dev/null || true

  DEB_FILE="${DIST_BASE}-linux_${ARCH}.deb"
  if ! dpkg-deb --build --root-owner-group "${STAGE_DEB}" "${DEB_FILE}" >/dev/null; then
    log_error "dpkg-deb packaging failed."
    exit "${EXIT_PACKAGE}"
  fi
  rm -rf "${STAGE_DEB}"
  finalize_artifact "${DEB_FILE}"
fi

# 4. Package RPM .rpm (Static binary + docs via rpmbuild)
if [ "${TARGET_LINUX}" = true ] && [ "${DO_RPM}" = true ]; then
  if ! command -v rpmbuild &> /dev/null; then
    log_error "rpmbuild not found. Cannot build RPM package."
    exit "${EXIT_DEPENDENCY}"
  fi

  log_info "Packaging RPM Package (.rpm)"
  RPM_TOPDIR="$(make_temp_dir "rpm_${APP_NAME}")"
  mkdir -p "${RPM_TOPDIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  SPEC_FILE="${RPM_TOPDIR}/SPECS/${APP_NAME}.spec"
  DATE_STR="$(date +"%a %b %d %Y")"

  # Stage binary into RPM build directory
  cp -af "${BINDIR}/${APP_NAME}" "${RPM_TOPDIR}/BUILD/${APP_NAME}"

  # Stage doc files if present
  DOC_INSTALL_SNIPPET=""
  DOC_FILES_SNIPPET=""
  if [ ${#DOC_FILES[@]} -gt 0 ]; then
    DOC_INSTALL_SNIPPET="mkdir -p %{buildroot}/usr/share/doc/${APP_NAME}"
    for doc in "${DOC_FILES[@]}"; do
      cp -af "${doc}" "${RPM_TOPDIR}/BUILD/$(basename "${doc}")"
      DOC_INSTALL_SNIPPET="${DOC_INSTALL_SNIPPET}
install -p -m 0644 \"%{_builddir}/$(basename "${doc}")\" \"%{buildroot}/usr/share/doc/${APP_NAME}/\""
    done
    DOC_FILES_SNIPPET="/usr/share/doc/${APP_NAME}"
  fi

  # Sanitize spec variables to escape % macros
  RPM_SPEC_SUMMARY="$(sanitize_rpm_spec_string "${RAW_SUMMARY}")"
  RPM_SPEC_DESC="$(sanitize_rpm_spec_string "${RAW_DESCRIPTION}")"
  RPM_SPEC_MAINT="$(sanitize_rpm_spec_string "${RAW_MAINTAINER}")"
  RPM_SPEC_LIC="$(sanitize_rpm_spec_string "${RAW_LICENSE}")"
  RPM_SPEC_URL="$(sanitize_rpm_spec_string "${RAW_URL}")"

  cat << EOF > "${SPEC_FILE}"
Name:           ${APP_NAME}
Version:        ${VERSION}
Release:        ${RPM_RELEASE}
Summary:        ${RPM_SPEC_SUMMARY}
License:        ${RPM_SPEC_LIC}
URL:            ${RPM_SPEC_URL}
Packager:       ${RPM_SPEC_MAINT}
AutoReqProv:    no

%define _build_id_links none
%define debug_package %{nil}
%define __strip /bin/true

%description
${RPM_SPEC_DESC}

%install
mkdir -p %{buildroot}${INSTALL_PATH}
install -p -m 0755 %{_builddir}/${APP_NAME} %{buildroot}${INSTALL_PATH}/${APP_NAME}
${DOC_INSTALL_SNIPPET}

%files
${INSTALL_PATH}/${APP_NAME}
${DOC_FILES_SNIPPET}

%changelog
* ${DATE_STR} ${RPM_SPEC_MAINT} - ${VERSION}-${RPM_RELEASE}
- Static binary package for universal Linux distribution
EOF

  if ! rpmbuild --define "_topdir ${RPM_TOPDIR}" -bb "${SPEC_FILE}" >/dev/null; then
    log_error "rpmbuild failed to create package."
    rm -rf "${RPM_TOPDIR}"
    exit "${EXIT_PACKAGE}"
  fi

  RPM_BUILT="$(find "${RPM_TOPDIR}/RPMS" -name "*.rpm" | head -n 1)"
  if [ -n "${RPM_BUILT}" ] && [ -f "${RPM_BUILT}" ]; then
    RPM_DEST="${DIST_BASE}-linux_${ARCH}.rpm"
    mv -f "${RPM_BUILT}" "${RPM_DEST}"
    finalize_artifact "${RPM_DEST}"
  else
    log_error "rpmbuild completed without producing an RPM package."
    rm -rf "${RPM_TOPDIR}"
    exit "${EXIT_PACKAGE}"
  fi
  rm -rf "${RPM_TOPDIR}"
fi

# 5. Source Archive Packaging (if --archive is passed)
# Securely excludes sensitive files (.env*, tokens, certificates, private keys)
SOURCE_EXCLUDES=("${DEFAULT_SOURCE_EXCLUDES[@]}")

if [ "${DO_ARCHIVE}" = true ]; then
  log_info "Packaging Source Archive"
  if [ "${TARGET_WIN}" = true ] && [ "${TARGET_LINUX}" = false ]; then
    SRC_ARC="${DIST_BASE}-src.zip"
    rm -f "${SRC_ARC}"
    zip -9rq "${SRC_ARC}" . -x "${SOURCE_EXCLUDES[@]}"
  else
    SRC_ARC="${DIST_BASE}-src.tar.xz"
    rm -f "${SRC_ARC}"
    tar_excludes=()
    for pat in "${SOURCE_EXCLUDES[@]}"; do
      tar_excludes+=("--exclude=${pat}")
    done
    tar -Jcf "${SRC_ARC}" "${tar_excludes[@]}" .
  fi
  finalize_artifact "${SRC_ARC}"
fi

# 6. Intermediate Binary Cleanup (if packaging was requested)
if [ "${HAS_PACKAGING}" = true ]; then
  log_info "Cleaning up intermediate binaries for ${APP_NAME} in ${BINDIR}"
  rm -f "${BINDIR}/${APP_NAME}" "${BINDIR}/${APP_NAME}.exe" "${BINDIR}/${APP_NAME}.tmp."* 2>/dev/null || true
  mkdir -p "${BINDIR}" 2>/dev/null || true
fi

echo "================================================================================"
log_success "Build and packaging completed successfully for ${APP_NAME}"
echo "================================================================================"
log_ndjson "SUCCESS" "finish" "Build and packaging completed successfully for ${APP_NAME}" "{\"exit_code\":0}"
exit "${EXIT_SUCCESS}"
