#!/bin/bash

# ==============================================================================
# SCRIPT: pdf_text-extractor.sh
# Version: 1.0.0
# Date: 2026-06-24
#
# OBJECTIVE:
#   Extracts layout-preserved plain text from PDF files using Poppler's 
#   'pdftotext' utility. Handles both single-file and batch directory processing
#   with robust error handling, path normalization, and CLI flag validation.
#
# CORE COMPONENTS & FUNCTIONALITY:
#   1. System utility pre-check (verifies presence of find, basename, dirname, mkdir).
#   2. In-memory path normalization helper (cross-platform backslash-to-forward-slash conversion).
#   3. Directory creation safety wrapper (ensure_directory).
#   4. Robust command-line argument parsing (with option-value boundary validation).
#   5. Target directory and path resolution.
#   6. Executable path discovery for Poppler's 'pdftotext' binary.
#   7. Dual-mode extraction (Directory/Batch mode with failure-tracking OR Single-file mode).
#
# DATA FLOW:
#   [CLI Arguments] ---> [Parse & Validate] ---> [Normalize Paths]
#                                                       |
#                                                       v
#   [Find pdftotext executable] <--- [Validate Poppler Directory]
#               |
#               +---------> IF Directory: [Loop matching PDFs] ---> [Extract Text] ---> [Track Success]
#               |
#               +---------> IF File:      [Resolve Output Path] ---> [Extract Text] ---> [Exit Status]
#
# EXIT CODES:
#   0: Success — All extractions completed flawlessly.
#   2: CLI Configuration Error — Invalid flags, missing mandatory variables, or argument violations.
#   3: Dependency Failure — Required system commands (find, mkdir, jq, etc.) or Poppler binaries missing.
#   4: Filesystem Input Violation — Source PDF path does not exist, or permissions are insufficient.
#   5: Partial / Integrity Failure — Completed run but some PDF files failed extraction or were corrupt.
#   6: Target Directory Allocation Error — Failed to create or access the output text directory.
# ==============================================================================

# Enable strict shell behavior:
#   -u: Treat unset variables as errors and exit immediately.
#   -o pipefail: Prevent masking errors in pipelines.
set -uo pipefail

# Verify that essential core utilities are available in the system PATH before proceeding.
for cmd in find basename dirname mkdir; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required system utility '$cmd' is not available in PATH." >&2
        exit 3
    fi
done

# HELPER: normalize_path
# Objective: Converts Windows-style backslashes (\) to Unix-style forward slashes (/).
# In-memory execution avoids spawning slow subprocesses or calling external utilities like 'tr'.
normalize_path() {
    local path="${1:-}"
    echo "${path//\\//}"
}

# HELPER: ensure_directory
# Objective: Safely creates a directory path if it does not already exist,
# and verifies that it is writable/accessible. Exits immediately on failure.
ensure_directory() {
    local dir="${1:-}"
    local desc="${2:-}"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        if [ ! -d "$dir" ]; then
            echo "Error: Failed to create or access $desc '$dir'." >&2
            exit 6
        fi
    fi
}

# HELPER: log_json
# Objective: Constructs a secure, newline-delimited JSON (NDJSON) log object.
# Uses 'jq --arg' to prevent syntax breaks or command injections from special characters.
log_json() {
    local level="${1:-}"
    local event="${2:-}"
    local msg="${3:-}"
    local pdf="${4:-}"
    local target="${5:-}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    
    jq -n \
        --arg ts "$timestamp" \
        --arg lvl "$level" \
        --arg evt "$event" \
        --arg msg "$msg" \
        --arg pdf "$pdf" \
        --arg tgt "$target" \
        '{timestamp: $ts, level: $lvl, event: $evt, message: $msg, pdf_path: $pdf, target_path: $tgt} | del(.[] | select(. == ""))' \
        --compact-output
}

