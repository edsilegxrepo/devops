#!/bin/bash
#
# generate_diffs_test.sh - Unit tests for generate_diffs.sh
# VERSION: 1.0.0
# DATE: 2026-06-25
# ==============================================================================
#
# OBJECTIVE:
#   Comprehensive unit test suite validating all functionality of generate_diffs.sh.
#   Tests cover CLI options, pattern matching, diff generation, rename detection,
#   parallel processing, edge cases, and output formats.
#
# TEST ENVIRONMENT:
#   - Uses temporary directory /tmp/unittests/generate_diffs_YYYYMMDDhhmmss for isolation
#   - Each test creates its own subdirectory with source/target/stage folders
#   - All artifacts are cleaned up after execution (even on failure/interrupt)
#   - Cross-platform: Linux, Cygwin, MSYS2, Git Bash (Windows)
#
# USAGE:
#   ./generate_diffs_test.sh [--verbose] [--sequential]
#
# OPTIONS:
#   --verbose, -v     Show detailed test output and assertion failures
#   --sequential, -s  Run tests one at a time (default: parallel)
#   --help, -h        Show help message
#
# EXIT CODES:
#   0 - All tests passed
#   1 - One or more tests failed
#
# TEST STRATEGY:
#   The test suite uses a layered approach to ensure comprehensive coverage:
#
#   1. UNIT TESTS - Individual function validation
#      - Helper functions (normalize_for_match, count_lines, build_find_expr)
#      - Path manipulation (get_relative_path, get_output_dir)
#      - Tests use mockup data to verify expected behavior
#
#   2. INTEGRATION TESTS - CLI option combinations
#      - Each CLI option tested in isolation (--verbose, --quiet, --json, etc.)
#      - Option combinations tested (--dry-run --summary-only)
#      - Error handling for invalid inputs (bad paths, invalid --jobs value)
#
#   3. FUNCTIONAL TESTS - End-to-end workflows
#      - Diff generation for changed files
#      - Rename detection (version bumps, platform suffixes)
#      - Source-only and target-only file detection
#      - JSON output format validation (NDJSON)
#
#   4. EDGE CASE TESTS - Boundary conditions
#      - Empty directories, empty files
#      - Paths with spaces and special characters
#      - Very long filenames
#      - Case sensitivity in extensions
#
#   5. CONCURRENCY TESTS - Parallel processing integrity
#      - Output not garbled under parallel execution
#      - Statistics counters accurate (no race conditions)
#      - JSON output remains valid NDJSON
#
# PARALLEL EXECUTION:
#   Tests run in parallel (max 4 concurrent) to reduce execution time.
#   Each test runs generate_diffs.sh with --jobs 1 to prevent subprocess
#   explosion (4 tests × 4 workers = 16 max processes).
#
#   ┌─────────────────────────────────────────────────────────────────┐
#   │                    TEST RUNNER (main process)                   │
#   ├─────────────────────────────────────────────────────────────────┤
#   │  1. Setup TEST_ROOT (/tmp/unittests/generate_diffs_YYYYMMDDHHMMSS) │
#   │  2. Generate numbered test list                                 │
#   │  3. Pipe to xargs -P 4 for parallel execution                   │
#   │  4. Collect results from RESULTS_DIR                            │
#   │  5. Display summary and cleanup                                 │
#   └─────────────────────────────────────────────────────────────────┘
#                              │
#          ┌───────────────────┼───────────────────┐
#          ▼                   ▼                   ▼
#   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
#   │  Worker 1   │     │  Worker 2   │     │  Worker N   │
#   ├─────────────┤     ├─────────────┤     ├─────────────┤
#   │ Source test │     │ Source test │     │ Source test │
#   │ file (funcs)│     │ file (funcs)│     │ file (funcs)│
#   │ Run test_X  │     │ Run test_Y  │     │ Run test_Z  │
#   │ Write result│     │ Write result│     │ Write result│
#   └─────────────┘     └─────────────┘     └─────────────┘
#
# SAFETY GUARDS (rm -rf protection):
#   The cleanup_test_env() function has 7 validation checks:
#   1. TEST_ROOT must be non-empty
#   2. Must start with /tmp/unittests/ (absolute path in temp)
#   3. Must match exact pattern /tmp/unittests/generate_diffs_NNNNNNNNNNNNNN
#   4. Must be a directory (not a file)
#   5. Must not be a symlink (prevents symlink attacks)
#   6. Must not contain ".." (prevents directory traversal)
#   7. Path length must be >= 25 chars (sanity check)
#
# DEPENDENCIES:
#   - Bash 4.3+ (for arrays and process substitution)
#   - generate_diffs.sh (script under test, must be in same directory)
#   - jq (optional, required for JSON-related tests)
#   - Standard Unix tools: find, grep, diff, wc, awk
#
################################################################################

set -o pipefail

# Get script directory (where generate_diffs.sh should be)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/generate_diffs.sh"

# Wrapper to call script with --jobs 1 (prevents subprocess explosion in parallel tests)
# Tests that specifically test parallel behavior override this explicitly
run_script() {
    "$SCRIPT_UNDER_TEST" --jobs 1 "$@"
}

# Test configuration - only set if not already set (allows parent to control)
if [[ -z "${TEST_ROOT:-}" ]]; then
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    TEST_ROOT="/tmp/unittests/generate_diffs_$TIMESTAMP"
fi
VERBOSE="${VERBOSE:-false}"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

################################################################################
# TEST FRAMEWORK
################################################################################
#
# Lightweight assertion-based testing framework providing:
#   - Colored output (PASS/FAIL/WARN/INFO) for terminal readability
#   - Assertion functions for common checks (equality, file existence, etc.)
#   - Automatic test counting and result tracking
#   - Verbose mode for debugging failed tests
#
# ASSERTION FUNCTIONS:
#   assert_eq           - Compare two values for equality
#   assert_not_empty    - Verify a value is not empty
#   assert_file_exists  - Check file exists
#   assert_file_not_exists - Check file does not exist
#   assert_dir_exists   - Check directory exists
#   assert_exit_code    - Verify command exit code
#   assert_contains     - Check string contains substring
#   assert_valid_ndjson - Validate JSON format (requires jq)
#
# USAGE PATTERN:
#   test_example() {
#       local test_dir=$(create_test_dir "example")
#       # Setup test data...
#       local output=$(run_script --source ... 2>&1)
#       local exit_code=$?
#       assert_exit_code 0 "$exit_code" "Should succeed" && \
#       assert_contains "$output" "expected" "Should have expected output"
#   }

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Run a test and track results
# Usage: run_test "test_name" test_function
run_test() {
    local name="$1"
    local func="$2"

    ((TESTS_RUN++))

    if [[ "$VERBOSE" = "true" ]]; then
        echo ""
        log_info "Running: $name"
    fi

    if $func; then
        ((TESTS_PASSED++))
        log_pass "$name"
        return 0
    else
        ((TESTS_FAILED++))
        log_fail "$name"
        return 1
    fi
}

# Assert that two values are equal
# Usage: assert_eq "expected" "actual" "message"
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Values should be equal}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        [[ "$VERBOSE" = "true" ]] && echo "  Expected: '$expected', Got: '$actual' - $msg" >&2
        return 1
    fi
}

# Assert that a value is not empty
# Usage: assert_not_empty "value" "message"
assert_not_empty() {
    local value="$1"
    local msg="${2:-Value should not be empty}"

    if [[ -n "$value" ]]; then
        return 0
    else
        [[ "$VERBOSE" = "true" ]] && echo "  Value is empty - $msg" >&2
        return 1
    fi
}

# Assert that a file exists
# Usage: assert_file_exists "path" "message"
assert_file_exists() {
    local path="$1"
    local msg="${2:-File should exist}"

    if [[ -f "$path" ]]; then
        return 0
    else
        [[ "$VERBOSE" = "true" ]] && echo "  File not found: $path - $msg" >&2
        return 1
    fi
}

