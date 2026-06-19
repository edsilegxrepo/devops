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

# Enable strict execution modes:
# -e: Exit immediately if any command exits with a non-zero status.
# -u: Treat unset variables and parameters as errors when performing parameter expansion.
# -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -euo pipefail

# =============================================================================
# Configuration & Path Resolution
# =============================================================================

# format_path - Normalize a file path for cross-platform compatibility between Windows and POSIX.
# This function is crucial for running Unix shell tools (like bash, find, xargs) under emulation layers
# (such as MSYS2, Git Bash, or Cygwin) alongside native Windows binaries (like node.exe).
#
# Arguments:
#   $1 - The input path to normalize.
#
# Outputs:
#   Writes the normalized path to stdout.
format_path() {
  # Assign the first argument to a local variable, defaulting to an empty string if unset.
  local input_path="${1:-}"
  
  # Replace all backslashes '\' with forward slashes '/' to prevent path escaping issues.
  local normalized="${input_path//\\//}"
  
  # If the 'cygpath' utility is available, use it to convert POSIX style mounts
  # (e.g. /e/data) into Windows mixed-style drive paths (e.g. E:/data) which node.exe understands.
  if command -v cygpath &> /dev/null; then
    normalized=$(cygpath -m "$normalized")
  fi
  
  # Remove trailing slash if present (unless it is a root directory like '/' or 'C:/')
  if [[ "$normalized" =~ .*/$ ]] && [[ ! "$normalized" =~ ^[A-Za-z]:/$ ]] && [[ "$normalized" != "/" ]]; then
    normalized="${normalized%/}"
  fi
  
  # Output the normalized path to standard output.
  echo "$normalized"
}

# SCRIPT_NAME - Store the base filename of the executing script (e.g. md2pdf.sh) for logging/help.
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# SCRIPT_VERSION - Define the current version of the wrapper script.
readonly SCRIPT_VERSION="1.2.0xg"

# SCRIPT_PATH - Resolve the absolute, normalized path of the executing script.
# This resolution uses readlink -f, realpath, or BASH_SOURCE[0] as progressive fallbacks
# to handle environments with varying tool availability. Sourcing this path allows parallel
# workers in subshells to dynamically access functions defined in this script.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2> /dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_PATH="$(format_path "$SCRIPT_PATH")"
readonly SCRIPT_PATH

# =============================================================================
# Utility & Logging Functions
# =============================================================================

# get_timestamp - Generates a standardized timestamp string.
# Returns ISO 8601 format for JSON mode and YYYY-MM-DD HH:mm:ss format for text mode.
#
# Arguments:
#   $1 - Format type ('json' or 'text')
get_timestamp() {
  local fmt="${1:-text}"
  # Check if bash supports built-in printf time formatting (introduced in Bash 4.2)
  # -1 represents the current epoch time.
  if [[ "$fmt" == "json" ]]; then
    # Try using printf built-in first to avoid process fork overhead.
    # ISO 8601 format: YYYY-MM-DDTHH:mm:ss+-HHMM
    printf "%(%Y-%m-%dT%H:%M:%S%z)T" -1 2>/dev/null || date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"
  else
    # Plain text format: YYYY-MM-DD HH:mm:ss
    printf "%(%Y-%m-%d %H:%M:%S)T" -1 2>/dev/null || date +"%Y-%m-%d %H:%M:%S"
  fi
}

# write_log - Underlying routing logger for writing metadata events to stderr.
#
# Arguments:
#   $1 - Log level key ('info', 'error', 'success')
#   $2 - Text format status prefix ('INFO', 'ERROR', 'OK')
#   $3..$N - The log message words
write_log() {
  local level="$1"
  local prefix="$2"
  shift 2
  local msg="$*"

  if [[ "${output_format:-text}" == "json" ]]; then
    local ts
    ts=$(get_timestamp "json")
    printf '{"timestamp":"%s","level":"%s","msg":"%s"}\n' "$ts" "$level" "$msg" >&2
  else
    local ts
    ts=$(get_timestamp "text")
    printf "[%s] [%s] %s\n" "$ts" "$prefix" "$msg" >&2
  fi
}

# log_info - Print informational progress messages to standard error.
# Standard error is used so that data channels (stdout) remain clean and unpolluted.
#
# Arguments:
#   $* - The message string to log.
log_info() {
  write_log "info" "INFO" "$@"
}

