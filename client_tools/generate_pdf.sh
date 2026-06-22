#!/bin/bash
# shellcheck disable=SC2034 # Variables are referenced dynamically via associative array mapping (false positives)
#
# generate_pdf.sh - Batch Office Document to PDF Converter
#
# VERSION: 1.9.0
#
# OBJECTIVE:
#   Recursively find Office documents (Word, Excel, PowerPoint) and
#   convert them to PDF using LibreOffice in headless mode. Designed for bulk
#   conversion of compliance/audit documents.
#
# FEATURES:
#   - Parallel processing using all available CPU cores (configurable)
#   - Incremental conversion: skips files where PDF already exists and is newer
#   - Dry-run mode to preview what would be converted
#   - Preserves original file timestamps on generated PDFs
#   - Summary statistics on completion with elapsed time
#   - Progress indicator showing current/total count
#   - Lock file to prevent concurrent runs
#   - Timeout protection for hung conversions
#
# USAGE:
#   ./generate_pdf.sh [OPTIONS]
#
# OPTIONS:
#   --source <dir>      Directory to search (mandatory)
#   --dry-run           Preview files without converting
#   --jobs <n>          Number of parallel jobs (default: number of CPUs)
#   --log <file>        Redirect all output (including errors) to log file
#   --force             Force reconversion, ignore incremental check
#   --quiet             Suppress LibreOffice output, show only summary
#   --verbose           Show detailed debug info (timestamps being compared)
#   --extensions <list> Override default extensions (comma-separated, e.g. "*.doc,*.xls")
#   --pattern <pattern> File pattern using wildcards/regex (alternative to --extensions)
#   --document          Include word processing documents (Writer formats)
#   --spreadsheet       Include spreadsheets (Calc formats)
#   --presentation      Include presentations (Impress formats)
#   --graphics          Include vector graphics and images (Draw formats)
#   --target <dir>      Output directory for PDFs (default: same as source)
#   --purge             Delete source file after successful conversion
#   --timeout <secs>    Timeout per file conversion in seconds (default: 300)
#   --max-files <n>     Maximum number of files to process (default: unlimited)
#   --format <fmt>      Output format: text or json (default: json, requires jq)
#   --version           Show version information
#   --help              Show this help message
#
# EXAMPLES:
#   ./generate_pdf.sh --source .                   # Convert in current directory
#   ./generate_pdf.sh --source /docs               # Convert in /docs
#   ./generate_pdf.sh --dry-run                    # Preview without converting
#   ./generate_pdf.sh --jobs 4                     # Limit to 4 parallel jobs
#   ./generate_pdf.sh --log convert.log            # Redirect all output to log file
#   ./generate_pdf.sh --force                      # Reconvert all files
#   ./generate_pdf.sh --quiet                      # Minimal output
#   ./generate_pdf.sh --extensions "*.doc,*.docx"  # Only Word documents
#   ./generate_pdf.sh --pattern "report_.*\.docx"  # Files matching regex pattern
#   ./generate_pdf.sh --document --spreadsheet     # Word and Excel files only
#   ./generate_pdf.sh --graphics                   # Images and vector graphics only
#   ./generate_pdf.sh --target /output/pdfs        # Output PDFs to specific directory
#   ./generate_pdf.sh --purge                      # Delete source after conversion
#   ./generate_pdf.sh --timeout 600                # 10 minute timeout per file
#   ./generate_pdf.sh --max-files 100              # Process at most 100 files
#   ./generate_pdf.sh --format text                # Use plain text output
#
# EXIT CODES:
#   0 - Success (all files converted or skipped)
#   1 - Error (one or more conversions failed)
#   2 - Invalid arguments
#
# DEPENDENCIES:
#   - Linux, Cygwin, or MSYS2 environment
#   - LibreOffice (soffice) installed at OFFICE_BASE path
#   - Bash 4.0+ (for associative arrays)
#   - GNU coreutils (find, xargs, mktemp, timeout, head, stat)
#   - jq (required when --format json is used, which is the default)
#
# PATH FORMAT:
#   - All paths must use forward slashes (/)
#   - Windows paths: d:/path/to/dir (NOT d:\path\to\dir)
#   - Unix paths: /path/to/dir
#   - Backslashes (\) are rejected with an error
#
# DATA FLOW:
#   1. Validate environment (soffice exists, source directory exists)
#   2. Acquire lock file to prevent concurrent runs
#   3. Parse CLI arguments (source, dry-run, jobs, etc.)
#   4. Build find expression from EXTENSIONS array
#   5. Count total files to process
#   6. Find matching files and pipe to parallel xargs workers
#   7. Each worker: check if up-to-date → skip or convert via LibreOffice
#   8. Track results in temp directory (one file per status type)
#   9. Aggregate and display summary with elapsed time
#   10. Release lock file
#
################################################################################

# Note: We intentionally do NOT use 'set -e' because:
# 1. xargs workers exit non-zero on conversion failure (expected)
# 2. We handle errors explicitly and report them in summary
set -o pipefail  # Catch errors in pipelines

# Require Bash 4.0+ for associative arrays and other features
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: This script requires Bash 4.0 or later" >&2
    echo "Current version: $BASH_VERSION" >&2
    exit 2
fi

VERSION="1.9.0"

################################################################################
# CONFIGURATION
################################################################################

# Default file extensions to search for (case-insensitive glob patterns)
# Explicit extensions to avoid matching unintended files like .docker
DEFAULT_EXTENSIONS=("*.doc" "*.docx" "*.xls" "*.xlsx" "*.ppt" "*.pptx")

