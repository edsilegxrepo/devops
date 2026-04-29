#!/bin/bash
# -----------------------------------------------------------------------------
# Code Audit Pipeline (code_audit.sh)
# v1.1.1xg  2026/04/17  XDG
#
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   To provide a multi-tiered, polyglot static analysis and security audit
#   framework that enforces syntactic correctness, security hardening, and
#   supply chain integrity for Python, Go, and Node.js projects.
#
# CORE COMPONENTS:
#   1. Flag Parser: Resolves execution scope and environment isolation.
#   2. Detection Engine: Verifies binary availability and heuristic project context.
#   3. Phased Orchestrator: Executes 5 specialized audit layers (Style -> Security).
#
# DATA FLOW:
#   Input: CLI Arguments -> Target Path Resolution -> Autodetection (Optional).
#   Execution: Phase 1 (Core Quality) -> Phase 2 (Safety/Complexity) ->
#              Phase 3 (Cleanup) -> Phase 4 (Secrets) -> Phase 5 (Supply Chain).
#   Output: Unified console report and security artifacts (e.g., sbom.json).
# -----------------------------------------------------------------------------

# ===== MODULES: INITIALIZATION =====

# --- MODULE: ENVIRONMENT SETUP ---
# PURPOSE: Initializes the global shell environment, hardening flags, and
#          default configuration state for the audit orchestrator.
# USAGE:   Called at the start of main() to establish the baseline configuration.
# -----------------------------------------------------------------------------
# Establish the script's absolute root directory for relative asset resolution.
# We use Mixed Path format (E:/...) for universal Bash and Native Tool compatibility.
CONF_SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if command -v cygpath > /dev/null 2>&1; then
  CONF_SCRIPT_ROOT=$(cygpath -m "$CONF_SCRIPT_ROOT")
fi
# SIDE EFFECTS: Sets shell options (set -Eeuo pipefail) and initializes globals.
# shellcheck disable=SC2034
setup_environment() {
  set -Eeuo pipefail

  # Platform Detection Logic: Distinguishes between Cygwin, MSYS2/Git-Bash, and Linux.
  local os_type
  os_type=$(uname -s)
  [[ "$os_type" == *"CYGWIN"* ]] && IS_CYGWIN=true || IS_CYGWIN=false
  [[ "$os_type" == *"MSYS"* || "$os_type" == *"MINGW"* ]] && IS_MSYS=true || IS_MSYS=false

  # Operational Heuristic: If we are in MSYS, we often need to disable automatic path conversion
  # when calling Windows binaries to prevent "double-mangling".
  MSYS_PREFIX_CMD=()
  [ "$IS_MSYS" = true ] && MSYS_PREFIX_CMD=("MSYS_NO_PATHCONV=1")

  # Global Audit Status: Accumulates failures across all tools.
  # 0 = All tools passed; 1 = One or more tools failed.
  GLOBAL_EXIT_STATUS=0
  AUDIT_START_TIME=$(date +%s) # Performance marker for duration analytics.

  # Configuration Persistence: Baseline state for audit operations.
  TARGET_PATH="."          # Baseline directory for all audit operations.
  PROCESS_PYTHON=true      # Flag to enable/disable Python toolset.
  PROCESS_GENERAL=true     # Flag for language-agnostic security tools.
  PROCESS_GOLANG=true      # Flag to enable/disable Go toolset.
  PROCESS_NODEJS=true      # Flag to enable/disable Node.js toolset.
  PROCESS_BASH=true        # Flag to enable/disable Bash toolset.
  PROCESS_POWERSHELL=true  # Flag to enable/disable PowerShell toolset.
  PROCESS_AUTO=false       # When true, script uses heuristic file detection.
  PROCESS_DETECT=false     # Diagnostic mode to verify installed binaries.
  PROCESS_EXTENDED=false   # Enables high-depth quality tools (Standalone + Extra Lints).
  PROCESS_EXTRA_SCAN=false # Enables heavy supply chain/SBOM tasks (Syft/Trivy).
  PROCESS_FIX=false        # If true, enables auto-fix/remediation for supported tools.
  LOG_PATH=""              # Optional file path to capture the audit report.
  HAS_ISOLATION=false      # Track if the user explicitly requested a specific scope.

  # Isolation tracking: Internal state for manual ecosystem overrides.
  SPEC_PYTHON=false     # Tracks explicit --python request for scope isolation.
  SPEC_GOLANG=false     # Tracks explicit --golang request for scope isolation.
  SPEC_NODEJS=false     # Tracks explicit --nodejs request for scope isolation.
  SPEC_BASH=false       # Tracks explicit --bash request for scope isolation.
  SPEC_POWERSHELL=false # Tracks explicit --powershell request for scope isolation.
  SPEC_GENERAL=false    # Tracks explicit --general request for scope isolation.

  # Phase Selective Execution Toggles:
  # -------------------------------------------------------------------------
  # By default, all phases are enabled. If any --run-* flag is provided,
  # SELECTIVE_PHASES becomes true and only explicitly enabled phases run.
  RUN_PHASE_1=true         # Toggle for Phase 1 (Quality)
  RUN_PHASE_2=true         # Toggle for Phase 2 (Logic)
  RUN_PHASE_3=true         # Toggle for Phase 3 (Cleanup)
  RUN_PHASE_4=true         # Toggle for Phase 4 (Secrets)
  RUN_PHASE_5=true         # Toggle for Phase 5 (Supply Chain)
  SELECTIVE_PHASES=false   # Internal tracker for selective mode activation.
  PROCESS_INSPECTION=false # Toggle for NilAway and deep inspection tools.

  # Installation & Update Engine State:
  PROCESS_INSTALL=false      # If true, install undetected tools and execute audit.
  PROCESS_INSTALL_ONLY=false # If true, install undetected tools and exit.
  PROCESS_UPDATE=false       # If true, update detected LOCAL tools and execute audit.
  PROCESS_UPDATE_ONLY=false  # If true, update detected LOCAL tools and exit.

  # Tool Ecosystem Registries: Centralized checklists for audit tools.
  AUDIT_PYTHON_TOOLS=("bandit" "pip-audit" "pyright" "radon" "ruff" "vulture")
  AUDIT_GOLANG_TOOLS=("go" "gofumpt" "golangci-lint" "gosec" "govulncheck" "nilaway" "nilness")
  AUDIT_NODEJS_TOOLS=("oxlint" "oxfmt" "biome" "npm" "node")
  AUDIT_BASH_TOOLS=("shellcheck" "shfmt")
  AUDIT_POWERSHELL_TOOLS=("pwsh")
  AUDIT_GENERAL_TOOLS=("ast-grep" "grype" "semgrep" "syft" "trivy" "trufflehog")

  # --- CONFIGURATION CONSTANTS (CENTRALIZED) ---
  # These variables eliminate hardcoding within the audit execution phases.

  # 1. COMMON CONFIGURATION
  CONF_SEARCH_DEPTH=3     # Max depth for heuristic language detection.
  CONF_GENERAL_TARGET="." # Target pattern for workspace-wide tools.
  CURL_OPTS=(-sSfL)       # Silent, fail-on-error, follow-redirects logic.
  CONF_BIN_DIR="${CONF_SCRIPT_ROOT}/bin"

  # 2. COMMON SECURITY & SAFETY TOOLS
  CONF_SEMGREP_CONFIG="auto"                                                                                         # Rule set selection for Semgrep.
  CONF_SEMGREP_FLAGS="--quiet"                                                                                       # Suppress summary rule box when zero findings.
  CONF_TRUFFLEHOG_FLAGS="--json --no-update --only-verified"                                                         # Native JSON mode for noise suppression.
  CONF_AST_GREP_FLAGS="run"                                                                                          # Default command for structural search (zero-config).
  CONF_TRIVY_FLAGS="--severity HIGH,CRITICAL --exit-code 1 --scanners vuln,misconfig,secret --skip-version-check -q" # Flags for defense-in-depth SCA.
  CONF_GRYPE_FLAGS="-q"                                                                                              # Quiet mode for vulnerability scanning.
  CONF_PIPAUDIT_FLAGS="-q"                                                                                           # Suppress non-critical cache warnings etc.
  CONF_BANDIT_FLAGS="-q -r -l -iii"                                                                                  # Security linting flags for Python.
  CONF_VERSION="1.1.1xg"                                                                                             # Application lifecycle version.

  # 3. SECURITY & RULE CONFIGURATION (ast-grep)
  # Rules are stored in the 'rules/' subdirectory relative to the script location.
  # We use 'scan' mode for rule-based detection and 'run' for ad-hoc patterns.
  CONF_RULES_DIR="${CONF_SCRIPT_ROOT}/rules"

  # 4. LANGUAGE-SPECIFIC: PYTHON
  CONF_PYTHON_TARGET="." # Target pattern for Python tools.
  CONF_RUFF_CACHE="${TEMP}/cache/python/ruff"
  CONF_VULTURE_CONFIDENCE=90 # Confidence threshold for dead code detection.
  CONF_RADON_FLAGS="-a -nc"  # Flags for complexity analysis.

  # 4. LANGUAGE-SPECIFIC: GOLANG
  CONF_GOLANG_TARGET="."                              # Target pattern for Go tools (normalized for Windows portability).
  GO_OPTS=(-ldflags="-s -w" -trimpath -buildmode=pie) # Hardened build flags for Go installations.
  CONF_GOFUMPT_FLAGS="-extra"                         # Extensions for strict Go formatting.
  CONF_GOLANGCI_FLAGS="--no-config"                   # Forced clean state for the meta-linter.
  CONF_NILAWAY_FLAGS="./..."                          # Target pattern for NilAway panic detection.
  CONF_NILNESS_FLAGS="./..."                          # Target pattern for Nilness precise analysis.
  CONF_GOVULNCHECK_TARGET="./..."                     # Target pattern for dependency vulnerability checks.

  # 5. LANGUAGE-SPECIFIC: NODE.JS
  CONF_NODEJS_TARGET="."                       # Target pattern for Node.js tools.
  CONF_BIOME_FLAGS=""                          # Default flags for Biome check command.
  CONF_OXLINT_FLAGS=""                         # Default flags for Oxlint linter.
  CONF_OXFMT_FLAGS=""                          # Default flags for oxfmt formatter.
  CONF_NPM_AUDIT_FLAGS="--audit-level=high -q" # Flags for registry-direct advisory checks.

  # 6. LANGUAGE-SPECIFIC: BASH
  CONF_BASH_TARGET="."                       # Target pattern for Bash tools.
  CONF_SHELLCHECK_FLAGS="-x --severity=info" # Linter flags for common bug detection.
  CONF_SHFMT_FLAGS="-i 2 -ci -sr"            # Formatter flags (check-only).

  # 7. LANGUAGE-SPECIFIC: POWERSHELL
  CONF_POWERSHELL_TARGET="." # Target pattern for PowerShell tools.
  CONF_PSLINT_FLAGS=""       # Default flags for the pslint.ps1 wrapper.

  # 7. LOCAL INSTALLATION CONSTANTS (NON-SUDO)
  CONF_USER_BIN="${HOME}/.local/bin"
  CONF_NPM_PREFIX="${HOME}/.npm-global"

  # Path Management: Isolate from conflicting POSIX environments and prioritize local toolsets.
  local unwanted_patterns=""
  if [ "$IS_CYGWIN" = true ]; then
    unwanted_patterns="msys64|git/bin|git/usr/bin|mingw64"
    if [ -n "${MSYS_HOME:-}" ]; then
      local msys_norm
      msys_norm=$(echo "${MSYS_HOME//\\/[\\\/]}" | tr '[:upper:]' '[:lower:]')
      unwanted_patterns="${unwanted_patterns}|${msys_norm}"
    fi
    sanitize_session_path "$unwanted_patterns"
  elif [ "$IS_MSYS" = true ]; then
    unwanted_patterns="cygwin64|cygwin/bin"
    if [ -n "${CYGWIN_HOME:-}" ]; then
      local cyg_norm
      cyg_norm=$(echo "${CYGWIN_HOME//\\/[\\\/]}" | tr '[:upper:]' '[:lower:]')
      unwanted_patterns="${unwanted_patterns}|${cyg_norm}"
    fi
    sanitize_session_path "$unwanted_patterns"
  fi

  # Prepend local managed bin folder and append user-local folder.
  export PATH="${CONF_BIN_DIR}:${PATH}:${CONF_USER_BIN}"

  # Go specific: Append GOPATH/bin if not already present
  local gopath_bin
  gopath_bin=$(go env GOPATH 2> /dev/null)/bin
  [ -n "$gopath_bin" ] && export PATH="${PATH}:${gopath_bin}"

  # Execution Environment Preparation
  # Conditional export ensures tools have dedicated persistent work areas.
  if [ "$PROCESS_PYTHON" = true ]; then export RUFF_CACHE_DIR="$CONF_RUFF_CACHE"; fi

  # 3. Parallel Execution: Status tracking directory for background processes.
  # Logic: We use files to track failures across subshells since variables are not shared.
  AUDIT_STATUS_DIR=$(mktemp -d 2> /dev/null || (mkdir -p "${TMPDIR:-/tmp}/audit_status_$$" && echo "${TMPDIR:-/tmp}/audit_status_$$"))
  export AUDIT_STATUS_DIR

  # 4. Environment Hardening:
  # 1. Force UTF-8 for Python tools (Prevents Semgrep encoding crashes on Windows).
  # 2. Disable Syft update checks for deterministic pipeline behavior.
  export PYTHONUTF8=1
  export SYFT_CHECK_FOR_APP_UPDATE=false
}