# log_error - Print error/failure status messages to standard error.
# Standard error is used so that data channels (stdout) remain clean and unpolluted.
#
# Arguments:
#   $* - The error message string to log.
log_error() {
  write_log "error" "ERROR" "$@"
}

# log_success - Print success status messages to standard error.
# Standard error is used so that data channels (stdout) remain clean and unpolluted.
#
# Arguments:
#   $* - The success message string to log.
log_success() {
  write_log "success" "OK" "$@"
}

# die - Print an error message and terminate the script with a non-zero exit status.
#
# Arguments:
#   $* - The error message explaining the failure.
die() {
  # Invoke the log_error function to write the message.
  log_error "$*"
  # Exit the script execution with exit status 1.
  exit 1
}

# check_asset - Checks if a file or directory exists and prints a formatted log.
#
# Arguments:
#   $1 - Asset type ('file' or 'dir')
#   $2 - Path to check
#   $3 - Short label/name to display in the log
#   $4 - Prefix formatting (default: "  -")
#
# Returns:
#   0 if the asset exists, 1 otherwise.
check_asset() {
  local type="$1"
  local path="$2"
  local label="$3"
  local prefix="${4:-  -}"

  if [[ "$type" == "dir" && -d "$path" ]] || [[ "$type" == "file" && -f "$path" ]]; then
    log_success "${prefix} ${label}: Found"
    return 0
  fi
  log_error "${prefix} ${label}: NOT FOUND (Expected at $path)"
  return 1
}

# =============================================================================
# Detection Module
# =============================================================================