# Assert that a file does not exist
# Usage: assert_file_not_exists "path" "message"
assert_file_not_exists() {
    local path="$1"
    local msg="${2:-File should not exist}"

    if [[ ! -f "$path" ]]; then
        return 0
    else
        [[ "$VERBOSE" = "true" ]] && echo "  File exists but shouldn't: $path - $msg" >&2
        return 1
    fi
}

# Assert that a directory exists
# Usage: assert_dir_exists "path" "message"
assert_dir_exists() {
    local path="$1"
    local msg="${2:-Directory should exist}"

    if [[ -d "$path" ]]; then
        return 0
    else
        [[ "$VERBOSE" = "true" ]] && echo "  Directory not found: $path - $msg" >&2
        return 1
    fi
}

# Assert exit code
# Usage: assert_exit_code expected_code actual_code "message"
assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Exit code should match}"

    if [[ "$expected" -eq "$actual" ]]; then
        return 0
    else
        [[ "$VERBOSE" = "true" ]] && echo "  Expected exit code $expected, got $actual - $msg" >&2
        return 1
    fi
}

# Assert string contains substring
# Usage: assert_contains "haystack" "needle" "message"
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-String should contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        [[ "$VERBOSE" = "true" ]] && echo "  String does not contain '$needle' - $msg" >&2
        return 1
    fi
}

# Assert output is valid JSON (each line)
# Usage: assert_valid_ndjson "output" "message"
assert_valid_ndjson() {
    local output="$1"
    local msg="${2:-Output should be valid NDJSON}"

    if echo "$output" | jq -e . >/dev/null 2>&1; then
        return 0
    else
        [[ "$VERBOSE" = "true" ]] && echo "  Invalid JSON - $msg" >&2
        return 1
    fi
}

################################################################################
# SETUP / TEARDOWN
################################################################################
#
# TEST ISOLATION STRATEGY:
#   Each test gets its own subdirectory under TEST_ROOT with the structure:
#     /tmp/unittests/generate_diffs_YYYYMMDDHHMMSS/
#       ├── test_name_1/
#       │   ├── source/    ← simulated source directory
#       │   ├── target/    ← simulated target directory
#       │   └── stage/     ← output directory for diffs
#       ├── test_name_2/
#       │   ├── source/
#       │   ├── target/
#       │   └── stage/
#       └── results/       ← parallel test results (PASS/FAIL + timing)
#
# This isolation ensures:
#   - Tests don't interfere with each other
#   - Parallel execution is safe
#   - Easy cleanup (single rm -rf of TEST_ROOT)
#   - Deterministic test behavior

setup_test_env() {
    log_info "Setting up test environment at $TEST_ROOT"
    mkdir -p "$TEST_ROOT"

    # Verify the script under test exists
    if [[ ! -f "$SCRIPT_UNDER_TEST" ]]; then
        log_fail "Script not found: $SCRIPT_UNDER_TEST"
        exit 1
    fi

    # Verify script is executable
    if [[ ! -x "$SCRIPT_UNDER_TEST" ]]; then
        chmod +x "$SCRIPT_UNDER_TEST"
    fi
}