# --- MODULE: ENVIRONMENT SANITIZATION ---
# PURPOSE: Purges conflicting POSIX environment paths from the session PATH.
# USAGE:   Called during setup_environment to ensure isolation (Cygwin vs MSYS).
sanitize_session_path() {
  local pattern="$1"

  # 1. Protect Windows drive letters (C:) by replacing colon with a temporary token.
  # We only match a single letter at the start of the string or immediately following a colon path separator.
  local protected
  protected=$(echo "$PATH" | sed -E 's/(^|:)([a-zA-Z]):/\1\2__DRIVE__/g')

  # 2. Convert path separators (:) to newlines, filter, and reassemble.
  local filtered
  filtered=$(echo "$protected" | tr ':' '\n' | grep -vEi "$pattern" | tr '\n' ':' | sed 's/:$//')

  # 3. Restore drive letters and update the session PATH.
  export PATH="${filtered//__DRIVE__/:}"
}

# --- MODULE: AUDIT EXECUTION WRAPPER ---
# PURPOSE: Executional wrapper that captures tool status without script exit.
# USAGE:   run_audit_tool <Label> <Command> [Args...]
# INPUTS:  $1: Label, $2: Command, $3+: Args.
run_audit_tool() {
  local label="$1"
  shift
  local cmd_args=()

  # Filter empty arguments to prevent tool failures on optional flags.
  for arg in "$@"; do
    [ -n "$arg" ] && cmd_args+=("$arg")
  done
  local cmd_bin="${cmd_args[0]}"
  if ! command -v "$cmd_bin" > /dev/null 2>&1; then
    if command -v "${cmd_bin}.exe" > /dev/null 2>&1; then
      cmd_bin="${cmd_bin}.exe"
      cmd_args[0]="$cmd_bin"
    else
      return 0
    fi
  fi

  echo "[TOOL] --> $label"
  # Logic: We use env with MSYS_NO_PATHCONV=1 in MSYS environments to ensure our
  # normalized paths (Mixed-Style) are passed exactly as intended to Windows binaries.
  if ! env "${MSYS_PREFIX_CMD[@]}" "${cmd_args[@]}" 2>&1; then
    echo "FAIL  : $label encountered issues."
    GLOBAL_EXIT_STATUS=1
    # Signal failure to parent if running in a background subshell
    [ -d "${AUDIT_STATUS_DIR:-}" ] && touch "$AUDIT_STATUS_DIR/FAIL_${label// /_}"
  fi
  echo ""
}

# --- MODULE: PATH FORMATTER ---
# PURPOSE: Ensures consistent cross-platform path formatting.
# USAGE:   format_path <Path>
# LOGIC:   Converts POSIX paths to Windows-style (Mixed) if cygpath is available.
format_path() {
  local path="$1"
  if command -v cygpath > /dev/null 2>&1; then
    cygpath -m "$path"
  else
    echo "$path"
  fi
}