# run_detect - Entry coordinator for the environment diagnostics verification pass.
# Performs detailed validation of system binaries, workspace configurations,
# local stylesheet directories, and required global Node.js dependency modules.
#
# Arguments:
#   $1 - Boolean flag indicating if missing assets should be downloaded/installed (default: false).
#
# Returns:
#   0 if all mandatory diagnostics pass, 1 otherwise.
run_detect() {
  # Bind arguments to locally-scoped variables
  local do_install="${1:-false}"
  # Initialize status tracker to true; set to false if any prerequisite check fails.
  local detected=true
  # Locate the parent directory of the wrapper script.
  local base_dir
  base_dir="$(dirname "$SCRIPT_PATH")"

  # Print diagnostic headers
  log_info "============================================================================="
  log_info " md2pdf Diagnostics - Prerequisites Verification"
  log_info "============================================================================="

  # 1. System Binaries Check
  log_info "1. System Binaries:"
  
  # Check if 'node' command is available on PATH.
  if command -v node &> /dev/null; then
    local node_ver
    # Extract the version string from node.
    node_ver=$(node --version)
    log_success "  - Node.js: Found ($node_ver)"
  else
    log_error "  - Node.js: NOT FOUND (Required)"
    detected=false
  fi

  # Check if 'npm' command is available on PATH.
  if command -v npm &> /dev/null; then
    local npm_ver
    # Extract the version string from npm.
    npm_ver=$(npm --version)
    log_success "  - npm: Found (v$npm_ver)"
  else
    log_error "  - npm: NOT FOUND (Required)"
    detected=false
  fi

  # Check if 'jq' command is available on PATH.
  if command -v jq &> /dev/null; then
    local jq_ver
    # Extract version from jq, capturing and discarding stderr, fallback to 'Found'.
    jq_ver=$(jq --version 2>/dev/null || echo "Found")
    log_success "  - jq: Found ($jq_ver)"
  else
    # jq is optional; standard Node.js is used as a fallback path parsing utility.
    log_info "  - jq: Not found (Optional; using fallback Node.js parser for JSON validation)"
  fi

  # 2. Workspace Assets & Configs Check
  log_info "2. Workspace Assets & Configs:"
  
  # Resolve path to the configuration file.
  local config_file="${base_dir}/md2pdf_config.json"
  
  # Verify if the config file exists on the filesystem.
  if [[ -f "$config_file" ]]; then
    log_success "  - md2pdf_config.json: Found"
    
    # Pre-flight check: Extract and verify the configured browser executable path
    local browser_exe=""
    if command -v jq &> /dev/null; then
      # Extract value of launch_options.executablePath using jq.
      browser_exe=$(jq -r '.launch_options.executablePath // empty' "$config_file" 2>/dev/null)
    else
      # Extract value of launch_options.executablePath using Node inline script fallback.
      browser_exe=$(node -e "try { console.log(JSON.parse(require('fs').readFileSync('$config_file', 'utf8')).launch_options.executablePath || ''); } catch(e) {}")
    fi

    # Check if a browser path was successfully retrieved.
    if [[ -n "$browser_exe" ]]; then
      local normalized_exe
      # Normalize the browser path to mixed-Windows layout.
      normalized_exe=$(format_path "$browser_exe")
      # Assert the browser executable file exists on disk.
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

  # Verify if the compiler folder directory is present.
  local compiler_dir="${base_dir}/md2pdf_compiler"
  check_asset "dir" "$compiler_dir" "md2pdf_compiler/ folder" || detected=false

  # Verify if the main JS compiler entry file exists.
  local compiler_js="${compiler_dir}/md2pdf_compiler.js"
  check_asset "file" "$compiler_js" "md2pdf_compiler.js" || detected=false

  # Verify package.json is present.
  local pkg_json="${compiler_dir}/package.json"
  check_asset "file" "$pkg_json" "package.json" || detected=false

  # Verify package-lock.json is present.
  local pkg_lock="${compiler_dir}/package-lock.json"
  check_asset "file" "$pkg_lock" "package-lock.json" || detected=false

  # Verify html/ template directory is present.
  local html_dir="${compiler_dir}/html"
  if check_asset "dir" "$html_dir" "html/ folder"; then
    # Iterate and check for all required layout HTML templates.
    local template_files=("header.html" "footer.html")
    for template in "${template_files[@]}"; do
      check_asset "file" "${html_dir}/${template}" "html/${template}" "    *" || detected=false
    done
  else
    detected=false
  fi

  # Verify css/ styles directory is present.
  local css_dir="${compiler_dir}/css"
  if check_asset "dir" "$css_dir" "css/ folder"; then
    # Check individual stylesheets
    local style_files=("markdown.css" "markdown-pdf.css" "tomorrow.css")
    for style in "${style_files[@]}"; do
      check_asset "file" "${css_dir}/${style}" "css/${style}" "    *" || detected=false
    done

    # Check local css/mermaid.min.js with custom download logic on failure.
    local mermaid_file="${css_dir}/mermaid.min.js"
    if [[ -f "$mermaid_file" ]]; then
      log_success "    * css/mermaid.min.js: Found (Local asset resolved)"
    else
      # If the asset is missing and do_install is true, attempt downloading it.
      if [[ "$do_install" == "true" ]]; then
        log_info "    * css/mermaid.min.js: Not found. Initiating download..."
        if command -v curl &>/dev/null; then
          # Download using curl
          if curl -sS -L "https://unpkg.com/mermaid/dist/mermaid.min.js" -o "$mermaid_file"; then
            log_success "    * css/mermaid.min.js: Downloaded successfully"
          else
            log_error "    * css/mermaid.min.js: Download failed"
            detected=false
          fi
        elif command -v wget &>/dev/null; then
          # Download using wget fallback
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
        # Log a warning; the compiler will fallback to online unpkg.com if missing.
        log_error "    * css/mermaid.min.js: WARNING (Not found, offline rendering will be disabled)"
        detected=false
      fi
    fi
  else
    detected=false
  fi

  # 3. Global Node Modules Check
  log_info "3. Global Node Modules:"
  local global_root
  # Retrieve the global npm root directory.
  global_root="$(npm root -g 2>/dev/null || echo "")"
  if [[ -z "$global_root" ]]; then
    log_error "  - Could not resolve global npm root directory"
    detected=false
  else
    log_success "  - Global npm root: $global_root"
    # List of required compiler packages.
    local deps=(
      "markdown-it"
      "markdown-it-emoji"
      "markdown-it-container"
      "markdown-it-plantuml"
      "@vscode/markdown-it-katex"
      "highlight.js"
      "puppeteer-core"
    )
    # Iterate and test loading each dependency within Node.js.
    for dep in "${deps[@]}"; do
      if NODE_PATH="$global_root" node -e "require('$dep')" &>/dev/null; then
        log_success "    * ${dep}: Detected"
      else
        log_error "    * ${dep}: NOT FOUND"
        detected=false
      fi
    done
  fi

  # Print diagnostics result footer
  log_info "============================================================================="
  if [ "$detected" = true ]; then
    log_success "All prerequisites are satisfied. Ready for conversion."
  else
    log_error "Some prerequisites are missing. Please fix the errors above."
  fi
  log_info "============================================================================="

  # Return execution status indicating if validation passed.
  [ "$detected" = true ]
}

