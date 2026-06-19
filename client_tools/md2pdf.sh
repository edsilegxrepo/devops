#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# md2pdf.sh - Convert Markdown files to PDF using a custom Node.js compiler
# v1.2.0xg  2026/06/18  XdG / MIS Center
# -----------------------------------------------------------------------------
# OBJECTIVES:
#   To convert single or multiple Markdown (.md) documents into PDF format
#   in a parallelized, resource-safe manner, with native support for Windows
#   (MSYS2, Cygwin, Git-Bash) and Linux host environments.
#
# CORE COMPONENTS:
#   1. Path Formatter (format_path): Normalizes all file paths to the Windows
#      mixed path style (drive:/sub/sub) and replaces backslashes to avoid
#      escape sequence issues across process boundaries.
#   2. Detection Engine (run_detect): Verifies system binaries, configurations,
#      stylesheets, and global Node.js packages.
#   3. Installation Engine (install_dependencies): Installs required global Node
#      modules and resolves dependencies.
#   4. Parallel Orchestrator (run_conversion): Finds files and runs them via
#      xargs in parallel, with process-capping (max 4) for CPU/RAM safety.
#
# FUNCTIONALITY & DATA FLOW:
#   - Input: CLI Options parsed by main() -> path inputs normalized by format_path().
#   - Execution: Resolves compiler script -> counts target files -> invokes find | xargs.
#   - Sourcing Design: The worker subshell sources SCRIPT_PATH to load and execute
#     convert_single_file(), avoiding non-portable function exports.
#   - Output: Generates target PDF files, aggregates success/fail metrics via an
#     atomic-append results file, and cleans up resources explicitly on completion.
#
# TEST STRATEGY:
#   1. Diagnostic Mode: Execute `./md2pdf.sh --detect` to verify system binaries
#      and Node module resolution.
#   2. Dry Run/Simulation: Run conversion on empty directories to verify early-exit logic.
#   3. Parallel stress test: Convert directories containing multiple Markdown files
#      with both typical names and names containing special characters/spaces to
#      ensure escape characters and parallel locks behave correctly.
#   4. Portability test: Execute in Linux environments and Windows subsets (MSYS2/Cygwin)
#      to verify forward slash translation and cygpath mixed-mode functionality.
# -----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# Configuration & Path Resolution
# =============================================================================

# format_path - Enforce drive:/sub/sub mixed path style in Windows, forbidding backslashes.
# This ensures path strings are fully compatible with both native Windows binaries
# (like node.exe) and Unix utilities (like bash, find, xargs) running in emulation layers.
format_path() {
  local input_path="${1:-}"
  # Replace all backslashes with forward slashes to ban '\' from path variables
  local normalized="${input_path//\\//}"
  # Translate POSIX mounts (e.g. /e/...) to Windows mixed drive paths (e.g. E:/...)
  if command -v cygpath &> /dev/null; then
    normalized=$(cygpath -m "$normalized")
  fi
  echo "$normalized"
}

# SCRIPT_NAME - The base filename of the executing script
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

readonly SCRIPT_VERSION="1.2.0xg"

# SCRIPT_PATH - The absolute, normalized path of the executing script.
# Resolved dynamically so that subshell workers can source it to load function definitions.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2> /dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_PATH="$(format_path "$SCRIPT_PATH")"
readonly SCRIPT_PATH

# =============================================================================
# Utility & Logging Functions
# =============================================================================

# log_info - Prints informational messages to standard error (>&2)
log_info() {
  printf "[INFO] %s\n" "$*" >&2
}

# log_error - Prints error/failure messages to standard error (>&2)
log_error() {
  printf "[ERROR] %s\n" "$*" >&2
}

# log_success - Prints successful operation notifications to standard error (>&2)
log_success() {
  printf "[OK] %s\n" "$*" >&2
}

# die - Log error message and terminate execution with a failure status (exit 1)
die() {
  log_error "$*"
  exit 1
}

# =============================================================================
# Detection Module
# =============================================================================

