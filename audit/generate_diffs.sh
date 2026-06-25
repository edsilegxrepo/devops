#!/bin/bash
#
# generate_diffs.sh - Recursive Script Diff Generator
# VERSION: 1.2.0
# DATE: 2026-06-25
# ==============================================================================#
# OBJECTIVE:
#   Recursively find scripts with identical names in source and target directories,
#   then generate unified diff files for analysis. Useful for comparing different
#   versions of script collections (e.g., compliance extract scripts).
#
# FEATURES:
#   - Parallel processing for performance
#   - Matches files by basename across directory structures
#   - Generates unified diff (-ub) with context
#   - Preserves directory structure in staging area
#   - Detects likely renames based on similar filenames
#   - Summary statistics on completion
#
# USAGE:
#   ./generate_diffs.sh --source <dir> --target <dir> --stage <dir> [OPTIONS]
#
# OPTIONS:
#   --source <dir>   Source directory (old/baseline version)
#   --target <dir>   Target directory (new version to compare)
#   --stage <dir>    Output directory for diff files
#   --jobs <n>       Number of parallel jobs (default: number of CPUs)
#   --log <file>     Redirect all output to log file
#   --verbose        Show detailed progress
#   --quiet          Suppress all output except errors
#   --summary-only   Only output the summary, no per-file messages
#   --dry-run        Preview what would be compared without generating diffs
#   --json           Output results as newline-delimited JSON (requires jq)
#   --pattern <pat>  File pattern(s) - groups, wildcards, or comma-separated mix
#                    Groups: shell, windows, sql, devel, config, all
#                    Examples: "shell", "shell,windows", "config,*.txt"
#                    Default: all
#   --exclude <pat>  Exclude files matching pattern (can be repeated)
#   --no-renames     Skip rename detection (faster for large directories)
#   --exit-code      Return exit code 1 if differences found (for CI/CD)
#   --version        Show version information
#   --help           Show this help message
#
# EXAMPLES:
#   ./generate_diffs.sh --source sources/20250625 --target sources/20260604 --stage diffs/
#   ./generate_diffs.sh --source old/ --target new/ --stage diffs/ --log compare.log
#   ./generate_diffs.sh --source old/ --target new/ --stage diffs/ --pattern shell
#   ./generate_diffs.sh --source old/ --target new/ --stage diffs/ --pattern "shell,devel"
#   ./generate_diffs.sh --source old/ --target new/ --stage diffs/ --pattern "config,*.txt"
#
# EXIT CODES:
#   0 - Success (no differences, or --exit-code not set)
#   1 - Error, or differences found (when --exit-code is set)
#   2 - Invalid arguments
#
# OUTPUT:
#   For each matching pair, creates: <stage>/<relative_path>/<filename>.diff
#   Example: diffs/Extract Script - Linux/ACTT_Linux_v20.0.sh.diff
#
# DEPENDENCIES:
#   - Bash 4.3+ (for nameref variables)
#   - GNU diff, find, coreutils
#   - jq (required only when --json is specified)
#
# COMPATIBILITY:
#   - Linux, Cygwin, MSYS2, Git Bash (Windows)
#   - Paths are normalized (backslashes converted to forward slashes)
#
# JSON OUTPUT (--json):
#   Each line is a JSON object with "type" field. Types:
#     {"type":"identical","file":"name.sh","source":"/path","target":"/path"}
#     {"type":"changed","file":"name.sh","source":"/path","target":"/path","diff":"/path"}
#     {"type":"source_only","file":"name.sh","path":"/path"}
#     {"type":"target_only","file":"name.sh","path":"/path"}
#     {"type":"rename_changed","source_file":"old.sh","target_file":"new.sh","diff":"/path"}
#     {"type":"rename_identical","source_file":"old.sh","target_file":"new.sh"}
#     {"type":"binary_rename","source_file":"old.dll","target_file":"new.dll"}
#     {"type":"summary","matched":N,"changed":N,...,"elapsed_seconds":N}
#
# DATA FLOW:
#   1. Validate parameters and directories
#   2. Build index of all scripts in source directory (basename -> full path)
#   3. Scan target directory for matching basenames
#   4. For each match, generate diff and save to staging area
#   5. Detect likely renames (source-only vs target-only with similar names)
#   6. Report summary (matched, changed, identical, source-only, target-only, renames)
#
# ARCHITECTURE:
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                           MAIN PROCESS                                  │
#   ├─────────────────────────────────────────────────────────────────────────┤
#   │  1. Parse CLI args → validate → normalize paths                         │
#   │  2. Build SOURCE_INDEX (basename|fullpath) from source directory        │
#   │  3. Find target files → pipe to xargs for parallel processing           │
#   │  4. Collect statistics from STATS_DIR files                             │
#   │  5. Detect renames (sequential - needs full source/target lists)        │
#   │  6. Generate summary report                                             │
#   └─────────────────────────────────────────────────────────────────────────┘
#                                    │
#                    ┌───────────────┼───────────────┐
#                    ▼               ▼               ▼
#   ┌────────────────────┐ ┌────────────────────┐ ┌────────────────────┐
#   │   WORKER 1 (bash)  │ │   WORKER 2 (bash)  │ │   WORKER N (bash)  │
#   ├────────────────────┤ ├────────────────────┤ ├────────────────────┤
#   │ • Lookup basename  │ │ • Lookup basename  │ │ • Lookup basename  │
#   │   in SOURCE_INDEX  │ │   in SOURCE_INDEX  │ │   in SOURCE_INDEX  │
#   │ • Generate diff    │ │ • Generate diff    │ │ • Generate diff    │
#   │ • Update stats     │ │ • Update stats     │ │ • Update stats     │
#   │   (via lock)       │ │   (via lock)       │ │   (via lock)       │
#   └────────────────────┘ └────────────────────┘ └────────────────────┘
#                    │               │               │
#                    └───────────────┼───────────────┘
#                                    ▼
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                         STATS_DIR (tmpdir)                              │
#   ├─────────────────────────────────────────────────────────────────────────┤
#   │  matched          - line count = matched pairs                          │
#   │  changed          - line count = files with differences                 │
#   │  identical        - line count = files without differences              │
#   │  source_only_list - filenames only in source                            │
#   │  target_only_list - filenames only in target                            │
#   │  lock.d/          - directory-based mutex (mkdir is atomic)             │
#   │  progress         - current file count for progress display             │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# THREAD SAFETY:
#   Parallel workers use a directory-based mutex (mkdir/rmdir) to serialize:
#   - Appending to statistics files (matched, changed, identical, etc.)
#   - Writing to stdout (prevents interleaved output)
#   - Updating progress counter
#   The mkdir operation is atomic on POSIX systems, making it safe for locking.
#
################################################################################