# HELPER: log_message
# Objective: Unified logging router. Outputs in NDJSON format if JSON_MODE is enabled,
# and falls back to clean plain-text standard error/output streams otherwise.
log_message() {
    local level="${1:-}"       # info, warning, error, summary
    local event="${2:-}"       # start, success, failure, skip, summary
    local msg="${3:-}"         # textual message
    local pdf="${4:-}"         # optional input file context
    local target="${5:-}"      # optional output file context
    
    if [ "${JSON_MODE:-false}" = true ]; then
        local jq_lvl="$level"
        [ "$level" = "warning" ] && jq_lvl="warn"
        [ "$level" = "summary" ] && jq_lvl="info"
        
        if [ "$level" = "error" ] || [ "$level" = "warning" ]; then
            log_json "$jq_lvl" "$event" "$msg" "$pdf" "$target" >&2
        else
            log_json "$jq_lvl" "$event" "$msg" "$pdf" "$target"
        fi
    else
        if [ "$level" = "error" ]; then
            echo "Error: $msg" >&2
        elif [ "$level" = "warning" ]; then
            echo "Warning: $msg" >&2
        else
            echo "$msg"
        fi
    fi
}

# HELPER: show_help
# Objective: Displays a professionally formatted usage and help menu for users.
show_help() {
    cat << EOF
Usage: $(basename "$0") --source-pdf <path> --target-text <path> [options]

Extracts layout-preserved plain text from PDF files using Poppler's 'pdftotext'.

Options:
  -h, --help               Show this help message and exit.
  --source-pdf <path>      Path to the source PDF file or directory containing PDF files (Required).
  --target-text <path>     Path to output text file (single mode) or target directory (batch mode) (Required).
  --poppler-path <path>    Path to the Poppler installation directory containing pdftotext.
                           Falls back to the POPPLER_HOME environment variable if omitted.
  --pattern <pattern>      Filename glob pattern to match when in directory/batch mode (Default: *.pdf).
  --safe                   Refuse to overwrite a target text file if it already exists.
  --json                   Format the output log in NDJSON format (requires 'jq').

Examples:
  # Single-file extraction:
  $(basename "$0") --source-pdf /data/doc.pdf --target-text /data/doc.txt --poppler-path /opt/poppler

  # Batch directory extraction:
  $(basename "$0") --source-pdf /data/pdfs --target-text /data/text_outputs --poppler-path /opt/poppler --pattern "*.PDF"
EOF
}

# Initialize variables to hold parsed options
POPPLER_PATH=""
SOURCE_PDF=""
TARGET_TEXT=""
PATTERN=""
SAFE_MODE=false
JSON_MODE=false