# Document category extensions (Writer module)
# Word processing: MS Word, OpenDocument, RTF, HTML, WordPerfect, etc.
DOCUMENT_EXTENSIONS=(
    "*.doc" "*.docx" "*.docm" "*.dotx" "*.dotm"  # Microsoft Word
    "*.odt" "*.ott" "*.fodt" "*.sxw"              # OpenDocument
    "*.html" "*.htm" "*.xhtml"                    # Web/Markup
    "*.rtf" "*.txt"                               # Standard text
    "*.wpd" "*.wps" "*.pages" "*.abw" "*.lwp"    # Third-party
)

# Spreadsheet category extensions (Calc module)
SPREADSHEET_EXTENSIONS=(
    "*.xlsx" "*.xls" "*.xlsm" "*.xlsb" "*.xltx" "*.xltm"  # Microsoft Excel
    "*.ods" "*.ots" "*.fods" "*.sxc"                       # OpenDocument
    "*.csv" "*.tsv"                                        # Structured data
    "*.numbers" "*.dif" "*.wk1" "*.123"                   # Alternative
)

# Presentation category extensions (Impress module)
PRESENTATION_EXTENSIONS=(
    "*.pptx" "*.ppt" "*.pptm" "*.potx" "*.potm" "*.ppsx" "*.pps"  # Microsoft PowerPoint
    "*.odp" "*.otp" "*.fodp" "*.sxi"                               # OpenDocument
    "*.key"                                                        # Apple Keynote
)

# Graphics category extensions (Draw module)
GRAPHICS_EXTENSIONS=(
    "*.odg" "*.fodg"                                    # OpenDocument Graphics
    "*.svg" "*.svgz" "*.wmf" "*.emf" "*.eps" "*.ai" "*.sxd"   # Vector formats
    "*.png" "*.jpg" "*.jpeg" "*.gif" "*.bmp" "*.tiff" "*.psd"  # Raster images
    "*.dxf"                                            # CAD
)

# Mandatory system binaries needed by the script
REQUIRED_BINARIES=("find" "xargs" "mktemp" "timeout" "stat" "touch" "wc" "tr" "cut" "date" "grep" "dirname" "basename" "rm" "tee")

################################################################################
# ARGUMENT PARSING
################################################################################

# Get number of CPU cores (Linux/Cygwin/MSYS2)
get_nproc() {
    if command -v nproc &>/dev/null; then
        nproc
    elif [[ -f /proc/cpuinfo ]]; then
        grep -c ^processor /proc/cpuinfo
    else
        echo 4  # Safe default
    fi
}

# Default values
SOURCE_DIR=""        # Directory to search for Office documents (mandatory)
DRY_RUN=false        # When true, only preview what would be converted
RUN_DETECT=false     # When true, run diagnostics and exit
JOBS=$(get_nproc)    # Number of parallel conversion jobs
LOG_FILE=""          # Optional log file path (empty = stdout/stderr)
FORCE=false          # When true, skip incremental check
QUIET=false          # When true, suppress LibreOffice output
VERBOSE=false        # When true, show detailed debug info
EXTENSIONS=()        # Custom extensions (empty = use defaults)
PATTERN=""           # Custom pattern for file matching (regex or glob)
TARGET_DIR=""        # Target directory for PDFs (empty = same as source)
INC_DOCUMENT=false   # Include document (Writer) extensions
INC_SPREADSHEET=false # Include spreadsheet (Calc) extensions
INC_PRESENTATION=false # Include presentation (Impress) extensions
INC_GRAPHICS=false   # Include graphics (Draw) extensions
PURGE=false          # When true, delete source file after successful conversion
TIMEOUT=300          # Timeout per file conversion in seconds
MAX_FILES=0          # Maximum files to process (0 = unlimited)
FORMAT="json"        # Output format: text or json

# Display usage information and exit
usage() {
    echo "Usage: $0 [OPTIONS]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --source <dir>       Directory to search (mandatory)" >&2
    echo "  --dry-run            Preview files without converting" >&2
    echo "  --jobs <n>           Number of parallel jobs (default: $(get_nproc))" >&2
    echo "  --log <file>         Redirect all output (including errors) to log file" >&2
    echo "  --force              Force reconversion, ignore incremental check" >&2
    echo "  --quiet              Suppress LibreOffice output, show only summary" >&2
    echo "  --verbose            Show detailed debug info (timestamps compared)" >&2
    echo "  --extensions <list>  Override extensions (comma-separated, e.g. \"*.doc,*.xls\")" >&2
    echo "  --pattern <pattern>  File pattern using wildcards/regex (alternative to --extensions)" >&2
    echo "  --document           Include word processing documents (Writer formats)" >&2
    echo "  --spreadsheet        Include spreadsheets (Calc formats)" >&2
    echo "  --presentation       Include presentations (Impress formats)" >&2
    echo "  --graphics           Include vector graphics and images (Draw formats)" >&2
    echo "  --target <dir>       Output directory for PDFs (default: same as source)" >&2
    echo "  --purge              Delete source file after successful conversion" >&2
    echo "  --timeout <secs>     Timeout per file conversion (default: 300)" >&2
    echo "  --max-files <n>      Maximum files to process (default: unlimited)" >&2
    echo "  --format <fmt>       Output format: text or json (default: json, requires jq)" >&2
    echo "  --detect             Run diagnostic check of system prerequisites" >&2
    echo "  --version            Show version information" >&2
    echo "  --help               Show this help message" >&2
    exit 2
}

# Display version
show_version() {
    echo "generate_pdf.sh version $VERSION"
    exit 0
}