# run_detect - Entry coordinator for the environment diagnostics verification pass.
# Performs detailed validation of system binaries, workspace configurations,
# local stylesheet directories, and required global Node.js dependency modules.
run_detect() {
  local do_install="${1:-false}"
  local detected=true
  local base_dir
  base_dir="$(dirname "$SCRIPT_PATH")"

  log_info "============================================================================="
  log_info " md2pdf Diagnostics - Prerequisites Verification"
  log_info "============================================================================="

  # 1. System Binaries
  log_info "1. System Binaries:"
  if command -v node &> /dev/null; then
    local node_ver
    node_ver=$(node --version)
    log_success "  - Node.js: Found ($node_ver)"
  else
    log_error "  - Node.js: NOT FOUND (Required)"
    detected=false
  fi

  if command -v npm &> /dev/null; then
    local npm_ver
    npm_ver=$(npm --version)
    log_success "  - npm: Found (v$npm_ver)"
  else
    log_error "  - npm: NOT FOUND (Required)"
    detected=false
  fi

  if command -v jq &> /dev/null; then
    local jq_ver
    jq_ver=$(jq --version 2>/dev/null || echo "Found")
    log_success "  - jq: Found ($jq_ver)"
  else
    log_info "  - jq: Not found (Optional; using fallback Node.js parser for JSON validation)"
  fi

  # 2. Workspace Assets & Configs
  log_info "2. Workspace Assets & Configs:"
  local config_file="${base_dir}/md2pdf_config.json"
  if [[ -f "$config_file" ]]; then
    log_success "  - md2pdf_config.json: Found"
    
    # Pre-flight check: Extract and verify the configured browser executable path
    local browser_exe=""
    if command -v jq &> /dev/null; then
      browser_exe=$(jq -r '.launch_options.executablePath // empty' "$config_file" 2>/dev/null)
    else
      browser_exe=$(node -e "try { console.log(JSON.parse(require('fs').readFileSync('$config_file', 'utf8')).launch_options.executablePath || ''); } catch(e) {}")
    fi

    if [[ -n "$browser_exe" ]]; then
      local normalized_exe
      normalized_exe=$(format_path "$browser_exe")
      if [[ -f "$normalized_exe" ]]; then
        log_success "  - Configured browser path: Found ($browser_exe)"
      else
        log_error "  - Configured browser path: NOT FOUND at '$browser_exe'"
        detected=false
      fi
    else
      log_error "  - Configured browser path: Path not specified in config JSON"
      detected=false
    fi
  else
    log_error "  - md2pdf_config.json: NOT FOUND (Expected at $config_file)"
    detected=false
  fi

  local compiler_dir="${base_dir}/md2pdf_compiler"
  if [[ -d "$compiler_dir" ]]; then
    log_success "  - md2pdf_compiler/ folder: Found"
  else
    log_error "  - md2pdf_compiler/ folder: NOT FOUND (Expected at $compiler_dir)"
    detected=false
  fi

  local compiler_js="${compiler_dir}/md2pdf_compiler.js"
  if [[ -f "$compiler_js" ]]; then
    log_success "  - md2pdf_compiler.js: Found"
  else
    log_error "  - md2pdf_compiler.js: NOT FOUND (Expected at $compiler_js)"
    detected=false
  fi

  local pkg_json="${compiler_dir}/package.json"
  if [[ -f "$pkg_json" ]]; then
    log_success "  - package.json: Found"
  else
    log_error "  - package.json: NOT FOUND (Expected at $pkg_json)"
    detected=false
  fi

  local pkg_lock="${compiler_dir}/package-lock.json"
  if [[ -f "$pkg_lock" ]]; then
    log_success "  - package-lock.json: Found"
  else
    log_error "  - package-lock.json: NOT FOUND (Expected at $pkg_lock)"
    detected=false
  fi

  local html_dir="${compiler_dir}/html"
  if [[ -d "$html_dir" ]]; then
    log_success "  - html/ folder: Found"
    
    # Check individual templates
    local template_files=("header.html" "footer.html")
    for template in "${template_files[@]}"; do
      local file_path="${html_dir}/${template}"
      if [[ -f "$file_path" ]]; then
        log_success "    * html/${template}: Found"
      else
        log_error "    * html/${template}: NOT FOUND (Expected at $file_path)"
        detected=false
      fi
    done
  else
    log_error "  - html/ folder: NOT FOUND (Expected at $html_dir)"
    detected=false
  fi

  local css_dir="${compiler_dir}/css"
  if [[ -d "$css_dir" ]]; then
    log_success "  - css/ folder: Found"
    
    # Check individual stylesheets
    local style_files=("markdown.css" "markdown-pdf.css" "tomorrow.css")
    for style in "${style_files[@]}"; do
      local file_path="${css_dir}/${style}"
      if [[ -f "$file_path" ]]; then
        log_success "    * css/${style}: Found"
      else
        log_error "    * css/${style}: NOT FOUND (Expected at $file_path)"
        detected=false
      fi
    done

    # Check local css/mermaid.min.js with custom warning / download behavior
    local mermaid_file="${css_dir}/mermaid.min.js"
    if [[ -f "$mermaid_file" ]]; then
      log_success "    * css/mermaid.min.js: Found (Local asset resolved)"
    else
      if [[ "$do_install" == "true" ]]; then
        log_info "    * css/mermaid.min.js: Not found. Initiating download..."
        if command -v curl &>/dev/null; then
          if curl -sS -L "https://unpkg.com/mermaid/dist/mermaid.min.js" -o "$mermaid_file"; then
            log_success "    * css/mermaid.min.js: Downloaded successfully"
          else
            log_error "    * css/mermaid.min.js: Download failed"
            detected=false
          fi
        elif command -v wget &>/dev/null; then
          if wget -q -O "$mermaid_file" "https://unpkg.com/mermaid/dist/mermaid.min.js"; then
            log_success "    * css/mermaid.min.js: Downloaded successfully"
          else
            log_error "    * css/mermaid.min.js: Download failed"
            detected=false
          fi
        else
          log_error "    * css/mermaid.min.js: Download failed (curl or wget not found)"
          detected=false
        fi
      else
        log_error "    * css/mermaid.min.js: WARNING (Not found, offline rendering will be disabled)"
        detected=false
      fi
    fi
  else
    log_error "  - css/ folder: NOT FOUND (Expected at $css_dir)"
    detected=false
  fi

  # 3. Global Node Modules
  log_info "3. Global Node Modules:"
  local global_root
  global_root="$(npm root -g 2>/dev/null || echo "")"
  if [[ -z "$global_root" ]]; then
    log_error "  - Could not resolve global npm root directory"
    detected=false
  else
    log_success "  - Global npm root: $global_root"
    local deps=(
      "markdown-it"
      "markdown-it-emoji"
      "markdown-it-container"
      "markdown-it-plantuml"
      "@vscode/markdown-it-katex"
      "highlight.js"
      "puppeteer-core"
    )
    for dep in "${deps[@]}"; do
      if NODE_PATH="$global_root" node -e "require('$dep')" &>/dev/null; then
        log_success "    * ${dep}: Detected"
      else
        log_error "    * ${dep}: NOT FOUND"
        detected=false
      fi
    done
  fi

  log_info "============================================================================="
  if [ "$detected" = true ]; then
    log_success "All prerequisites are satisfied. Ready for conversion."
  else
    log_error "Some prerequisites are missing. Please fix the errors above."
  fi
  log_info "============================================================================="

  [ "$detected" = true ]
}