# Parse command line options sequentially
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --safe)
            SAFE_MODE=true
            shift 1
            ;;
        --json)
            JSON_MODE=true
            shift 1
            ;;
        --poppler-path)
            # Ensure the flag is accompanied by a value
            if [ $# -lt 2 ]; then
                echo "Error: --poppler-path requires an argument." >&2
                exit 2
            fi
            POPPLER_PATH="$2"
            shift 2
            ;;
        --source-pdf)
            # Ensure the flag is accompanied by a value
            if [ $# -lt 2 ]; then
                echo "Error: --source-pdf requires an argument." >&2
                exit 2
            fi
            SOURCE_PDF="$2"
            shift 2
            ;;
        --target-text)
            # Ensure the flag is accompanied by a value
            if [ $# -lt 2 ]; then
                echo "Error: --target-text requires an argument." >&2
                exit 2
            fi
            TARGET_TEXT="$2"
            shift 2
            ;;
        --pattern)
            # Ensure the flag is accompanied by a value
            if [ $# -lt 2 ]; then
                echo "Error: --pattern requires an argument." >&2
                exit 2
            fi
            PATTERN="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown argument $1" >&2
            exit 2
            ;;
    esac
done

# If JSON mode is enabled, verify that jq is available in the system PATH
if [ "$JSON_MODE" = true ]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: --json option requires 'jq' utility to be available in PATH." >&2
        exit 3
    fi
fi

# Validate that both mandatory target and source paths are supplied
if [ -z "$SOURCE_PDF" ]; then
    echo "Error: Source PDF path must be specified via --source-pdf." >&2
    echo "Use -h or --help for usage details." >&2
    exit 2
fi

if [ -z "$TARGET_TEXT" ]; then
    echo "Error: Target text path must be specified via --target-text." >&2
    echo "Use -h or --help for usage details." >&2
    exit 2
fi

# Resolve Poppler directory and locate standard binary dependencies (pdftotext, pdfinfo)
POPPLER_DIR="${POPPLER_PATH:-${POPPLER_HOME:-}}"
PDFTOTEXT_BIN=""
PDFINFO_BIN=""

if [ -z "$POPPLER_DIR" ]; then
    # No Poppler path specified; check if pdftotext is available globally in PATH
    if command -v pdftotext >/dev/null 2>&1; then
        PDFTOTEXT_BIN="pdftotext"
        # Check if pdfinfo is also available globally
        if command -v pdfinfo >/dev/null 2>&1; then
            PDFINFO_BIN="pdfinfo"
        fi
    else
        echo "Error: Poppler path must be specified via --poppler-path, POPPLER_HOME, or available globally in PATH." >&2
        echo "Use -h or --help for usage details." >&2
        exit 3
    fi
else
    # Normalize paths for cross-platform file system operation
    POPPLER_DIR=$(normalize_path "$POPPLER_DIR")
    [ "$POPPLER_DIR" != "/" ] && POPPLER_DIR="${POPPLER_DIR%/}"
    
    # Validate the existence of the resolved Poppler directory
    if [ ! -d "$POPPLER_DIR" ]; then
        echo "Error: Poppler directory '$POPPLER_DIR' does not exist." >&2
        exit 3
    fi

    # Locate pdftotext and pdfinfo executables across standard Windows and Unix subdirectories
    if [ -f "$POPPLER_DIR/pdftotext.exe" ]; then
        PDFTOTEXT_BIN="$POPPLER_DIR/pdftotext.exe"
    elif [ -f "$POPPLER_DIR/pdftotext" ]; then
        PDFTOTEXT_BIN="$POPPLER_DIR/pdftotext"
    elif [ -f "$POPPLER_DIR/bin/pdftotext.exe" ]; then
        PDFTOTEXT_BIN="$POPPLER_DIR/bin/pdftotext.exe"
    elif [ -f "$POPPLER_DIR/bin/pdftotext" ]; then
        PDFTOTEXT_BIN="$POPPLER_DIR/bin/pdftotext"
    else
        echo "Error: pdftotext executable not found in $POPPLER_DIR or $POPPLER_DIR/bin." >&2
        exit 3
    fi

    if [ -f "$POPPLER_DIR/pdfinfo.exe" ]; then
        PDFINFO_BIN="$POPPLER_DIR/pdfinfo.exe"
    elif [ -f "$POPPLER_DIR/pdfinfo" ]; then
        PDFINFO_BIN="$POPPLER_DIR/pdfinfo"
    elif [ -f "$POPPLER_DIR/bin/pdfinfo.exe" ]; then
        PDFINFO_BIN="$POPPLER_DIR/bin/pdfinfo.exe"
    elif [ -f "$POPPLER_DIR/bin/pdfinfo" ]; then
        PDFINFO_BIN="$POPPLER_DIR/bin/pdfinfo"
    fi
fi

# Always normalize input and target file paths
SOURCE_PDF=$(normalize_path "$SOURCE_PDF")
[ "$SOURCE_PDF" != "/" ] && SOURCE_PDF="${SOURCE_PDF%/}"
TARGET_TEXT=$(normalize_path "$TARGET_TEXT")
[ "$TARGET_TEXT" != "/" ] && TARGET_TEXT="${TARGET_TEXT%/}"

# Set default search pattern to "*.pdf" if not specified by the user
PATTERN="${PATTERN:-*.pdf}"

# ==============================================================================
# MODE 1: Directory/Batch Mode
# Executed if the specified source path is a directory.
# ==============================================================================
if [ -d "$SOURCE_PDF" ]; then
    # Ensure target output directory exists and is writable
    ensure_directory "$TARGET_TEXT" "target directory"
    
    # Determine the maximum number of parallel processes (concurrency limit)
    max_jobs=4
    if command -v nproc >/dev/null 2>&1; then
        max_jobs=$(nproc)
    elif [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then
        max_jobs="$NUMBER_OF_PROCESSORS"
    fi
    
    # Validate that max_jobs is a valid integer, fallback to 4 if not
    if ! [[ "$max_jobs" =~ ^[0-9]+$ ]] || [ "$max_jobs" -lt 1 ]; then
        max_jobs=4
    fi
    
    # Create a secure temporary directory for buffering standard error of parallel jobs
    temp_dir=$(mktemp -d 2>/dev/null || { mkdir -p "${TMPDIR:-/tmp}/pdf_extractor_$$" && echo "${TMPDIR:-/tmp}/pdf_extractor_$$"; })
    
    # Ensure temporary directory is cleaned up upon exit
    trap 'rm -rf "$temp_dir"' EXIT
    
    found_any=false
    exit_status=0
    pids_and_names=()
    success_count=0
    skipped_count=0
    failed_count=0
    
    # Process files matching pattern, using null-delimiter to handle spaces safely
    while IFS= read -r -d '' pdf_file; do
        found_any=true
        if [ ! -r "$pdf_file" ]; then
            log_message "warning" "file_skip_unreadable" "PDF file '$pdf_file' is not readable. Skipping." "$pdf_file"
            skipped_count=$((skipped_count + 1))
            exit_status=5
            continue
        fi
        
        # Derive output filename by swapping extension to .txt
        base_name=$(basename "$pdf_file" .pdf)
        target_file="$TARGET_TEXT/${base_name}.txt"
        
        # Check if the output file already exists in safe mode to prevent overwriting
        if [ "$SAFE_MODE" = true ] && [ -f "$target_file" ]; then
            log_message "warning" "file_skip_existing" "Target file '$target_file' already exists. Skipping (safe mode)." "$pdf_file" "$target_file"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Verify file integrity before starting extraction (if pdfinfo is available)
        if [ -n "$PDFINFO_BIN" ]; then
            if ! "$PDFINFO_BIN" "$pdf_file" >/dev/null 2>&1; then
                log_message "error" "file_corrupt" "PDF file '$pdf_file' is corrupt or invalid. Skipping." "$pdf_file"
                failed_count=$((failed_count + 1))
                exit_status=5
                continue
            fi
        fi
        
        # Limit parallel background processes to max_jobs
        if [ "$(jobs -r -p | wc -l)" -ge "$max_jobs" ]; then
            # Wait for at least one background process to finish before proceeding
            wait -n 2>/dev/null || sleep 0.1
        fi
        
        log_message "info" "extraction_start" "Extracting: '$pdf_file' -> '$target_file'" "$pdf_file" "$target_file"
        
        # Invoke pdftotext tool in the background, buffering standard error to prevent interleaving/garbling
        "$PDFTOTEXT_BIN" -layout "$pdf_file" "$target_file" 2>"$temp_dir/err_$base_name" &
        pids_and_names+=("$!|$base_name|$pdf_file|$target_file")
        
    done < <(find "$SOURCE_PDF" -maxdepth 1 -type f -iname "$PATTERN" -print0 2>/dev/null)
    
    # Wait for all background processes to complete, outputting their buffered stderr synchronously
    for item in ${pids_and_names[@]+"${pids_and_names[@]}"}; do
        pid="${item%%|*}"
        rest="${item#*|}"
        base_name="${rest%%|*}"
        rest="${rest#*|}"
        pdf_file="${rest%%|*}"
        target_file="${rest##*|}"
        
        # Wait for the specific background process and check its exit status
        wait "$pid"
        job_status=$?
        
        # Output any buffered error synchronously to prevent garbling
        if [ -s "$temp_dir/err_$base_name" ]; then
            if [ "$JSON_MODE" = true ]; then
                err_msg=$(cat "$temp_dir/err_$base_name" | tr -d '\r\n')
                log_message "error" "extraction_failure" "pdftotext execution failed: $err_msg" "$pdf_file" "$target_file"
            else
                cat "$temp_dir/err_$base_name" >&2
            fi
        fi
        
        if [ $job_status -ne 0 ]; then
            log_message "error" "extraction_failure" "Failed to extract text from '$pdf_file'." "$pdf_file" "$target_file"
            failed_count=$((failed_count + 1))
            exit_status=5
        else
            success_count=$((success_count + 1))
        fi
    done
    
    # Validate that at least one file was processed matching the criteria
    if [ "$found_any" = false ]; then
        echo "No PDF files found matching pattern '$PATTERN' in directory '$SOURCE_PDF'." >&2
        exit 4
    fi
    
    # Output a concise, professionally styled summary of the batch operation
    log_message "summary" "batch_summary" "Batch Extraction Completed: $((success_count + failed_count + skipped_count)) file(s) found [$success_count succeeded, $skipped_count skipped, $failed_count failed]."
    exit $exit_status

# ==============================================================================
# MODE 2: Single-File Mode
# Executed if the specified source path points directly to an existing file.
# ==============================================================================
elif [ -f "$SOURCE_PDF" ]; then
    # Verify that the input file is readable
    if [ ! -r "$SOURCE_PDF" ]; then
        log_message "error" "file_unreadable" "Source PDF '$SOURCE_PDF' is not readable." "$SOURCE_PDF"
        exit 4
    fi
    
    # Resolve the destination target file path
    if [ -d "$TARGET_TEXT" ] || [[ "$TARGET_TEXT" == */ ]] || [[ "$TARGET_TEXT" != *.txt ]]; then
        # If target is a directory or lacks a .txt suffix, treat as a target directory and derive filename
        ensure_directory "$TARGET_TEXT" "target directory"
        base_name=$(basename "$SOURCE_PDF" .pdf)
        target_file="$TARGET_TEXT/${base_name}.txt"
    else
        # Target is a custom filename; ensure parent directory exists
        target_dir="$(dirname "$TARGET_TEXT")"
        ensure_directory "$target_dir" "parent directory"
        target_file="$TARGET_TEXT"
    fi
    
    # Check if the output file already exists in safe mode to prevent overwriting
    if [ "$SAFE_MODE" = true ] && [ -f "$target_file" ]; then
        log_message "error" "file_skip_existing" "Target file '$target_file' already exists. Aborting (safe mode)." "$SOURCE_PDF" "$target_file"
        exit 4
    fi
    
    # Verify file integrity before starting extraction (if pdfinfo is available)
    if [ -n "$PDFINFO_BIN" ]; then
        if ! "$PDFINFO_BIN" "$SOURCE_PDF" >/dev/null 2>&1; then
            log_message "error" "file_corrupt" "Source PDF '$SOURCE_PDF' is corrupt or invalid." "$SOURCE_PDF"
            exit 5
        fi
    fi
    
    log_message "info" "extraction_start" "Extracting: '$SOURCE_PDF' -> '$target_file'" "$SOURCE_PDF" "$target_file"
    
    # Invoke pdftotext tool preserving original physical layout
    if ! "$PDFTOTEXT_BIN" -layout "$SOURCE_PDF" "$target_file"; then
        log_message "error" "extraction_failure" "Failed to extract text from '$SOURCE_PDF'." "$SOURCE_PDF" "$target_file"
        exit 5
    fi
else
    # Error: Source path does not exist on disk
    log_message "error" "source_not_found" "Source path '$SOURCE_PDF' does not exist." "$SOURCE_PDF"
    exit 4
fi