set -e
set -o pipefail

VERSION="1.2.0"

################################################################################
# CONFIGURATION
################################################################################

# Extension groups - can be combined additively via CLI flags
# shellcheck disable=SC2034 # These arrays are used dynamically
EXT_SHELL=("*.sh" "*.bash" "*.zsh" "*.fish" "*.ksh" "*.csh" "*.tcsh")
EXT_WINDOWS=("*.ps1" "*.bat" "*.cmd")
EXT_SQL=("*.sql")
EXT_DEVEL=(
    "*.py" "*.rb" "*.pl" "*.pm" "*.php"
    "*.js" "*.ts" "*.mjs" "*.cjs"
    "*.go" "*.rs"
    "*.c" "*.h" "*.cpp" "*.hpp" "*.cc" "*.cxx" "*.hxx"
    "*.cs" "*.fs" "*.vb"
    "*.java" "*.kt" "*.kts" "*.scala" "*.sc"
)
EXT_CONFIG=("*.yaml" "*.yml" "*.json" "*.xml" "*.toml" "*.ini" "*.conf")

# Binary/dependency extensions (tracked for renames but not diffed)
# shellcheck disable=SC2034 # Used via nameref in build_find_expr
BINARY_EXTENSIONS=("*.exe" "*.dll" "*.so" "*.dat" "*.bin" "*.jar")

################################################################################
# ARGUMENT PARSING
################################################################################

SOURCE_DIR=""
TARGET_DIR=""
STAGE_DIR=""
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
VERBOSE=false
QUIET=false
SUMMARY_ONLY=false
DRY_RUN=false
LOG_FILE=""
JSON_OUTPUT=false
PATTERN="all"
EXCLUDE_PATTERNS=()
NO_RENAMES=false
EXIT_CODE=false

usage() {
    echo "Usage: $0 --source <dir> --target <dir> --stage <dir> [OPTIONS]" >&2
    echo "" >&2
    echo "Required:" >&2
    echo "  --source <dir>   Source directory (old/baseline version)" >&2
    echo "  --target <dir>   Target directory (new version to compare)" >&2
    echo "  --stage <dir>    Output directory for diff files" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --jobs <n>       Number of parallel jobs (default: $JOBS)" >&2
    echo "  --log <file>     Redirect all output to log file" >&2
    echo "  --verbose        Show detailed progress" >&2
    echo "  --quiet          Suppress all output except errors" >&2
    echo "  --summary-only   Only output the summary, no per-file messages" >&2
    echo "  --dry-run        Preview what would be compared without generating diffs" >&2
    echo "  --json           Output results as NDJSON (requires jq)" >&2
    echo "  --exclude <pat>  Exclude files matching pattern (can be repeated)" >&2
    echo "  --no-renames     Skip rename detection (faster for large directories)" >&2
    echo "  --exit-code      Return exit code 1 if differences found (for CI/CD)" >&2
    echo "  --pattern <pat>  File pattern(s) to match (default: all)" >&2
    echo "                   Groups: shell, windows, sql, devel, config, all" >&2
    echo "                   Wildcards: *.sh, *.go, *.txt" >&2
    echo "                   Combine with commas: shell,windows or config,*.txt" >&2
    echo "  --version        Show version information" >&2
    echo "  --help           Show this help message" >&2
    echo "" >&2
    echo "Pattern groups:" >&2
    echo "  shell    Shell scripts (sh, bash, zsh, fish, ksh, csh, tcsh)" >&2
    echo "  windows  Windows scripts (ps1, bat, cmd)" >&2
    echo "  sql      SQL files" >&2
    echo "  devel    Development languages (py, rb, pl, php, js, ts, go, rs," >&2
    echo "           c, cpp, cs, fs, vb, java, kt, scala)" >&2
    echo "  config   Config/markup (yaml, yml, json, xml, toml, ini, conf)" >&2
    echo "  all      All groups (default)" >&2
    exit 2
}

show_version() {
    echo "generate_diffs.sh version $VERSION"
    exit 0
}

# Helper: validate that an option has a non-empty, non-flag value
require_arg() {
    local opt="$1" val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        echo "Error: $opt requires a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)  require_arg "$1" "${2:-}"; SOURCE_DIR="$2"; shift 2 ;;
        --target)  require_arg "$1" "${2:-}"; TARGET_DIR="$2"; shift 2 ;;
        --stage)   require_arg "$1" "${2:-}"; STAGE_DIR="$2"; shift 2 ;;
        --jobs)    require_arg "$1" "${2:-}"; JOBS="$2"; shift 2 ;;
        --log)     require_arg "$1" "${2:-}"; LOG_FILE="$2"; shift 2 ;;
        --pattern) require_arg "$1" "${2:-}"; PATTERN="$2"; shift 2 ;;
        --verbose)      VERBOSE=true; shift ;;
        --quiet)        QUIET=true; shift ;;
        --summary-only) SUMMARY_ONLY=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --json)         JSON_OUTPUT=true; shift ;;
        --exclude)      require_arg "$1" "${2:-}"; EXCLUDE_PATTERNS+=("$2"); shift 2 ;;
        --no-renames)   NO_RENAMES=true; shift ;;
        --exit-code)    EXIT_CODE=true; shift ;;
        --version) show_version ;;
        --help)    usage ;;
        *)         echo "Error: Unknown option: $1" >&2; usage ;;
    esac
