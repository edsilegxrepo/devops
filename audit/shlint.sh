#!/bin/bash
# -----------------------------------------------------------------------------
# shlint.sh
# v1.1.0xg  2026/04/29  XDG / MIS Center
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   Automates Bash script hygiene by enforcing standard formatting (shfmt)
#   and performing static analysis (shellcheck).
#
# SYNTAX:
#   shlint.sh <script.sh>
#
# DEPENDENCIES:
#   - shfmt
#   - shellcheck
#
# EXIT CODES:
#   0 - Success (Formatted and Linted)
#   1 - Usage Error (File not found or empty)
#   2 - Syntax Error (Incorrect file extension)
# -----------------------------------------------------------------------------

# Check if the file exists and is not empty
if [[ -s "$1" ]]; then
  # Ensure the file has a .sh extension
  if [[ "$1" != *.sh ]]; then
    echo "Error: File '$1' does not have a .sh extension."
    exit 2
  fi

  # Format with parameters:
  #   -i 2: Indent with 2 spaces
  #   -ci:  Indent switch case patterns
  #   -sr:  Space after redirect operators
  #   -w:   Write changes back to the file
  shfmt -i 2 -ci -sr -w "$1"

  # Run shellcheck and follow sourced files
  shellcheck -x "$1"
else
  echo "Usage: $0 <script.sh>"
  exit 1
fi