# Run diagnostics checks on prerequisites
run_detect() {
    local exit_status=0
    echo "[INFO] ====================================================================="
    echo "[INFO]  generate_pdf Diagnostics - Prerequisites Verification"
    echo "[INFO] ====================================================================="
    
    echo "[INFO] 1. Operating System & Shell:"
    # Check Bash version
    if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
        echo "[OK]   - Bash version: Found ($BASH_VERSION)"
    else
        echo "[ERROR] - Bash version: Requires 4.0+, found ($BASH_VERSION)"
        exit_status=1
    fi
    
    # Check OS
    if [[ -n "${OS_TYPE:-}" ]]; then
        echo "[OK]   - Operating System: Supported ($(uname -s))"
    else
        echo "[ERROR] - Operating System: Unsupported ($(uname -s))"
        exit_status=1
    fi
    
    echo "[INFO] 2. System Utilities:"
    for bin in "${REQUIRED_BINARIES[@]}"; do
        if command -v "$bin" &>/dev/null; then
            echo "[OK]   - $bin: Found"
        else
            echo "[ERROR] - $bin: NOT FOUND"
            exit_status=1
        fi
    done
    
    # Check pkill (optional, used for clean interruption)
    if command -v pkill &>/dev/null; then
        echo "[OK]   - pkill (orphan cleanup): Found"
    else
        echo "[INFO]  - pkill (orphan cleanup): Not found, falling back to standard kill"
    fi
    
    # Check hashing algorithms
    local found_hash=false
    for hash_bin in "xxhsum" "sha256sum" "cksum"; do
        if command -v "$hash_bin" &>/dev/null; then
            echo "[OK]   - $hash_bin: Found"
            found_hash=true
        else
            echo "[INFO]  - $hash_bin: Not found (optional fallback)"
        fi
    done
    if [[ "$found_hash" == "false" ]]; then
        echo "[ERROR] - No path hashing utility found (need xxhsum, sha256sum, or cksum)"
        exit_status=1
    fi

    # Check flock
    if command -v flock &>/dev/null; then
        echo "[OK]   - flock (atomic counter): Found"
    else
        echo "[INFO]  - flock (atomic counter): Not found (will use fallback progress counting)"
    fi
    
    echo "[INFO] 3. Format Parser:"
    if command -v jq &>/dev/null; then
        echo "[OK]   - jq (JSON parsing): Found"
    else
        echo "[INFO]  - jq (JSON parsing): Not found (optional, required if using default --format json)"
    fi
    
    echo "[INFO] 4. LibreOffice Installation:"
    local soffice_bin="${OFFICE_BASE}/soffice"
    if [[ -f "$soffice_bin" || -f "${soffice_bin}.exe" ]]; then
        echo "[OK]   - LibreOffice (soffice): Found at $soffice_bin"
    else
        echo "[ERROR] - LibreOffice (soffice): NOT FOUND at $soffice_bin"
        echo "[INFO]    Set the OFFICE_BASE environment variable to specify the correct program folder path."
        exit_status=1
    fi
    
    echo "[INFO] ====================================================================="
    if [[ $exit_status -eq 0 ]]; then
        echo "[OK] All prerequisites are satisfied. Ready for conversion."
    else
        echo "[ERROR] Some prerequisites are missing. Please resolve the errors above."
    fi
    echo "[INFO] ====================================================================="
    
    exit $exit_status
}

# Helper to check that an option has a value
require_arg() {
    if [[ -z "$2" || "$2" == --* ]]; then
        echo "Error: $1 requires an argument" >&2
        exit 2
    fi
}

# Parse arguments
if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            require_arg "$1" "${2:-}"
            SOURCE_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --detect)
            RUN_DETECT=true
            shift
            ;;
        --jobs)
            require_arg "$1" "${2:-}"
            JOBS="$2"
            shift 2
            ;;
        --log)
            require_arg "$1" "${2:-}"
            LOG_FILE="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --extensions)
            require_arg "$1" "${2:-}"
            IFS=',' read -ra EXTENSIONS <<< "$2"
            shift 2
            ;;
        --pattern)
            require_arg "$1" "${2:-}"
            PATTERN="$2"
            shift 2
            ;;
        --target)
            require_arg "$1" "${2:-}"
            TARGET_DIR="$2"
            shift 2
            ;;
        --document)
            INC_DOCUMENT=true
            shift
            ;;
        --spreadsheet)
            INC_SPREADSHEET=true
            shift
            ;;
        --presentation)
            INC_PRESENTATION=true
            shift
            ;;
        --graphics)
            INC_GRAPHICS=true
            shift
            ;;
        --purge)
            PURGE=true
            shift
            ;;
        --timeout)
            require_arg "$1" "${2:-}"
            TIMEOUT="$2"
            shift 2
            ;;
        --max-files)
            require_arg "$1" "${2:-}"
            MAX_FILES="$2"
            shift 2
            ;;
        --format)
            require_arg "$1" "${2:-}"
            FORMAT="$2"
            shift 2
            ;;
        --version)
            show_version
            ;;
        --help)
            usage
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Verify mandatory source directory is specified (unless running diagnostics)
if [[ -z "$SOURCE_DIR" ]]; then
    if [[ "$RUN_DETECT" != "true" ]]; then
        echo "Error: --source is required" >&2
        usage
    fi
fi

# Build extensions from category flags if any are specified
# Uses associative array to map flag variables to extension arrays
# Indirect expansion (${!flag}, ${!arr_name}) resolves variable names dynamically
CATEGORY_SELECTED=false
declare -A CATEGORY_MAP=(
    ["INC_DOCUMENT"]="DOCUMENT_EXTENSIONS"
    ["INC_SPREADSHEET"]="SPREADSHEET_EXTENSIONS"
    ["INC_PRESENTATION"]="PRESENTATION_EXTENSIONS"
    ["INC_GRAPHICS"]="GRAPHICS_EXTENSIONS"
)
for flag in "${!CATEGORY_MAP[@]}"; do
    if [[ "${!flag}" == "true" ]]; then
        arr_name="${CATEGORY_MAP[$flag]}[@]"
        EXTENSIONS+=("${!arr_name}")
        CATEGORY_SELECTED=true
    fi