# =============================================================================
# Installation Module
# =============================================================================

# install_dependencies - Installs required dependencies globally via npm
install_dependencies() {
  log_info "Installing compiler dependencies globally via npm..."

  if ! command -v npm &> /dev/null; then
    die "npm not found. Please install Node.js first."
  fi

  if npm install -g markdown-it markdown-it-emoji markdown-it-container markdown-it-plantuml @vscode/markdown-it-katex highlight.js puppeteer-core; then
    log_success "Installation complete"
    run_detect "true"
  else
    die "Installation failed"
  fi
}

# =============================================================================
# Conversion Module
# =============================================================================

# convert_single_file - Renders a single markdown file into a PDF document.
# Output naming preserves the input document base name with a .pdf extension.
# If force_overwrite is false and the target PDF already exists, it skips the conversion.
# Capture status code safely before passing it to log_error.
convert_single_file() {
  local config_file="${1:-}"
  local source_file="${2:-}"
  local target_dir="${3:-}"
  local force_overwrite="${4:-false}"

  local basename
  basename="$(basename "$source_file" .md)"
  local target_file="${target_dir}/${basename}.pdf"

  # Skip conversion if target PDF already exists and --force is not specified
  if [[ "$force_overwrite" != "true" ]] && [[ -f "$target_file" ]]; then
    echo "SKIP|[INFO]  Skipped (already exists): $target_file"
    return 0
  fi

  # Explicitly remove the target file first if it exists to ensure a clean write
  rm -f "$target_file"

  local compiler_script
  compiler_script="$(dirname "$SCRIPT_PATH")/md2pdf_compiler/md2pdf_compiler.js"

  local local_node_modules global_root node_path_val
  local_node_modules="$(dirname "$SCRIPT_PATH")/md2pdf_compiler/node_modules"
  global_root="$(npm root -g 2>/dev/null || echo "")"
  node_path_val="$local_node_modules"
  if [[ -n "$global_root" ]]; then
    if [[ "${OSTYPE:-}" == "msys" || "${OSTYPE:-}" == "cygwin" ]]; then
      node_path_val="${node_path_val};${global_root}"
    else
      node_path_val="${node_path_val}:${global_root}"
    fi
  fi

  if NODE_PATH="$node_path_val" node "$compiler_script" --config-file "$config_file" --source "$source_file" --target "$target_file"; then
    echo "OK|[OK]   Converted: $source_file -> $target_file"
    return 0
  else
    # Capture exit status immediately to avoid masking by intervening log commands
    local exit_code=$?
    echo "FAIL|[ERROR] Failed: $source_file (exit code: $exit_code)"
    return 1
  fi
}

