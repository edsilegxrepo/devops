#!/bin/bash
# -----------------------------------------------------------------------------
# shlint.sh
# v1.3.0xg  2026/10/28  XDG / MIS Center
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   Automates Bash script hygiene by enforcing standard formatting (shfmt)
#   and performing static analysis (shellcheck). Engineered for both iterative
#   local development (--write) and strict CI/CD gatekeeping (--check).
#
# CORE COMPONENTS:
#   1. Prerequisite Validator: Enforces fail-fast presence of shfmt and shellcheck.
#   2. Argument Router: Resolves operational modes (--check, --write, --help)
#      using strictly long-form flags (short options disabled to prevent ambiguity).
#   3. Target Resolver: Parses target files or directories, pruning VCS internals
#      (.git), vendor trees, and cache directories.
#   4. Processing Engine (process_file): Validates shell script types (.sh, .bash,
#      .inc, or shell shebangs), canonicalizes paths to prevent self-formatting,
#      and executes formatting inspection/mutation followed by shellcheck analysis.
#
# DATA FLOW:
#   Input: CLI Arguments -> Flag Parsing -> Tool Dependency Checks -> Target Discovery
#   Execution: Canonical Path Resolution -> Self-Skip Check -> shfmt -> shellcheck
#   Output: Unified per-file telemetry ([OK]/[FAIL]) and standardized exit codes.
#
# SYNTAX:
#   shlint.sh [--check | --write] [--help] <target> [target2...]
#
# OPTIONS:
#   --check    Run in read-only verification mode (diff output on format drift).
#              Exits with non-zero status if formatting or linting fails. (Ideal for CI/CD).
#   --write    Format files in-place and run static analysis (default mode).
#   --help     Display this manual and exit.
#
# DEPENDENCIES:
#   - shfmt (mvdan/sh)
#   - shellcheck (koalaman/shellcheck)
#
# EXIT CODES:
#   0 - Success (All targeted scripts formatted and compliant)
#   1 - Usage Error (Invalid options, missing arguments, or short flags used)
#   2 - Validation Failure (Format drift or shellcheck linting failure)
#   4 - Missing Dependency (shfmt or shellcheck not found in PATH)
# -----------------------------------------------------------------------------

set -euo pipefail

# --- MODULE: USAGE AND HELP ---
usage() {
  local exit_code="${1:-0}"
  cat << EOF
Usage: $0 [--check | --write] [--help] <target> [target2...]

Operational Modes:
  --write     Format files in-place and run static analysis (default).
  --check     Run in read-only check mode (reports diffs; does not mutate files).
  --help      Show this help message and exit.

Arguments:
  <target>    File (.sh, .bash, .inc, or shell shebang) or directory to scan.

Note:
  Short flags are disabled to prevent ambiguity and CLI syntax errors.
  Use explicit long flags only.

Exit Codes:
  0 - Success
  1 - Usage Error
  2 - Validation Failure
  4 - Missing Dependency
EOF
  exit "${exit_code}"
}

# --- MODULE: ARGUMENT PARSING ---
MODE="write"
TARGETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --write)
      MODE="write"
      shift
      ;;
    --help)
      usage 0
      ;;
    --*)
      echo "ERROR: Unknown option '$1'. Use --check, --write, or --help." >&2
      usage 1
      ;;
    -*)
      echo "ERROR: Short flag '$1' is not permitted. Short flags are disabled to prevent errors. Use long options: --check, --write, --help." >&2
      exit 1
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "ERROR: No target file or directory provided." >&2
  usage 1
fi

# --- MODULE: DEPENDENCY VALIDATION ---
check_dependencies() {
  local missing=()
  command -v shfmt &> /dev/null || missing+=("shfmt")
  command -v shellcheck &> /dev/null || missing+=("shellcheck")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependency tool(s): ${missing[*]}" >&2
    echo "Please ensure shfmt and shellcheck are installed and accessible in PATH." >&2
    exit 4
  fi
}
check_dependencies

# Canonical path of running script to prevent interpreter self-formatting
SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}" 2> /dev/null || realpath "${BASH_SOURCE[0]}" 2> /dev/null || echo "${BASH_SOURCE[0]}")"

# --- MODULE: FILE TYPE DETECTOR ---
is_shell_file() {
  local f="$1"
  case "$f" in
    *.sh | *.bash | *.inc)
      return 0
      ;;
    *)
      if [[ -f "$f" && -r "$f" ]]; then
        local first_line
        first_line="$(head -n 1 "$f" 2> /dev/null || true)"
        if [[ "$first_line" =~ ^#\!.*(bash|sh)([[:space:]]|$) ]]; then
          return 0
        fi
      fi
      return 1
      ;;
  esac
}

# --- MODULE: PROCESSING ENGINE ---
process_file() {
  local file="$1"

  if ! is_shell_file "$file"; then
    echo "Warning: File '$file' is not recognized as a shell script (.sh, .bash, .inc, or shell shebang). Skipping."
    return 0
  fi

  local file_real
  file_real="$(readlink -f "$file" 2> /dev/null || realpath "$file" 2> /dev/null || echo "$file")"
  if [[ "$file_real" == "$SCRIPT_REAL" ]]; then
    echo "Warning: Skipping self ($file) to prevent interpreter read errors."
    return 0
  fi

  if [[ ! -s "$file" ]]; then
    echo "Warning: File '$file' is empty or not found. Skipping."
    return 0
  fi

  echo "--> Processing: $file"

  local file_err=0

  # Format Phase (using strictly long-form tool options)
  if [ "$MODE" == "check" ]; then
    if ! shfmt --indent 2 --case-indent --space-redirects --diff "$file"; then
      echo "  [FAIL] Formatting check failed (formatting drift detected): $file" >&2
      file_err=2
    fi
  else
    if ! shfmt --indent 2 --case-indent --space-redirects --write "$file"; then
      echo "  [FAIL] Formatting failed: $file" >&2
      file_err=2
    fi
  fi

  # Static Analysis Phase (using strictly long-form tool options)
  if ! shellcheck --external-sources "$file"; then
    echo "  [FAIL] Static analysis (shellcheck) failed: $file" >&2
    file_err=2
  fi

  if [ "$file_err" -eq 0 ]; then
    echo "  [OK] Compliant: $file"
    return 0
  else
    return "$file_err"
  fi
}

# --- MODULE: TARGET RESOLVER AND ORCHESTRATOR ---
GLOBAL_EXIT=0

for target in "${TARGETS[@]}"; do
  if [[ -d "$target" ]]; then
    echo "--> Scanning directory: $target"
    # Find all .sh, .bash, and .inc files recursively, safely pruning VCS and dependency directories
    while IFS= read -r -d '' file; do
      process_file "$file" || GLOBAL_EXIT=2
    done < <(find "$target" \
      -type d \( -name ".git" -o -name "vendor" -o -name "node_modules" -o -name ".cache" \) -prune \
      -o -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.inc" \) -print0)
  elif [[ -f "$target" ]]; then
    process_file "$target" || GLOBAL_EXIT=2
  else
    echo "Warning: Target '$target' is not a valid file or directory. Skipping."
  fi
done

if [ "$GLOBAL_EXIT" -eq 0 ]; then
  echo "--- DONE: All targeted scripts are compliant. ---"
else
  echo "--- DONE: Linting or formatting failures detected. ---"
fi

exit "$GLOBAL_EXIT"