# =============================================================================
# Installation Module
# =============================================================================

# install_dependencies - Installs required dependencies globally via npm
install_dependencies() {
  log_info "Installing compiler dependencies globally via npm..."

  # Verify npm is present in PATH before execution.
  if ! command -v npm &> /dev/null; then
    die "npm not found. Please install Node.js first."
  fi

  # Run npm install globally (-g) for all required compiler modules.
  if npm install -g markdown-it markdown-it-emoji markdown-it-container markdown-it-plantuml @vscode/markdown-it-katex highlight.js puppeteer-core; then
    log_success "Installation complete"
    # Rerun diagnostics tool checks after installation succeeds.
    run_detect "true"
  else
    die "Installation failed"
  fi
}

# =============================================================================
# Conversion Module
# =============================================================================

# truncate_string - Slice a long string to prevent line wraps in plain text tables.
# Enforces the DRY principle across table columns formatting.
#
# Arguments:
#   $1 - The input string to inspect.
#   $2 - The maximum length constraint (default: 60 characters).
#
# Outputs:
#   Writes the truncated string to stdout.
truncate_string() {
  # Retrieve arguments with defaults.
  local str="${1:-}"
  local max_len="${2:-60}"
  
  # Check if string length exceeds the threshold.
  if ((${#str} > max_len)); then
    # Slice the string and append '...' to indicate truncation.
    echo "${str:0:$((max_len - 3))}..."
  else
    # Output the string unmodified.
    echo "$str"
  fi
}

# convert_single_file - Compiles a single markdown document into a PDF.
# Output naming preserves the input document base name with a .pdf extension.
# If force_overwrite is false and the target PDF already exists, it skips the conversion.
# Capture status code safely before passing it to log_error.
#
# Arguments:
#   $1 - Absolute path to the JSON config file.
#   $2 - Absolute path to the source Markdown file (.md).
#   $3 - Absolute path to the destination directory for the generated PDF.
#   $4 - Boolean flag to force overwriting existing PDFs ('true' or 'false').
#   $5 - Output format identifier ('json' or 'text').
#
# Outputs:
#   Writes status information record string in format: "src_file.md|STATUS|tgt_file.pdf|extra_info" to stdout.
convert_single_file() {
  # Bind arguments to locally-scoped variables for subshell isolation.
  local config_file="${1:-}"
  local source_file="${2:-}"
  local target_dir="${3:-}"
  local force_overwrite="${4:-false}"
  local output_format="${5:-json}"

  # Extract the base name of the source markdown file (stripping the path and .md extension).
  local basename
  basename="$(basename "$source_file" .md)"
  
  # Compute the target destination PDF filepath.
  # Use parameter expansion trailing slash strip to prevent double-slash creation.
  local target_file="${target_dir%/}/${basename}.pdf"

  # Skip compilation if the target PDF exists and force overwrite is not set to true.
  if [[ "$force_overwrite" != "true" ]] && [[ -f "$target_file" ]]; then
    # Print skip status record to stdout.
    echo "${basename}.md|SKIP|${basename}.pdf|"
    return 0
  fi

  # Remove existing target PDF to avoid permission issues and guarantee a clean write.
  rm -f "$target_file"

  # Compute absolute path to the node compiler javascript file.
  local compiler_script
  compiler_script="$(dirname "$SCRIPT_PATH")/md2pdf_compiler/md2pdf_compiler.js"

  # Resolve node modules search paths.
  local local_node_modules global_root node_path_val
  local_node_modules="$(dirname "$SCRIPT_PATH")/md2pdf_compiler/node_modules"
  global_root="$(npm root -g 2>/dev/null || echo "")"
  node_path_val="$local_node_modules"
  
  # Append global npm root if successfully resolved.
  if [[ -n "$global_root" ]]; then
    # Use Windows path separator ';' or Unix path separator ':' based on OSTYPE.
    if [[ "${OSTYPE:-}" == "msys" || "${OSTYPE:-}" == "cygwin" ]]; then
      node_path_val="${node_path_val};${global_root}"
    else
      node_path_val="${node_path_val}:${global_root}"
    fi
  fi

  # Launch the JS compiler process.
  # Note: Standard output of the compiler is redirected to stderr (>&2) to ensure
  # progress and info logs do not contaminate the stdout stream of this bash script,
  # which is reserved exclusively for the structured data results list.
  if NODE_PATH="$node_path_val" node "$compiler_script" --config-file "$config_file" --source "$source_file" --target "$target_file" --format "$output_format" >&2; then
    # Output success status record to stdout.
    echo "${basename}.md|OK|${basename}.pdf|"
    return 0
  else
    # Capture the compiler exit code immediately before executing other commands.
    local exit_code=$?
    # Output failure status record with exit code to stdout.
    echo "${basename}.md|FAIL|${basename}.pdf|(exit: $exit_code)"
    return 1
  fi
}

# render_text_table - Format and output a clean 3-column CLI ASCII table.
#
# Arguments:
#   $1 - Path to the temporary results records file.
#
# Outputs:
#   Writes the formatted table to stdout.
render_text_table() {
  # Store path to the temporary results file.
  local results_file="$1"

  # Print table column headers. Status is left-aligned within a 30-character column,
  # Input MD and Output PDF are left-aligned in 60-character columns.
  printf "%s\n" "------------------------------+------------------------------------------------------------+------------------------------------------------------------"
  printf "%-30s| %-60s| %-60s\n" "            Status" "                          Input MD" "                         Output PDF"
  # Print the horizontal divider line.
  printf "%s\n" "------------------------------+------------------------------------------------------------+------------------------------------------------------------"

  # Sort the results file to group records: FAIL first, then OK, then SKIP.
  # Read records line by line, splitting fields by '|'.
  sort "$results_file" | while IFS='|' read -r src_file status tgt_file extra_info; do
    # Verify that we parsed at least the source file and status fields.
    if [[ -n "$src_file" && -n "$status" ]]; then
      # Translate status code keys into user-friendly strings.
      local status_text=""
      case "$status" in
        OK)   status_text="[OK] Converted" ;;
        SKIP) status_text="[SKIP] Skipped" ;;
        FAIL) status_text="[FAIL] Failed" ;;
        *)    status_text="[$status]" ;;
      esac

      # Append any extra information (such as process exit codes) to the target file field.
      local tgt_disp="$tgt_file"
      if [[ -n "$extra_info" ]]; then
        tgt_disp="$tgt_disp $extra_info"
      fi

      # Truncate values to fit columns perfectly using the truncate_string helper.
      local src_disp
      src_disp=$(truncate_string "$src_file" 60)
      tgt_disp=$(truncate_string "$tgt_disp" 60)

      # Output the aligned row.
      printf "%-30s| %-60s| %-60s\n" "$status_text" "$src_disp" "$tgt_disp"
    fi
  done

  # Print bottom border line to complete the table layout on stdout
  printf "%s\n" "------------------------------+------------------------------------------------------------+------------------------------------------------------------"
}