# --- MODULE: TOOL AVAILABILITY CHECK ---
# PURPOSE: Diagnostic utility to verify and report tool binary availability.
# USAGE:   check_tool <BinaryName>
# INPUTS:  $1: The command name to check via 'command -v'.
# SIDE EFFECTS: Outputs a formatted status line to stdout.
check_tool() {
  local bin="$1"
  local actual_bin="$bin"

  # Fallback for Windows environments where .exe isn't automatically resolved
  if ! command -v "$actual_bin" > /dev/null 2>&1; then
    if command -v "${bin}.exe" > /dev/null 2>&1; then
      actual_bin="${bin}.exe"
    fi
  fi

  if command -v "$actual_bin" > /dev/null 2>&1; then
    local path
    path=$(command -v "$actual_bin")
    local ver=""

    # Heuristic version extraction: Attempts common version flags and scrubs the output.
    # Uses || true to ensure grep failures or missing flags do not trigger 'set -e'.
    # We scan up to 5 lines to handle tools like ShellCheck that report versions on line 2.
    # Logic: We strip carriage returns (\r) to prevent cursor-reset formatting issues.
    ver=$("$actual_bin" --version 2>&1 | head -n 5 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][a-zA-Z0-9.]+)?' | head -n 1 | tr -d '\r' || true)
    [ -z "$ver" ] && ver=$("$actual_bin" version 2>&1 | head -n 5 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][a-zA-Z0-9.]+)?' | head -n 1 | tr -d '\r' || true)
    [ -z "$ver" ] && ver=$("$actual_bin" -v 2>&1 | head -n 5 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][a-zA-Z0-9.]+)?' | head -n 1 | tr -d '\r' || true)

    # Fallback for Go-style build IDs (common in NilAway and custom Go binaries)
    [ -z "$ver" ] && ver=$("$actual_bin" -V=full 2>&1 | grep -oE 'buildID=[a-f0-9]+' | cut -d= -f2 | head -n 1 | tr -d '\r' || true)

    # Truncate version string to 7 characters and add ellipsis if necessary.
    if [ -n "$ver" ]; then
      if [ ${#ver} -gt 7 ]; then
        ver="v${ver:0:7}.."
      else
        ver="v$ver"
      fi
    else
      ver="            "
    fi

    local display_path
    display_path=$(format_path "$path")
    printf "  %-30s : [FOUND]   %-12s %s\n" "$bin" "$ver" "$display_path"
  else
    printf "  %-30s : [MISSING]\n" "$bin"
  fi
}

# --- MODULE: LOCAL ASSET CHECK ---
# PURPOSE: Diagnostic utility to verify the presence of non-binary project assets.
# USAGE:   check_asset <FilePath>
# INPUTS:  $1: The absolute path to the file.
check_asset() {
  local file="$1"
  local base
  base=$(basename "$file")
  local ver="            "

  if [ -f "$file" ]; then
    # Logic: If it's the pslint.ps1 orchestrator, extract its internal version.
    if [[ "$base" == "pslint.ps1" ]]; then
      # We explicitly strip \r to prevent terminal cursor-reset issues on Windows.
      ver=$(pwsh -ExecutionPolicy Bypass -File "$file" -Version 2> /dev/null | head -n 1 | tr -d '\r' || echo "")
      [ -n "$ver" ] && ver="v$ver"
    fi
    local display_file
    display_file=$(format_path "$file")
    printf "  %-30s : [FOUND]   %-12s %s\n" "$base" "$ver" "$display_file"
  else
    printf "  %-30s : [MISSING]\n" "$base"
  fi
}

# --- MODULE: INTERFACE USAGE GUIDE ---
# PURPOSE: Displays the command-line interface usage guide and available flags.
# USAGE:   show_usage
# INPUTS:  None (reads from HEREDOC).
# SIDE EFFECTS: Outputs manual to stdout.
show_usage() {
  cat << EOF

Usage: $0 [--path <dir>] [--auto] [--detect] [--extended] [--extra-scan] [--fix] [--log <path>] [--python] [--golang] [--nodejs] [--bash] [--powershell] [--general] [--install] [--install-only] [--update] [--update-only]

Code Audit Pipeline v${CONF_VERSION}

Options:
  --path <dir>:        Run the audit in the specified directory.
  --auto:              Autodetect toolsets based on files (plus general checks).
  --detect:            Check and report which audit tools are installed.
  --extended:          Run deep code quality tools (nil-checks, strict formatting, extra Go linters).
  --extra-scan:        Run heavy security/supply chain scans (Syft SBOM, Trivy config scans).
  --fix:               Enable auto-fixes/formatting (DEFAULT is zero-impact check only).
  --log <path>:        Redirect and append all output to the specified log file.
  --python:            Force include/isolate Python tools.
  --golang:            Force include/isolate Go tools.
  --nodejs:            Force include/isolate Node.js tools.
  --bash:              Force include/isolate Bash tools.
  --powershell:        Force include/isolate PowerShell tools.
  --general:           Force include/isolate general tools.
  --run-quality:       Execute Phase 1 only (Quality/Style).
  --run-logic:         Execute Phase 2 only (Logic/Safety).
  --run-cleanup:       Execute Phase 3 only (Cleanup/Hygiene).
  --run-detectsecrets: Execute Phase 4 only (Secrets).
  --run-supplychain:   Execute Phase 5 only (Supply Chain/SBOM).
  --install:           Install missing tools for specified scope and run audit.
  --install-only:      Install missing tools only (Pre-stage) and exit.
  --update:            Update existing local tools for specified scope and run audit.
  --update-only:       Update existing local tools only and exit.
  --help:              Show this help message.

EOF
}

# ===== MODULES: LOGIC BLOCKS =====

# --- MODULE: CLI ARGUMENT PARSER ---
# PURPOSE: Iterative parser to resolve user intent into internal state flags.
# USAGE:   parse_arguments "$@"
# INPUTS:  $@: The global argument list from the script invocation.
# SIDE EFFECTS: Modifies global PROCESS_* and SPEC_* configuration flags.
parse_arguments() {
  # If no arguments are passed, show usage and exit
  if [ "$#" -eq 0 ]; then
    show_usage
    exit 0
  fi

  # Helper: Transitions the orchestrator into 'Selective Mode' on first hit.
  activate_selective_mode() {
    if [ "$SELECTIVE_PHASES" = false ]; then
      RUN_PHASE_1=false
      RUN_PHASE_2=false
      RUN_PHASE_3=false
      RUN_PHASE_4=false
      RUN_PHASE_5=false
      SELECTIVE_PHASES=true
    fi
  }

  # Flag Parsing: Decouples user intent from internal execution logic.
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --path)
        TARGET_PATH="$2"
        shift
        ;;
      --auto)
        PROCESS_AUTO=true
        HAS_ISOLATION=true
        ;;
      --detect) PROCESS_DETECT=true ;;
      --extended) PROCESS_EXTENDED=true ;;
      --inspection) PROCESS_INSPECTION=true ;;
      --extra-scan) PROCESS_EXTRA_SCAN=true ;;
      --fix) PROCESS_FIX=true ;;
      --log)
        LOG_PATH="$2"
        shift
        ;;
      --python)
        HAS_ISOLATION=true
        SPEC_PYTHON=true
        ;;
      --golang)
        HAS_ISOLATION=true
        SPEC_GOLANG=true
        ;;
      --nodejs)
        HAS_ISOLATION=true
        SPEC_NODEJS=true
        ;;
      --bash)
        HAS_ISOLATION=true
        SPEC_BASH=true
        ;;
      --powershell)
        HAS_ISOLATION=true
        SPEC_POWERSHELL=true
        ;;
      --general)
        HAS_ISOLATION=true
        SPEC_GENERAL=true
        ;;
      --run-quality)
        activate_selective_mode
        RUN_PHASE_1=true
        ;;
      --run-logic)
        activate_selective_mode
        RUN_PHASE_2=true
        ;;
      --run-cleanup)
        activate_selective_mode
        RUN_PHASE_3=true
        ;;
      --run-detectsecrets)
        activate_selective_mode
        RUN_PHASE_4=true
        ;;
      --run-supplychain)
        activate_selective_mode
        RUN_PHASE_5=true
        ;;
      --install)
        PROCESS_INSTALL=true
        ;;
      --install-only)
        PROCESS_INSTALL_ONLY=true
        ;;
      --update)
        PROCESS_UPDATE=true
        ;;
      --update-only)
        PROCESS_UPDATE_ONLY=true
        ;;
      --help | -h)
        show_usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 1
        ;;
    esac
    shift
  done
}

# --- MODULE: PARALLEL TOOL ORCHESTRATOR ---
# PURPOSE: Internal helper to queue tool checks for the global parallel report.
# USAGE:   queue_check <CategoryIdx> <ToolArray[@]>
queue_checks() {
  local cat_idx="$1"
  shift
  local tools=("$@")
  local tool_idx=0
  for tool in "${tools[@]}"; do
    tool_idx=$((tool_idx + 1))
    local pad_cat
    pad_cat=$(printf "%02d" "$cat_idx")
    local pad_tool
    pad_tool=$(printf "%03d" "$tool_idx")
    # Launch check in background and capture to ordered buffer file.
    check_tool "$tool" > "$DIAG_TMP_DIR/${pad_cat}_${pad_tool}_${tool}" &
  done
}