done

# Use default extensions if no category flags and no explicit extensions/pattern
if [[ "$CATEGORY_SELECTED" == "false" && ${#EXTENSIONS[@]} -eq 0 && -z "$PATTERN" ]]; then
    EXTENSIONS=("${DEFAULT_EXTENSIONS[@]}")
fi

# Detect operating system
case "$(uname -s)" in
    Linux*)       OS_TYPE="linux" ;;
    CYGWIN*)      OS_TYPE="cygwin" ;;
    MINGW*|MSYS*) OS_TYPE="msys" ;;
    *)            OS_TYPE="" ;;
esac

# Fail early if OS is not supported (only on standard runs)
if [[ -z "$OS_TYPE" && "$RUN_DETECT" != "true" ]]; then
    echo "Error: This script requires Linux, Cygwin, or MSYS2" >&2
    echo "Detected OS: $(uname -s)" >&2
    exit 2
fi

# Dynamically set default OFFICE_BASE if not set by the user
if [[ -z "${OFFICE_BASE:-}" ]]; then
    if [[ "$OS_TYPE" == "linux" ]]; then
        if command -v soffice &>/dev/null; then
            OFFICE_BASE=$(dirname "$(command -v soffice)")
        else
            OFFICE_BASE="/usr/lib/libreoffice/program"
        fi
    elif [[ "$OS_TYPE" == "cygwin" || "$OS_TYPE" == "msys" ]]; then
        if [[ -f "c:/Program Files/LibreOffice/program/soffice.exe" ]]; then
            OFFICE_BASE="c:/Program Files/LibreOffice/program"
        elif [[ -f "c:/Program Files (x86)/LibreOffice/program/soffice.exe" ]]; then
            OFFICE_BASE="c:/Program Files (x86)/LibreOffice/program"
        else
            OFFICE_BASE="d:/apps/office/libreoffice/program"
        fi
    fi
fi

# Verify OFFICE_BASE is not blank (unless running in diagnostics mode)
if [[ -z "${OFFICE_BASE:-}" ]]; then
    if [[ "$RUN_DETECT" != "true" ]]; then
        echo "Error: OFFICE_BASE is not specified and could not be dynamically resolved." >&2
        exit 2
    fi
fi
export OFFICE_BASE

# Redirect all output to log file if specified
if [[ -n "$LOG_FILE" ]]; then
    # Validate log file directory exists
    LOG_DIR=$(dirname "$LOG_FILE")
    if [[ "$LOG_DIR" != "." && ! -d "$LOG_DIR" ]]; then
        echo "Error: Log file directory does not exist: $LOG_DIR" >&2
        exit 2
    fi
    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
fi

# Run diagnostics if --detect flag is set
if [[ "$RUN_DETECT" == "true" ]]; then
    run_detect
fi

################################################################################
# PATH UTILITIES
################################################################################

# Validate path format: reject backslashes, validate Windows drive format
# Usage: validate_path "path" "option_name"
validate_path() {
    local path="$1"
    local opt_name="$2"

    # Reject paths containing backslashes
    if [[ "$path" == *\\* ]]; then
        echo "Error: $opt_name contains backslashes. Use forward slashes instead." >&2
        echo "  Got: $path" >&2
        echo "  Use: ${path//\\//}" >&2
        exit 2
    fi

    # Reject root paths (/ in Linux, or drive roots like c:/ or c: in Windows)
    if [[ "$path" == "/" || "$path" =~ ^[a-zA-Z]:/?$ ]]; then
        echo "Error: $opt_name cannot be the root directory." >&2
        echo "  Got: $path" >&2
        exit 2
    fi

    # On Windows-style paths (d:/...), validate format
    if [[ "$path" =~ ^[a-zA-Z]: ]]; then
        # Must be drive letter followed by colon and forward slash
        if [[ ! "$path" =~ ^[a-zA-Z]:/  && "$path" != [a-zA-Z]: ]]; then
            echo "Error: $opt_name has invalid Windows path format." >&2
            echo "  Got: $path" >&2
            echo "  Expected format: d:/path/to/dir" >&2
            exit 2
        fi
    fi
}

# Remove trailing slash from path to avoid // in concatenation
# Usage: path=$(normalize_path "$path")
normalize_path() {
    local path="$1"
    # Remove trailing slash unless it's the root (/ or d:/)
    if [[ "$path" =~ ^[a-zA-Z]:/$ ]]; then
        # Windows root like "d:/" - keep as is
        echo "$path"
    elif [[ "$path" == "/" ]]; then
        # Unix root - keep as is
        echo "$path"
    else
        # Remove trailing slash
        echo "${path%/}"
    fi
}

################################################################################
# VALIDATION
################################################################################

# Validate and normalize path helper (validates then normalizes in place)
validate_and_normalize_path() {
    local var_name="$1" opt_name="$2"
    local value="${!var_name}"
    [[ -z "$value" ]] && return 0
    validate_path "$value" "$opt_name"
    printf -v "$var_name" '%s' "$(normalize_path "$value")"
}

# Validate and normalize all path inputs (rejects backslashes, removes trailing slashes)
validate_and_normalize_path SOURCE_DIR "--source"
validate_and_normalize_path TARGET_DIR "--target"
validate_and_normalize_path LOG_FILE "--log"

# Validation helper for positive integers
require_positive_int() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: $name must be a positive integer, got: $value" >&2
        exit 2
    fi
}