# render_json - Formats the compilation results into a structured JSON array.
#
# Arguments:
#   $1 - Path to the temporary results records file.
#
# Outputs:
#   Writes the compiled JSON string to stdout.
render_json() {
  # Store path to the results file.
  local results_file="$1"
  local sorted_file
  
  # Allocate a temporary file to hold the sorted results.
  sorted_file=$(mktemp)
  # Normalize the temp file path for cross-platform safety.
  sorted_file=$(format_path "$sorted_file")
  
  # Sort results to ensure consistent order (FAIL < OK < SKIP) and write to the sorted file.
  sort "$results_file" > "$sorted_file"

  # Use jq if installed, falling back to a custom Node.js parser script if missing.
  if command -v jq &>/dev/null; then
    # Run jq parser:
    # -R: Read raw strings.
    # -s: Read entire input into a single string.
    # We split by newlines, filter out empty lines, split fields by '|', and build JSON objects.
    jq -R -s '
      split("\n") | map(select(length > 0)) | map(
        split("|") | select(length >= 3) | {
          status: (if .[1] == "OK" then "Converted" elif .[1] == "SKIP" then "Skipped" else "Failed" end),
          input_md: .[0],
          output_pdf: .[2]
        } + (if .[3] != "" then {extra_info: .[3]} else {} end)
      )
    ' "$sorted_file"
  else
    # Fallback Node inline parser:
    # Reads the file synchronously, splits lines, maps records, filters out null values,
    # and outputs prettified JSON.
    node -e '
      const fs = require("fs");
      const lines = fs.readFileSync(process.argv[1], "utf8").trim().split(/\r?\n/).filter(Boolean);
      const json = lines.map(line => {
        const parts = line.split("|");
        if (parts.length < 3) return null;
        const [md, status, pdf, extra] = parts;
        const obj = {
          status: status === "OK" ? "Converted" : status === "SKIP" ? "Skipped" : "Failed",
          input_md: md,
          output_pdf: pdf
        };
        if (extra) {
          obj.extra_info = extra;
        }
        return obj;
      }).filter(Boolean);
      console.log(JSON.stringify(json, null, 2));
    ' "$sorted_file"
  fi
  
  # Remove the temporary sorted file.
  rm -f "$sorted_file"
}

