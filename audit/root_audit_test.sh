#!/bin/bash
# -----------------------------------------------------------------------------
# Unit test suite for root_audit.sh (root_audit_test.sh)
# v1.0.0xg  2026/04/23  XDG
#
# ==============================================================================
# SCRIPT: root_audit_test.sh
# OBJECTIVE: Comprehensive Unit Testing for the root_audit.sh utility.
# 
# CORE COMPONENTS:
#   1. Isolated Workspace Manager: Creates ephemeral, sandboxed environments.
#   2. Mock Engine: Overrides system utilities (getent, chpasswd, sshd, etc.).
#   3. Assertion Library: Standardized true/false/exit-code validation.
#   4. Test Matrix: Covers 29 high-level security scenarios.
#
# FUNCTIONALITY:
#   - Validates password complexity policies.
#   - Simulates filesystem states (immutable flags, backup creation).
#   - Verifies the sudo safety "kill-switch" across multiple configurations.
#   - Tests CLI flow control, exit codes, and environment variable injection.
#   - Ensures total isolation (no host system modification).
#   - Validates JSON output mode for CI/CD compatibility.
#
# DATA FLOW:
#   Setup (Sandbox) -> Mock Definition -> Source Utility -> 
#   Sequential Test Execution -> Assertion Checks -> Cleanup (Trap).
# ==============================================================================

# Setup Workspace: Ensures tests run in a predictable, non-destructive environment.
TMPDIR="${TMPDIR:-/tmp}"
WORKSPACE="${TMPDIR}/unitests/$(uuidgen)"
mkdir -p "${WORKSPACE}/sudoers.d"

# Cleanup on exit: Automatic removal of the sandboxed workspace.
trap 'rm -rf "${WORKSPACE}"' EXIT

SCRIPT_PATH="$(dirname "$0")/root_audit.sh"

# UI Colors
GREEN='\e[32m'
RED='\e[31m'
NC='\e[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Mock Files: Virtual system files used to simulate /etc configuration.
MOCK_SSH_CONFIG="${WORKSPACE}/ssh_config"
MOCK_SHADOW="${WORKSPACE}/shadow"
MOCK_SUDOERS="${WORKSPACE}/sudoers"
touch "${MOCK_SSH_CONFIG}" "${MOCK_SHADOW}" "${MOCK_SUDOERS}"

# --- Assertion Library ---

assert_true() {
    # Objective: Verify that a command returns success (0).
    local cmd="$1"
    local msg="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo -e "[${GREEN}PASS${NC}] $msg"
        ((TESTS_PASSED++))
    else
        echo -e "[${RED}FAIL${NC}] $msg"
        ((TESTS_FAILED++))
    fi
}

assert_false() {
    # Objective: Verify that a command returns failure (!= 0).
    local cmd="$1"
    local msg="$2"
    if ! eval "$cmd" >/dev/null 2>&1; then
        echo -e "[${GREEN}PASS${NC}] $msg"
        ((TESTS_PASSED++))
    else
        echo -e "[${RED}FAIL${NC}] $msg"
        ((TESTS_FAILED++))
    fi
}

assert_exit() {
    # Objective: Verify that a function/command returns a specific exit code.
    local cmd="$1"
    local expected="$2"
    local msg="$3"
    set +e
    eval "$cmd" >/dev/null 2>&1
    local actual=$?
    if [[ $actual -eq $expected ]]; then
        echo -e "[${GREEN}PASS${NC}] $msg (Exit: $actual)"
        ((TESTS_PASSED++))
    else
        echo -e "[${RED}FAIL${NC}] $msg (Expected: $expected, Actual: $actual)"
        ((TESTS_FAILED++))
    fi
}

# --- System Mocks ---
# These functions override standard Linux binaries to simulate various system states.

chpasswd() { echo "MOCK chpasswd" >&2; }
passwd() { echo "MOCK passwd" >&2; }
systemctl() { return 0; }
date() { echo "20260423140000"; }
chattr() { echo "MOCK chattr" >&2; }
lsattr() {
    # Simulates the output of lsattr based on a toggle variable.
    [[ "${MOCK_IMMUTABLE:-false}" == "true" ]] && echo "----i--------- $1" || echo "-------------- $1"
}

getent() {
    # Simulates group membership checks for wheel/sudo groups.
    if [[ "$1" == "group" ]]; then
        if [[ "$2" == "wheel" && "${MOCK_WHEEL:-}" == "true" ]]; then
            echo "wheel:x:10:adminuser"
        elif [[ "$2" == "sudo" && "${MOCK_SUDO_GRP:-}" == "true" ]]; then
            echo "sudo:x:27:ubuntuser"
        else
            return 1
        fi
    fi
}

# Override environment for the script: Points the target utility to our mock sandbox.
export SSH_CONFIG="${MOCK_SSH_CONFIG}"
export SHADOW_FILE="${MOCK_SHADOW}"
export SUDOERS_FILE="${MOCK_SUDOERS}"
export SUDOERS_DIR="${WORKSPACE}/sudoers.d"

# Source the target script: Loads functions into the current shell for testing.
source "${SCRIPT_PATH}"
set +e

# Security Bypass: Redefine check_root to allow tests to run as non-root users.
check_root() { [[ "${MOCK_EUID:-0}" -ne 0 ]] && return 1 || return 0; }

echo -e "--- Workspace: ${WORKSPACE} ---"
echo -e "--- Starting Full-Spectrum Unit Tests (v6: JSON+) ---\n"

# --- Test Matrix Execution ---

