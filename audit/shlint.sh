#!/bin/bash
# -----------------------------------------------------------------------------
# shlint.sh
# v1.2.0xg  2026/04/29  XDG / MIS Center
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   Automates Bash script hygiene by enforcing standard formatting (shfmt)
#   and performing static analysis (shellcheck). It is designed to be used
#   both manually by developers and automatically in CI/CD pipelines.
#
# CORE COMPONENTS:
#   1. Target Resolver: Parses input arguments to handle individual files or
#      recursively scan directories using `find`.
#   2. Processing Engine (process_file): Validates file extensions, prevents
#      self-execution recursion, and sequentially executes the format and lint phases.
#
# DATA FLOW:
#   Input: CLI Arguments (Files/Directories) -> Target Loop -> File Discovery
#   Execution: Path Validation -> Self-Skip Check -> shfmt (Write) -> shellcheck (Analyze)
#   Output: Unified console progress and a binary Global Exit Status (0 or 2).
#
# SYNTAX:
#   shlint.sh <target> [target2...]
#     <target> can be a single file, a list of files, or a directory.
#     If a directory is provided, it recursively processes all *.sh files.
#
# DEPENDENCIES:
#   - shfmt
#   - shellcheck
#
# EXIT CODES:
#   0 - Success (Formatted and Linted)
#   1 - Usage Error (No targets provided)
#   2 - Validation Failure (Format/Lint error on one or more files)
# -----------------------------------------------------------------------------

# --- MODULE: ARGUMENT VALIDATION ---
# Ensures the script was called with at least one target to process.
if [ $# -eq 0 ]; then
  echo "Usage: $0 <file.sh|directory> [target2 ...]"
  exit 1
fi

# --- MODULE: PROCESSING ENGINE ---
# PURPOSE: Executes the core hygiene operations on a single bash script.
# LOGIC:
#   1. Validates the file has a .sh extension and contains data.
#   2. Validates the file is not the orchestrator itself to prevent interpreter crashes.
#   3. Executes `shfmt` to standardize syntax spacing and indentation in-place.
#   4. Executes `shellcheck` for deep static analysis and bug discovery.
process_file() {
  local file="$1"

  if [[ "$file" != *.sh ]]; then
    echo "Warning: File '$file' does not have a .sh extension. Skipping."
    return 0
  fi

  if [[ "$(basename "$file")" == "shlint.sh" ]]; then
    echo "Warning: Skipping self ($file) to prevent interpreter read errors."
    return 0
  fi

  if [[ ! -s "$file" ]]; then
    echo "Warning: File '$file' is empty or not found. Skipping."
    return 0
  fi

  echo "--> Processing: $file"

  # Format with parameters:
  #   -i 2: Indent with 2 spaces
  #   -ci:  Indent switch case patterns
  #   -sr:  Space after redirect operators
  #   -w:   Write changes back to the file
  shfmt -i 2 -ci -sr -w "$file" || return 2

  # Run shellcheck and follow sourced files
  shellcheck -x "$file" || return 2
}

# --- MODULE: TARGET RESOLVER AND ORCHESTRATOR ---
# PURPOSE: Iterates over user-provided arguments, resolving them to actionable files.
# Tracks the cumulative exit status across all iterations.
GLOBAL_EXIT=0

for target in "$@"; do
  if [[ -d "$target" ]]; then
    echo "--> Scanning directory: $target"
    # Find all .sh files in the directory and process them safely handling spaces
    while IFS= read -r -d '' file; do
      process_file "$file" || GLOBAL_EXIT=2
    done < <(find "$target" -type f -name "*.sh" -print0)
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

exit $GLOBAL_EXIT