# run_conversion - Handles parallel dispatching of markdown conversions.
# Captures performance duration metrics and handles redirect logs formatting.
#
# Arguments:
#   $1 - Path to the JSON config file.
#   $2 - Path to the source Markdown folder directory.
#   $3 - Path to the target PDF output directory.
#   $4 - Boolean flag to force overwriting existing PDFs ('true' or 'false').
#   $5 - Output format identifier ('json' or 'text').
#   $6 - Path to the log output file (optional).
#
# Returns:
#   0 if all files compiled successfully (or skipped), 1 if any compilation failed.
run_conversion() {
  # Bind input parameters to local variables
  local config_file="${1:-}"
  local source_dir="${2:-}"
  local target_dir="${3:-}"
  local force_overwrite="${4:-false}"
  local output_format="${5:-json}"
  local log_file_path="${6:-}"

  # Capture current SECONDS for performance elapsed time tracking.
  local start_time=$SECONDS

  # Determine optimal parallel concurrency limits.
  local max_procs
  # Detect available CPU threads.
  max_procs=$(nproc 2> /dev/null || sysctl -n hw.ncpu 2> /dev/null || echo 4)
  # Cap concurrency at 4 to prevent RAM/CPU starvation from multiple Chromium threads.
  if ((max_procs > 4)); then
    max_procs=4
  fi

  # Print general processing configuration details.
  log_info "Starting conversion with $max_procs parallel processes..."
  log_info "Config: $config_file"
  log_info "Source: $source_dir"
  log_info "Target: $target_dir"
  log_info "Force Overwrite: $force_overwrite"
  log_info "Format: $output_format"
  if [[ -n "$log_file_path" ]]; then
    log_info "Log File: $log_file_path"
  fi

  # Exit early if the source directory contains no Markdown files.
  if ! find "$source_dir" -maxdepth 1 -type f -name "*.md" | grep -q .; then
    log_info "No markdown files found in $source_dir. Nothing to do."
    return 0
  fi

  # Create the output target directory if it does not already exist.
  mkdir -p "$target_dir"

  # Initialize compilation counts tracking.
  local failed=0
  local total=0
  local success=0

  # Create a secure temporary file to write raw worker results records.
  local results_file
  results_file=$(mktemp)
  results_file=$(format_path "$results_file")
  
  # Register a cleanup trap to remove the results file upon script exit.
  # SC2064: Expand results_file now so the cleanup path is hardcoded.
  # shellcheck disable=SC2064
  trap "rm -f '$results_file'" EXIT

  log_info "Initiating parallel compiler workers. Standard outputs are buffered to prevent terminal flickering"
  log_info "Results will be printed sequentially upon task completion..."

  # Find markdown files, filter them with null bytes, and stream to xargs.
  # -P $max_procs: Run workers in parallel.
  # -I {}: Replace placeholder with filename.
  # We spawn bash to source this script file to load convert_single_file.
  # SC2016: Sourced variables are not expanded in parent, but evaluated in subshells.
  # shellcheck disable=SC2016
  find "$source_dir" -maxdepth 1 -type f -name "*.md" -print0 |
    xargs -0 -P "$max_procs" -I {} bash -c '
            source "$1"
            res=$(convert_single_file "$2" "$3" "$4" "$5" "$6")
            echo "$res" >> "$7"
        ' _ "$SCRIPT_PATH" "$config_file" {} "$target_dir" "$force_overwrite" "$output_format" "$results_file"

  # Process and output the compiled results.
  if [[ -f "$results_file" ]]; then
    # Create a temporary file to store the formatted report.
    local final_report
    final_report=$(mktemp)
    final_report=$(format_path "$final_report")

    # Render report in either JSON or plain text format.
    if [[ "$output_format" == "json" ]]; then
      render_json "$results_file" > "$final_report"
    else
      render_text_table "$results_file" > "$final_report"
    fi

    # Output the report to stdout (captured globally by log redirection if enabled).
    cat "$final_report"
    
    # Delete the temporary report file.
    rm -f "$final_report"

    # Compile final execution statistics.
    local success_count skipped_count
    success_count=$(grep -c "|OK|" "$results_file" 2> /dev/null || true)
    skipped_count=$(grep -c "|SKIP|" "$results_file" 2> /dev/null || true)
    success=$((${success_count:-0} + ${skipped_count:-0}))
    failed=$(grep -c "|FAIL|" "$results_file" 2> /dev/null || true)
    total=$((success + ${failed:-0}))
  fi

  # Clean up results file and remove the trap before returning.
  rm -f "$results_file"
  trap - EXIT

  # Compute execution duration in seconds.
  local elapsed=$((SECONDS - start_time))
  
  # Format final completion logs output.
  if [[ "$output_format" == "json" ]]; then
    local ts
    ts=$(get_timestamp "json")
    # Log structured JSON metrics on stderr.
    printf '{"timestamp":"%s","level":"info","msg":"Conversion complete: %d/%d succeeded, %d failed in %ds","success":%d,"failed":%d,"total":%d,"duration_seconds":%d}\n' \
      "$ts" "$success" "$total" "$failed" "$elapsed" "$success" "$failed" "$total" "$elapsed" >&2
  else
    # Log plain text on stderr.
    log_info "Conversion complete: $success/$total succeeded, $failed failed in ${elapsed}s"
  fi

  # Return success (0) if there were 0 failures, 1 otherwise.
  [[ $failed -eq 0 ]]
}