# --- MODULE: DIAGNOSTIC READINESS REPORT ---
# PURPOSE: Performs a global parallelized readiness check of the execution environment.
# USAGE:   Triggered by the --detect flag.
run_diagnosis() {
  if [ "$PROCESS_DETECT" = false ]; then return; fi

  echo "---------------------------------------------------------"
  echo " TOOL DETECTION & READINESS REPORT"
  echo "---------------------------------------------------------"

  # Establish a shared temporary buffer for all parallel tasks.
  DIAG_TMP_DIR=$(mktemp -d 2> /dev/null || (mkdir -p "${TMPDIR:-/tmp}/audit_diag_$$" && echo "${TMPDIR:-/tmp}/audit_diag_$$"))

  # Launch checks across categories based on isolation flags or global mode.
  if [ "$HAS_ISOLATION" = false ] || [ "$PROCESS_PYTHON" = true ] || [ "$SPEC_PYTHON" = true ]; then
    queue_checks 1 "${AUDIT_PYTHON_TOOLS[@]}"
  fi

  if [ "$HAS_ISOLATION" = false ] || [ "$PROCESS_GOLANG" = true ] || [ "$SPEC_GOLANG" = true ]; then
    queue_checks 2 "${AUDIT_GOLANG_TOOLS[@]}"
  fi

  if [ "$HAS_ISOLATION" = false ] || [ "$PROCESS_NODEJS" = true ] || [ "$SPEC_NODEJS" = true ]; then
    queue_checks 3 "${AUDIT_NODEJS_TOOLS[@]}"
  fi

  if [ "$HAS_ISOLATION" = false ] || [ "$PROCESS_BASH" = true ] || [ "$SPEC_BASH" = true ]; then
    queue_checks 4 "${AUDIT_BASH_TOOLS[@]}"
  fi

  # Special Category: PowerShell (Includes high-latency script version check)
  if [ "$HAS_ISOLATION" = false ] || [ "$PROCESS_POWERSHELL" = true ] || [ "$SPEC_POWERSHELL" = true ]; then
    local pad_cat="05"
    check_tool "pwsh" > "$DIAG_TMP_DIR/${pad_cat}_001_pwsh" &
    check_asset "$CONF_SCRIPT_ROOT/pslint.ps1" > "$DIAG_TMP_DIR/${pad_cat}_002_pslint" &
  fi

  if [ "$HAS_ISOLATION" = false ] || [ "$PROCESS_GENERAL" = true ] || [ "$SPEC_GENERAL" = true ]; then
    queue_checks 6 "${AUDIT_GENERAL_TOOLS[@]}"
  fi

  # Synchronize and Stream: Display results category-by-category as they complete.
  local category_names=("" "Python Quality & Security Tools" "Golang Quality & Security Tools" "Node.js Quality & Security Tools" "Bash Quality & Security Tools" "PowerShell Quality Tools" "General Purpose Audit Tools")

  # Logic: We iterate through categories and wait for their specific toolsets.
  for cat_num in 1 2 3 4 5 6; do
    local pad_cat
    pad_cat=$(printf "%02d" "$cat_num")
    local should_display=false

    # Check if this category was part of the audit scope.
    case $cat_num in
      1) [[ "$HAS_ISOLATION" == false || "$PROCESS_PYTHON" == true || "$SPEC_PYTHON" == true ]] && should_display=true ;;
      2) [[ "$HAS_ISOLATION" == false || "$PROCESS_GOLANG" == true || "$SPEC_GOLANG" == true ]] && should_display=true ;;
      3) [[ "$HAS_ISOLATION" == false || "$PROCESS_NODEJS" == true || "$SPEC_NODEJS" == true ]] && should_display=true ;;
      4) [[ "$HAS_ISOLATION" == false || "$PROCESS_BASH" == true || "$SPEC_BASH" == true ]] && should_display=true ;;
      5) [[ "$HAS_ISOLATION" == false || "$PROCESS_POWERSHELL" == true || "$SPEC_POWERSHELL" == true ]] && should_display=true ;;
      6) [[ "$HAS_ISOLATION" == false || "$PROCESS_GENERAL" == true || "$SPEC_GENERAL" == true ]] && should_display=true ;;
    esac

    if [ "$should_display" = true ]; then
      echo "[${category_names[$cat_num]}]"

      # Special Handling: Category 5 (PowerShell) has a manual file mapping.
      if [ "$cat_num" -eq 5 ]; then
        for f in "$DIAG_TMP_DIR/${pad_cat}_001_pwsh" "$DIAG_TMP_DIR/${pad_cat}_002_pslint"; do
          while [ ! -s "$f" ]; do sleep 0.1; done
          cat "$f"
        done
      else
        # Standard Categories: Map to the global tool arrays.
        local target_tools=()
        case $cat_num in
          1) target_tools=("${AUDIT_PYTHON_TOOLS[@]}") ;;
          2) target_tools=("${AUDIT_GOLANG_TOOLS[@]}") ;;
          3) target_tools=("${AUDIT_NODEJS_TOOLS[@]}") ;;
          4) target_tools=("${AUDIT_BASH_TOOLS[@]}") ;;
          6) target_tools=("${AUDIT_GENERAL_TOOLS[@]}") ;;
        esac

        local t_idx=0
        for t in "${target_tools[@]}"; do
          t_idx=$((t_idx + 1))
          local pad_t
          pad_t=$(printf "%03d" "$t_idx")
          local f="$DIAG_TMP_DIR/${pad_cat}_${pad_t}_${t}"
          while [ ! -s "$f" ]; do sleep 0.1; done
          cat "$f"
        done
      fi
      echo ""
    fi
  done

  # Final cleanup of all background tasks (safety catch) and buffers.
  wait
  rm -rf "$DIAG_TMP_DIR"
  echo "---------------------------------------------------------"
  exit 0
}

# --- MODULE: CONTEXT AND AUTODETECTION RESOLVER ---
# PURPOSE: Resolves the target directory and executes heuristic autodetection.
# USAGE:   Called after arguments are parsed to establish project focus.
# INPUTS:  Uses global TARGET_PATH and PROCESS_AUTO flags.
# SIDE EFFECTS: May change the current working directory (cd).
resolve_context() {
  # Operational Flow: Context Resolution
  # -------------------------------------------------------------------------

  # Step 1: Directory context validation and normalization
  if [ ! -d "$TARGET_PATH" ]; then
    echo "Error: Directory $TARGET_PATH does not exist." >&2
    exit 1
  fi

  # Normalize to absolute path and apply Mixed-Style formatting (E:/...)
  local abs_path
  abs_path=$(cd "$TARGET_PATH" && pwd)
  TARGET_PATH=$(format_path "$abs_path")

  # Diagnostic Suppression: We only announce the scope during actual audits.
  # For readiness checks (--detect), the focus is on tools, not local files.
  if [ "$PROCESS_DETECT" = false ]; then
    echo "--> Audit Scope: $(format_path "$TARGET_PATH")"
  fi
  cd "$abs_path" || exit 1

  # Step 2: Toolset isolation/autodetection logic
  if [ "$PROCESS_AUTO" = true ]; then
    PROCESS_GENERAL=true
    # Heuristic detection: We use a portable find strategy to identify project fingerprints.
    # Logic: We check for existence of specific extensions at the root and near-root levels.
    # We use 'head -n 1' as a portable alternative to the GNU-specific '-quit' flag.
    [ -n "$(find . -maxdepth "${CONF_SEARCH_DEPTH:-3}" -name "*.py" 2> /dev/null | head -n 1)" ] && PROCESS_PYTHON=true || PROCESS_PYTHON=false
    [ -n "$(find . -maxdepth "${CONF_SEARCH_DEPTH:-3}" -name "*.go" 2> /dev/null | head -n 1)" ] && PROCESS_GOLANG=true || PROCESS_GOLANG=false

    # Node.js: Look for package.json or common JS/TS extensions.
    [ -n "$(find . -maxdepth "${CONF_SEARCH_DEPTH:-3}" \( -name "package.json" -o -name "*.js" -o -name "*.ts" -o -name "*.jsx" -o -name "*.tsx" \) 2> /dev/null | head -n 1)" ] && PROCESS_NODEJS=true || PROCESS_NODEJS=false

    # Bash: Look for .sh files.
    [ -n "$(find . -maxdepth "${CONF_SEARCH_DEPTH:-3}" -name "*.sh" 2> /dev/null | head -n 1)" ] && PROCESS_BASH=true || PROCESS_BASH=false

    # PowerShell: Look for .ps1, .psm1, or .psd1 files.
    [ -n "$(find . -maxdepth "${CONF_SEARCH_DEPTH:-3}" \( -name "*.ps1" -o -name "*.psm1" -o -name "*.psd1" \) 2> /dev/null | head -n 1)" ] && PROCESS_POWERSHELL=true || PROCESS_POWERSHELL=false

    if [ "$PROCESS_PYTHON" = true ]; then echo "--> [Auto-Detect] Python environment active."; fi
    if [ "$PROCESS_GOLANG" = true ]; then echo "--> [Auto-Detect] Golang environment active."; fi
    if [ "$PROCESS_NODEJS" = true ]; then echo "--> [Auto-Detect] Node.js environment active."; fi
    if [ "$PROCESS_BASH" = true ]; then echo "--> [Auto-Detect] Bash environment active."; fi
    if [ "$PROCESS_POWERSHELL" = true ]; then echo "--> [Auto-Detect] PowerShell environment active."; fi
  elif [ "$HAS_ISOLATION" = true ]; then
    # If the user explicitly isolated the run, only those targets are active.
    PROCESS_PYTHON=$SPEC_PYTHON
    PROCESS_GOLANG=$SPEC_GOLANG
    PROCESS_NODEJS=$SPEC_NODEJS
    PROCESS_BASH=$SPEC_BASH
    PROCESS_POWERSHELL=$SPEC_POWERSHELL
    PROCESS_GENERAL=$SPEC_GENERAL
  fi

  # Synchronize ecosystem-specific targets with the now-normalized TARGET_PATH.
  CONF_PYTHON_TARGET="$TARGET_PATH"
  CONF_GOLANG_TARGET="$TARGET_PATH"
  CONF_NODEJS_TARGET="$TARGET_PATH"
  CONF_BASH_TARGET="$TARGET_PATH"
  CONF_POWERSHELL_TARGET="$TARGET_PATH"
  CONF_GENERAL_TARGET="$TARGET_PATH"
}