done

# Validate required parameters
if [[ -z "$SOURCE_DIR" ]]; then
    echo "Error: --source is required" >&2
    usage
fi
if [[ -z "$TARGET_DIR" ]]; then
    echo "Error: --target is required" >&2
    usage
fi
if [[ -z "$STAGE_DIR" ]]; then
    echo "Error: --stage is required" >&2
    usage
fi

# Redirect all output to log file if specified
if [[ -n "$LOG_FILE" ]]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

################################################################################
# PATH NORMALIZATION (Cygwin/MSYS2/Linux compatibility)
################################################################################

# Normalize path: convert backslashes to forward slashes, remove trailing slash
# Usage: normalized=$(normalize_path "$path")
normalize_path() {
    local p="$1"
    # Convert backslashes to forward slashes
    p="${p//\\//}"
    # Remove trailing slash (but keep root "/" intact)
    [[ "$p" != "/" ]] && p="${p%/}"
    echo "$p"
}

# Normalize all input paths
SOURCE_DIR=$(normalize_path "$SOURCE_DIR")
TARGET_DIR=$(normalize_path "$TARGET_DIR")
STAGE_DIR=$(normalize_path "$STAGE_DIR")
[[ -n "$LOG_FILE" ]] && LOG_FILE=$(normalize_path "$LOG_FILE")

################################################################################
# VALIDATION
################################################################################

# Validate --jobs is a positive integer
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --jobs must be a positive integer, got: $JOBS" >&2
    exit 2
fi

# Validate jq is available if --json is specified
if [[ "$JSON_OUTPUT" = "true" ]]; then
    if ! command -v jq &> /dev/null; then
        echo "Error: --json requires jq to be installed" >&2
        exit 1
    fi
fi


if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: Source directory does not exist: $SOURCE_DIR" >&2
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: Target directory does not exist: $TARGET_DIR" >&2
    exit 1
fi

# Create staging directory if it doesn't exist
mkdir -p "$STAGE_DIR"

################################################################################
# HELPER FUNCTIONS
################################################################################

# Print message to stdout (suppressed in JSON or quiet mode)
# Usage: log "message"
log() {
    if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
        echo "$@"
    fi
    return 0
}

# Emit a JSON record to stdout (only in JSON mode)
# Usage: json_emit '{"type":"event",...}'
json_emit() {
    if [[ "$JSON_OUTPUT" = "true" ]]; then
        echo "$1"
    fi
    return 0
}