# Validation helper for enumerated values
require_enum() {
    local name="$1" value="$2"
    shift 2
    local valid=("$@")
    for v in "${valid[@]}"; do
        [[ "$value" == "$v" ]] && return 0
    done
    echo "Error: $name must be one of: ${valid[*]}, got: $value" >&2
    exit 2
}

# Validate numeric and enum arguments
require_positive_int "--jobs" "$JOBS"
require_positive_int "--timeout" "$TIMEOUT"
[[ "$MAX_FILES" != "0" ]] && require_positive_int "--max-files" "$MAX_FILES"
require_enum "--format" "$FORMAT" "text" "json"

# Verify presence of mandatory system binaries
MISSING_BINARIES=()
for bin in "${REQUIRED_BINARIES[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
        MISSING_BINARIES+=("$bin")
    fi
done

# Ensure at least one lock hashing algorithm is available
if ! command -v xxhsum &>/dev/null && ! command -v sha256sum &>/dev/null && ! command -v cksum &>/dev/null; then
    MISSING_BINARIES+=("xxhsum/sha256sum/cksum")
fi

if [[ ${#MISSING_BINARIES[@]} -gt 0 ]]; then
    echo "Error: Missing required system dependencies: ${MISSING_BINARIES[*]}" >&2
    echo "Please install these utilities using your package manager." >&2
    exit 2
fi

# Check jq dependency for json format
if [[ "$FORMAT" == "json" ]]; then
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required for --format json but was not found" >&2
        echo "Install jq or use --format text" >&2
        exit 2
    fi
fi

# Validate --target directory: create if needed, check write permission
if [[ -n "$TARGET_DIR" ]]; then
    if [[ ! -d "$TARGET_DIR" ]]; then
        if ! mkdir -p "$TARGET_DIR" 2>/dev/null; then
            echo "Error: Cannot create target directory: $TARGET_DIR" >&2
            exit 2
        fi
    fi
    if [[ ! -w "$TARGET_DIR" ]]; then
        echo "Error: Target directory is not writable: $TARGET_DIR" >&2
        exit 2
    fi
fi

# Validate mutually exclusive file selection options
# Category flags (--document, --spreadsheet, etc.) cannot be combined with --extensions or --pattern
if [[ "$CATEGORY_SELECTED" == "true" ]]; then
    if [[ -n "$PATTERN" ]]; then
        echo "Error: Category flags (--document, --spreadsheet, etc.) cannot be combined with --pattern" >&2
        exit 2
    fi
fi

# --pattern and explicit --extensions are mutually exclusive
if [[ -n "$PATTERN" && ${#EXTENSIONS[@]} -gt 0 ]]; then
    echo "Error: --pattern and --extensions/category flags are mutually exclusive" >&2
    exit 2
fi

# Validate and normalize OFFICE_BASE path
validate_path "$OFFICE_BASE" "OFFICE_BASE"
OFFICE_BASE=$(normalize_path "$OFFICE_BASE")
export OFFICE_BASE

# Check if LibreOffice soffice binary exists
SOFFICE_PATH="${OFFICE_BASE}/soffice"
if [[ ! -f "$SOFFICE_PATH" && ! -f "${SOFFICE_PATH}.exe" ]]; then
    echo "Error: LibreOffice not found at $SOFFICE_PATH" >&2
    echo "Please set OFFICE_BASE to the correct path in the script." >&2
    exit 1
fi

# Check if source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: Source directory does not exist: $SOURCE_DIR" >&2
    exit 1
fi

################################################################################
# LOCK FILE
################################################################################

# Lock file prevents concurrent runs on the same directory
# Uses the absolute path of search directory to create unique lock
LOCK_DIR=$(cd "$SOURCE_DIR" && pwd)
# Generate hash for lock file (xxhsum 128-bit, fallback to sha256sum, fallback to cksum)
if command -v xxhsum &>/dev/null; then
    LOCK_HASH=$(echo "$LOCK_DIR" | xxhsum -H128 | cut -d' ' -f1)
elif command -v sha256sum &>/dev/null; then
    LOCK_HASH=$(echo "$LOCK_DIR" | sha256sum | cut -d' ' -f1)
else
    # Fallback: use cksum
    LOCK_HASH=$(echo "$LOCK_DIR" | cksum | cut -d' ' -f1)
fi
LOCK_FILE="${TEMP:-/tmp}/generate_pdf_${LOCK_HASH}.lock"

# Track if we acquired the lock (for cleanup)
LOCK_ACQUIRED=false

# Acquire lock (or exit if already locked)
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$LOCK_PID" 2>/dev/null; then
            echo "Error: Another instance is already running (PID: $LOCK_PID)" >&2
            echo "Lock file: $LOCK_FILE" >&2
            exit 1
        else
            # Stale lock file, remove it
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED=true
}

# Release lock on exit (only if we acquired it)
release_lock() {
    [[ "$LOCK_ACQUIRED" == "true" ]] && rm -f "$LOCK_FILE"
}

acquire_lock

################################################################################
# BUILD FIND EXPRESSION
################################################################################

# Build find expression from EXTENSIONS array or PATTERN
# Constructs: -iname "*.doc*" -o -iname "*.xls*" -o -iname "*.ppt*"
# Or with --pattern: -regex ".*pattern.*"
FIND_EXPR=()
if [[ -n "$PATTERN" ]]; then
    # Use regex pattern for more complex matching
    FIND_EXPR+=("-regextype" "posix-extended" "-regex" "$PATTERN")
else
    for ext in "${EXTENSIONS[@]}"; do
        [[ ${#FIND_EXPR[@]} -gt 0 ]] && FIND_EXPR+=("-o")
        FIND_EXPR+=("-iname" "$ext")
    done
fi

################################################################################
# HELPER FUNCTIONS
################################################################################

# Safely remove a temporary directory (guards against accidental rm -rf disasters)
safe_rmdir() {
    local dir="$1"
    local temp_base="${TEMP:-/tmp}"
    # Only remove if it's a temp directory created by mktemp
    # Pattern: /tmp/tmp.XXXXXX or $TEMP/tmp.XXXXXX
    if [[ -n "$dir" && "$dir" != "/" && -d "$dir" ]]; then
        case "$dir" in
            "$temp_base"/tmp.*|/tmp/tmp.*)
                rm -rf "$dir"
                ;;
        esac
    fi
}

# Count lines in a file (returns 0 if file doesn't exist or is empty)
# Uses tr -d to strip whitespace from wc output for clean arithmetic
count_lines() {
    local file="$1"
    if [[ -f "$file" ]]; then
        wc -l < "$file" | tr -d '[:space:]'
    else
        echo 0
    fi
}

# Kill any remaining soffice processes we spawned (using pkill or fallback to kill via ps tree traversal)
kill_spawned_soffice() {
    if command -v pkill &>/dev/null; then
        pkill -P $$ soffice 2>/dev/null || true
    else
        local soffice_pids
        # shellcheck disable=SC2009 # pgrep is from the same package as pkill (procps), which is missing here
        soffice_pids=$(ps -ef 2>/dev/null | grep -i "soffice" | grep -v "grep" | awk '{print $2}')
        for pid in $soffice_pids; do
            # Check parent, grandparent, and great-grandparent PIDs
            local ppid
            ppid=$(ps -ef 2>/dev/null | awk -v p="$pid" '$2 == p {print $3}')
            if [[ "$ppid" == "$$" ]]; then
                kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
            else
                local gpid
                gpid=$(ps -ef 2>/dev/null | awk -v p="$ppid" '$2 == p {print $3}')
                if [[ "$gpid" == "$$" ]]; then
                    kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
                else
                    local ggpid
                    ggpid=$(ps -ef 2>/dev/null | awk -v p="$gpid" '$2 == p {print $3}')
                    if [[ "$ggpid" == "$$" ]]; then
                        kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
                    fi
                fi
            fi
        done
    fi
}

################################################################################
# STATISTICS TRACKING
################################################################################

# Record start time for elapsed calculation
START_TIME=$(date +%s)

# Create temporary directory for tracking conversion results
# Each parallel worker appends "1" to a status file (success/failed/skipped)
# Line count of each file gives the total for that status
STATS_DIR=$(mktemp -d)

# Track if we were interrupted
INTERRUPTED=false

# Cleanup on exit - release lock and remove stats dir
cleanup() {
    local exit_code=$?
    kill_spawned_soffice
    # If interrupted, report partial results before cleanup
    if [[ "$INTERRUPTED" == "true" && -d "$STATS_DIR" ]]; then
        echo "" >&2
        echo "Interrupted! Partial results:" >&2
        echo "  Converted: $(count_lines "$STATS_DIR/success")" >&2
        echo "  Failed: $(count_lines "$STATS_DIR/failed")" >&2
    fi
    release_lock
    safe_rmdir "$STATS_DIR"
    exit $exit_code
}

# Handle interruption signals gracefully
handle_interrupt() {
    INTERRUPTED=true
    echo "" >&2
    echo "Received interrupt signal, cleaning up..." >&2
    exit 130
}

# Register signal handlers
trap cleanup EXIT              # Always run cleanup on exit
trap handle_interrupt INT TERM # Handle Ctrl+C and termination signals

# Export variables needed by subshell workers (xargs spawns separate bash processes)
export DRY_RUN STATS_DIR FORCE QUIET VERBOSE TIMEOUT TARGET_DIR PURGE FORMAT

################################################################################
# COUNT TOTAL FILES
################################################################################

# Helper: get pattern description for output
get_pattern_desc() {
    [[ -n "$PATTERN" ]] && echo "$PATTERN" || echo "${EXTENSIONS[*]}"
}

# Find all matching files once, store in temp file (avoids running find twice)
FILE_LIST="$STATS_DIR/file_list"
find "$SOURCE_DIR" \( "${FIND_EXPR[@]}" \) -type f -print0 2>/dev/null > "$FILE_LIST"

# Count total files (count null bytes if file is non-empty)
if [[ -s "$FILE_LIST" ]]; then
    TOTAL_FILES=$(tr -cd '\0' < "$FILE_LIST" | wc -c | tr -d '[:space:]')
else
    TOTAL_FILES=0
fi

# Apply --max-files limit if specified
if [[ "$MAX_FILES" -gt 0 && "$TOTAL_FILES" -gt "$MAX_FILES" ]]; then
    if [[ "$FORMAT" == "text" ]]; then
        echo "Note: Limiting to $MAX_FILES files (found $TOTAL_FILES)" >&2
    fi
    # Truncate file list to MAX_FILES entries (null-delimited)
    TRUNCATED_LIST="$STATS_DIR/file_list_truncated"
    head -z -n "$MAX_FILES" "$FILE_LIST" > "$TRUNCATED_LIST"
    mv "$TRUNCATED_LIST" "$FILE_LIST"
    TOTAL_FILES=$MAX_FILES
fi

if [[ "$TOTAL_FILES" -eq 0 ]]; then
    tgt="${TARGET_DIR:-$SOURCE_DIR}"
    if [[ "$FORMAT" == "json" ]]; then
        jq -M -c -n --arg source "$SOURCE_DIR" --arg target "$tgt" --arg pattern "$(get_pattern_desc)" \
            '{status: "no_files", message: "No matching files found", source: $source, target: $target, pattern: $pattern}' >&2
    else
        echo "No matching files found" >&2
        echo "Source directory: $SOURCE_DIR" >&2
        echo "Target directory: $tgt" >&2
        echo "Pattern: $(get_pattern_desc)" >&2
    fi
    exit 0
fi

if [[ "$FORMAT" == "text" ]]; then
    tgt="${TARGET_DIR:-$SOURCE_DIR}"
    echo "Found $TOTAL_FILES file(s) to process" >&2
    echo "Source directory: $SOURCE_DIR" >&2
    echo "Target directory: $tgt" >&2
    echo "Pattern: $(get_pattern_desc)" >&2
    echo "Parallel jobs: $JOBS" >&2
    [[ "$FORCE" == "true" ]] && echo "Mode: FORCE (reconverting all)" >&2
    [[ "$DRY_RUN" == "true" ]] && echo "Mode: DRY-RUN (no actual conversion)" >&2
    [[ "$PURGE" == "true" ]] && echo "Mode: PURGE (deleting source after conversion)" >&2
    echo "" >&2
fi

# Export total for progress display
export TOTAL_FILES

################################################################################
# MAIN PROCESSING LOOP
################################################################################

# Process files from cached list in parallel
# -print0 / -0: Handle filenames with spaces/special chars via null delimiter
# -P: Run up to $JOBS parallel processes
# -I {}: Replace {} with each filename
# shellcheck disable=SC2016 # Variables are exported and expand at runtime in subshell
xargs -0 -P "$JOBS" -I {} bash -c '
    # Source file path (passed as argument $1 to avoid word-splitting issues)
    src="$1"

    # Output directory (use TARGET_DIR if specified, else same as source)
    if [ -n "$TARGET_DIR" ]; then
        outdir="$TARGET_DIR"
    else
        outdir="$(dirname "$src")"
    fi

    # Normalize outdir to remove trailing slash (avoid // in paths)
    outdir="${outdir%/}"

    # Expected PDF path: same name as source but with .pdf extension
    pdf_target="$outdir/$(basename "${src%.*}").pdf"

    # Helper function for output (all file processing logs go to stdout)
    emit_msg() {
        local level="$1" msg="$2" file="$3"
        local output_str
        if [ "$FORMAT" = "json" ]; then
            output_str=$(jq -M -c -n --arg level "$level" --arg msg "$msg" --arg file "$file" \
                "{level: \$level, message: \$msg, file: \$file}")
        else
            output_str="$msg"
        fi
        echo "$output_str" >> "$STATS_DIR/msg_$CURRENT"
    }

    # Get file modification time (GNU stat on Linux/Cygwin/MSYS2)
    get_mtime() {
        stat -c %Y "$1" 2>/dev/null || echo 0
    }

    # Get current progress count using atomic counter file
    # Use flock for atomic increment (avoids race conditions)
    CURRENT=1
    if command -v flock &>/dev/null; then
        CURRENT=$(
            flock "$STATS_DIR/counter.lock" bash -c "
                count=\$(cat \"$STATS_DIR/counter\" 2>/dev/null || echo 0)
                next=\$((count + 1))
                echo \"\$next\" > \"$STATS_DIR/counter\"
                echo \"\$next\"
            "
        )
    else
        # Fallback: count from stats files (less accurate during parallel runs)
        CURRENT=$(cat "$STATS_DIR/success" "$STATS_DIR/skipped" "$STATS_DIR/failed" "$STATS_DIR/would_convert" 2>/dev/null | wc -l | tr -d "[:space:]")
        CURRENT=$((CURRENT + 1))
    fi
    PROGRESS="[$CURRENT/$TOTAL_FILES]"

    # Skip if PDF exists and has same timestamp as source (meaning source unchanged)
    # We use timestamp equality because touch -r sets PDF time = source time after conversion
    # This enables incremental conversion - only process changed files
    # Skip this check if --force is set
    if [ "$FORCE" != "true" ] && [ -f "$pdf_target" ]; then
        src_ts=$(get_mtime "$src")
        pdf_ts=$(get_mtime "$pdf_target")
        if [ "$src_ts" = "$pdf_ts" ]; then
            if [ "$VERBOSE" = "true" ]; then
                emit_msg "info" "$PROGRESS Skipping (up-to-date, ts=$src_ts): $src" "$src"
            elif [ "$QUIET" != "true" ]; then
                emit_msg "info" "$PROGRESS Skipping (up-to-date): $src" "$src"
            fi
            echo "1" >> "$STATS_DIR/skipped"
            exit 0
        elif [ "$VERBOSE" = "true" ]; then
            emit_msg "debug" "$PROGRESS Timestamps differ (src=$src_ts, pdf=$pdf_ts): $src" "$src"
        fi
    fi

    # Dry run mode - report what would be converted without doing it
    if [ "$DRY_RUN" = "true" ]; then
        emit_msg "info" "$PROGRESS Would convert: $src" "$src"
        echo "1" >> "$STATS_DIR/would_convert"
        exit 0
    fi

    # Get temp path (Cygwin needs Windows-style path for LibreOffice)
    if command -v cygpath &>/dev/null; then
        tmpdir=$(cygpath -m "${TEMP:-/tmp}")
    else
        tmpdir="${TEMP:-/tmp}"
    fi

    # Build soffice command (DRY: single definition)
    # timeout syntax: timeout [OPTIONS] DURATION COMMAND
    #   - $TIMEOUT (e.g. 300): seconds before sending SIGTERM
    #   - --kill-after=10 (-k 10): if still alive 10s after SIGTERM, send SIGKILL
    # This prevents zombie soffice processes that ignore SIGTERM
    soffice_cmd=(
        timeout --kill-after=10 "$TIMEOUT" "${OFFICE_BASE}/soffice"
        --nologo --headless --invisible
        "-env:UserInstallation=file:///$tmpdir/libreoffice_$BASHPID"
        --convert-to pdf --outdir "$outdir" "$src"
    )

    # Run conversion
    if [ "$QUIET" = "true" ]; then
        "${soffice_cmd[@]}" >/dev/null 2>&1
        soffice_exit=$?
    else
        soffice_output=$("${soffice_cmd[@]}" 2>&1)
        soffice_exit=$?
    fi

    # Handle conversion result
    if [ $soffice_exit -ne 0 ]; then
        if [ $soffice_exit -eq 124 ]; then
            emit_msg "error" "$PROGRESS Error: Timeout after ${TIMEOUT}s converting $src" "$src"
        else
            emit_msg "error" "$PROGRESS Error: Failed to convert $src (exit code: $soffice_exit)" "$src"
            [ "$QUIET" != "true" ] && [ "$FORMAT" = "text" ] && [ -n "${soffice_output:-}" ] && \
                echo "$soffice_output" | grep -v "Could not find platform independent libraries" >> "$STATS_DIR/msg_$CURRENT"
        fi
        echo "1" >> "$STATS_DIR/failed"
        exit 1
    fi

    # Show filtered output on success (text mode, non-quiet only)
    [ "$QUIET" != "true" ] && [ "$FORMAT" = "text" ] && [ -n "${soffice_output:-}" ] && \
        echo "$soffice_output" | grep -v "Could not find platform independent libraries" >> "$STATS_DIR/msg_$CURRENT" || true

    # Use pdf_target calculated earlier (same path)
    pdf="$pdf_target"

    # If the PDF was successfully created, copy the timestamp from the source file
    # This preserves the original modification time for audit purposes
    if [ -f "$pdf" ]; then
        touch -r "$src" "$pdf"
        if [ "$QUIET" != "true" ]; then
            emit_msg "info" "$PROGRESS Converted: $src -> $pdf" "$src"
        fi
        echo "1" >> "$STATS_DIR/success"

        # Purge source file if requested
        if [ "$PURGE" = "true" ]; then
            if rm "$src" 2>/dev/null; then
                if [ "$VERBOSE" = "true" ]; then
                    emit_msg "info" "$PROGRESS Purged source: $src" "$src"
                fi
                echo "1" >> "$STATS_DIR/purged"
            else
                emit_msg "warning" "$PROGRESS Warning: Failed to purge source: $src" "$src"
            fi
        fi
    else
        emit_msg "error" "$PROGRESS Warning: Expected PDF not found: $pdf" "$src"
        echo "1" >> "$STATS_DIR/failed"
    fi
' _ {} < "$FILE_LIST"

# Print buffered worker outputs in order to stdout
for ((i=1; i<=TOTAL_FILES; i++)); do
    if [[ -f "$STATS_DIR/msg_$i" ]]; then
        cat "$STATS_DIR/msg_$i"
    fi
done

################################################################################
# SUMMARY REPORT
################################################################################

# Calculate elapsed time in seconds, minutes, and remainder seconds
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

# Aggregate results by counting lines in each stats file
# (each worker appends "1" per operation, so line count = total)
SUCCESS=$(count_lines "$STATS_DIR/success")
FAILED=$(count_lines "$STATS_DIR/failed")
SKIPPED=$(count_lines "$STATS_DIR/skipped")
WOULD_CONVERT=$(count_lines "$STATS_DIR/would_convert")
PURGED=$(count_lines "$STATS_DIR/purged")

# Output summary in requested format
output_summary() {
    local status
    if [[ "$DRY_RUN" == "true" ]]; then
        status="dry_run"
    elif [[ $FAILED -gt 0 ]]; then
        status="partial_failure"
    else
        status="success"
    fi

    local tgt="${TARGET_DIR:-$SOURCE_DIR}"
    if [[ "$FORMAT" == "json" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            jq -M -c -n --arg status "$status" --arg source "$SOURCE_DIR" --arg target "$tgt" --argjson elapsed "$ELAPSED" \
                --argjson would_convert "$WOULD_CONVERT" --argjson skipped "$SKIPPED" \
                '{status: $status, source: $source, target: $target, summary: {would_convert: $would_convert, skipped: $skipped}, elapsed_seconds: $elapsed}'
        else
            jq -M -c -n --arg status "$status" --arg source "$SOURCE_DIR" --arg target "$tgt" --argjson elapsed "$ELAPSED" \
                --argjson converted "$SUCCESS" --argjson failed "$FAILED" \
                --argjson skipped "$SKIPPED" --argjson purged "$PURGED" \
                '{status: $status, source: $source, target: $target, summary: {converted: $converted, failed: $failed, skipped: $skipped, purged: $purged}, elapsed_seconds: $elapsed}'
        fi
    else
        echo ""
        echo "=== Summary ==="
        echo "Source directory: $SOURCE_DIR"
        echo "Target directory: $tgt"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "Would convert: $WOULD_CONVERT"
        else
            echo "Converted: $SUCCESS"
            echo "Failed: $FAILED"
        fi
        echo "Skipped (up-to-date): $SKIPPED"
        [[ "$PURGE" == "true" && "$DRY_RUN" != "true" ]] && echo "Purged: $PURGED"
        [[ $ELAPSED_MIN -gt 0 ]] && echo "Elapsed time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s" || echo "Elapsed time: ${ELAPSED_SEC}s"
    fi
}

output_summary >&2

# Exit with appropriate code: 0 = success, 1 = one or more failures
if [[ $FAILED -gt 0 ]]; then
    exit 1
fi

# exit 0 implicit