# --- MODULE: GLOBAL REPORTING INITIALIZATION ---
# PURPOSE: Establishes a global output redirection layer for audit reporting.
# USAGE:   Triggered by the presence of a LOG_PATH variable.
# INPUTS:  Uses global LOG_PATH.
# SIDE EFFECTS: Redirects subsequent stdout and stderr via 'exec'.
# Helper: Displays a high-visibility phase banner with timestamping.
log_phase_banner() {
  local phase_num="$1"
  local phase_name="$2"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo ""
  echo "========================================================="
  echo " PHASE ${phase_num}: ${phase_name}"
  echo " STARTED: ${timestamp}"
  echo "========================================================="
}

init_reporting() {
  # Step 3: Global Logging Initialization
  # If a log path is specified, captures both stdout and stderr into a single
  # comprehensive report for developer remediation and audit evidence.
  if [ -n "$LOG_PATH" ]; then
    mkdir -p "$(dirname "$LOG_PATH")" || true
    # Redirect stdout and stderr to both console and log file
    exec > >(tee -a "$LOG_PATH") 2>&1

    # Executive Header (Only written if logging is active)
    local start_date
    start_date=$(date +"%A, %b %d, %Y %H:%M:%S")
    echo "#########################################################"
    echo "#          CODE AUDIT PIPELINE EXECUTIVE REPORT         #"
    echo "#########################################################"
    echo "# VERSION    : ${CONF_VERSION}"
    echo "# START TIME : ${start_date}"
    echo "# TARGET     : ${TARGET_PATH}"
    echo "# USER       : ${USER:-unknown}"
    echo "# HOST       : $(hostname 2> /dev/null || echo 'unknown')"
    echo "#########################################################"
    echo ""
  fi
}

# ===== MODULES: AUDIT PHASES =====

# --- AUDIT PHASE 1: CORE QUALITY & TYPES ---
# PURPOSE: Executes Phase 1 audit layers (Linting, Formatting, Type Safety).
# USAGE:   Called by main() during the sequential audit flow.
# INPUTS:  Uses PROCESS_PYTHON and PROCESS_GOLANG flags.
# SIDE EFFECTS: Outputs phase results to stdout/log.
run_phase_1_quality() {
  if [ "$PROCESS_PYTHON" = false ] && [ "$PROCESS_GOLANG" = false ] && [ "$PROCESS_NODEJS" = false ] && [ "$PROCESS_BASH" = false ] && [ "$PROCESS_POWERSHELL" = false ]; then
    if [ "$SELECTIVE_PHASES" = true ]; then
      echo "INFO: Phase 1 (Quality/Style) is not applicable for the current ecosystem selection."
    fi
    return
  fi

  # PHASE 1: Baseline Quality (Lints, Formatters, Type Safety)
  # -------------------------------------------------------------------------
  log_phase_banner "1" "SYNTAX, STYLE AND TYPES"

  if [ "$PROCESS_PYTHON" = true ]; then
    echo "[Python]"
    # Ruff: Industry-standard fast linter and formatter.
    # Implements logic checks, stylistic enforcement, and auto-fix capabilities.
    if [ "$PROCESS_FIX" = true ]; then
      run_audit_tool "Ruff Linter (Fix)" ruff check --fix "$CONF_PYTHON_TARGET"
      run_audit_tool "Ruff Formatter (Fix)" ruff format "$CONF_PYTHON_TARGET"
    else
      run_audit_tool "Ruff Linter (Check Only)" ruff check "$CONF_PYTHON_TARGET"
      run_audit_tool "Ruff Formatter (Check Only)" ruff format --check "$CONF_PYTHON_TARGET"
    fi
    # Pyright: Microsoft static type checker for enforcing type safety across the project.
    run_audit_tool "Pyright Type Checker" pyright "$CONF_PYTHON_TARGET"
  fi

  if [ "$PROCESS_GOLANG" = true ]; then
    echo "[Golang]"
    if [ "$PROCESS_FIX" = true ]; then
      # gofumpt: Stricter, more opinionated Go formatter.
      # We use -l to list affected files and -w to write changes.
      run_audit_tool "Gofumpt (Fix)" gofumpt -l -w "$CONF_GOLANG_TARGET"
    else
      # Default mode: List non-compliant files without modifying the source.
      run_audit_tool "Gofumpt (Check Only)" gofumpt -l "$CONF_GOLANG_TARGET"
    fi

    # golangci-lint: High-performance orchestrator for Go linters.
    # Aggregates results from dozens of internal and community-standard Go linters.
    local EXT_LINTERS=""
    local FIX_FLAG=""
    [ "$PROCESS_FIX" = true ] && FIX_FLAG="--fix"
    if [ "$PROCESS_EXTENDED" = true ]; then
      # Extended mode: adds linters for complexity, magic numbers, and stylistic edge cases.
      EXT_LINTERS="--enable=gocritic,goconst,mnd,interfacebloat,gocyclo,copyloopvar,bodyclose,nilerr,nilnil"

      # go fix: Modernizes legacy Go code patterns.
      if [ "$PROCESS_FIX" = true ]; then
        run_audit_tool "Go Fix (Fix Mode)" go fix ./...
      else
        run_audit_tool "Go Fix (Check Only)" go fix -diff ./...
      fi
    fi

    run_audit_tool "GolangCI Meta-Linter" golangci-lint run "$EXT_LINTERS" "$FIX_FLAG" "$CONF_GOLANGCI_FLAGS" "$CONF_GOLANG_TARGET"
  fi

  if [ "$PROCESS_NODEJS" = true ]; then
    echo "[Node.js]"
    # Oxlint: Ultra-fast JavaScript/TypeScript linter with zero-config defaults.
    local OXLINT_FIX_FLAG=""
    [ "$PROCESS_FIX" = true ] && OXLINT_FIX_FLAG="--fix"
    run_audit_tool "Oxlint Linter" oxlint "$OXLINT_FIX_FLAG" "$CONF_NODEJS_TARGET" "$CONF_OXLINT_FLAGS"

    # oxfmt: Fast Prettier-compatible formatter.
    local OXFMT_MODE_FLAG=""
    [ "$PROCESS_FIX" = false ] && OXFMT_MODE_FLAG="--check"
    run_audit_tool "Oxfmt Formatter" oxfmt "$OXFMT_MODE_FLAG" "$CONF_NODEJS_TARGET" "$CONF_OXFMT_FLAGS"

    # Biome: Unified toolchain performing Linting, Formatting, and Import Sorting.
    # Uses 'check' for holistic audit and adds '--write' for auto-remediation.
    local BIOME_FIX_FLAG=""
    [ "$PROCESS_FIX" = true ] && BIOME_FIX_FLAG="--write"
    run_audit_tool "Biome Audit" biome check "$BIOME_FIX_FLAG" "$CONF_NODEJS_TARGET" "$CONF_BIOME_FLAGS"
  fi

  if [ "$PROCESS_BASH" = true ]; then
    echo "[Bash]"
    # ShellCheck: Industry-standard linter for catching common shell bugs and anti-patterns.
    # We use find to ensure recursive discovery within the configured depth.
    run_audit_tool "ShellCheck (Lint)" find "$CONF_BASH_TARGET" -maxdepth "$CONF_SEARCH_DEPTH" -name "*.sh" -exec shellcheck "$CONF_SHELLCHECK_FLAGS" {} +

    # shfmt: Enforces a consistent coding style across Bash scripts (check-only default).
    if [ "$PROCESS_FIX" = true ]; then
      run_audit_tool "shfmt (Fix Mode)" find "$CONF_BASH_TARGET" -maxdepth "$CONF_SEARCH_DEPTH" -name "*.sh" -exec shfmt "$CONF_SHFMT_FLAGS" -w {} +
    else
      run_audit_tool "shfmt (Check Only)" find "$CONF_BASH_TARGET" -maxdepth "$CONF_SEARCH_DEPTH" -name "*.sh" -exec shfmt "$CONF_SHFMT_FLAGS" -d {} +
    fi
  fi

  if [ "$PROCESS_POWERSHELL" = true ]; then
    echo "[PowerShell]"
    local PS_FIX_FLAG=""
    [ "$PROCESS_FIX" = true ] && PS_FIX_FLAG="-Fix"
    local PS_STRICT_FLAG=""
    [ "$PROCESS_EXTENDED" = true ] && PS_STRICT_FLAG="-Strict"

    # pslint.ps1: Custom PowerShell linter wrapper utilizing PSScriptAnalyzer.
    # We invoke via pwsh to ensure cross-platform compatibility (Cygwin/MSYS2).
    run_audit_tool "PowerShell Linter (pslint)" pwsh -ExecutionPolicy Bypass -File "$CONF_SCRIPT_ROOT/pslint.ps1" -Path "$CONF_POWERSHELL_TARGET" -Recursive "$PS_FIX_FLAG" "$PS_STRICT_FLAG" "$CONF_PSLINT_FLAGS"
  fi
}