# run_conversion - Orchestrates parallel processing of target files.
# Parallelism Design:
#   - nproc / sysctl checks are used to dynamically resolve logical CPU counts.
#   - Capped at 4 concurrent processes to prevent resource exhaustion (OOM/CPU starvation)
#     resulting from multiple concurrent headless Puppeteer/Chromium rendering tasks.
#   - Sourcing pattern (source "$1") in xargs completely avoids non-portable function exports,
#     ensuring full cross-platform compatibility with Windows (MSYS2/Cygwin) and Linux hosts.
#   - Uses atomic file-appends (echo >> results_file) to safely log execution status without
#     race conditions, as small appends under PIPE_BUF are atomic in POSIX.
#   - Clears EXIT trap and removes the temp file explicitly to prevent resource leakage
#     if sourced in an active shell session.
run_conversion() {
  local config_file="${1:-}"
  local source_dir="${2:-}"
  local target_dir="${3:-}"
  local force_overwrite="${4:-false}"

  local max_procs
  max_procs=$(nproc 2> /dev/null || sysctl -n hw.ncpu 2> /dev/null || echo 4)
  # Cap at 4 to prevent CPU/RAM exhaustion from multiple Puppeteer instances
  if ((max_procs > 4)); then
    max_procs=4
  fi

  log_info "Starting conversion with $max_procs parallel processes..."
  log_info "Config: $config_file"
  log_info "Source: $source_dir"
  log_info "Target: $target_dir"
  log_info "Force Overwrite: $force_overwrite"

  # Fast-exit if no markdown files are found, preventing shell/subshell spawn overhead
  if ! find "$source_dir" -maxdepth 1 -type f -name "*.md" | grep -q .; then
    log_info "No markdown files found in $source_dir. Nothing to do."
    return 0
  fi

  # Ensure target directory exists
  mkdir -p "$target_dir"

  # Find all markdown files and process in parallel
  local failed=0
  local total=0
  local success=0

  # Use a temporary file to track results
  local results_file
  results_file=$(mktemp)
  results_file=$(format_path "$results_file")
  # SC2064: Variable expansion at definition time is desired as results_file is local
  # shellcheck disable=SC2064
  trap "rm -f '$results_file'" EXIT

  log_info "Initiating parallel compiler workers. Standard outputs are buffered to prevent terminal flickering;
       results will be printed sequentially upon task completion..."

  # Find and process files in parallel using xargs
  # SC2016: Sourced parameters ($1, $2) must be evaluated inside the subshell, not expanded early
  # shellcheck disable=SC2016
  find "$source_dir" -maxdepth 1 -type f -name "*.md" -print0 |
    xargs -0 -P "$max_procs" -I {} bash -c '
            source "$1"
            res=$(convert_single_file "$2" "$3" "$4" "$5")
            echo "$res" >> "$6"
        ' _ "$SCRIPT_PATH" "$config_file" {} "$target_dir" "$force_overwrite" "$results_file"

  # Print results and compile metrics
  if [[ -f "$results_file" ]]; then
    # Sort results to output cleanly in alphabetical order of filename messages
    sort "$results_file" | while IFS='|' read -r _ msg; do
      if [[ -n "$msg" ]]; then
        printf "%s\n" "$msg" >&2
      fi
    done

    local success_count skipped_count
    success_count=$(grep -c "^OK" "$results_file" 2> /dev/null || true)
    skipped_count=$(grep -c "^SKIP" "$results_file" 2> /dev/null || true)
    success=$((${success_count:-0} + ${skipped_count:-0}))
    failed=$(grep -c "^FAIL" "$results_file" 2> /dev/null || true)
    total=$((success + ${failed:-0}))
  fi

  # Explicit cleanup and trap removal to prevent resource leakage in sourced shells
  rm -f "$results_file"
  trap - EXIT

  log_info "============================================"
  log_info "Conversion complete: $success/$total succeeded, $failed failed"

  [[ $failed -eq 0 ]]
}

# =============================================================================
# Validation Module
# =============================================================================

