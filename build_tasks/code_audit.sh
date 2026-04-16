#!/bin/bash
# -----------------------------------------------------------------------------
# Code Audit Pipeline (code_audit.sh)
# v1.1.0xg  2026/04/15  XDG
# 
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   To provide a multi-tiered, polyglot static analysis and security audit 
#   framework that enforces syntactic correctness, security hardening, and 
#   supply chain integrity for Python and Go projects.
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
# USAGE:   Called at the start of main() to establish the baseline baseline.
# INPUTS:  None.
# SIDE EFFECTS: Sets shell options (set -Eeuo pipefail) and initializes globals.
setup_environment() {
    set -Eeuo pipefail
    
    # Global Audit Status: Accumulates failures across all tools.
    # 0 = All tools passed; 1 = One or more tools failed.
    GLOBAL_EXIT_STATUS=0
    
    # Configuration Persistence: Baseline state for audit operations.
    TARGET_PATH="."           # Baseline directory for all audit operations.
    PROCESS_PYTHON=true       # Flag to enable/disable Python toolset.
    PROCESS_GENERAL=true      # Flag for language-agnostic security tools.
    PROCESS_GOLANG=true       # Flag to enable/disable Go toolset.
    PROCESS_AUTO=false        # When true, script uses heuristic file detection.
    PROCESS_DETECT=false      # Diagnostic mode to verify installed binaries.
    PROCESS_EXTENDED=false    # Enables high-depth quality tools (Standalone + Extra Lints).
    PROCESS_EXTRA_SCAN=false  # Enables heavy supply chain/SBOM tasks (Syft/Trivy).
    PROCESS_FIX=false         # If true, enables auto-fix/remediation for supported tools.
    LOG_PATH=""               # Optional file path to capture the audit report.
    HAS_ISOLATION=false       # Track if the user explicitly requested a specific scope.
    
    # Isolation tracking: Internal state for manual ecosystem overrides.
    SPEC_PYTHON=false         # Tracks explicit --python request for scope isolation.
    SPEC_GOLANG=false         # Tracks explicit --golang request for scope isolation.
    SPEC_GENERAL=false        # Tracks explicit --general request for scope isolation.
    
    # Tool Ecosystem Registries: Centralized checklists for audit tools.
    AUDIT_PYTHON_TOOLS=("pip-audit" "pyright" "radon" "ruff" "vulture")
    AUDIT_GOLANG_TOOLS=("go" "gofumpt" "golangci-lint" "gosec" "govulncheck" "nilaway")
    AUDIT_GENERAL_TOOLS=("grype" "semgrep" "syft" "trivy" "trufflehog")

    # --- CONFIGURATION CONSTANTS (CENTRALIZED) ---
    # These variables eliminate hardcoding within the audit execution phases.
    CONF_SEARCH_DEPTH=3                 # Max depth for heuristic language detection.
    CONF_RUFF_CACHE="${TEMP}/cache/python/ruff"
    CONF_PYTHON_TARGET="."              # Target pattern for Python tools.
    CONF_GOLANG_TARGET="./..."          # Target pattern for Go tools.
    CONF_GENERAL_TARGET="."             # Target pattern for workspace-wide tools.
    
    CONF_VULTURE_CONFIDENCE=90          # Confidence threshold for dead code detection.
    CONF_TRUFFLEHOG_FLAGS="--no-update" # Suppression for internal updater failures.
    CONF_SEMGREP_CONFIG="auto"          # Rule set selection for Semgrep.
    CONF_RADON_FLAGS="-a -nc"           # Flags for complexity analysis.
    CONF_GOFUMPT_FLAGS="-extra"         # Extensions for strict Go formatting.
    CONF_GOLANGCI_FLAGS="--no-config"    # Forced clean state for the meta-linter.

    # Execution Environment Preparation
    # Conditional export ensures tools have dedicated persistent work areas.
    if [ "$PROCESS_PYTHON" = true ]; then export RUFF_CACHE_DIR="$CONF_RUFF_CACHE"; fi
}