# Build JSON object using jq (safe escaping)
# Usage: json_object key1 val1 key2 val2 ...
json_object() {
    local args=()
    while [[ $# -ge 2 ]]; do
        args+=("--arg" "$1" "$2")
        shift 2
    done
    jq -cn "${args[@]}" '$ARGS.named'
}

# Safely remove a temporary directory (guards against accidental rm -rf disasters)
# shellcheck disable=SC2329 # Invoked dynamically via trap on EXIT
safe_rmdir() {
    local dir="$1"
    # Guard: must be non-empty, not root, must exist, and be under temp directory
    if [[ -n "$dir" && "$dir" != "/" && -d "$dir" && "$dir" == "${TMPDIR:-${TEMP:-/tmp}}"/* ]]; then
        rm -rf "$dir"
    fi
}

# Count lines in a file (returns 0 if file doesn't exist or is empty)
count_lines() {
    if [[ -f "$1" ]]; then
        wc -l < "$1" | tr -d ' '
    else
        echo 0
    fi
}

# Build find expression from extension array
# Usage: build_find_expr ARRAY_NAME
# Result stored in FIND_EXPR array
build_find_expr() {
    local -n exts=$1
    FIND_EXPR=()
    for ext in "${exts[@]}"; do
        [[ ${#FIND_EXPR[@]} -gt 0 ]] && FIND_EXPR+=("-o")
        FIND_EXPR+=("-iname" "$ext")
    done
}

# Get relative path from base directory, handling edge cases
# Usage: rel=$(get_relative_path "$full_path" "$base_dir")
get_relative_path() {
    local full="$1" base="$2"
    local rel="${full#"$base"}"
    rel="${rel#/}"
    echo "$rel"
}

# Get output directory in staging area for a file
# Usage: out_dir=$(get_output_dir "$file_path" "$base_dir" "$stage_dir")
get_output_dir() {
    local file="$1" base="$2" stage="$3"
    local rel rel_dir
    rel=$(get_relative_path "$file" "$base")
    rel_dir=$(dirname "$rel")
    [[ "$rel_dir" == "." ]] && rel_dir=""
    if [[ -n "$rel_dir" ]]; then
        echo "$stage/$rel_dir"
    else
        echo "$stage"
    fi
}

# Normalize filename for fuzzy matching (used for rename detection)
# Removes version numbers, platform suffixes, underscores/dashes, lowercases
# Usage: core=$(normalize_for_match "$filename")
normalize_for_match() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | \
        sed -E 's/\.[^.]+$//; s/[_-]?v?[0-9]+\.[0-9]+//g; s/[_-]?[0-9]{4}\.[0-9]+//g; s/[_-]?(windows|unix)$//' | \
        tr -d '_-'
}

################################################################################
# BUILD FIND EXPRESSION
################################################################################

# Parse --pattern value (comma-separated groups and/or wildcards)
# Examples: "all", "shell", "shell,windows", "config,*.txt"
EXTENSIONS=()

IFS=',' read -ra PATTERN_PARTS <<< "$PATTERN"
for part in "${PATTERN_PARTS[@]}"; do
    # Trim whitespace
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"

    case "$part" in
        all)
            EXTENSIONS+=("${EXT_SHELL[@]}" "${EXT_WINDOWS[@]}" "${EXT_SQL[@]}" "${EXT_DEVEL[@]}" "${EXT_CONFIG[@]}")
            ;;
        shell)
            EXTENSIONS+=("${EXT_SHELL[@]}")
            ;;
        windows)
            EXTENSIONS+=("${EXT_WINDOWS[@]}")
            ;;
        sql)
            EXTENSIONS+=("${EXT_SQL[@]}")
            ;;
        devel)
            EXTENSIONS+=("${EXT_DEVEL[@]}")
            ;;
        config)
            EXTENSIONS+=("${EXT_CONFIG[@]}")
            ;;
        *)
            # Treat as wildcard pattern (e.g., *.txt, *.go)
            EXTENSIONS+=("$part")
            ;;
    esac
done

# Build find expression from extensions
build_find_expr EXTENSIONS

# Build exclude expression if patterns provided
EXCLUDE_EXPR=()
EXCLUDE_PATTERNS_STR=""
for pat in "${EXCLUDE_PATTERNS[@]}"; do
    EXCLUDE_EXPR+=("!" "-iname" "$pat")
    EXCLUDE_PATTERNS_STR+="${pat}|"
done
EXCLUDE_PATTERNS_STR="${EXCLUDE_PATTERNS_STR%|}"  # Remove trailing |

################################################################################
# STATISTICS TRACKING
################################################################################

START_TIME=$(date +%s)
STATS_DIR=$(mktemp -d)
trap 'safe_rmdir "$STATS_DIR"' EXIT

# Initialize tracking files (counters use line count, so just touch empty files)
touch "$STATS_DIR/matched"
touch "$STATS_DIR/changed"
touch "$STATS_DIR/identical"
touch "$STATS_DIR/source_only_list"
touch "$STATS_DIR/target_only_list"

################################################################################
# BUILD SOURCE INDEX
################################################################################

log "Building source index from: $SOURCE_DIR"

# Create temporary file for source index (basename -> full path)
SOURCE_INDEX="$STATS_DIR/source_index"

# Index all scripts in source by basename (normalize paths)
# Use process substitution to avoid subshell issues with pipelines
while IFS= read -r -d '' file; do
    # Normalize path for cross-platform compatibility
    file="${file//\\//}"
    bname=$(basename "$file")
    echo "$bname|$file"
done < <(find "$SOURCE_DIR" \( "${FIND_EXPR[@]}" \) "${EXCLUDE_EXPR[@]}" -type f -print0) > "$SOURCE_INDEX"

SOURCE_COUNT=$(wc -l < "$SOURCE_INDEX" | tr -d ' ')
log "Indexed $SOURCE_COUNT source script(s)"

################################################################################
# FIND MATCHES AND GENERATE DIFFS
################################################################################

# Count target files
TARGET_COUNT=$(find "$TARGET_DIR" \( "${FIND_EXPR[@]}" \) "${EXCLUDE_EXPR[@]}" -type f | wc -l | tr -d ' ')

log "Scanning target directory: $TARGET_DIR"
log "Found $TARGET_COUNT target script(s)"
log "Staging diffs to: $STAGE_DIR"
log ""

export SOURCE_INDEX STAGE_DIR STATS_DIR VERBOSE QUIET SUMMARY_ONLY DRY_RUN SOURCE_DIR TARGET_DIR JSON_OUTPUT EXCLUDE_PATTERNS_STR TARGET_COUNT

# Create lock directory path for thread-safe writes (mkdir is atomic)
# LOCKING MECHANISM: We use mkdir/rmdir as a mutex because:
#   1. mkdir is atomic on POSIX systems - only one process succeeds
#   2. No race conditions between check-and-create
#   3. Works across all shells without external tools (flock not portable)
#   4. Automatically released if process crashes (rmdir in trap or next acquire)
LOCK_DIR="$STATS_DIR/lock.d"
export LOCK_DIR

# Progress counter file - tracks how many files have been processed
# Used to show "[N/Total] Processing files..." progress indicator
PROGRESS_FILE="$STATS_DIR/progress"
echo "0" > "$PROGRESS_FILE"
export PROGRESS_FILE

# PARALLEL PROCESSING PIPELINE:
# find → xargs -P $JOBS → bash workers
#
# Each worker:
#   1. Receives one target file path via {} substitution
#   2. Looks up matching source file by basename in SOURCE_INDEX
#   3. If match found: generate diff, update matched/changed/identical counters
#   4. If no match: record as target-only
#   5. All counter updates use the lock to prevent race conditions
#
# Why xargs instead of GNU parallel:
#   - xargs is POSIX standard, available everywhere
#   - -P flag provides simple parallelism
#   - -0 handles filenames with spaces/special chars safely
#
# shellcheck disable=SC2016 # Variables are exported and expand at runtime in subshell
find "$TARGET_DIR" \( "${FIND_EXPR[@]}" \) "${EXCLUDE_EXPR[@]}" -type f -print0 | \
xargs -0 -P "$JOBS" -I {} bash -c '
    # Acquire lock using mkdir (atomic operation)
    acquire_lock() {
        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
            sleep 0.01
        done
    }

    # Release lock
    release_lock() {
        rmdir "$LOCK_DIR" 2>/dev/null || true
    }

    # Thread-safe append to a file
    locked_append() {
        local file="$1" content="$2"
        acquire_lock
        printf "%s\n" "$content" >> "$file"
        release_lock
    }

    # Thread-safe stdout output
    locked_echo() {
        acquire_lock
        printf "%s\n" "$1"
        release_lock
    }

    # Increment progress counter and optionally show progress
    increment_progress() {
        acquire_lock
        local count
        count=$(<"$PROGRESS_FILE")
        count=$((count + 1))
        echo "$count" > "$PROGRESS_FILE"
        # Show progress for larger file sets (every 10 files or at completion)
        if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" && "$SUMMARY_ONLY" != "true" ]]; then
            if (( TARGET_COUNT >= 20 && (count % 10 == 0 || count == TARGET_COUNT) )); then
                printf "\r[%d/%d] Processing files..." "$count" "$TARGET_COUNT" >&2
            fi
        fi
        release_lock
    }

    target_file="$1"
    # Normalize path (convert backslashes, no trailing slash)
    target_file="${target_file//\\//}"
    target_basename=$(basename "$target_file")

    # Look up source file by basename (use grep -F for fixed string to avoid regex injection)
    source_match=$(grep -F "${target_basename}|" "$SOURCE_INDEX" | grep "^${target_basename}|" | head -1 | cut -d"|" -f2)

    if [[ -n "$source_match" ]]; then
        # Found matching file in source
        locked_append "$STATS_DIR/matched" "1"

        # Get relative path from target dir for staging structure
        # Strip TARGET_DIR prefix and leading slash to avoid // in paths
        rel_file="${target_file#"$TARGET_DIR"}"
        rel_file="${rel_file#/}"
        rel_path=$(dirname "$rel_file")
        [[ "$rel_path" == "." ]] && rel_path=""

        # Create output directory in staging area (handle empty rel_path)
        if [[ -n "$rel_path" ]]; then
            out_dir="$STAGE_DIR/$rel_path"
        else
            out_dir="$STAGE_DIR"
        fi

        if [[ "$DRY_RUN" = "true" ]]; then
            # Dry-run: just check if files differ without writing
            if diff -q "$source_match" "$target_file" >/dev/null 2>&1; then
                locked_append "$STATS_DIR/identical" "1"
                if [[ "$JSON_OUTPUT" = "true" && "$SUMMARY_ONLY" != "true" ]]; then
                    locked_echo "$(jq -cn --arg type "identical" --arg file "$target_basename" --arg source "$source_match" --arg target "$target_file" '"'"'$ARGS.named'"'"')"
                elif [[ "$VERBOSE" = "true" && "$QUIET" != "true" && "$SUMMARY_ONLY" != "true" ]]; then
                    locked_echo "[dry-run] Identical: $target_basename"
                fi
            else
                locked_append "$STATS_DIR/changed" "1"
                if [[ "$JSON_OUTPUT" = "true" && "$SUMMARY_ONLY" != "true" ]]; then
                    locked_echo "$(jq -cn --arg type "changed" --arg file "$target_basename" --arg source "$source_match" --arg target "$target_file" '"'"'$ARGS.named'"'"')"
                elif [[ "$QUIET" != "true" && "$SUMMARY_ONLY" != "true" ]]; then
                    if [[ "$VERBOSE" = "true" ]]; then
                        locked_echo "[dry-run] Would diff: $target_basename"
                    else
                        locked_echo "[dry-run] $target_basename"
                    fi
                fi
            fi
        else
            mkdir -p "$out_dir"

            # Generate diff
            diff_file="$out_dir/${target_basename}.diff"

            # diff returns 1 if files differ, 0 if identical - dont fail on diff
            if diff -ub "$source_match" "$target_file" > "$diff_file" 2>/dev/null; then
                # Files are identical (diff returns 0)
                locked_append "$STATS_DIR/identical" "1"
                rm -f "$diff_file"  # Remove empty diff
                if [[ "$JSON_OUTPUT" = "true" && "$SUMMARY_ONLY" != "true" ]]; then
                    locked_echo "$(jq -cn --arg type "identical" --arg file "$target_basename" --arg source "$source_match" --arg target "$target_file" '"'"'$ARGS.named'"'"')"
                elif [[ "$VERBOSE" = "true" && "$QUIET" != "true" && "$SUMMARY_ONLY" != "true" ]]; then
                    locked_echo "Identical: $target_basename"
                fi
            else
                # Files differ (diff returns 1)
                locked_append "$STATS_DIR/changed" "1"
                if [[ "$JSON_OUTPUT" = "true" && "$SUMMARY_ONLY" != "true" ]]; then
                    locked_echo "$(jq -cn --arg type "changed" --arg file "$target_basename" --arg source "$source_match" --arg target "$target_file" --arg diff "$diff_file" '"'"'$ARGS.named'"'"')"
                elif [[ "$QUIET" != "true" && "$SUMMARY_ONLY" != "true" ]]; then
                    if [[ "$VERBOSE" = "true" ]]; then
                        locked_echo "Changed: $target_basename -> $diff_file"
                    else
                        locked_echo "Diff: $target_basename"
                    fi
                fi
            fi
        fi
    else
        # No match in source - target-only file
        locked_append "$STATS_DIR/target_only" "1"
        locked_append "$STATS_DIR/target_only_list" "$target_basename"
        if [[ "$JSON_OUTPUT" = "true" && "$SUMMARY_ONLY" != "true" ]]; then
            locked_echo "$(jq -cn --arg type "target_only" --arg file "$target_basename" --arg path "$target_file" '"'"'$ARGS.named'"'"')"
        elif [[ "$VERBOSE" = "true" && "$QUIET" != "true" && "$SUMMARY_ONLY" != "true" ]]; then
            locked_echo "Target-only: $target_basename"
        fi
    fi

    # Update progress counter
    increment_progress
' _ {}

# Clear progress line if it was shown
if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" && "$SUMMARY_ONLY" != "true" && "$TARGET_COUNT" -ge 20 ]]; then
    printf "\r%-50s\r" "" >&2
fi

################################################################################
# FIND SOURCE-ONLY FILES
################################################################################

log ""
log "Checking for source-only files..."

# Get list of target basenames
TARGET_BASENAMES="$STATS_DIR/target_basenames"
find "$TARGET_DIR" \( "${FIND_EXPR[@]}" \) -type f -exec basename {} \; | sort -u > "$TARGET_BASENAMES"

# Find source files not in target
if [[ -s "$SOURCE_INDEX" ]]; then
    while IFS='|' read -r file_basename source_path; do
        [[ -z "$file_basename" ]] && continue
        if ! grep -qxF "$file_basename" "$TARGET_BASENAMES" 2>/dev/null; then
            echo "1" >> "$STATS_DIR/source_only"
            echo "$file_basename" >> "$STATS_DIR/source_only_list"
            if [[ "$JSON_OUTPUT" = "true" && "$SUMMARY_ONLY" != "true" ]]; then
                json_emit "$(json_object type source_only file "$file_basename" path "$source_path")"
            elif [[ "$VERBOSE" = "true" && "$QUIET" != "true" && "$SUMMARY_ONLY" != "true" ]]; then
                echo "Source-only: $file_basename"
            fi
        fi
    done < "$SOURCE_INDEX"
fi

################################################################################
# DETECT LIKELY RENAMES
################################################################################

# RENAME DETECTION ALGORITHM:
# Matches source-only files with target-only files using fuzzy name comparison.
# This catches common rename patterns like version bumps and platform suffix changes.
#
# The normalize_for_match() function strips:
#   - File extension (.sh, .py, etc.)
#   - Version numbers (v1.0, v2.0, 2024.01, etc.)
#   - Platform suffixes (_windows, _unix)
#   - Underscores and dashes
#   - Case differences (converted to lowercase)
#
# Examples of detected renames:
#   script_v1.0.sh      → script_v2.0.sh       (version bump)
#   script_unix.sh      → script.sh            (platform suffix removed)
#   My-Script_v1.sh     → my_script_v2.sh      (case + formatting + version)
#   ACTT_2024.01.sh     → ACTT_2025.06.sh      (date-based version)
#
# When a rename is detected:
#   - If content differs: generate diff with naming pattern source__TO__target.diff
#   - If content identical: report as rename-identical (name change only)

RENAMES_FILE="$STATS_DIR/renames"
touch "$RENAMES_FILE"

if [[ "$NO_RENAMES" = "true" ]]; then
    log ""
    log "Skipping rename detection (--no-renames)"
else
    log ""
    log "Analyzing potential renames..."

    # Only process if we have source-only files to check
    if [[ -s "$STATS_DIR/source_only_list" && -s "$STATS_DIR/target_only_list" ]]; then
    while read -r source_name; do
        [[ -z "$source_name" ]] && continue
        source_core=$(normalize_for_match "$source_name")
        source_ext="${source_name##*.}"

        # Get full path of source file (use grep -F for fixed string matching)
        source_path=$(grep -F "${source_name}|" "$SOURCE_INDEX" | head -1 | cut -d"|" -f2)

        # Look for matching target file
        while read -r target_name; do
            [[ -z "$target_name" ]] && continue
            target_core=$(normalize_for_match "$target_name")
            target_ext="${target_name##*.}"

            # Match if normalized core names are equal and extensions match
            if [[ "$source_core" == "$target_core" && "$source_ext" == "$target_ext" ]]; then
                echo "$source_name -> $target_name" >> "$RENAMES_FILE"

                # Generate diff for renamed file (use -quit for efficiency)
                target_path=$(find "$TARGET_DIR" -name "$target_name" -type f -print -quit 2>/dev/null)

                if [[ -n "$source_path" && -n "$target_path" ]]; then
                    target_path="${target_path//\\//}"
                    out_dir=$(get_output_dir "$target_path" "$TARGET_DIR" "$STAGE_DIR")

                    if [[ "$DRY_RUN" = "true" ]]; then
                        # Dry-run: just check if files differ
                        if diff -q "$source_path" "$target_path" >/dev/null 2>&1; then
                            echo "1" >> "$STATS_DIR/renamed_identical"
                            if [[ "$JSON_OUTPUT" = "true" ]]; then
                                json_emit "$(json_object type rename_identical source_file "$source_name" target_file "$target_name")"
                            elif [[ "$VERBOSE" = "true" && "$QUIET" != "true" ]]; then
                                echo "[dry-run] Identical (rename): $source_name -> $target_name"
                            fi
                        else
                            echo "1" >> "$STATS_DIR/renamed_changed"
                            if [[ "$JSON_OUTPUT" = "true" ]]; then
                                json_emit "$(json_object type rename_changed source_file "$source_name" target_file "$target_name")"
                            elif [[ "$QUIET" != "true" ]]; then
                                echo "[dry-run] Would diff (rename): $source_name -> $target_name"
                            fi
                        fi
                    else
                        mkdir -p "$out_dir"
                        diff_file="$out_dir/${source_name}__TO__${target_name}.diff"

                        if ! diff -ub "$source_path" "$target_path" > "$diff_file" 2>/dev/null; then
                            echo "1" >> "$STATS_DIR/renamed_changed"
                            if [[ "$JSON_OUTPUT" = "true" ]]; then
                                json_emit "$(json_object type rename_changed source_file "$source_name" target_file "$target_name" diff "$diff_file")"
                            elif [[ "$QUIET" != "true" ]]; then
                                echo "Diff (rename): $source_name -> $target_name"
                            fi
                        else
                            rm -f "$diff_file"
                            echo "1" >> "$STATS_DIR/renamed_identical"
                            if [[ "$JSON_OUTPUT" = "true" ]]; then
                                json_emit "$(json_object type rename_identical source_file "$source_name" target_file "$target_name")"
                            elif [[ "$VERBOSE" = "true" && "$QUIET" != "true" ]]; then
                                echo "Identical (rename): $source_name -> $target_name"
                            fi
                        fi
                    fi
                fi
                break
            fi
        done < "$STATS_DIR/target_only_list"
    done < "$STATS_DIR/source_only_list"
    fi
fi  # end NO_RENAMES check

################################################################################
# DETECT BINARY/DEPENDENCY RENAMES
################################################################################

BINARY_RENAMES_FILE="$STATS_DIR/binary_renames"
touch "$BINARY_RENAMES_FILE"

if [[ "$NO_RENAMES" != "true" ]]; then
    log "Checking for binary/dependency renames..."

    # Build find expression for binary extensions
    build_find_expr BINARY_EXTENSIONS
    BINARY_FIND_EXPR=("${FIND_EXPR[@]}")

    # Index binaries in source and target
    SOURCE_BINARIES="$STATS_DIR/source_binaries"
    TARGET_BINARIES="$STATS_DIR/target_binaries"

find "$SOURCE_DIR" \( "${BINARY_FIND_EXPR[@]}" \) -type f -exec basename {} \; 2>/dev/null | sort -u > "$SOURCE_BINARIES"
find "$TARGET_DIR" \( "${BINARY_FIND_EXPR[@]}" \) -type f -exec basename {} \; 2>/dev/null | sort -u > "$TARGET_BINARIES"

# Find binaries in source not in target (by exact name)
# shellcheck disable=SC2094 # Reading from SOURCE_BINARIES, writing to BINARY_RENAMES_FILE (different files)
if [[ -s "$SOURCE_BINARIES" && -s "$TARGET_BINARIES" ]]; then
    while read -r source_bin; do
        [[ -z "$source_bin" ]] && continue
        if ! grep -qx "$source_bin" "$TARGET_BINARIES" 2>/dev/null; then
            source_core=$(normalize_for_match "$source_bin")

            while read -r target_bin; do
                [[ -z "$target_bin" ]] && continue
                if ! grep -qx "$target_bin" "$SOURCE_BINARIES" 2>/dev/null; then
                    target_core=$(normalize_for_match "$target_bin")

                    if [[ "$source_core" == "$target_core" ]]; then
                        echo "$source_bin -> $target_bin" >> "$BINARY_RENAMES_FILE"
                        if [[ "$JSON_OUTPUT" = "true" ]]; then
                            json_emit "$(json_object type binary_rename source_file "$source_bin" target_file "$target_bin")"
                        fi
                        break
                    fi
                fi
            done < "$TARGET_BINARIES"
        fi
    done < "$SOURCE_BINARIES"
fi

# Also check source-only scripts against target binaries (extension change like .bat -> .dat)
if [[ -s "$STATS_DIR/source_only_list" && -s "$TARGET_BINARIES" ]]; then
    while read -r source_script; do
        [[ -z "$source_script" ]] && continue
        source_core=$(normalize_for_match "$source_script")

        while read -r target_bin; do
            [[ -z "$target_bin" ]] && continue
            target_core=$(normalize_for_match "$target_bin")

            if [[ "$source_core" == "$target_core" ]]; then
                echo "$source_script -> $target_bin (extension change)" >> "$BINARY_RENAMES_FILE"
                if [[ "$JSON_OUTPUT" = "true" ]]; then
                    json_emit "$(json_object type extension_change source_file "$source_script" target_file "$target_bin")"
                fi
                break
            fi
        done < "$TARGET_BINARIES"
    done < "$STATS_DIR/source_only_list"
    fi
fi  # end NO_RENAMES check for binary renames

################################################################################
# SUMMARY REPORT
################################################################################

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

MATCHED=$(count_lines "$STATS_DIR/matched")
CHANGED=$(count_lines "$STATS_DIR/changed")
IDENTICAL=$(count_lines "$STATS_DIR/identical")
SOURCE_ONLY=$(count_lines "$STATS_DIR/source_only")
TARGET_ONLY=$(count_lines "$STATS_DIR/target_only")
RENAMES=$(count_lines "$RENAMES_FILE")
RENAMED_CHANGED=$(count_lines "$STATS_DIR/renamed_changed")
RENAMED_IDENTICAL=$(count_lines "$STATS_DIR/renamed_identical")
BINARY_RENAMES=$(count_lines "$BINARY_RENAMES_FILE")
DIFF_COUNT=$(find "$STAGE_DIR" -name "*.diff" -type f 2>/dev/null | wc -l | tr -d ' ')

if [[ "$JSON_OUTPUT" = "true" ]]; then
    # Emit summary as final JSON record
    jq -cn \
        --arg type "summary" \
        --arg source_dir "$SOURCE_DIR" \
        --arg target_dir "$TARGET_DIR" \
        --arg stage_dir "$STAGE_DIR" \
        --argjson matched "$MATCHED" \
        --argjson changed "$CHANGED" \
        --argjson identical "$IDENTICAL" \
        --argjson source_only "$SOURCE_ONLY" \
        --argjson target_only "$TARGET_ONLY" \
        --argjson renames "$RENAMES" \
        --argjson renamed_changed "$RENAMED_CHANGED" \
        --argjson renamed_identical "$RENAMED_IDENTICAL" \
        --argjson binary_renames "$BINARY_RENAMES" \
        --argjson diff_count "$DIFF_COUNT" \
        --argjson elapsed_seconds "$ELAPSED" \
        --argjson dry_run "$( [[ "$DRY_RUN" = "true" ]] && echo true || echo false )" \
        '$ARGS.named'
elif [[ "$QUIET" != "true" ]]; then
    # Helper for printing section headers
    section() { echo "--------------------------------------------------------------------------------"; echo "$1"; echo "--------------------------------------------------------------------------------"; }

    # Helper for printing indented file list from a file
    print_list() { while read -r line; do echo "  $line"; done < "$1"; echo ""; }

    echo ""
    echo "================================================================================"
    if [[ "$DRY_RUN" = "true" ]]; then
        echo "                         DIFF ANALYSIS SUMMARY [DRY-RUN]"
    else
        echo "                              DIFF ANALYSIS SUMMARY"
    fi
    echo "================================================================================"
    echo ""
    echo "Source: $SOURCE_DIR"
    echo "Target: $TARGET_DIR"
    [[ "$DRY_RUN" != "true" ]] && echo "Output: $STAGE_DIR"
    echo ""
    section "STATISTICS"

    echo "Matched pairs:     $MATCHED"
    echo "  - Changed:       $CHANGED (diffs generated)"
    echo "  - Identical:     $IDENTICAL (no diff needed)"
    echo "Source-only:       $SOURCE_ONLY (not in target)"
    echo "Target-only:       $TARGET_ONLY (new in target)"
    echo "Likely renames:    $RENAMES"
    echo "  - Changed:       $RENAMED_CHANGED (diffs generated)"
    echo "  - Identical:     $RENAMED_IDENTICAL (name only)"
    echo "Binary renames:    $BINARY_RENAMES"
    echo ""

    # List changed files
    if (( DIFF_COUNT > 0 )); then
        section "CHANGED FILES (diffs generated) [$DIFF_COUNT]"
        find "$STAGE_DIR" -name "*.diff" -type f -exec basename {} .diff \; | sort
        echo ""
    fi

    # List likely renames
    if [[ -s "$RENAMES_FILE" ]]; then
        section "LIKELY RENAMES (version updates) [$RENAMES]"
        echo "These files appear to be renamed versions of each other:"
        echo ""
        print_list "$RENAMES_FILE"
    fi

    # List binary/dependency renames
    if [[ -s "$BINARY_RENAMES_FILE" ]]; then
        section "BINARY/DEPENDENCY RENAMES [$BINARY_RENAMES]"
        echo "These binary/dependency files appear to be renamed:"
        echo ""
        print_list "$BINARY_RENAMES_FILE"
    fi

    # List source-only files (not matched as renames or binary renames)
    UNMATCHED_SOURCE="$STATS_DIR/unmatched_source"
    if [[ -s "$STATS_DIR/source_only_list" ]]; then
        # Build exclusion pattern from renames
        EXCLUDE_PATTERN="$STATS_DIR/exclude_source"
        {
            cut -d' ' -f1 "$RENAMES_FILE" 2>/dev/null || true
            cut -d' ' -f1 "$BINARY_RENAMES_FILE" 2>/dev/null || true
        } > "$EXCLUDE_PATTERN"

        if [[ -s "$EXCLUDE_PATTERN" ]]; then
            grep -vxFf "$EXCLUDE_PATTERN" "$STATS_DIR/source_only_list" > "$UNMATCHED_SOURCE" 2>/dev/null || true
        else
            cp "$STATS_DIR/source_only_list" "$UNMATCHED_SOURCE"
        fi

        if [[ -s "$UNMATCHED_SOURCE" ]]; then
            UNMATCHED_SOURCE_COUNT=$(wc -l < "$UNMATCHED_SOURCE" | tr -d ' ')
            section "SOURCE-ONLY FILES (removed/deprecated) [$UNMATCHED_SOURCE_COUNT]"
            echo "These files exist only in source (may be removed or deprecated):"
            echo ""
            print_list "$UNMATCHED_SOURCE"
        fi
    fi

    # List target-only files (not matched as renames)
    UNMATCHED_TARGET="$STATS_DIR/unmatched_target"
    if [[ -s "$STATS_DIR/target_only_list" ]]; then
        # Build exclusion pattern from renames (extract target names after "->")
        EXCLUDE_PATTERN="$STATS_DIR/exclude_target"
        cut -d'>' -f2 "$RENAMES_FILE" 2>/dev/null | sed 's/^ //' > "$EXCLUDE_PATTERN" || true

        if [[ -s "$EXCLUDE_PATTERN" ]]; then
            grep -vxFf "$EXCLUDE_PATTERN" "$STATS_DIR/target_only_list" > "$UNMATCHED_TARGET" 2>/dev/null || true
        else
            cp "$STATS_DIR/target_only_list" "$UNMATCHED_TARGET"
        fi

        if [[ -s "$UNMATCHED_TARGET" ]]; then
            UNMATCHED_TARGET_COUNT=$(wc -l < "$UNMATCHED_TARGET" | tr -d ' ')
            section "TARGET-ONLY FILES (new additions) [$UNMATCHED_TARGET_COUNT]"
            echo "These files exist only in target (newly added):"
            echo ""
            print_list "$UNMATCHED_TARGET"
        fi
    fi

    echo "--------------------------------------------------------------------------------"
    echo "Elapsed time: ${ELAPSED}s"
    echo "================================================================================"
fi

################################################################################
# EXIT CODE
################################################################################

# Return non-zero if differences found (for CI/CD integration)
if [[ "$EXIT_CODE" = "true" ]]; then
    if (( CHANGED > 0 || RENAMED_CHANGED > 0 )); then
        exit 1
    fi
fi

exit 0