# --- AUDIT PHASE 2: ADVANCED LOGIC AND SAFETY ---
# PURPOSE: Executes Phase 2 layers focusing on logical complexity and safety.
# USAGE:   Triggered for Python, Golang, and general language-agnostic tools.
# INPUTS:  Uses PROCESS_* and PROCESS_EXTENDED flags.
# SIDE EFFECTS: Cumulative updates to GLOBAL_EXIT_STATUS.
run_phase_2_logic() {
  if [ "$PROCESS_GENERAL" = false ] && [ "$PROCESS_PYTHON" = false ] && [ "$PROCESS_GOLANG" = false ] && [ "$PROCESS_NODEJS" = false ] && [ "$PROCESS_BASH" = false ]; then
    if [ "$SELECTIVE_PHASES" = true ]; then
      echo "INFO: Phase 2 (Logic/Safety) is not applicable for the current ecosystem selection."
    fi
    return
  fi

  # PHASE 2: Advanced Logic Analysis (Complexity and Security Patterns)
  # -------------------------------------------------------------------------
  log_phase_banner "2" "LOGIC, SAFETY AND COMPLEXITY"
  if [ "$PROCESS_GENERAL" = true ]; then
    # Semgrep: Polyglot static analysis with support for auto-remediation.
    local SEMGREP_FIX_FLAG=""
    if [ "$PROCESS_FIX" = true ]; then SEMGREP_FIX_FLAG="--autofix"; fi
    # shellcheck disable=SC2086
    run_audit_tool "Semgrep Scan" semgrep scan "$SEMGREP_FIX_FLAG" $CONF_SEMGREP_FLAGS --config "$CONF_SEMGREP_CONFIG" --error
  fi

  # ast-grep: Structural search utilizing tree-sitter for high-precision rule-based matching.
  # Logic: We run ast-grep if general tools are enabled OR if specific languages are isolated.
  if [ "$PROCESS_GENERAL" = true ] || [ "$HAS_ISOLATION" = true ]; then
    if [ "$HAS_ISOLATION" = true ]; then
      if [ "$PROCESS_PYTHON" = true ] && [ -f "$CONF_RULES_DIR/python-audit.yml" ]; then
        run_audit_tool "ast-grep security scan (Python, python-audit.yml)" ast-grep scan --config "$CONF_RULES_DIR/python-audit.yml" "$CONF_PYTHON_TARGET"
      fi
      if [ "$PROCESS_GOLANG" = true ] && [ -f "$CONF_RULES_DIR/go-audit.yml" ]; then
        run_audit_tool "ast-grep security scan (Golang, go-audit.yml)" ast-grep scan --config "$CONF_RULES_DIR/go-audit.yml" "$CONF_GOLANG_TARGET"
      fi
      if [ "$PROCESS_NODEJS" = true ] && [ -f "$CONF_RULES_DIR/node-audit.yml" ]; then
        run_audit_tool "ast-grep security scan (Node.js, node-audit.yml)" ast-grep scan --config "$CONF_RULES_DIR/node-audit.yml" "$CONF_NODEJS_TARGET"
      fi
      if [ "$PROCESS_BASH" = true ] && [ -f "$CONF_RULES_DIR/bash-audit.yml" ]; then
        run_audit_tool "ast-grep security scan (Bash, bash-audit.yml)" ast-grep scan --config "$CONF_RULES_DIR/bash-audit.yml" "$CONF_BASH_TARGET"
      fi
    else
      # Global Scan: Runs all project-wide security rules against the workspace.
      if [ -d "$CONF_RULES_DIR" ]; then
        run_audit_tool "ast-grep holistic security scan (all rules)" ast-grep scan --config "$CONF_RULES_DIR" "$CONF_GENERAL_TARGET"
      fi
    fi
  fi
  if [ "$PROCESS_PYTHON" = true ]; then
    # Bandit: Security-focused static analysis for Python.
    # shellcheck disable=SC2086
    run_audit_tool "Bandit Security Scan" bandit $CONF_BANDIT_FLAGS "$CONF_PYTHON_TARGET"
    # Radon: Measures cyclomatic complexity to flag poorly structured code (technical debt).
    # We pass flags separately to ensure the argument parser correctly handles them.
    run_audit_tool "Radon Complexity Analysis" radon cc "$CONF_PYTHON_TARGET" -a -nc
  fi

  if [ "$PROCESS_GOLANG" = true ]; then
    # gosec: Specialized security scanner catching Go-specific vulnerabilities and unsafe patterns.
    run_audit_tool "Gosec Security Scan" gosec "$CONF_GOLANG_TARGET"

    if [ "$PROCESS_INSPECTION" = true ]; then
      # NilAway: Deep static analysis for detecting potential nil-pointer dereferences (panics).
      # Requires a valid Go environment and target pattern.
      run_audit_tool "NilAway Panic Detection" nilaway $CONF_NILAWAY_FLAGS
    fi

    if [ "$PROCESS_EXTENDED" = true ]; then
      # Nilness: Precise analysis for detecting potential nil comparisons and pointer misuse.
      # Executed in Phase 2 alongside deep safety tools.
      run_audit_tool "Nilness Logic Scan" nilness $CONF_NILNESS_FLAGS
    fi
  fi
}

# --- AUDIT PHASE 3: REPOSITORY HYGIENE ---
# PURPOSE: Executes Phase 3 layers for technical debt and dead code reduction.
# USAGE:   Currently optimized for Python-centric project hygiene.
# INPUTS:  Uses PROCESS_PYTHON flag.
# SIDE EFFECTS: Cumulative updates to GLOBAL_EXIT_STATUS.
run_phase_3_cleanup() {
  if [ "$PROCESS_PYTHON" = false ]; then
    if [ "$SELECTIVE_PHASES" = true ]; then
      echo "INFO: Phase 3 (Cleanup) is currently only applicable for Python projects."
    fi
    return
  fi
  # PHASE 3: Repository Hygiene
  # -------------------------------------------------------------------------
  log_phase_banner "3" "CODE CLEANUP (HYGIENE)"
  # Vulture: Scans for dead code (unused variables/functions) with high confidence.
  run_audit_tool "Vulture Dead Code Scan" vulture "$CONF_PYTHON_TARGET" --min-confidence "$CONF_VULTURE_CONFIDENCE"
}