# --- MODULE: AUDIT EXECUTION WRAPPER ---
# PURPOSE: Executional wrapper that captures tool status without script exit.
# USAGE:   run_audit_tool <Label> <Command> [Args...]
# INPUTS:  $1: Human-readable tool label.
#          $2+: The actual command and its arguments.
# SIDE EFFECTS: Updates the GLOBAL_EXIT_STATUS if a command fails.
run_audit_tool() {
    local label="$1"
    shift
    local cmd="$1"

    # Pre-execution Availability Check: Prevents 'command not found' shell errors.
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "WARNING: $label skipped. Binary '$cmd' is not found in PATH."
        return 0
    fi

    echo "--> Running $label..."
    if ! "$@"; then
        echo "FAILED: $label detected issues or failed to execute."
        GLOBAL_EXIT_STATUS=1
    fi
    echo ""
}

# --- MODULE: TOOL AVAILABILITY CHECK ---
# PURPOSE: Diagnostic utility to verify and report tool binary availability.
# USAGE:   check_tool <BinaryName>
# INPUTS:  $1: The command name to check via 'command -v'.
# SIDE EFFECTS: Outputs a formatted status line to stdout.
check_tool() {
    local bin="$1"
    if command -v "$bin" >/dev/null 2>&1; then
        local path
        path=$(command -v "$bin")
        local ver=""

        # Heuristic version extraction: Attempts common version flags and scrubs the output.
        # Uses || true to ensure grep failures or missing flags do not trigger 'set -e'.
        ver=$("$bin" --version 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][a-zA-Z0-9.]+)?' | head -n 1 || true)
        [ -z "$ver" ] && ver=$("$bin" version 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][a-zA-Z0-9.]+)?' | head -n 1 || true)
        [ -z "$ver" ] && ver=$("$bin" -v 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][a-zA-Z0-9.]+)?' | head -n 1 || true)
        
        # Fallback for Go-style build IDs (common in NilAway and custom Go binaries)
        [ -z "$ver" ] && ver=$("$bin" -V=full 2>&1 | grep -oE 'buildID=[a-f0-9]+' | cut -d= -f2 | head -n 1 || true)

        # Truncate version string to 7 characters and add ellipsis if necessary.
        if [ -n "$ver" ]; then 
            if [ ${#ver} -gt 7 ]; then
                ver="v${ver:0:7}.."
            else
                ver="v$ver"
            fi
        else 
            ver="          "
        fi

        printf "  %-15s : [FOUND]   %-12s %s\n" "$bin" "$ver" "$path"
    else
        printf "  %-15s : [MISSING]\n" "$bin"
    fi
}

# --- MODULE: INTERFACE USAGE GUIDE ---
# PURPOSE: Displays the command-line interface usage guide and available flags.
# USAGE:   show_usage
# INPUTS:  None (reads from HEREDOC).
# SIDE EFFECTS: Outputs manual to stdout.
show_usage() {
    cat << EOF

Usage: $0 [--path <dir>] [--auto] [--detect] [--extended] [--extra-scan] [--fix] [--log <path>] [--python] [--golang] [--general]

Options:
  --path <dir>:    Run the audit in the specified directory.
  --auto:           Autodetect toolsets based on files (plus general checks).
  --detect:         Check and report which audit tools are installed.
  --extended:       Run deep code quality tools (nil-checks, strict formatting, extra Go linters).
  --extra-scan:     Run heavy security/supply chain scans (Syft SBOM, Trivy config scans).
  --fix:            Enable auto-fixes/formatting (DEFAULT is zero-impact check only).
  --log <path>:     Redirect and append all output to the specified log file.
  --python:         Force include/isolate Python tools.
  --golang:         Force include/isolate Go tools.
  --general:        Force include/isolate general tools.
  --help:           Show this help message.

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

    # Flag Parsing: Decouples user intent from internal execution logic.
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --path)       TARGET_PATH="$2"; shift ;;
            --auto)       PROCESS_AUTO=true; HAS_ISOLATION=true ;;
            --detect)     PROCESS_DETECT=true ;;
            --extended)   PROCESS_EXTENDED=true ;;
            --extra-scan) PROCESS_EXTRA_SCAN=true ;;
            --fix)        PROCESS_FIX=true ;;
            --log)        LOG_PATH="$2"; shift ;;
            --python)     HAS_ISOLATION=true; SPEC_PYTHON=true ;;
            --golang)     HAS_ISOLATION=true; SPEC_GOLANG=true ;;
            --general)    HAS_ISOLATION=true; SPEC_GENERAL=true ;;
            --help|-h)    show_usage; exit 0 ;;
            *)            echo "Unknown argument: $1"; exit 1 ;;
        esac
        shift
    done
}