# =============================================================================
# Validation Module
# =============================================================================

# validate_args - Assert presence of configuration, directories, and dependencies.
#
# Arguments:
#   $1 - Path to the JSON config file.
#   $2 - Path to the source Markdown folder directory.
#   $3 - Path to the target PDF output directory.
validate_args() {
  local config_file="${1:-}"
  local source_dir="${2:-}"
  local target_dir="${3:-}"

  # Assert that source and target directories are not root directories (e.g. '/' or 'D:/')
  if [[ "$source_dir" == "/" ]] || [[ "$source_dir" =~ ^[A-Za-z]:/$ ]]; then
    die "Root directories are not allowed as source: $source_dir"
  fi
  if [[ "$target_dir" == "/" ]] || [[ "$target_dir" =~ ^[A-Za-z]:/$ ]]; then
    die "Root directories are not allowed as target: $target_dir"
  fi

  # Assert the configuration file exists.
  [[ -f "$config_file" ]] || die "Config file not found: $config_file"
  
  # Assert the source directory exists.
  [[ -d "$source_dir" ]] || die "Source directory not found: $source_dir"

  # Assert Node.js, CSS styles folder, and layout templates folder exist.
  command -v node &> /dev/null || die "Node.js not found. Please install Node.js first."
  [[ -d "$(dirname "$SCRIPT_PATH")/md2pdf_compiler/css" ]] || die "Local CSS styles directory not found. Please ensure 'css' folder exists inside the md2pdf_compiler directory."
  [[ -d "$(dirname "$SCRIPT_PATH")/md2pdf_compiler/html" ]] || die "Local HTML templates directory not found. Please ensure 'html' folder exists inside the md2pdf_compiler directory."

  # Validate that the config JSON file has correct syntax.
  if command -v jq &> /dev/null; then
    # Check syntax using jq.
    jq . "$config_file" &> /dev/null || die "Malformed JSON structure in config file: $config_file"
  else
    # Check syntax using Node fallback.
    node -e 'try { JSON.parse(require("fs").readFileSync(process.argv[process.argv.length - 1], "utf8")); } catch(e) { process.exit(1); }' "$config_file" &> /dev/null ||
      die "Malformed JSON structure in config file: $config_file"
  fi
}

# =============================================================================
# Help / Usage
# =============================================================================

