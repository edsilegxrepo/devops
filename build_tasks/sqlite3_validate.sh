#!/bin/bash
# -----------------------------------------------------------------------------
# SQLite 3 Build Verification Script (sqlite3_validate.sh)
# v1.0.3xg  2026/04/14  XdG
#
# OBJECTIVE:
# Perform a comprehensive verification of a compiled SQLite 3 binary to ensure
# it meets the required specifications, including versioning, feature support,
# functional correctness, and presence of supplemental tools.
#
# CORE COMPONENTS:
# - Version Validation: Compares binary version against a target.
# - Feature Verification: Checks 'PRAGMA compile_options' for required flags.
# - Functional Testing: Executes SQL samples for Math, JSON, and UI modes.
# - Toolchain Audit: Verifies existence of rsync, analyzer, and diff tools.
#
# DATA FLOW:
# [CLI Args] -> [parse_args] -> [Validation Phase]
#                                   |
#                                   +-- 1. Version Check
#                                   +-- 2. Feature Check (FTS5, RTREE, etc.)
#                                   +-- 3. Functional Logic (Math/JSON/Box)
#                                   +-- 4. Supplemental Tool Search
#                                   |
#                                [Exit Code 0 (Success) or 1 (Failure)]
#
# PREREQUISITES:
# - SQLite 3 binary (target for verification).
# - Bash 4.0+
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Global Configuration ---
# SQLITE_BIN: Path to the sqlite3 executable under test.
# TARGET_VERSION: The semantic version string to validate against.
# FAILURES: Accumulator for test case failures.
SQLITE_BIN="./sqlite3"
TARGET_VERSION=""
FAILURES=0

# UI: Colors for standard output formatting
PASS='\033[0;32m[PASS]\033[0m'
FAIL='\033[0;31m[FAIL]\033[0m'

# --- Functions ---

usage() {
    cat <<EOF >&2

Usage: $0 --version=<v.vv.v> [OPTIONS]

Mandatory:
  --version=<v.vv.v>  The expected SQLite version (e.g., 3.53.0)

Options:
  --path=<path>       Path to the sqlite3 binary (default: ./sqlite3)
  --list-features     List all compiled-in SQLite features and exit
  --with-lemon        Include 'lemon' in the supplemental tools check
  --help              Display this help message

EOF
    exit 0
}

log_pass() {
    echo -e "${PASS} $1"
}

log_fail() {
    echo -e "${FAIL} $1" >&2
    FAILURES=$((FAILURES + 1))
}

# check_option: Helper to probe the binary's internal configuration list.
# Uses 'PRAGMA compile_options' to verify if a feature was included at build time.
check_option() {
    local opt="$1"
    if "$SQLITE_BIN" :memory: "PRAGMA compile_options;" | grep -q "^${opt}$"; then
        log_pass "Feature/Config active: ${opt}"
    else
        log_fail "Feature/Config missing: ${opt}"
    fi
}

# --- Parameter Parsing ---

for i in "$@"; do
    case $i in
        --version=*)
            TARGET_VERSION="${i#*=}"
            shift
            ;;
        --path=*)
            SQLITE_BIN="${i#*=}"
            shift
            ;;
        --list-features)
            if [[ ! -x "$SQLITE_BIN" ]]; then
                echo "Error: Executable binary not found at $SQLITE_BIN" >&2
                exit 1
            fi
            "$SQLITE_BIN" :memory: "PRAGMA compile_options;"
            exit 0
            ;;
        --with-lemon)
            INCLUDE_LEMON=1
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo "Error: Unknown option: $i" >&2
            usage
            ;;
    esac
done

if [[ -z "$TARGET_VERSION" ]]; then
    echo "Error: Missing mandatory --version parameter." >&2
    usage
fi

if [[ ! -x "$SQLITE_BIN" ]]; then
    echo "Error: Executable binary not found at $SQLITE_BIN" >&2
    exit 1
fi