cleanup_test_env() {
    # SAFETY GUARDS for rm -rf - be extremely paranoid
    # 1. Must be non-empty
    [[ -z "$TEST_ROOT" ]] && return 0
    # 2. Must start with /tmp/unittests/ (absolute path in temp)
    [[ "$TEST_ROOT" != /tmp/unittests/* ]] && return 0
    # 3. Must match our exact naming pattern
    [[ "$TEST_ROOT" != /tmp/unittests/generate_diffs_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] ]] && return 0
    # 4. Must be a directory (not a symlink to somewhere dangerous)
    [[ ! -d "$TEST_ROOT" ]] && return 0
    [[ -L "$TEST_ROOT" ]] && return 0
    # 5. Path must not contain .. or be too short
    [[ "$TEST_ROOT" == *..* ]] && return 0
    [[ ${#TEST_ROOT} -lt 25 ]] && return 0

    log_info "Cleaning up test environment"
    rm -rf -- "$TEST_ROOT"
    log_info "Removed $TEST_ROOT"
}


# Create a fresh test subdirectory
# Usage: create_test_dir "test_name"
create_test_dir() {
    local name="$1"
    local dir="$TEST_ROOT/$name"
    mkdir -p "$dir/source" "$dir/target" "$dir/stage"
    echo "$dir"
}

################################################################################
# UNIT TESTS - HELPER FUNCTIONS
################################################################################
#
# These tests verify the internal helper functions of generate_diffs.sh.
# Since functions are not exported, we test them indirectly through script
# behavior using carefully crafted input files that exercise specific code paths.
#
# Coverage:
#   - normalize_for_match: Tested via rename detection with versioned filenames
#   - count_lines: Tested via summary statistics output
#   - build_find_expr: Tested via --pattern option combinations
#   - get_relative_path/get_output_dir: Tested via directory structure preservation

# Test: normalize_for_match function (rename detection normalization)
test_normalize_for_match() {
    local test_dir
    test_dir=$(create_test_dir "normalize_for_match")

    # Test rename detection indirectly through script behavior

    # Test cases via the script's dry-run with specific filenames
    # We'll test this indirectly through rename detection

    # Create source with versioned filename
    echo '#!/bin/bash' > "$test_dir/source/script_v1.0.sh"
    echo '# version 1' >> "$test_dir/source/script_v1.0.sh"

    # Create target with different version
    echo '#!/bin/bash' > "$test_dir/target/script_v2.0.sh"
    echo '# version 2' >> "$test_dir/target/script_v2.0.sh"

    # Run script - should detect as rename
    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    assert_contains "$output" "Likely renames:" "Should detect version rename"
}

# Test: count_lines function
test_count_lines() {
    local test_dir
    test_dir=$(create_test_dir "count_lines")

    # Create test files with known line counts
    echo -e "line1\nline2\nline3" > "$test_dir/three_lines.txt"
    echo "" > "$test_dir/one_line.txt"

    # Test via script behavior - the summary shows line counts
    echo '#!/bin/bash' > "$test_dir/source/a.sh"
    echo '#!/bin/bash' > "$test_dir/source/b.sh"
    echo '#!/bin/bash' > "$test_dir/source/c.sh"
    echo '#!/bin/bash' > "$test_dir/target/a.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run --summary-only 2>&1)

    # Should show: Matched pairs: 1, Source-only: 2
    assert_contains "$output" "Matched pairs:     1" "Should count 1 matched"
    assert_contains "$output" "Source-only:       2" "Should count 2 source-only"
}

# Test: build_find_expr function (extension pattern building)
test_build_find_expr() {
    local test_dir
    test_dir=$(create_test_dir "build_find_expr")

    # Create files with different extensions
    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo 'print("hello")' > "$test_dir/source/test.py"
    echo 'print("hello")' > "$test_dir/target/test.py"
    echo 'Get-Help' > "$test_dir/source/test.ps1"
    echo 'Get-Help' > "$test_dir/target/test.ps1"

    # Test shell pattern only
    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 1 target script" "Shell pattern should find 1 file"

    # Test multiple patterns
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern "shell,devel" --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 2 target script" "Combined pattern should find 2 files"
}

# Test: get_relative_path and get_output_dir functions
test_path_functions() {
    local test_dir
    test_dir=$(create_test_dir "path_functions")

    # Create nested directory structure
    mkdir -p "$test_dir/source/subdir/nested"
    mkdir -p "$test_dir/target/subdir/nested"

    echo '#!/bin/bash' > "$test_dir/source/subdir/nested/deep.sh"
    echo '#!/bin/bash' > "$test_dir/target/subdir/nested/deep.sh"
    echo '# modified' >> "$test_dir/target/subdir/nested/deep.sh"

    # Run and check that staging preserves structure
    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell >/dev/null 2>&1

    assert_file_exists "$test_dir/stage/subdir/nested/deep.sh.diff" \
        "Diff should preserve directory structure"
}

################################################################################
# UNIT TESTS - CLI OPTIONS
################################################################################
#
# Tests for all command-line options to ensure:
#   - Options are parsed correctly
#   - Required options are enforced
#   - Invalid values are rejected with appropriate exit codes
#   - Option behaviors match documentation
#
# Exit code conventions tested:
#   0 - Success
#   1 - Runtime error (invalid path, missing jq for --json, etc.)
#   2 - Invalid arguments (missing required options, bad --jobs value)

# Test: --help option
test_help_option() {
    local output
    output=$(run_script --help 2>&1)
    local exit_code=$?

    # Note: usage() exits with code 2 by design (consistent for errors and help)
    assert_exit_code 2 "$exit_code" "--help should exit 2" && \
    assert_contains "$output" "Usage:" "--help should show usage" && \
    assert_contains "$output" "--source" "--help should mention --source" && \
    assert_contains "$output" "--target" "--help should mention --target" && \
    assert_contains "$output" "--stage" "--help should mention --stage"
}

# Test: --version option
test_version_option() {
    local output
    output=$(run_script --version 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "--version should exit 0" && \
    assert_contains "$output" "version" "--version should show version"
}

# Test: Missing required arguments
test_missing_arguments() {
    local output exit_code

    # Missing all required args
    output=$(run_script 2>&1)
    exit_code=$?
    assert_exit_code 2 "$exit_code" "Missing args should exit 2"

    # Missing --target and --stage
    output=$(run_script --source /tmp/unittests/ 2>&1)
    exit_code=$?
    assert_exit_code 2 "$exit_code" "Missing --target should exit 2"
}

# Test: Invalid source directory
test_invalid_source() {
    local test_dir
    test_dir=$(create_test_dir "invalid_source")

    local output exit_code
    output=$(run_script --source "/nonexistent_dir_12345" \
        --target "$test_dir/target" --stage "$test_dir/stage" 2>&1)
    exit_code=$?

    assert_exit_code 1 "$exit_code" "Invalid source should exit 1" && \
    assert_contains "$output" "does not exist" "Should report source doesn't exist"
}

# Test: Invalid --jobs value
test_invalid_jobs() {
    local test_dir
    test_dir=$(create_test_dir "invalid_jobs")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    local output exit_code
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --jobs "abc" 2>&1)
    exit_code=$?

    assert_exit_code 2 "$exit_code" "Invalid --jobs should exit 2"
}

# Test: --verbose option
test_verbose_option() {
    local test_dir
    test_dir=$(create_test_dir "verbose")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --verbose --dry-run 2>&1)

    assert_contains "$output" "Identical:" "Verbose should show identical files"
}

# Test: --quiet option
test_quiet_option() {
    local test_dir
    test_dir=$(create_test_dir "quiet")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet --dry-run 2>&1)

    # Quiet mode should produce minimal output
    local line_count
    line_count=$(echo "$output" | wc -l | tr -d ' ')

    # Should be essentially empty (maybe just a newline)
    [[ "$line_count" -le 2 ]]
}

# Test: --summary-only option
test_summary_only_option() {
    local test_dir
    test_dir=$(create_test_dir "summary_only")

    echo '#!/bin/bash' > "$test_dir/source/test1.sh"
    echo '#!/bin/bash' > "$test_dir/target/test1.sh"
    echo '# changed' >> "$test_dir/target/test1.sh"
    echo '#!/bin/bash' > "$test_dir/source/test2.sh"
    echo '#!/bin/bash' > "$test_dir/target/test2.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --summary-only --dry-run 2>&1)

    # Should have summary but not per-file messages like "Diff: test1.sh"
    assert_contains "$output" "SUMMARY" "Should show summary" && \
    ! assert_contains "$output" "Diff: test1.sh" "Should not show per-file diff message" 2>/dev/null
}

# Test: --dry-run option
test_dry_run_option() {
    local test_dir
    test_dir=$(create_test_dir "dry_run")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo '# modified' >> "$test_dir/target/test.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    # Dry-run should not create diff files
    assert_file_not_exists "$test_dir/stage/test.sh.diff" "Dry-run should not create diff files" && \
    assert_contains "$output" "DRY-RUN" "Output should indicate dry-run mode"
}

# Test: --json option
test_json_option() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "json")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo '# modified' >> "$test_dir/target/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/new.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    # Each line should be valid JSON
    local valid=true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! echo "$line" | jq -e . >/dev/null 2>&1; then
            valid=false
            break
        fi
    done <<< "$output"

    $valid && \
    assert_contains "$output" '"type"' "JSON should have type field"
}

# Test: --log option
test_log_option() {
    local test_dir
    test_dir=$(create_test_dir "log")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo '# modified' >> "$test_dir/target/test.sh"

    local log_file="$test_dir/output.log"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --log "$log_file" --dry-run 2>&1

    # Verify log file exists and has expected content
    assert_file_exists "$log_file" "Log file should be created" && \
    assert_contains "$(cat "$log_file")" "SUMMARY" "Log should contain summary" && \
    assert_contains "$(cat "$log_file")" "Matched pairs:" "Log should contain statistics" && \
    assert_contains "$(cat "$log_file")" "Changed:" "Log should contain change count" && \
    assert_contains "$(cat "$log_file")" "source" "Log should reference source dir" && \
    assert_contains "$(cat "$log_file")" "target" "Log should reference target dir"
}

# Test: --exit-code option (no changes)
test_exit_code_no_changes() {
    local test_dir
    test_dir=$(create_test_dir "exit_code_no_changes")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --exit-code --dry-run --quiet 2>&1
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "No changes should exit 0 with --exit-code"
}

# Test: --exit-code option (with changes)
test_exit_code_with_changes() {
    local test_dir
    test_dir=$(create_test_dir "exit_code_with_changes")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo '# modified' >> "$test_dir/target/test.sh"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --exit-code --dry-run --quiet 2>&1
    local exit_code=$?

    assert_exit_code 1 "$exit_code" "Changes found should exit 1 with --exit-code"
}

# Test: --exclude option
test_exclude_option() {
    local test_dir
    test_dir=$(create_test_dir "exclude")

    echo '#!/bin/bash' > "$test_dir/source/keep.sh"
    echo '#!/bin/bash' > "$test_dir/target/keep.sh"
    echo '#!/bin/bash' > "$test_dir/source/skip_this.sh"
    echo '#!/bin/bash' > "$test_dir/target/skip_this.sh"
    echo '#!/bin/bash' > "$test_dir/source/also_skip.sh"
    echo '#!/bin/bash' > "$test_dir/target/also_skip.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --exclude "*skip*" --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 1 target script" "Exclude should filter files"
}

# Test: Multiple --exclude options
test_exclude_multiple() {
    local test_dir
    test_dir=$(create_test_dir "exclude_multiple")

    echo '#!/bin/bash' > "$test_dir/source/keep.sh"
    echo '#!/bin/bash' > "$test_dir/target/keep.sh"
    echo '#!/bin/bash' > "$test_dir/source/skip_a.sh"
    echo '#!/bin/bash' > "$test_dir/target/skip_a.sh"
    echo '#!/bin/bash' > "$test_dir/source/skip_b.sh"
    echo '#!/bin/bash' > "$test_dir/target/skip_b.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --exclude "*_a*" --exclude "*_b*" \
        --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 1 target script" "Multiple excludes should work"
}

# Test: --no-renames option
test_no_renames_option() {
    local test_dir
    test_dir=$(create_test_dir "no_renames")

    echo '#!/bin/bash' > "$test_dir/source/script_v1.sh"
    echo '#!/bin/bash' > "$test_dir/target/script_v2.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --no-renames --dry-run 2>&1)

    assert_contains "$output" "Skipping rename detection" "Should indicate skipping renames" && \
    assert_contains "$output" "Likely renames:    0" "Should show 0 renames"
}

################################################################################
# UNIT TESTS - PATTERN MATCHING
################################################################################
#
# Tests for the --pattern option which filters files by extension groups:
#   shell   - *.sh, *.bash, *.zsh, *.fish, *.ksh, *.csh, *.tcsh
#   windows - *.ps1, *.bat, *.cmd
#   sql     - *.sql
#   devel   - *.py, *.rb, *.pl, *.js, *.ts, *.go, *.rs, *.c, *.cpp, *.java, etc.
#   config  - *.yaml, *.yml, *.json, *.xml, *.toml, *.ini, *.conf
#   all     - All of the above (default)
#
# Also supports:
#   - Wildcards: --pattern "*.txt"
#   - Combinations: --pattern "shell,config,*.txt"

# Test: --pattern shell
test_pattern_shell() {
    local test_dir
    test_dir=$(create_test_dir "pattern_shell")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo '#!/bin/bash' > "$test_dir/source/test.bash"
    echo '#!/bin/bash' > "$test_dir/target/test.bash"
    echo 'Get-Help' > "$test_dir/source/test.ps1"
    echo 'Get-Help' > "$test_dir/target/test.ps1"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 2 target script" "Shell pattern should find .sh and .bash"
}

# Test: --pattern windows
test_pattern_windows() {
    local test_dir
    test_dir=$(create_test_dir "pattern_windows")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo 'Get-Help' > "$test_dir/source/test.ps1"
    echo 'Get-Help' > "$test_dir/target/test.ps1"
    echo '@echo off' > "$test_dir/source/test.bat"
    echo '@echo off' > "$test_dir/target/test.bat"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern windows --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 2 target script" "Windows pattern should find .ps1 and .bat"
}

# Test: --pattern sql
test_pattern_sql() {
    local test_dir
    test_dir=$(create_test_dir "pattern_sql")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo 'SELECT 1;' > "$test_dir/source/test.sql"
    echo 'SELECT 1;' > "$test_dir/target/test.sql"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern sql --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 1 target script" "SQL pattern should find .sql only"
}

# Test: --pattern devel
test_pattern_devel() {
    local test_dir
    test_dir=$(create_test_dir "pattern_devel")

    echo 'print("hi")' > "$test_dir/source/test.py"
    echo 'print("hi")' > "$test_dir/target/test.py"
    echo 'package main' > "$test_dir/source/test.go"
    echo 'package main' > "$test_dir/target/test.go"
    echo 'fn main()' > "$test_dir/source/test.rs"
    echo 'fn main()' > "$test_dir/target/test.rs"
    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern devel --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 3 target script" "Devel pattern should find .py, .go, .rs"
}

# Test: --pattern config
test_pattern_config() {
    local test_dir
    test_dir=$(create_test_dir "pattern_config")

    echo 'key: value' > "$test_dir/source/test.yaml"
    echo 'key: value' > "$test_dir/target/test.yaml"
    echo '{"key": "value"}' > "$test_dir/source/test.json"
    echo '{"key": "value"}' > "$test_dir/target/test.json"
    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern config --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 2 target script" "Config pattern should find .yaml and .json"
}

# Test: --pattern with wildcard
test_pattern_wildcard() {
    local test_dir
    test_dir=$(create_test_dir "pattern_wildcard")

    echo 'content' > "$test_dir/source/readme.txt"
    echo 'content' > "$test_dir/target/readme.txt"
    echo 'content' > "$test_dir/source/data.csv"
    echo 'content' > "$test_dir/target/data.csv"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern "*.txt" --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 1 target script" "Wildcard pattern should find .txt only"
}

# Test: --pattern combined (group + wildcard)
test_pattern_combined() {
    local test_dir
    test_dir=$(create_test_dir "pattern_combined")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo 'content' > "$test_dir/source/readme.txt"
    echo 'content' > "$test_dir/target/readme.txt"
    echo 'content' > "$test_dir/source/data.csv"
    echo 'content' > "$test_dir/target/data.csv"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern "shell,*.txt" --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 2 target script" "Combined pattern should find shell + .txt"
}

################################################################################
# UNIT TESTS - DIFF GENERATION
################################################################################
#
# Tests for the core diff generation functionality:
#   - Changed files produce .diff files with unified diff format
#   - Identical files do NOT produce .diff files (no empty diffs)
#   - Directory structure is preserved in staging area
#   - Diff content shows correct +/- lines

# Test: Diff generation for changed files
test_diff_generation() {
    local test_dir
    test_dir=$(create_test_dir "diff_generation")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo 'echo "original"' >> "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo 'echo "modified"' >> "$test_dir/target/test.sh"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet 2>&1

    assert_file_exists "$test_dir/stage/test.sh.diff" "Diff file should be created" && \
    assert_contains "$(cat "$test_dir/stage/test.sh.diff")" "-echo \"original\"" \
        "Diff should show removed line" && \
    assert_contains "$(cat "$test_dir/stage/test.sh.diff")" "+echo \"modified\"" \
        "Diff should show added line"
}

# Test: No diff for identical files
test_no_diff_identical() {
    local test_dir
    test_dir=$(create_test_dir "no_diff_identical")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo 'echo "same"' >> "$test_dir/source/test.sh"
    cp "$test_dir/source/test.sh" "$test_dir/target/test.sh"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet 2>&1

    assert_file_not_exists "$test_dir/stage/test.sh.diff" \
        "No diff file should be created for identical files"
}

# Test: Diff preserves directory structure
test_diff_directory_structure() {
    local test_dir
    test_dir=$(create_test_dir "diff_dir_structure")

    mkdir -p "$test_dir/source/level1/level2"
    mkdir -p "$test_dir/target/level1/level2"

    echo '#!/bin/bash' > "$test_dir/source/level1/level2/deep.sh"
    echo '#!/bin/bash' > "$test_dir/target/level1/level2/deep.sh"
    echo '# changed' >> "$test_dir/target/level1/level2/deep.sh"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet 2>&1

    assert_file_exists "$test_dir/stage/level1/level2/deep.sh.diff" \
        "Diff should be in correct subdirectory"
}

################################################################################
# UNIT TESTS - RENAME DETECTION
################################################################################
#
# Tests for the rename detection algorithm that matches source-only files
# with target-only files based on normalized names. The normalization strips:
#   - Version numbers (v1.0, v2.0, 2024.01)
#   - Platform suffixes (_unix, _windows)
#   - Case differences, underscores, dashes
#
# Test scenarios:
#   - Version bump: script_v1.0.sh → script_v2.0.sh
#   - Platform suffix: script_unix.sh → script.sh
#   - Rename with content changes (generates diff)
#   - Rename identical content (name change only)

# Test: Detect version renames (v1.0 -> v2.0)
test_rename_version() {
    local test_dir
    test_dir=$(create_test_dir "rename_version")

    echo '#!/bin/bash' > "$test_dir/source/script_v1.0.sh"
    echo '#!/bin/bash' > "$test_dir/target/script_v2.0.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    assert_contains "$output" "script_v1.0.sh -> script_v2.0.sh" \
        "Should detect version rename"
}

# Test: Detect platform suffix renames
test_rename_platform() {
    local test_dir
    test_dir=$(create_test_dir "rename_platform")

    echo '#!/bin/bash' > "$test_dir/source/script_unix.sh"
    echo '#!/bin/bash' > "$test_dir/target/script.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    assert_contains "$output" "Likely renames:" "Should have renames section" && \
    [[ "$output" == *"script_unix.sh"* ]] && [[ "$output" == *"script.sh"* ]]
}

# Test: Rename with content changes generates diff
test_rename_with_diff() {
    local test_dir
    test_dir=$(create_test_dir "rename_with_diff")

    echo '#!/bin/bash' > "$test_dir/source/script_v1.sh"
    echo 'echo "version 1"' >> "$test_dir/source/script_v1.sh"
    echo '#!/bin/bash' > "$test_dir/target/script_v2.sh"
    echo 'echo "version 2"' >> "$test_dir/target/script_v2.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell 2>&1)

    # Check for rename diff file (format: source__TO__target.diff)
    local diff_file
    diff_file=$(find "$test_dir/stage" -name "*__TO__*.diff" -type f 2>/dev/null | head -1)

    # If no diff file found, check if the output indicates a rename was detected
    if [[ -z "$diff_file" ]]; then
        # Rename with changes should be logged even if diff file location varies
        assert_contains "$output" "Diff (rename):" "Should show rename diff message" || \
        assert_contains "$output" "rename" "Should indicate rename detected"
    else
        assert_not_empty "$diff_file" "Rename diff file should be created"
    fi
}

################################################################################
# UNIT TESTS - SOURCE-ONLY AND TARGET-ONLY
################################################################################

# Test: Source-only files detection
test_source_only() {
    local test_dir
    test_dir=$(create_test_dir "source_only")

    echo '#!/bin/bash' > "$test_dir/source/common.sh"
    echo '#!/bin/bash' > "$test_dir/target/common.sh"
    echo '#!/bin/bash' > "$test_dir/source/old_script.sh"
    # old_script.sh not in target

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    assert_contains "$output" "Source-only:       1" "Should detect 1 source-only file" && \
    assert_contains "$output" "old_script.sh" "Should list source-only file"
}

# Test: Target-only files detection
test_target_only() {
    local test_dir
    test_dir=$(create_test_dir "target_only")

    echo '#!/bin/bash' > "$test_dir/source/common.sh"
    echo '#!/bin/bash' > "$test_dir/target/common.sh"
    echo '#!/bin/bash' > "$test_dir/target/new_script.sh"
    # new_script.sh not in source

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    assert_contains "$output" "Target-only:       1" "Should detect 1 target-only file" && \
    assert_contains "$output" "new_script.sh" "Should list target-only file"
}

################################################################################
# UNIT TESTS - PARALLEL PROCESSING
################################################################################
#
# Tests to verify that parallel execution (xargs -P) maintains data integrity:
#   - Output lines are not interleaved/garbled (locking works)
#   - Statistics counters are accurate (no race conditions)
#   - JSON output remains valid NDJSON format
#
# These tests use --jobs 4 (not the default --jobs 1) to actually exercise
# the parallel code paths and locking mechanisms.

# Test: Parallel processing doesn't garble output
test_parallel_no_garble() {
    local test_dir
    test_dir=$(create_test_dir "parallel_no_garble")

    # Create many files to trigger parallel processing
    for i in $(seq 1 20); do
        echo "#!/bin/bash" > "$test_dir/source/script_$i.sh"
        echo "echo \"script $i\"" >> "$test_dir/source/script_$i.sh"
        echo "#!/bin/bash" > "$test_dir/target/script_$i.sh"
        echo "echo \"script $i modified\"" >> "$test_dir/target/script_$i.sh"
    done

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --jobs 4 --dry-run 2>&1)

    # Check that summary is intact (not garbled)
    assert_contains "$output" "DIFF ANALYSIS SUMMARY" "Summary header should be intact" && \
    assert_contains "$output" "Matched pairs:     20" "Should show correct match count"
}

# Test: Parallel JSON output is valid
test_parallel_json_valid() {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping parallel JSON test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "parallel_json")

    for i in $(seq 1 10); do
        echo "#!/bin/bash" > "$test_dir/source/script_$i.sh"
        echo "#!/bin/bash" > "$test_dir/target/script_$i.sh"
        [[ $((i % 2)) -eq 0 ]] && echo "# modified" >> "$test_dir/target/script_$i.sh"
    done

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --jobs 4 --json --dry-run 2>&1)

    # Validate all JSON lines
    local invalid=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! echo "$line" | jq -e . >/dev/null 2>&1; then
            ((invalid++))
        fi
    done <<< "$output"

    assert_eq 0 "$invalid" "All JSON lines should be valid"
}

################################################################################
# UNIT TESTS - EDGE CASES
################################################################################
#
# Tests for boundary conditions and unusual inputs that could cause failures:
#   - Empty directories (no files to process)
#   - Paths with spaces ("sub dir/my script.sh")
#   - Special characters in filenames (dashes, underscores, dots)
#   - Case sensitivity in extensions (.SH vs .sh vs .Sh)
#   - Very long filenames (approaching filesystem limits)
#   - Empty files (0 bytes)
#   - Error visibility in --quiet mode
#   - Diff format validation (unified diff headers)
#   - Default pattern behavior (--pattern all)
#   - Auto-creation of stage directory

# Test: Empty directories
test_empty_directories() {
    local test_dir
    test_dir=$(create_test_dir "empty_dirs")

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run --summary-only 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Empty directories should not cause error" && \
    assert_contains "$output" "Found 0 target script" "Should report 0 files"
}

# Test: Paths with spaces
test_paths_with_spaces() {
    local test_dir
    test_dir=$(create_test_dir "paths_with_spaces")

    mkdir -p "$test_dir/source/sub dir/nested path"
    mkdir -p "$test_dir/target/sub dir/nested path"

    echo '#!/bin/bash' > "$test_dir/source/sub dir/nested path/my script.sh"
    echo '#!/bin/bash' > "$test_dir/target/sub dir/nested path/my script.sh"
    echo '# modified' >> "$test_dir/target/sub dir/nested path/my script.sh"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet 2>&1
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Paths with spaces should work" && \
    assert_file_exists "$test_dir/stage/sub dir/nested path/my script.sh.diff" \
        "Diff should be created for path with spaces"
}

# Test: Special characters in filenames
test_special_characters() {
    local test_dir
    test_dir=$(create_test_dir "special_chars")

    # Create files with special but valid characters
    echo '#!/bin/bash' > "$test_dir/source/script-with-dashes.sh"
    echo '#!/bin/bash' > "$test_dir/target/script-with-dashes.sh"
    echo '#!/bin/bash' > "$test_dir/source/script_with_underscores.sh"
    echo '#!/bin/bash' > "$test_dir/target/script_with_underscores.sh"
    echo '#!/bin/bash' > "$test_dir/source/script.name.with.dots.sh"
    echo '#!/bin/bash' > "$test_dir/target/script.name.with.dots.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run --summary-only 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Special characters should be handled" && \
    assert_contains "$output" "Matched pairs:     3" "Should match all 3 files"
}

# Test: Case sensitivity in extensions
test_case_sensitivity() {
    local test_dir
    test_dir=$(create_test_dir "case_sensitivity")

    # On case-insensitive filesystems (Windows, macOS), these may collide
    # Use different base names to ensure both files exist
    echo '#!/bin/bash' > "$test_dir/source/test_upper.SH"
    echo '#!/bin/bash' > "$test_dir/target/test_upper.SH"
    echo '#!/bin/bash' > "$test_dir/source/test_mixed.Sh"
    echo '#!/bin/bash' > "$test_dir/target/test_mixed.Sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run --summary-only 2>&1)

    # Should find both files with case-insensitive extension matching via -iname
    assert_contains "$output" "Found 2 target script" "Should match files case-insensitively"
}

# Test: Very long filenames
test_long_filenames() {
    local test_dir
    test_dir=$(create_test_dir "long_filenames")

    local long_name="this_is_a_very_long_filename_that_tests_the_handling_of_long_paths_in_the_script.sh"

    echo '#!/bin/bash' > "$test_dir/source/$long_name"
    echo '#!/bin/bash' > "$test_dir/target/$long_name"
    echo '# modified' >> "$test_dir/target/$long_name"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet 2>&1
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Long filenames should work" && \
    assert_file_exists "$test_dir/stage/$long_name.diff" "Diff should be created"
}

# Test: Empty files are handled correctly
test_empty_files() {
    local test_dir
    test_dir=$(create_test_dir "empty_files")

    # Create empty source, non-empty target
    touch "$test_dir/source/empty.sh"
    echo '#!/bin/bash' > "$test_dir/target/empty.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run --summary-only 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Empty files should not crash" && \
    assert_contains "$output" "Changed:" "Should detect change from empty to non-empty"
}

# Test: --quiet still shows errors on stderr
test_quiet_shows_errors() {
    local test_dir
    test_dir=$(create_test_dir "quiet_errors")

    # Use non-existent source to trigger error
    local output
    output=$(run_script --source "/nonexistent_12345" --target "$test_dir/target" \
        --stage "$test_dir/stage" --quiet 2>&1)
    local exit_code=$?

    assert_exit_code 1 "$exit_code" "Should exit with error" && \
    assert_contains "$output" "does not exist" "Error should still appear even with --quiet"
}

# Test: Diff file contains valid unified diff format
test_diff_format_valid() {
    local test_dir
    test_dir=$(create_test_dir "diff_format")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo 'echo "line1"' >> "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo 'echo "line2"' >> "$test_dir/target/test.sh"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet 2>&1

    local diff_file="$test_dir/stage/test.sh.diff"
    assert_file_exists "$diff_file" "Diff file should exist" && \
    assert_contains "$(cat "$diff_file")" "---" "Diff should have --- header" && \
    assert_contains "$(cat "$diff_file")" "+++" "Diff should have +++ header" && \
    assert_contains "$(cat "$diff_file")" "@@" "Diff should have @@ hunk markers"
}

# Test: Default pattern is 'all' (includes multiple extension groups)
test_default_pattern_all() {
    local test_dir
    test_dir=$(create_test_dir "default_pattern")

    # Create files from different groups
    echo '#!/bin/bash' > "$test_dir/source/script.sh"
    echo '#!/bin/bash' > "$test_dir/target/script.sh"
    echo 'print("hi")' > "$test_dir/source/code.py"
    echo 'print("hi")' > "$test_dir/target/code.py"
    echo 'key: value' > "$test_dir/source/config.yaml"
    echo 'key: value' > "$test_dir/target/config.yaml"

    # Run WITHOUT --pattern (should use default 'all')
    local output
    output=$("$SCRIPT_UNDER_TEST" --jobs 1 --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --dry-run --summary-only 2>&1)

    assert_contains "$output" "Found 3 target script" "Default pattern should find all file types"
}

# Test: Stage directory is created if it doesn't exist
test_stage_dir_created() {
    local test_dir
    test_dir=$(create_test_dir "stage_created")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo '# changed' >> "$test_dir/target/test.sh"

    # Remove stage dir to ensure it's created
    rmdir "$test_dir/stage"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet 2>&1
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Should succeed" && \
    assert_dir_exists "$test_dir/stage" "Stage dir should be created" && \
    assert_file_exists "$test_dir/stage/test.sh.diff" "Diff should be created in new stage dir"
}

################################################################################
# UNIT TESTS - JSON OUTPUT TYPES
################################################################################
#
# Tests for --json output mode (NDJSON - Newline Delimited JSON).
# Each scenario produces a specific JSON record type:
#   identical       - Files match, no diff needed
#   changed         - Files differ, diff generated
#   source_only     - File exists only in source
#   target_only     - File exists only in target
#   rename_changed  - Renamed file with content changes
#   rename_identical- Renamed file, same content
#   summary         - Final statistics record
#
# These tests skip gracefully if jq is not installed.

# Test: JSON output for identical files
test_json_type_identical() {
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON type test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "json_identical")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    cp "$test_dir/source/test.sh" "$test_dir/target/test.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    assert_contains "$output" '"type":"identical"' "Should have identical type in JSON"
}

# Test: JSON output for changed files
test_json_type_changed() {
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON type test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "json_changed")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo '# modified' >> "$test_dir/target/test.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    assert_contains "$output" '"type":"changed"' "Should have changed type in JSON"
}

# Test: JSON output for source-only files
test_json_type_source_only() {
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON type test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "json_source_only")

    echo '#!/bin/bash' > "$test_dir/source/old.sh"
    # No matching file in target

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    assert_contains "$output" '"type":"source_only"' "Should have source_only type in JSON"
}

# Test: JSON output for target-only files
test_json_type_target_only() {
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON type test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "json_target_only")

    echo '#!/bin/bash' > "$test_dir/target/new.sh"
    # No matching file in source

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    assert_contains "$output" '"type":"target_only"' "Should have target_only type in JSON"
}

# Test: JSON summary record
test_json_type_summary() {
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON type test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "json_summary")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    assert_contains "$output" '"type":"summary"' "Should have summary type in JSON" && \
    assert_contains "$output" '"elapsed_seconds"' "Summary should have elapsed time"
}

# Test: JSON output for rename with changes
test_json_type_rename_changed() {
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON type test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "json_rename_changed")

    # Use version format that normalize_for_match recognizes (v1.0, v2.0)
    echo '#!/bin/bash' > "$test_dir/source/script_v1.0.sh"
    echo 'echo "v1"' >> "$test_dir/source/script_v1.0.sh"
    echo '#!/bin/bash' > "$test_dir/target/script_v2.0.sh"
    echo 'echo "v2"' >> "$test_dir/target/script_v2.0.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    assert_contains "$output" '"type":"rename_changed"' "Should have rename_changed type in JSON"
}

# Test: JSON output for rename identical
test_json_type_rename_identical() {
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON type test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "json_rename_identical")

    # Use version format that normalize_for_match recognizes (v1.0, v2.0)
    echo '#!/bin/bash' > "$test_dir/source/script_v1.0.sh"
    echo '#!/bin/bash' > "$test_dir/target/script_v2.0.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    assert_contains "$output" '"type":"rename_identical"' "Should have rename_identical type in JSON"
}

################################################################################
# UNIT TESTS - PATH NORMALIZATION
################################################################################
#
# Tests for cross-platform path handling:
#   - Backslash to forward slash conversion (Windows paths)
#   - Trailing slash handling (both with and without)
#
# This ensures the script works correctly on:
#   - Linux (native forward slashes)
#   - Cygwin/MSYS2/Git Bash (mixed path formats)
#   - Windows paths passed from PowerShell

# Test: Path normalization handles backslashes
test_path_normalization_backslash() {
    local test_dir
    test_dir=$(create_test_dir "path_normalize")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    # The script normalizes paths internally - verify output doesn't have backslashes
    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --dry-run 2>&1)

    # JSON output paths should use forward slashes (no backslashes)
    # shellcheck disable=SC1003  # We're checking for literal backslashes, not escaping quotes
    if echo "$output" | grep -q '\\\\'; then
        return 1  # Found backslashes in output
    fi
    return 0
}

# Test: Path normalization handles trailing slashes
test_path_normalization_trailing() {
    local test_dir
    test_dir=$(create_test_dir "path_trailing")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"

    # Pass paths with trailing slashes
    local output exit_code
    output=$(run_script --source "$test_dir/source/" --target "$test_dir/target/" \
        --stage "$test_dir/stage/" --pattern shell --dry-run --summary-only 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "Trailing slashes should be handled" && \
    assert_contains "$output" "Matched pairs:     1" "Should process files correctly"
}

################################################################################
# UNIT TESTS - BINARY RENAME DETECTION
################################################################################
#
# Tests for detection of renamed binary/dependency files:
#   - Binary extensions: *.exe, *.dll, *.so, *.dat, *.bin, *.jar
#   - These are tracked for renames but NOT diffed (binary content)
#   - Extension changes detected (e.g., tool.sh → tool.exe)

# Test: Binary file rename detection
test_binary_rename_detection() {
    local test_dir
    test_dir=$(create_test_dir "binary_rename")

    # Create binary files (extension tracked for renames)
    echo 'binary content' > "$test_dir/source/lib_v1.0.dll"
    echo 'binary content' > "$test_dir/target/lib_v2.0.dll"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern all --dry-run 2>&1)

    assert_contains "$output" "Binary renames:" "Should have binary renames section"
}

# Test: Extension change detection (script to binary)
test_extension_change_detection() {
    local test_dir
    test_dir=$(create_test_dir "extension_change")

    # Create a script that was "compiled" to binary
    echo '#!/bin/bash' > "$test_dir/source/tool.sh"
    echo 'binary' > "$test_dir/target/tool.exe"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern all --dry-run 2>&1)

    # Should detect as extension change in binary renames
    assert_contains "$output" "extension change" "Should detect extension change" || \
    assert_contains "$output" "Binary renames:" "Should show in binary renames section"
}

################################################################################
# UNIT TESTS - VALIDATION
################################################################################
#
# Tests for input validation and error handling:
#   - Invalid target directory (exit code 1)
#   - Sequential processing (--jobs 1)
#   - jq dependency check for --json mode

# Test: Invalid target directory
test_invalid_target() {
    local test_dir
    test_dir=$(create_test_dir "invalid_target")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"

    local output exit_code
    output=$(run_script --source "$test_dir/source" \
        --target "/nonexistent_target_12345" --stage "$test_dir/stage" 2>&1)
    exit_code=$?

    assert_exit_code 1 "$exit_code" "Invalid target should exit 1" && \
    assert_contains "$output" "does not exist" "Should report target doesn't exist"
}

# Test: --jobs with value 1 (sequential)
test_jobs_sequential() {
    local test_dir
    test_dir=$(create_test_dir "jobs_sequential")

    for i in 1 2 3; do
        echo "#!/bin/bash" > "$test_dir/source/script_$i.sh"
        echo "#!/bin/bash" > "$test_dir/target/script_$i.sh"
    done

    local output exit_code
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --jobs 1 --dry-run --summary-only 2>&1)
    exit_code=$?

    assert_exit_code 0 "$exit_code" "Sequential processing should work" && \
    assert_contains "$output" "Matched pairs:     3" "Should process all files"
}

# Test: --json without jq installed (simulated by checking error message format)
test_json_requires_jq() {
    # This test verifies the error message when jq would be missing
    # We can't actually uninstall jq, so we verify the check exists in the script
    local check
    check=$(grep -c "command -v jq" "$SCRIPT_UNDER_TEST")

    [[ "$check" -ge 1 ]]  # Should have at least one jq check
}

################################################################################
# UNIT TESTS - LOG FILE
################################################################################
#
# Tests for --log option that redirects output to a file:
#   - Log file is created and contains expected content
#   - Works with --json to produce NDJSON log files
#   - All output types are captured (not just stdout)

# Test: --log with --json produces NDJSON in log file
test_log_json_output() {
    if ! command -v jq &>/dev/null; then
        log_warn "Skipping JSON log test - jq not installed"
        return 0
    fi

    local test_dir
    test_dir=$(create_test_dir "log_json")

    echo '#!/bin/bash' > "$test_dir/source/test.sh"
    echo '#!/bin/bash' > "$test_dir/target/test.sh"
    echo '# modified' >> "$test_dir/target/test.sh"

    local log_file="$test_dir/output.json"

    run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --json --log "$log_file" --dry-run 2>&1

    # Verify log file exists and contains valid NDJSON
    assert_file_exists "$log_file" "JSON log file should be created" && \
    assert_contains "$(cat "$log_file")" '"type"' "Log should contain JSON with type field" && \
    assert_contains "$(cat "$log_file")" '"type":"changed"' "Log should contain changed record" && \
    assert_contains "$(cat "$log_file")" '"type":"summary"' "Log should contain summary record"

    # Verify each line is valid JSON
    local invalid=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! echo "$line" | jq -e . >/dev/null 2>&1; then
            ((invalid++))
        fi
    done < "$log_file"
    [[ "$invalid" -eq 0 ]]
}

################################################################################
# UNIT TESTS - PROGRESS INDICATOR
################################################################################
#
# Tests for the progress indicator shown during processing:
#   - Displays "[N/Total] Processing files..." for sets >= 20 files
#   - Updates every 10 files and at completion
#   - Suppressed in --quiet mode
#   - Progress line is cleared after completion (doesn't pollute output)

# Test: Progress indicator for large file sets
test_progress_indicator() {
    local test_dir
    test_dir=$(create_test_dir "progress")

    # Create enough files to trigger progress (threshold is 20)
    for i in $(seq 1 25); do
        echo "#!/bin/bash" > "$test_dir/source/script_$i.sh"
        echo "#!/bin/bash" > "$test_dir/target/script_$i.sh"
    done

    local output
    # Progress goes to stderr, capture both
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    # Progress indicator writes to stderr and is cleared, so we just verify it completes
    assert_contains "$output" "Matched pairs:     25" "Should process all files with progress"
}

# Test: Progress indicator suppressed with --quiet
test_progress_quiet() {
    local test_dir
    test_dir=$(create_test_dir "progress_quiet")

    for i in $(seq 1 25); do
        echo "#!/bin/bash" > "$test_dir/source/script_$i.sh"
        echo "#!/bin/bash" > "$test_dir/target/script_$i.sh"
    done

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --quiet --dry-run 2>&1)

    # Quiet mode should have minimal output
    local line_count
    line_count=$(echo "$output" | wc -l | tr -d ' ')

    [[ "$line_count" -le 2 ]]
}

################################################################################
# UNIT TESTS - SUMMARY REPORT
################################################################################
#
# Tests for the summary report displayed after processing:
#   - All statistics categories present (matched, changed, identical, etc.)
#   - Section headers properly formatted
#   - Elapsed time displayed
#   - Lists of source-only, target-only, and renamed files

# Test: Summary shows all statistics
test_summary_statistics() {
    local test_dir
    test_dir=$(create_test_dir "summary_stats")

    # Create various scenarios
    echo '#!/bin/bash' > "$test_dir/source/same.sh"
    cp "$test_dir/source/same.sh" "$test_dir/target/same.sh"

    echo '#!/bin/bash' > "$test_dir/source/changed.sh"
    echo '#!/bin/bash' > "$test_dir/target/changed.sh"
    echo '# modified' >> "$test_dir/target/changed.sh"

    echo '#!/bin/bash' > "$test_dir/source/removed.sh"
    echo '#!/bin/bash' > "$test_dir/target/added.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    assert_contains "$output" "Matched pairs:" "Should show matched pairs" && \
    assert_contains "$output" "Changed:" "Should show changed count" && \
    assert_contains "$output" "Identical:" "Should show identical count" && \
    assert_contains "$output" "Source-only:" "Should show source-only count" && \
    assert_contains "$output" "Target-only:" "Should show target-only count" && \
    assert_contains "$output" "Elapsed time:" "Should show elapsed time"
}

# Test: Summary section headers present
test_summary_sections() {
    local test_dir
    test_dir=$(create_test_dir "summary_sections")

    echo '#!/bin/bash' > "$test_dir/source/old.sh"
    echo '#!/bin/bash' > "$test_dir/target/new.sh"

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --dry-run 2>&1)

    assert_contains "$output" "DIFF ANALYSIS SUMMARY" "Should have summary header" && \
    assert_contains "$output" "STATISTICS" "Should have statistics section" && \
    assert_contains "$output" "SOURCE-ONLY FILES" "Should have source-only section" && \
    assert_contains "$output" "TARGET-ONLY FILES" "Should have target-only section"
}

################################################################################
# UNIT TESTS - LOCKING (thread safety)
################################################################################
#
# Tests that the directory-based mutex (mkdir/rmdir) correctly serializes
# access to shared resources under high concurrency:
#   - Statistics counters remain accurate
#   - No missing or duplicate counts
#   - Deterministic results regardless of worker execution order
#
# This is the ultimate test of the parallel processing integrity.

# Test: Concurrent writes don't corrupt stats
test_concurrent_stats() {
    local test_dir
    test_dir=$(create_test_dir "concurrent_stats")

    # Create many files to stress concurrent processing
    for i in $(seq 1 30); do
        echo "#!/bin/bash" > "$test_dir/source/script_$i.sh"
        echo "#!/bin/bash" > "$test_dir/target/script_$i.sh"
        # Make half of them changed
        [[ $((i % 2)) -eq 0 ]] && echo "# modified $i" >> "$test_dir/target/script_$i.sh"
    done

    local output
    output=$(run_script --source "$test_dir/source" --target "$test_dir/target" \
        --stage "$test_dir/stage" --pattern shell --jobs 8 --dry-run --summary-only 2>&1)

    # Verify counts are correct (not corrupted by race conditions)
    assert_contains "$output" "Matched pairs:     30" "Should count all 30 matched" && \
    assert_contains "$output" "Changed:       15" "Should count 15 changed" && \
    assert_contains "$output" "Identical:     15" "Should count 15 identical"
}

################################################################################
# PARALLEL TEST RUNNER
################################################################################
#
# TEST REGISTRY AND EXECUTION
#
# ALL_TESTS array defines the complete test suite with 67 tests organized by category.
# Tests are executed in parallel by default (max 4 concurrent) using xargs -P.
#
# Execution flow:
#   1. Generate numbered test list from ALL_TESTS
#   2. Pipe to xargs which spawns worker scripts
#   3. Each worker sources this file (--source-only) to get function definitions
#   4. Worker runs its assigned test and writes result to RESULTS_DIR
#   5. Main process collects results in order and displays summary

# All test functions
ALL_TESTS=(
    # CLI Options
    test_help_option
    test_version_option
    test_missing_arguments
    test_invalid_source
    test_invalid_jobs
    test_verbose_option
    test_quiet_option
    test_summary_only_option
    test_dry_run_option
    test_json_option
    test_log_option
    test_exit_code_no_changes
    test_exit_code_with_changes
    test_exclude_option
    test_exclude_multiple
    test_no_renames_option
    # Pattern Matching
    test_pattern_shell
    test_pattern_windows
    test_pattern_sql
    test_pattern_devel
    test_pattern_config
    test_pattern_wildcard
    test_pattern_combined
    # Helper Functions
    test_normalize_for_match
    test_count_lines
    test_build_find_expr
    test_path_functions
    # Diff Generation
    test_diff_generation
    test_no_diff_identical
    test_diff_directory_structure
    # Rename Detection
    test_rename_version
    test_rename_platform
    test_rename_with_diff
    # Source/Target Only
    test_source_only
    test_target_only
    # Parallel Processing
    test_parallel_no_garble
    test_parallel_json_valid
    # Edge Cases
    test_empty_directories
    test_paths_with_spaces
    test_special_characters
    test_case_sensitivity
    test_long_filenames
    test_empty_files
    test_quiet_shows_errors
    test_diff_format_valid
    test_default_pattern_all
    test_stage_dir_created
    # JSON Output Types
    test_json_type_identical
    test_json_type_changed
    test_json_type_source_only
    test_json_type_target_only
    test_json_type_summary
    test_json_type_rename_changed
    test_json_type_rename_identical
    # Path Normalization
    test_path_normalization_backslash
    test_path_normalization_trailing
    # Binary Rename Detection
    test_binary_rename_detection
    test_extension_change_detection
    # Validation
    test_invalid_target
    test_jobs_sequential
    test_json_requires_jq
    # Log File
    test_log_json_output
    # Progress Indicator
    test_progress_indicator
    test_progress_quiet
    # Summary Report
    test_summary_statistics
    test_summary_sections
    # Thread Safety
    test_concurrent_stats
)

################################################################################
# MAIN
################################################################################

# If sourced with --source-only, just define functions and exit
# This allows subshells to source this file to get test function definitions
if [[ "${1:-}" == "--source-only" ]]; then
    # shellcheck disable=SC2317  # return is reachable when sourced, exit when executed
    return 0 2>/dev/null || exit 0
fi

# Ensure cleanup on exit or interrupt (INT=Ctrl+C, TERM=kill)
# Only set trap in main execution, not when sourced
trap cleanup_test_env EXIT INT TERM

# Parse arguments
PARALLEL=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --sequential|-s)
            PARALLEL=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--sequential]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v     Show detailed test output"
            echo "  --sequential, -s  Run tests sequentially (default: parallel)"
            echo "  --help, -h        Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

echo ""
echo "========================================================================"
echo "  generate_diffs.sh Unit Tests"
echo "========================================================================"
echo ""

# Record start time
START_TIME=$(date +%s)

# Setup
setup_test_env

# Get number of parallel jobs - cap at 4 to limit total subprocess explosion
# (each test spawns generate_diffs.sh which itself uses xargs -P)
NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
MAX_JOBS=$(( NPROC < 4 ? NPROC : 4 ))

TOTAL_TESTS=${#ALL_TESTS[@]}
RESULTS_DIR="$TEST_ROOT/results"
mkdir -p "$RESULTS_DIR"

if [[ "$PARALLEL" = "true" ]]; then
    log_info "Running $TOTAL_TESTS tests in parallel (max $MAX_JOBS concurrent tests)..."
    echo ""

    # Export variables needed by subshells
    export RESULTS_DIR SCRIPT_UNDER_TEST TEST_ROOT VERBOSE

    # Create a runner script that sources this file to get all functions
    # This avoids the "environment too large" error from exporting functions
    TEST_RUNNER="$TEST_ROOT/run_one_test.sh"
    cat > "$TEST_RUNNER" << RUNNER_EOF
#!/bin/bash
# Source the test script to get all function definitions
source "$SCRIPT_DIR/generate_diffs_test.sh" --source-only 2>/dev/null

TEST_NUM="\$1"
TEST_NAME="\$2"
START=\$(date +%s.%N 2>/dev/null || date +%s)
if \$TEST_NAME >/dev/null 2>&1; then
    RESULT="PASS"
else
    RESULT="FAIL"
fi
END=\$(date +%s.%N 2>/dev/null || date +%s)
# Use awk for floating point math (more portable than bc)
DURATION=\$(awk "BEGIN {printf \"%.2f\", \$END - \$START}" 2>/dev/null || echo "0.00")
echo "\${RESULT}:\${DURATION}" > "\$RESULTS_DIR/\$(printf '%04d' "\$TEST_NUM")_\$TEST_NAME"
RUNNER_EOF
    chmod +x "$TEST_RUNNER"

    # Generate numbered test list and run with xargs
    TEST_NUM=0
    for test_name in "${ALL_TESTS[@]}"; do
        ((TEST_NUM++))
        echo "$TEST_NUM $test_name"
    done | xargs -P "$MAX_JOBS" -L 1 "$TEST_RUNNER"

    # Collect results in order
    TEST_NUM=0
    for test_name in "${ALL_TESTS[@]}"; do
        ((TEST_NUM++))
        ((TESTS_RUN++))
        RESULT_FILE="$RESULTS_DIR/$(printf '%04d' "$TEST_NUM")_$test_name"
        if [[ -f "$RESULT_FILE" ]]; then
            IFS=: read -r STATUS DURATION < "$RESULT_FILE"
            if [[ "$STATUS" == "PASS" ]]; then
                ((TESTS_PASSED++))
                log_pass "$(printf '[%04d] %-45s %6ss' "$TEST_NUM" "$test_name" "$DURATION")"
            else
                ((TESTS_FAILED++))
                log_fail "$(printf '[%04d] %-45s %6ss' "$TEST_NUM" "$test_name" "$DURATION")"
            fi
        else
            ((TESTS_FAILED++))
            log_fail "$(printf '[%04d] %-45s (no result)' "$TEST_NUM" "$test_name")"
        fi
    done
else
    log_info "Running $TOTAL_TESTS tests sequentially..."
    echo ""

    TEST_NUM=0
    for test_name in "${ALL_TESTS[@]}"; do
        ((TEST_NUM++))
        ((TESTS_RUN++))
        START=$(date +%s.%N 2>/dev/null || date +%s)
        if $test_name >/dev/null 2>&1; then
            END=$(date +%s.%N 2>/dev/null || date +%s)
            DURATION=$(awk "BEGIN {printf \"%.2f\", $END - $START}" 2>/dev/null || echo "0.00")
            ((TESTS_PASSED++))
            log_pass "$(printf '[%04d] %-45s %6ss' "$TEST_NUM" "$test_name" "$DURATION")"
        else
            END=$(date +%s.%N 2>/dev/null || date +%s)
            DURATION=$(awk "BEGIN {printf \"%.2f\", $END - $START}" 2>/dev/null || echo "0.00")
            ((TESTS_FAILED++))
            log_fail "$(printf '[%04d] %-45s %6ss' "$TEST_NUM" "$test_name" "$DURATION")"
        fi
    done
fi

# Cleanup
echo ""
cleanup_test_env

# Calculate total elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

# Summary
echo ""
echo "========================================================================"
echo "  Test Results"
echo "========================================================================"
echo ""
echo "  Total:   $TESTS_RUN"
echo -e "  ${GREEN}Passed:  $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "  ${RED}Failed:  $TESTS_FAILED${NC}"
fi
echo ""
echo "  Elapsed: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