# show_usage - Print command line help documentation to standard error.
show_usage() {
  # Write multi-line manual text using heredoc.
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
  --format <json|text>  Specify the output results format (default: json).
  --log <file>          Path to log output file (receives structured conversion summary).
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

# show_version - Output the script version code to standard output.
show_version() {
  echo "md2pdf.sh v$SCRIPT_VERSION"
}

# =============================================================================
# Main Module & Lifecycle Execution
# =============================================================================

# main - Core entry point orchestrating program lifecycle.
# Parses inputs, runs environment validation checks, and dispatches workers.
#
# Arguments:
#   $@ - All arguments received from command line.
main() {
  # Initialize local configuration variables.
  local do_detect=false
  local do_install=false
  local force_overwrite=false
  local config_file=""
  local source_dir=""
  local target_dir=""
  local output_format="json"
  local log_file_path=""

  # Loop through CLI options using a shift parser.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d | --detect)
        # Set detect mode to true.
        do_detect=true
        shift
        ;;
      -i | --install)
        # Set install mode to true.
        do_install=true
        shift
        ;;
      -c | --config)
        # Validate that the config argument has a value.
        [[ -n "${2:-}" ]] || die "--config requires a value"
        # Normalize the config file path.
        config_file="$(format_path "$2")"
        shift 2
        ;;
      -s | --source)
        # Validate that the source directory argument has a value.
        [[ -n "${2:-}" ]] || die "--source requires a value"
        # Normalize the source directory path.
        source_dir="$(format_path "$2")"
        shift 2
        ;;
      -t | --target)
        # Validate that the target directory argument has a value.
        [[ -n "${2:-}" ]] || die "--target requires a value"
        # Normalize the target directory path.
        target_dir="$(format_path "$2")"
        shift 2
        ;;
      -f | --force)
        # Force overwriting existing PDFs.
        force_overwrite=true
        shift
        ;;
      --format)
        # Validate that the format argument has a value.
        [[ -n "${2:-}" ]] || die "--format requires a value (json or text)"
        # Restrict values to 'json' or 'text'.
        [[ "$2" == "json" || "$2" == "text" ]] || die "Invalid format: $2 (must be json or text)"
        output_format="$2"
        shift 2
        ;;
      --log)
        # Validate that the log path argument has a value.
        [[ -n "${2:-}" ]] || die "--log requires a file path value"
        # Normalize the log output file path.
        log_file_path="$(format_path "$2")"
        shift 2
        ;;
      -v | --version)
        # Print script version and exit.
        show_version
        exit 0
        ;;
      -h | --help)
        # Print help documentation and exit.
        show_usage
        exit 0
        ;;
      *)
        # Terminate script for unknown options.
        die "Unknown option: $1"
        ;;
    esac
  done

  # Process logic when detect flag is active.
  if $do_detect; then
    if run_detect "$do_install"; then
      exit 0
    elif $do_install; then
      # Attempt installation if dependencies are missing and install is permitted.
      install_dependencies
      exit $?
    else
      log_info "Use --install to install missing dependencies"
      exit 1
    fi
  fi

  # Validate presence of necessary parameters for file conversion.
  if [[ -z "$config_file" || -z "$source_dir" || -z "$target_dir" ]]; then
    log_error "Missing required arguments for conversion"
    show_usage
    exit 1
  fi

  # Initialize descriptor redirection if a log file path is specified.
  # This guarantees that the entire execution log (both stdout and stderr combined) is saved.
  local log_redirected=false
  if [[ -n "$log_file_path" ]]; then
    # Ensure parent directories of the log path exist.
    mkdir -p "$(dirname "$log_file_path")"
    # Copy original file descriptors 1 and 2 to 3 and 4 for restoration on termination.
    exec 3>&1
    exec 4>&2
    # Redirect stdout and stderr to tee to mirror outputs to the log file.
    exec > >(tee -a "$log_file_path")
    exec 2> >(tee -a "$log_file_path" >&2)
    log_redirected=true
  fi

  # Call validator to assert filesystem integrity.
  validate_args "$config_file" "$source_dir" "$target_dir"
  
  # Dispatch parallel compilation workers.
  run_conversion "$config_file" "$source_dir" "$target_dir" "$force_overwrite" "$output_format" "$log_file_path"

  # Restore original stdout and stderr descriptors to flush background writers cleanly.
  if $log_redirected; then
    exec 1>&3 3>&-
    exec 2>&4 4>&-
    wait
  fi
}

# Sourcing guard: Prevents automatic script execution if this script file is sourced as a library
# (such as inside the parallel xargs subshells to import convert_single_file).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Execute main program loop, forwarding all shell command arguments.
  main "$@"
fi