# --- AUDIT PHASE 4: SECRETS MANAGEMENT ---
# PURPOSE: Executes Phase 4 layers for secret detection and identity management.
# USAGE:   Global security check for hard-coded credentials/tokens.
# INPUTS:  Uses PROCESS_GENERAL flag.
# SIDE EFFECTS: Critical alerts if sensitive data is found in plain text.
run_phase_4_secrets() {
  if [ "$PROCESS_GENERAL" = false ]; then
    if [ "$SELECTIVE_PHASES" = true ]; then
      echo "INFO: Phase 4 (Secrets) is not applicable when general security tools are disabled."
    fi
    return
  fi
  # PHASE 4: Identity & Secrets Management
  # -------------------------------------------------------------------------
  log_phase_banner "4" "SECRETS DETECTION"
  # TruffleHog: Scans the filesystem for hard-coded passwords, keys, and tokens.
  # We use subcommand-first syntax for robust argument parsing.
  # shellcheck disable=SC2086
  run_audit_tool "TruffleHog Secrets Scan" trufflehog filesystem $CONF_TRUFFLEHOG_FLAGS "$CONF_GENERAL_TARGET"
}

# --- AUDIT PHASE 5: SUPPLY CHAIN & SBOM ---
# PURPOSE: Executes Phase 5 layers for SBOM generation and supply chain audit.
# USAGE:   Deep dependency scanning and holistic configuration audits.
# INPUTS:  Uses PROCESS_EXTRA_SCAN and standard ecosystem flags.
# SIDE EFFECTS: Generates external artifacts (e.g., sytf reports).
run_phase_5_supply_chain() {
  local NEED_PHASE=false
  [ "$PROCESS_GENERAL" = true ] || [ "$PROCESS_PYTHON" = true ] || [ "$PROCESS_GOLANG" = true ] || [ "$PROCESS_NODEJS" = true ] || [ "$PROCESS_EXTRA_SCAN" = true ] && NEED_PHASE=true
  if [ "$NEED_PHASE" = false ]; then
    if [ "$SELECTIVE_PHASES" = true ]; then
      echo "INFO: Phase 5 (Supply Chain) is not applicable for the current ecosystem selection."
    fi
    return
  fi

  # PHASE 5: Supply Chain Management (Dependency Audit & SBOM)
  # -------------------------------------------------------------------------
  log_phase_banner "5" "SUPPLY CHAIN AND VULNERABILITIES"

  if [ "$PROCESS_GENERAL" = true ]; then
    # Grype: General vulnerability scanner for OS packages and lock files.
    # shellcheck disable=SC2086
    run_audit_tool "Grype Vulnerability Scan" grype $CONF_GRYPE_FLAGS "$CONF_GENERAL_TARGET"
  fi

  if [ "$PROCESS_PYTHON" = true ]; then
    # pip-audit: Purpose-built scanner utilizing the Python Packaging Advisory (PyPA) database.
    # We target specific manifests to avoid irrelevant host-environment scans.
    local PIP_AUDIT_MANIFEST_FOUND=false
    local PIP_FIX_FLAG=""
    [ "$PROCESS_FIX" = true ] && PIP_FIX_FLAG="--fix"

    for req_file in "requirements.txt" "requirements-dev.txt"; do
      if [ -f "$req_file" ]; then
        # shellcheck disable=SC2086
        run_audit_tool "pip-audit ($req_file)" pip-audit $CONF_PIPAUDIT_FLAGS -r "$req_file" $PIP_FIX_FLAG
        PIP_AUDIT_MANIFEST_FOUND=true
      fi
    done

    if [ -f "pyproject.toml" ]; then
      # pyproject.toml: Handles local project context via standard pip-audit discovery.
      # shellcheck disable=SC2086
      run_audit_tool "pip-audit (pyproject.toml)" pip-audit $CONF_PIPAUDIT_FLAGS $PIP_FIX_FLAG
      PIP_AUDIT_MANIFEST_FOUND=true
    fi

    if [ "$PIP_AUDIT_MANIFEST_FOUND" = false ]; then
      echo "[WARNING] pip-audit skipped: No dependency manifest (requirements.txt or pyproject.toml) detected in project root."
    fi
  fi

  if [ "$PROCESS_NODEJS" = true ]; then
    # npm audit: Registry-specific verification (Real-time advisories).
    # We only run this if a lockfile is present to avoid predictable NPM 'ENOLOCK' errors.
    if [ -f "package-lock.json" ] || [ -f "yarn.lock" ] || [ -f "pnpm-lock.yaml" ]; then
      # shellcheck disable=SC2086
      run_audit_tool "NPM Audit" npm audit $CONF_NPM_AUDIT_FLAGS
    else
      echo "[INFO] NPM Audit skipped: No lockfile detected (required for security analysis)."
    fi
  fi

  if [ "$PROCESS_GOLANG" = true ]; then
    # govulncheck: Official Google tool for scanning the Go vulnerability database.
    run_audit_tool "GoVulnCheck" govulncheck "$CONF_GOLANG_TARGET"
  fi

  if [ "$PROCESS_EXTRA_SCAN" = true ]; then
    echo "[General Purpose Extra Scans]"
    # Syft: Generates an artifact listing all software components (SBOM).
    run_audit_tool "Syft SBOM Generation" syft "$CONF_GENERAL_TARGET"
    # Trivy: Comprehensive second-opinion scanner for vulns and misconfigurations.
    # shellcheck disable=SC2086
    run_audit_tool "Trivy Holistic Scan" trivy filesystem $CONF_TRIVY_FLAGS "$CONF_GENERAL_TARGET"
  fi
}

# ===== MODULES: REPORTING AND ORCHESTRATION =====

# --- MODULE: AUTOMATED INSTALLATION ENGINE ---
# PURPOSE: Detects and installs missing tools into user-context without sudo.
# USAGE:   Called before audit phases when --install flags are active.
# INPUTS:  Ecosystem-specific requests.
# SIDE EFFECTS: Modifies ~/.local/bin, ~/.npm-global, and GOPATH/bin.

# Helper: Checks if a binary is installed in a local user-context path.
is_local_tool() {
  local bin="$1"
  local bin_path
  bin_path=$(command -v "$bin" 2> /dev/null)
  [ -z "$bin_path" ] && return 1

  # Get absolute GOPATH if possible
  local gopath_bin
  gopath_bin=$(go env GOPATH 2> /dev/null)/bin

  # Residency Check: Compare resolved path against known local prefixes.
  if [[ "$bin_path" == "${CONF_USER_BIN}"* ]] ||
    [[ "$bin_path" == "${CONF_NPM_PREFIX}"* ]] ||
    [[ -n "$gopath_bin" && "$bin_path" == "${gopath_bin}"* ]]; then
    return 0
  fi
  return 1
}

bootstrap_uv() {
  if ! command -v uv > /dev/null 2>&1; then
    echo "--> [Bootstrap] Installing 'uv' into user context..."
    curl "${CURL_OPTS[@]}" https://astral.sh/uv/install.sh | sh
    # Ensure uv is in the current execution path immediately after install
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
}

prep_npm_prefix() {
  if [ ! -d "$CONF_NPM_PREFIX" ]; then
    echo "--> [Prep] Configuring local NPM prefix: $CONF_NPM_PREFIX"
    mkdir -p "$CONF_NPM_PREFIX"
    npm config set prefix "$CONF_NPM_PREFIX"
  fi
  # Ensure current execution sees the prefix binaries
  export PATH="${CONF_NPM_PREFIX}/bin:${PATH}"
}

install_python_tool() {
  local pkg="$1"
  echo "--> [Install/Update] Python tool: $pkg"
  bootstrap_uv
  if command -v uv > /dev/null 2>&1; then
    uv tool install "$pkg" --upgrade --force
  else
    python3 -m pip install --user "$pkg" --upgrade
  fi
}

install_golang_tool() {
  local url="$1"
  echo "--> [Install] Golang tool: $url"
  go install "${GO_OPTS[@]}" "${url}@latest"
}

install_nodejs_tool() {
  local pkg="$1"
  echo "--> [Install/Update] Node.js tool: $pkg"
  prep_npm_prefix
  # Appending @latest ensures version refresh
  [[ "$pkg" != *"@"* ]] && pkg="${pkg}@latest"
  npm install -g "$pkg"
}