# 1. validate_password: Policy compliance validation.
echo "Testing validate_password Policy:"
assert_true  "validate_password 'ValidPass12345678901234567890123#'" "Policy: Accepts valid password"
assert_false "validate_password 'short'" "Policy: Rejects short password"
assert_false "validate_password 'alllowercase12345678901234567890#'" "Policy: Rejects missing uppercase"
assert_false "validate_password 'ALLUPPERCASE12345678901234567890#'" "Policy: Rejects missing lowercase"
assert_false "validate_password 'NoSpecialChars1234567890123456789'" "Policy: Rejects missing special chars"

# 2. Attributes & Backups: Filesystem state management validation.
echo -e "\nTesting Filesystem Safety:"
MOCK_IMMUTABLE="true"
assert_true "is_immutable '${MOCK_SHADOW}'" "Safety: Detects immutable flag"
WAS_IMM=$(prepare_for_edit "${MOCK_SSH_CONFIG}" 2>/dev/null)
assert_true "[[ ${WAS_IMM} -eq 0 ]]" "Safety: prepare_for_edit returns expected state"
assert_true "[[ -f ${MOCK_SSH_CONFIG}.20260423140000 ]]" "Safety: Backup file created"

# 3. Sudo Safety Check: Lockout prevention validation.
echo -e "\nTesting Sudo Access Verification:"
MOCK_WHEEL="true"
assert_true "verify_sudo_users" "Safety: Detects admin via wheel group"
MOCK_WHEEL="false"; MOCK_SUDO_GRP="true"
assert_true "verify_sudo_users" "Safety: Detects admin via sudo group"
MOCK_SUDO_GRP="false"
echo "explicituser ALL=(ALL) ALL" > "${MOCK_SUDOERS}"
assert_true "verify_sudo_users" "Safety: Detects admin via explicit sudoers entry"
echo "" > "${MOCK_SUDOERS}"
assert_false "verify_sudo_users" "Safety: Fails safely when no administrators found"

# 4. Audit Detection Logic: Security state reporting validation.
echo -e "\nTesting Audit Detection Logic:"
# Mock helper to simulate individual shadow fields.
get_user_shadow() { echo "${MOCK_SHADOW_FIELD}"; }
MOCK_SHADOW_FIELD="\$6\$stronghash"
assert_true "audit_no_password" "Audit: Detects password exists"
assert_true "audit_hashes" "Audit: Detects strong SHA-512 hash"
MOCK_SHADOW_FIELD="!"
assert_true "audit_unlocked" "Audit: Detects locked account"
MOCK_SHADOW_FIELD="\$1\$weak"
assert_false "audit_hashes" "Audit: Correctly flags weak MD5 hash"
sshd() { echo "permitrootlogin yes"; }
assert_false "audit_ssh_login" "Audit: Flags enabled root SSH access"
sshd() { echo "permitrootlogin no"; }
assert_true "audit_ssh_login" "Audit: Confirms disabled root SSH access"

# 5. CLI & Execution Flows: End-to-end integration and UX validation.
echo -e "\nTesting CLI & Operational Flows:"
MOCK_EUID=0
# Mock the audit orchestrator for high-level CLI testing.
run_full_audit() { return 0; }

assert_exit "main --mode audit" 0 "CLI: Audit pass (Clean system)"
assert_exit "main" 1 "CLI: Fails with no arguments (Usage enforced)"
assert_exit "main --mode audit --generate" 1 "CLI: Blocks restricted flags in audit mode"

# Remediate triggers safety check on failure.
run_full_audit() { return 1; }
MOCK_WHEEL="false"; MOCK_SUDO_GRP="false"; echo "" > "${MOCK_SUDOERS}"
assert_exit "main --mode remediate --generate" 1 "Main: Aborts remediation on sudo safety failure"

# Successful Remediation path.
MOCK_WHEEL="true"
assert_exit "main --mode remediate --generate" 0 "Main: Successful remediation when safety passes"

# Environment Variable support validation.
export ROOT_PASSWORD="ValidPass12345678901234567890123#"
assert_exit "main --mode remediate" 0 "Main: Successfully uses ROOT_PASSWORD environment variable"
unset ROOT_PASSWORD

# Simulation Mode validation.
assert_exit "main --mode remediate --generate --simulate" 0 "Main: Simulation mode executes cleanly"

# JSON Mode validation.
echo -e "\nTesting JSON Mode:"
# Check if output contains valid JSON keys (flexible grep for jq formatting)
JSON_OUT=$(main --mode audit --json 2>/dev/null || true)
assert_true "echo '${JSON_OUT}' | grep -qi 'status'" "JSON: Output contains status key"
assert_true "echo '${JSON_OUT}' | grep -qi 'immutable'" "JSON: Output contains immutable key"
MOCK_IMMUTABLE="true"
JSON_OUT_IMM=$(main --mode audit --json 2>/dev/null || true)
assert_true "echo '${JSON_OUT_IMM}' | grep -qi '\"immutable\": true'" "JSON: Correctly reports immutable true"

# Privilege enforcement validation.
MOCK_EUID=1000
assert_exit "main --mode audit" 1 "Security: Rejects non-root execution (EUID check)"

# Final Result Reporting
echo -e "\n--- Test Summary ---"
echo "Passed: ${TESTS_PASSED}"
echo "Failed: ${TESTS_FAILED}"

if [[ ${TESTS_FAILED} -eq 0 ]]; then
    echo -e "\n${GREEN}FULL-SPECTRUM TEST SUCCESS${NC}"
    exit 0
else
    echo -e "\n${RED}TEST FAILURES DETECTED${NC}"
    exit 1
fi