# --- MODULE: PARALLEL TOOL ORCHESTRATOR ---
# PURPOSE: Spawns background tasks for tool checks to optimize diagnostic speed.
# USAGE:   parallel_check_tools <SectionLabel> <ToolArray[@]>
# INPUTS:  $1: Section header label.
#          $2+: Array of binary names.
# SIDE EFFECTS: Creates and destroys a temporary output buffer directory.
parallel_check_tools() {
    local label="$1"
    shift
    local tools=("$@")
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "[$label]"
    local idx=0
    for tool in "${tools[@]}"; do
        idx=$((idx + 1))
        local pad_idx
        pad_idx=$(printf "%03d" "$idx")
        # Launch check in background and capture to ordered buffer file.
        check_tool "$tool" > "$tmp_dir/${pad_idx}_${tool}" &
    done
    
    # Synchronize: Wait for all binary checks to complete.
    wait

    # Consolidate results in the correct order.
    cat "$tmp_dir"/*
    rm -rf "$tmp_dir"
    echo ""
}

# --- MODULE: DIAGNOSTIC READINESS REPORT ---
# PURPOSE: Performs a parallelized readiness check of the execution environment.
# USAGE:   Triggered by the --detect flag.
# INPUTS:  Uses global detection state.
# SIDE EFFECTS: Terminates the script after displaying the report.
run_diagnosis() {
    if [ "$PROCESS_DETECT" = false ]; then return; fi
    
    [ -n "$LOG_PATH" ] && init_reporting
    
    echo "---------------------------------------------------------"
    echo " TOOL DETECTION & READINESS REPORT"
    echo "---------------------------------------------------------"
    
    parallel_check_tools "Python Quality & Security Tools" "${AUDIT_PYTHON_TOOLS[@]}"
    parallel_check_tools "Golang Quality & Security Tools" "${AUDIT_GOLANG_TOOLS[@]}"
    parallel_check_tools "General Purpose Audit Tools" "${AUDIT_GENERAL_TOOLS[@]}"

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
    
    # Step 1: Directory context validation
    if [ "$TARGET_PATH" != "." ]; then
        if [ -d "$TARGET_PATH" ]; then
            echo "--> Switching to directory: $TARGET_PATH"
            cd "$TARGET_PATH" || exit 1
        else
            echo "Error: Directory $TARGET_PATH does not exist."
            exit 1
        fi
    fi

    # Step 2: Toolset isolation/autodetection logic
    if [ "$PROCESS_AUTO" = true ]; then
        PROCESS_GENERAL=true
        # Heuristic detection (limit depth for performance)
        [ -n "$(find . -maxdepth "$CONF_SEARCH_DEPTH" -name "*.py" -print -quit)" ] && PROCESS_PYTHON=true || PROCESS_PYTHON=false
        [ -n "$(find . -maxdepth "$CONF_SEARCH_DEPTH" -name "*.go" -print -quit)" ] && PROCESS_GOLANG=true || PROCESS_GOLANG=false
        
        if [ "$PROCESS_PYTHON" = true ]; then echo "--> [Auto-Detect] Python environment active."; fi
        if [ "$PROCESS_GOLANG" = true ]; then echo "--> [Auto-Detect] Golang environment active."; fi
    elif [ "$HAS_ISOLATION" = true ]; then
        # Disable everything except explicitly requested toolsets
        PROCESS_PYTHON=$SPEC_PYTHON
        PROCESS_GOLANG=$SPEC_GOLANG
        PROCESS_GENERAL=$SPEC_GENERAL
    fi
}

# --- MODULE: GLOBAL REPORTING INITIALIZATION ---
# PURPOSE: Establishes a global output redirection layer for audit reporting.
# USAGE:   Triggered by the presence of a LOG_PATH variable.
# INPUTS:  Uses global LOG_PATH.
# SIDE EFFECTS: Redirects subsequent stdout and stderr via 'exec'.
init_reporting() {
    # Step 3: Global Logging Initialization
    # If a log path is specified, captures both stdout and stderr into a single
    # comprehensive report for developer remediation and audit evidence.
    if [ -n "$LOG_PATH" ]; then
        echo "--> Redirecting audit report to: $LOG_PATH"
        mkdir -p "$(dirname "$LOG_PATH")" || true
        # Redirect stdout and stderr to both console and log file
        exec > >(tee -a "$LOG_PATH") 2>&1
    fi
}

# ===== MODULES: AUDIT PHASES =====

# --- AUDIT PHASE 1: CORE QUALITY & TYPES ---
# PURPOSE: Executes Phase 1 audit layers (Linting, Formatting, Type Safety).
# USAGE:   Called by main() during the sequential audit flow.
# INPUTS:  Uses PROCESS_PYTHON and PROCESS_GOLANG flags.
# SIDE EFFECTS: Outputs phase results to stdout/log.
run_phase_1_quality() {
    if [ "$PROCESS_PYTHON" = false ] && [ "$PROCESS_GOLANG" = false ]; then return; fi
    
    # PHASE 1: Baseline Quality (Lints, Formatters, Type Safety)
    # -------------------------------------------------------------------------
    echo "--- PHASE 1: SYNTAX, STYLE AND TYPES ---"
    
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
            # go fmt: Standard tool for formatting Go source code.
            run_audit_tool "Go Format (Fix)" go fmt "$CONF_GOLANG_TARGET"
            if [ "$PROCESS_EXTENDED" = true ]; then
                # gofumpt: Stricter, more opinionated Go formatter.
                run_audit_tool "Gofumpt Formatter (Fix)" gofumpt -w "$CONF_GOFUMPT_FLAGS" "$CONF_GENERAL_TARGET"
            fi
        else
            # Non-destructive check: Use gofmt -l to list files that would be changed.
            run_audit_tool "Go Format (Check Only)" gofmt -l "$CONF_GOLANG_TARGET"
            if [ "$PROCESS_EXTENDED" = true ]; then
                run_audit_tool "Gofumpt Formatter (Check Only)" gofumpt -l "$CONF_GOFUMPT_FLAGS" "$CONF_GENERAL_TARGET"
            fi
        fi
        
        # golangci-lint: High-performance orchestrator for Go linters.
        # Aggregates results from dozens of internal and community-standard Go linters.
        local EXT_LINERS=""
        local FIX_FLAG=""
        [ "$PROCESS_FIX" = true ] && FIX_FLAG="--fix"
        if [ "$PROCESS_EXTENDED" = true ]; then
            # Extended mode: adds linters for complexity, magic numbers, and stylistic edge cases.
            EXT_LINERS="--enable=gocritic,goconst,mnd,interfacebloat,gocyclo,copyloopvar"
        fi
        
        run_audit_tool "GolangCI Meta-Linter" golangci-lint run $EXT_LINERS $FIX_FLAG "$CONF_GOLANGCI_FLAGS" "$CONF_GOLANG_TARGET"
    fi
}

# --- AUDIT PHASE 2: ADVANCED LOGIC AND SAFETY ---
# PURPOSE: Executes Phase 2 layers focusing on logical complexity and safety.
# USAGE:   Triggered for Python, Golang, and general language-agnostic tools.
# INPUTS:  Uses PROCESS_* and PROCESS_EXTENDED flags.
# SIDE EFFECTS: Cumulative updates to GLOBAL_EXIT_STATUS.
run_phase_2_logic() {
    if [ "$PROCESS_GENERAL" = false ] && [ "$PROCESS_PYTHON" = false ] && [ "$PROCESS_GOLANG" = false ]; then return; fi
    
    # PHASE 2: Advanced Logic Analysis (Complexity and Security Patterns)
    # -------------------------------------------------------------------------
    echo "--- PHASE 2: LOGIC, SAFETY AND COMPLEXITY ---"
    if [ "$PROCESS_GENERAL" = true ]; then
        # Semgrep: Polyglot static analysis searching for dangerous coding patterns.
        # Focuses on high-risk vulnerabilities (SQLi, XSS, Command Injection).
        run_audit_tool "Semgrep Scan" semgrep scan --config "$CONF_SEMGREP_CONFIG" --error
    fi
    if [ "$PROCESS_PYTHON" = true ]; then
        # Radon: Measures cyclomatic complexity to flag poorly structured code (technical debt).
        run_audit_tool "Radon Complexity Analysis" radon cc "$CONF_PYTHON_TARGET" $CONF_RADON_FLAGS
    fi
    
    if [ "$PROCESS_GOLANG" = true ] && [ "$PROCESS_EXTENDED" = true ]; then
        # nilaway: Uber-designed developer productivity tool for potential nil pointer panic detection.
        run_audit_tool "NilAway Panic Detector" nilaway "$CONF_GOLANG_TARGET"
        # gosec: Specialized security scanner catching Go-specific vulnerabilities and unsafe patterns.
        run_audit_tool "Gosec Security Scan" gosec "$CONF_GOLANG_TARGET"
    fi
}

# --- AUDIT PHASE 3: REPOSITORY HYGIENE ---
# PURPOSE: Executes Phase 3 layers for technical debt and dead code reduction.
# USAGE:   Currently optimized for Python-centric project hygiene.
# INPUTS:  Uses PROCESS_PYTHON flag.
# SIDE EFFECTS: Cumulative updates to GLOBAL_EXIT_STATUS.
run_phase_3_cleanup() {
    if [ "$PROCESS_PYTHON" = false ]; then return; fi
    # PHASE 3: Repository Hygiene
    # -------------------------------------------------------------------------
    echo "--- PHASE 3: CODE CLEANUP (PYTHON) ---"
    # Vulture: Scans for dead code (unused variables/functions) with high confidence.
    run_audit_tool "Vulture Dead Code Scan" vulture "$CONF_PYTHON_TARGET" --min-confidence "$CONF_VULTURE_CONFIDENCE"
}

# --- AUDIT PHASE 4: SECRETS MANAGEMENT ---
# PURPOSE: Executes Phase 4 layers for secret detection and identity management.
# USAGE:   Global security check for hard-coded credentials/tokens.
# INPUTS:  Uses PROCESS_GENERAL flag.
# SIDE EFFECTS: Critical alerts if sensitive data is found in plain text.
run_phase_4_secrets() {
    if [ "$PROCESS_GENERAL" = false ]; then return; fi
    # PHASE 4: Identity & Secrets Management
    # -------------------------------------------------------------------------
    echo "--- PHASE 4: SECRETS DETECTION ---"
    # TruffleHog: Scans the filesystem for hard-coded passwords, keys, and tokens.
    run_audit_tool "TruffleHog Secrets Scan" trufflehog $CONF_TRUFFLEHOG_FLAGS filesystem "$CONF_GENERAL_TARGET"
}

# --- AUDIT PHASE 5: SUPPLY CHAIN & SBOM ---
# PURPOSE: Executes Phase 5 layers for SBOM generation and supply chain audit.
# USAGE:   Deep dependency scanning and holistic configuration audits.
# INPUTS:  Uses PROCESS_EXTRA_SCAN and standard ecosystem flags.
# SIDE EFFECTS: Generates external artifacts (e.g., sytf reports).
run_phase_5_supply_chain() {
    local NEED_PHASE=false
    [ "$PROCESS_GENERAL" = true ] || [ "$PROCESS_PYTHON" = true ] || [ "$PROCESS_GOLANG" = true ] || [ "$PROCESS_EXTRA_SCAN" = true ] && NEED_PHASE=true
    if [ "$NEED_PHASE" = false ]; then return; fi

    # PHASE 5: Supply Chain Management (Dependency Audit & SBOM)
    # -------------------------------------------------------------------------
    echo "--- PHASE 5: SUPPLY CHAIN (DEPENDENCY AND VULNERABILITY SCANNING) ---"
    if [ "$PROCESS_GENERAL" = true ]; then
        # Grype: General vulnerability scanner for OS packages and lock files.
        # Scans requirements.txt or poetry.lock against known CVE databases.
        run_audit_tool "Grype Vulnerability Scan" grype "$CONF_GENERAL_TARGET"
    fi
    if [ "$PROCESS_PYTHON" = true ]; then
        # pip-audit: Purpose-built scanner utilizing the Python Packaging Advisory (PyPA) database.
        run_audit_tool "pip-audit" pip-audit
    fi
    if [ "$PROCESS_GOLANG" = true ] && [ "$PROCESS_EXTENDED" = true ]; then
        # govulncheck: Official Google tool for scanning the Go vulnerability database.
        run_audit_tool "GoVulnCheck" govulncheck "$CONF_GOLANG_TARGET"
    fi
    
    if [ "$PROCESS_EXTRA_SCAN" = true ]; then
        echo "[General Purpose Extra Scans]"
        # Syft: Generates an artifact listing all software components (SBOM).
        run_audit_tool "Syft SBOM Generation" syft "$CONF_GENERAL_TARGET"
        # Trivy: Comprehensive second-opinion scanner for vulns and misconfigurations.
        run_audit_tool "Trivy Holistic Scan" trivy filesystem "$CONF_GENERAL_TARGET"
    fi
}

# ===== MODULES: REPORTING AND ORCHESTRATION =====

# --- MODULE: AUDIT TERMINATION AND REPORTING ---
# PURPOSE: Concludes the audit session and returns the final unified status.
# USAGE:   Final operation in the main() orchestrator.
# INPUTS:  Uses GLOBAL_EXIT_STATUS.
# SIDE EFFECTS: Terminates the script with exit status 0 or 1.
finalize_report() {
    echo "---------------------------------------------------------"
    if [ "$GLOBAL_EXIT_STATUS" -eq 0 ]; then
        echo "AUDIT COMPLETE: All tools passed successfully."
    else
        echo "AUDIT COMPLETE: One or more tools detected potential issues."
    fi
    echo "---------------------------------------------------------"
    exit $GLOBAL_EXIT_STATUS
}

# --- MODULE: ORCHESTRATOR, MAIN EXECUTION ENTRY POINT ---
# PURPOSE: Top-level entry point and execution coordinator for the audit script.
# USAGE:   main "$@"
# INPUTS:  $@: Command-line arguments.
# SIDE EFFECTS: Orchestrates the full lifecycle from init to reporting.
main() {
    setup_environment
    parse_arguments "$@"
    run_diagnosis     # Exits early if --detect is passed
    resolve_context
    init_reporting
    
    # Enable Audit Mode (Cumulative Reporting)
    set +e
    
    run_phase_1_quality
    run_phase_2_logic
    run_phase_3_cleanup
    run_phase_4_secrets
    run_phase_5_supply_chain
    
    finalize_report
}

# Invoke Entry Point
main "$@"