echo "--- Starting SQLite $TARGET_VERSION Build Verification ---"

# 1. Version Check
CURRENT_VER=$("$SQLITE_BIN" :memory: "SELECT sqlite_version();")
if [[ "$CURRENT_VER" == "$TARGET_VERSION" ]]; then
    log_pass "Version matches: $CURRENT_VER"
else
    log_fail "Version mismatch! Found: $CURRENT_VER, Expected: $TARGET_VERSION"
fi

# 2. PRAGMA compile_options check
# This ensures that the binary was compiled with the exact feature set required
# by the project's specification (e.g., FTS5 for full-text search, Secure Delete).
echo "Verifying features defined in SPEC..."
FEATURES="ENABLE_FTS3 ENABLE_FTS4 ENABLE_FTS5 ENABLE_RTREE ENABLE_GEOPOLY ENABLE_SESSION ENABLE_COLUMN_METADATA ENABLE_DBSTAT_VTAB ENABLE_UNLOCK_NOTIFY ENABLE_STMTVTAB ENABLE_MATH_FUNCTIONS ENABLE_FTS3_PARENTHESIS ENABLE_PREUPDATE_HOOK ENABLE_UPDATE_DELETE_LIMIT ENABLE_MEMSYS5 DISABLE_DIRSYNC SECURE_DELETE TEMP_STORE=2 THREADSAFE=1 DQS=0"

for opt in $FEATURES; do
    check_option "$opt"
done

# 3. Functional: Math Functions
MATH_TEST=$("$SQLITE_BIN" :memory: "SELECT power(2,3);")
if [[ "$MATH_TEST" == "8.0" ]]; then
    log_pass "Math functions functional (power(2,3) == 8.0)"
else
    log_fail "Math functions failed (power(2,3) == $MATH_TEST)"
fi

# 4. Functional: JSON/JSONB
JSON_TEST=$("$SQLITE_BIN" :memory: "SELECT json_extract('{\"a\":123}', '$.a');")
if [[ "$JSON_TEST" == "123" ]]; then
    log_pass "JSON (standard) functional"
else
    log_fail "JSON (standard) failed"
fi

JSONB_TEST=$("$SQLITE_BIN" :memory: "SELECT typeof(jsonb('{\"test\":1}'));")
if [[ "$JSONB_TEST" == "blob" ]]; then
    log_pass "JSONB (binary JSON) functional"
else
    log_fail "JSONB check failed (Expected blob, found $JSONB_TEST)"
fi

# 5. Functional: QRF / Box Mode
# Verifies that the CLI supports Unicode-aware table formatting (Box Mode)
# and correctly handles column truncations (charlimit).
QRF_TEST=$("$SQLITE_BIN" :memory: ".mode box --charlimit 5" "SELECT 'Hello World';" 2>&1)
if [[ $QRF_TEST == *"Hello..."* ]]; then
    log_pass "QRF (Unicode Box Mode) functional"
else
    log_fail "QRF/Box mode failed"
fi

# 6. Tool Presence
echo "Checking for supplemental binaries..."
SQLITE_DIR=$(dirname "$SQLITE_BIN")
TOOLS="sqlite3_rsync sqlite3_analyzer sqldiff"
if [[ "${INCLUDE_LEMON:-0}" -eq 1 ]]; then
    TOOLS="$TOOLS lemon"
fi

for tool in $TOOLS; do
    TOOL_PATH="$SQLITE_DIR/$tool"
    if [[ -x "$TOOL_PATH" ]]; then
        log_pass "Tool found: $tool"
    elif command -v "$tool" >/dev/null 2>&1; then
        log_pass "Tool found in PATH: $tool"
    else
        log_fail "Tool missing: $tool"
    fi
done

echo "--- Verification Complete ---"
if (( FAILURES > 0 )); then
    echo -e "${FAIL} $FAILURES test(s) failed." >&2
    exit 1
else
    echo -e "${PASS} All tests passed."
    exit 0
fi