# validate_args - Asserts that the mandatory config file and source directories exist,
# and verifies that Node.js is available and prerequisites are met.
validate_args() {
  local config_file="${1:-}"
  local source_dir="${2:-}"
  local target_dir="${3:-}"

  [[ -f "$config_file" ]] || die "Config file not found: $config_file"
  [[ -d "$source_dir" ]] || die "Source directory not found: $source_dir"

  # Enforce Node.js, local CSS, and local HTML template folders presence as hard prerequisites
  command -v node &> /dev/null || die "Node.js not found. Please install Node.js first."
  [[ -d "$(dirname "$SCRIPT_PATH")/md2pdf_compiler/css" ]] || die "Local CSS styles directory not found. Please ensure 'css' folder exists inside the md2pdf_compiler directory."
  [[ -d "$(dirname "$SCRIPT_PATH")/md2pdf_compiler/html" ]] || die "Local HTML templates directory not found. Please ensure 'html' folder exists inside the md2pdf_compiler directory."

  # Verify config file contains valid JSON structure (preferring jq, falling back to node)
  if command -v jq &> /dev/null; then
    jq . "$config_file" &> /dev/null || die "Malformed JSON structure in config file: $config_file"
  else
    node -e 'try { JSON.parse(require("fs").readFileSync(process.argv[process.argv.length - 1], "utf8")); } catch(e) { process.exit(1); }' "$config_file" &> /dev/null ||
      die "Malformed JSON structure in config file: $config_file"
  fi

  # Target directory will be created if needed
}

# =============================================================================
# Help / Usage
# =============================================================================

# show_usage - Renders a professionally formatted CLI manual to standard error
show_usage() {
  cat << EOF

Markdown to PDF Converter (md2pdf.sh)
=============================================================================
Usage: $SCRIPT_NAME [OPTIONS]

Primary Options:
  -d, --detect          Detect Node.js and compiler dependencies.
  -i, --install         Install compiler dependencies globally (use with --detect).
  -c, --config <file>   Path to JSON config file (required for conversion).
  -s, --source <dir>    Source directory containing .md files (required).
  -t, --target <dir>    Target directory for generated PDFs (required).
  -f, --force           Force overwrite of existing target PDFs (skipped by default).
  -v, --version         Show script version.
  -h, --help            Show this help message.

Path Normalization (Windows / Linux Compatibility):
  The script automatically normalizes all path inputs to the Windows mixed
  path format (drive:/sub/sub) and replaces backslashes to ensure compatibility
  across POSIX and native shell environments.

Examples:
  # Detect required tools
  $SCRIPT_NAME --detect

  # Detect and install missing npm packages
  $SCRIPT_NAME --detect --install

  # Run batch markdown conversion
  $SCRIPT_NAME --config config.json --source ./docs --target ./pdfs

  # Run batch conversion using shorthand parameters
  $SCRIPT_NAME -c config.json -s ./docs -t ./pdfs

=============================================================================
EOF
}

# show_version - Outputs the script version to stdout
show_version() {
  echo "md2pdf.sh v$SCRIPT_VERSION"
}

# =============================================================================
# Main Module & Lifecycle Execution
# =============================================================================

# main - Core orchestrator entry point. Handles parsing, validation, and control routing.
main() {
  local do_detect=false
  local do_install=false
  local force_overwrite=false
  local config_file=""
  local source_dir=""
  local target_dir=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d | --detect)
        do_detect=true
        shift
        ;;
      -i | --install)
        do_install=true
        shift
        ;;
      -c | --config)
        [[ -n "${2:-}" ]] || die "--config requires a value"
        config_file="$(format_path "$2")"
        shift 2
        ;;
      -s | --source)
        [[ -n "${2:-}" ]] || die "--source requires a value"
        source_dir="$(format_path "$2")"
        shift 2
        ;;
      -t | --target)
        [[ -n "${2:-}" ]] || die "--target requires a value"
        target_dir="$(format_path "$2")"
        shift 2
        ;;
      -f | --force)
        force_overwrite=true
        shift
        ;;
      -v | --version)
        show_version
        exit 0
        ;;
      -h | --help)
        show_usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  # Handle detect mode
  if $do_detect; then
    if run_detect "$do_install"; then
      exit 0
    elif $do_install; then
      install_dependencies
      exit $?
    else
      log_info "Use --install to install missing dependencies"
      exit 1
    fi
  fi

  # Validate required arguments for conversion
  if [[ -z "$config_file" || -z "$source_dir" || -z "$target_dir" ]]; then
    log_error "Missing required arguments for conversion"
    show_usage
    exit 1
  fi

  validate_args "$config_file" "$source_dir" "$target_dir"
  run_conversion "$config_file" "$source_dir" "$target_dir" "$force_overwrite"
}

# Guard to prevent immediate execution of main() if the script is sourced for libraries.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