install_script_tool() {
  local label="$1"
  local url="$2"
  echo "--> [Install/Update] $label via official script..."
  curl "${CURL_OPTS[@]}" "$url" | sh -s -- -b "$CONF_USER_BIN"
}

# Helper: Validates that an installation or update request has a valid scope.
validate_install_scope() {
  if [ "$PROCESS_INSTALL" = true ] || [ "$PROCESS_INSTALL_ONLY" = true ] ||
    [ "$PROCESS_UPDATE" = true ] || [ "$PROCESS_UPDATE_ONLY" = true ]; then
    if [ "$HAS_ISOLATION" = false ] && [ "$SELECTIVE_PHASES" = false ] && [ "$PROCESS_AUTO" = false ]; then
      echo "WARNING: --install/--update flags require a specified scope (--python, --golang, --run-*, etc.)."
      echo "To prevent accidental global bloat, please specify which tools you need."
      exit 1
    fi
  fi
}

# Lifecycle: Executes installation or update for requested ecosystems.
execute_install_logic() {
  if [ "$PROCESS_INSTALL" = false ] && [ "$PROCESS_INSTALL_ONLY" = false ] &&
    [ "$PROCESS_UPDATE" = false ] && [ "$PROCESS_UPDATE_ONLY" = false ]; then return; fi

  echo "========================================================="
  echo " INSTALLATION & UPDATE ENGINE (USER-CONTEXT)"
  echo "========================================================="

  # Helper: Universal trigger condition for tool procurement.
  # Logic:
  # 1. If tool is MISSING entirely -> Trigger INSTALL logic.
  # 2. If tool is PRESENT + UPDATE flag is ON + Residency is LOCAL -> Trigger UPDATE logic.
  # 3. Else -> Skip (to avoid global environment pollution).
  should_process() {
    local bin="$1"
    # Condition 1: Install undetected tools
    if ! command -v "$bin" > /dev/null 2>&1; then return 0; fi

    # Condition 2: Update local tools only
    if [ "$PROCESS_UPDATE" = true ] || [ "$PROCESS_UPDATE_ONLY" = true ]; then
      if is_local_tool "$bin"; then return 0; fi
    fi

    # Condition 3: skip everything else (Global tools, or present tools without update flag)
    return 1
  }

  if [ "$PROCESS_PYTHON" = true ]; then
    for tool in "ruff" "pyright" "radon" "vulture" "pip-audit" "bandit"; do
      if should_process "$tool"; then
        install_python_tool "$tool"
      fi
    done
  fi

  if [ "$PROCESS_GOLANG" = true ]; then
    for tool in "gofumpt" "golangci-lint" "nilaway" "gosec" "govulncheck" "nilness"; do
      if should_process "$tool"; then
        case $tool in
          "gofumpt") install_golang_tool "mvdan.cc/gofumpt" ;;
          "golangci-lint") install_golang_tool "github.com/golangci/golangci-lint/cmd/golangci-lint" ;;
          "nilaway") install_golang_tool "github.com/uber-go/nilaway/cmd/nilaway" ;;
          "nilness") install_golang_tool "golang.org/x/tools/go/analysis/passes/nilness/cmd/nilness" ;;
          "gosec") install_golang_tool "github.com/securego/gosec/v2/cmd/gosec" ;;
          "govulncheck") install_golang_tool "golang.org/x/vuln/cmd/govulncheck" ;;
        esac
      fi
    done
  fi

  if [ "$PROCESS_NODEJS" = true ]; then
    if should_process "oxlint"; then install_nodejs_tool "oxlint"; fi
    if should_process "oxfmt"; then install_nodejs_tool "oxfmt"; fi
    if should_process "biome"; then install_nodejs_tool "@biomejs/biome"; fi
  fi

  if [ "$PROCESS_BASH" = true ]; then
    if should_process "shfmt"; then
      install_golang_tool "mvdan.cc/sh/v3/cmd/shfmt"
    fi
    if should_process "shellcheck"; then
      # We use the Node.js wrapper for a reliable no-sudo binary installation.
      install_nodejs_tool "shellcheck"
    fi
  fi

  if [ "$PROCESS_GENERAL" = true ]; then
    if should_process "semgrep"; then install_python_tool "semgrep"; fi
    if should_process "ast-grep"; then install_nodejs_tool "@ast-grep/cli"; fi

    # Binary-specific installation scripts (Fast, no-recompile procurement)
    if should_process "trufflehog"; then
      install_script_tool "TruffleHog" "https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh"
    fi
    if should_process "trivy"; then
      install_script_tool "Trivy" "https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh"
    fi
    if should_process "grype"; then
      install_script_tool "Grype" "https://raw.githubusercontent.com/anchore/grype/main/install.sh"
    fi
    if should_process "syft"; then
      install_script_tool "Syft" "https://raw.githubusercontent.com/anchore/syft/main/install.sh"
    fi
  fi

  if [ "$PROCESS_POWERSHELL" = true ]; then
    if command -v pwsh > /dev/null 2>&1; then
      echo "--> [Install/Update] Bootstrapping PowerShell dependencies (PSScriptAnalyzer)..."
      pwsh -ExecutionPolicy Bypass -File "$CONF_SCRIPT_ROOT/pslint.ps1" -CheckLinter
    else
      echo "[WARNING] pwsh not found. Cannot bootstrap PowerShell dependencies."
    fi
  fi

  echo "--- INSTALLATION/UPDATE COMPLETE ---"
  if [ "$PROCESS_INSTALL_ONLY" = true ] || [ "$PROCESS_UPDATE_ONLY" = true ]; then
    echo "Pre-staging/Update complete. Audit execution skipped as requested."
    exit 0
  fi
}

# --- MODULE: AUDIT TERMINATION AND REPORTING ---
# PURPOSE: Concludes the audit session and returns the final unified status.
# USAGE:   Final operation in the main() orchestrator.
# INPUTS:  Uses GLOBAL_EXIT_STATUS.
# SIDE EFFECTS: Terminates the script with exit status 0 or 1.
finalize_report() {
  local end_time
  end_time=$(date +%s)
  local duration
  duration=$((end_time - AUDIT_START_TIME))
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  echo -e "\n#########################################################"
  echo "#              AUDIT SUMMARY AND EXECUTION              #"
  echo "#########################################################"
  echo "# END TIME   : ${timestamp}"
  echo "# DURATION   : ${duration} seconds"
  if [ "$GLOBAL_EXIT_STATUS" -eq 0 ]; then
    echo "# STATUS     : [PASSED] ALL CONTROLS COMPLIANT"
  else
    echo "# STATUS     : [FAILED] ISSUES DETECTED FOR REMEDIATION"
  fi
  exit $GLOBAL_EXIT_STATUS
}

# --- MODULE: ORCHESTRATOR, MAIN EXECUTION ENTRY POINT ---
# PURPOSE: Top-level entry point and execution coordinator for the audit script.
# USAGE:   main "$@"
# INPUTS:  $@: Command-line arguments.
# SIDE EFFECTS: Orchestrates the full lifecycle from init to reporting.
main() {
  setup_environment

  # Global Signal Handler for graceful termination of audit sub-processes.
  trap 'echo "INTERRUPTED: Cleaning up..." >&2; [ -n "$(jobs -pr)" ] && kill $(jobs -pr) 2>/dev/null; exit 1' SIGINT SIGTERM

  parse_arguments "$@"
  init_reporting # Move up to capture resolve and install phases
  validate_install_scope

  # Operational Phase: Context & Readiness
  resolve_context
  run_diagnosis

  # Operational Phase: Toolset Synchronization
  execute_install_logic

  # Enable Audit Mode (Cumulative Reporting)
  set +e

  [ "$RUN_PHASE_1" = true ] && run_phase_1_quality
  [ "$RUN_PHASE_2" = true ] && run_phase_2_logic
  [ "$RUN_PHASE_3" = true ] && run_phase_3_cleanup
  [ "$RUN_PHASE_4" = true ] && run_phase_4_secrets
  [ "$RUN_PHASE_5" = true ] && run_phase_5_supply_chain

  # Final Status Aggregation:
  # Check if any background processes signaled failure.
  if [ -d "${AUDIT_STATUS_DIR:-}" ] && [ "$(ls -A "$AUDIT_STATUS_DIR" 2> /dev/null)" ]; then
    GLOBAL_EXIT_STATUS=1
    rm -rf "$AUDIT_STATUS_DIR"
  fi

  finalize_report
}

# Invoke Entry Point
main "$@"
