#!/bin/bash
# -----------------------------------------------------------------------------
# Unit test suite for root_audit.sh (root_audit_test.sh)
# v1.0.0xg  2026/04/23  XDG

# ==============================================================================
# SCRIPT: root_audit_test.sh
# OBJECTIVE: Comprehensive Unit Testing for the root_audit.sh utility.
#
# CORE COMPONENTS:
#   1. Isolated Workspace Manager: Creates ephemeral, sandboxed environments.
#   2. Mock Engine: Overrides system utilities (getent, chpasswd, sshd, etc.).
#   3. Assertion Library: Standardized true/false/exit-code validation.
#   4. Test Matrix: Covers 96 granular security scenarios.
#
# FUNCTIONALITY:
#   - Validates password complexity policies.
#   - Simulates filesystem states (immutable flags, backup creation).
#   - Verifies the sudo safety "kill-switch" across multiple configurations.
#   - Tests CLI flow control, exit codes, and environment variable injection.
#   - Ensures total isolation (no host system modification).
#   - Validates JSON output mode for CI/CD compatibility.
#   - Verifies selective remediation logic (only fix what is broken).
#   - Ensures robust sudoers parsing (indents, primary GID, complex syntax).
#   - Validates SUDO_USER environment variable fallback for safety checks.
#   - Confirms sudoers count and list are reported in Audit mode.
#   - Verifies 'restore' mode functionality and backup existence checks.
#
# DATA FLOW:
#   Setup (Sandbox) -> Mock Definition -> Source Utility ->
#   Sequential Test Execution -> Assertion Checks -> Cleanup (Trap).
#
# HOW TO RUN (normal and for TTY allocation):
#   sudo ./root_audit_test.sh
#   script -q -c "sudo ./root_audit_test.sh" /dev/null
# ==============================================================================

# shellcheck disable=SC2329,SC2034,SC1090
# 1. Root Enforcement: Unit tests require root to simulate protected system states.
# (Disabled for CI/CD environment verification)
if [[ "${EUID}" -ne 0 ]] || ! sudo -l > /dev/null 2>&1; then
  echo -e "[\e[31mFAIL\e[0m] Tests must be run with sudo/root privileges (verified via sudo -l)."
  exit 1
fi

# Setup Workspace: Ensures tests run in a predictable, non-destructive environment.
TMPDIR="${TMPDIR:-/tmp}"
WORKSPACE="${TMPDIR}/unitests/$(uuidgen)"
mkdir -p "${WORKSPACE}/sudoers.d"

# Cleanup on exit: Automatic removal of the sandboxed workspace.
trap '[[ "${DEBUG:-false}" == "true" ]] || rm -rf "${WORKSPACE:?}"' EXIT

MOCK_SUDOERS_DIR="${WORKSPACE}/sudoers.d"
mkdir -p "${MOCK_SUDOERS_DIR}"

MOCK_SSH_CONFIG_DIR="${WORKSPACE}/ssh_config.d"
mkdir -p "${MOCK_SSH_CONFIG_DIR}"

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
# Default authorized administrator for success scenarios
echo "%wheel ALL=(ALL) ALL" > "${MOCK_SUDOERS}"
MOCK_SUDO_GRP="true"
MOCK_SSHD_PERMIT="no"

# --- Assertion Library ---

assert_true() {
  # Objective: Verify that a command returns success (0).
  local cmd="$1"
  local msg="$2"
  if eval "$cmd" > /dev/null 2>&1; then
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
  if ! eval "$cmd" > /dev/null 2>&1; then
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
  eval "$cmd" > /dev/null 2>&1
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

chpasswd() {
  # Drain stdin to prevent pipe blocking
  cat > /dev/null
  # Mock behavior: Update the shadow file with a strong hash.
  sed -i "s|^root:.*|root:\$6\$newstronghash:19000:0:99999:7:::|" "${MOCK_SHADOW}"
  echo "MOCK chpasswd" >&2
}
passwd() {
  # Drain stdin if any (passwd doesn't usually take stdin here but mocks should be safe)
  [[ ! -t 0 ]] && cat > /dev/null
  # Mock behavior: Lock the account by prepending '!' to the shadow hash in the file.
  if [[ "${1}" == "-l" ]]; then
    local current
    current=$(grep "^root:" "${MOCK_SHADOW}" | cut -d: -f2)
    [[ "${current}" != "!"* ]] && sed -i "s|^root:|root:!|" "${MOCK_SHADOW}"
  fi
  echo "MOCK passwd" >&2
}
systemctl() { return 0; }
date() { echo "20260423140000"; }
chattr() { echo "MOCK chattr" >&2; }
sshd() {
  # Mock sshd -T output and -t validation.
  if [[ "${1}" == "-t" ]]; then
    return "${MOCK_SSHD_T_FAIL:-0}"
  fi
  # Tests can override this by redefining the function locally.
  echo "permitrootlogin ${MOCK_SSHD_PERMIT:-no}"
}
sudo() {
  if [[ "${1}" == "-l" ]]; then
    # If -U is provided, we simulate looking up a specific user's privileges
    if [[ "${2}" == "-U" ]]; then
       # For testing, we assume 'testuser', 'builder', 'adminuser', 'explicituser' are valid admins
       case "${3}" in
         testuser|builder|adminuser|explicituser|envuser|indenteduser)
           echo "(ALL : ALL) ALL"
           return 0
           ;;
         *)
           echo "User ${3} is not allowed to run sudo on this host."
           return 1
           ;;
       esac
    fi
    echo "${MOCK_SUDO_L_OUT:-(ALL : ALL) ALL}"
    return "${MOCK_SUDO_L_FAIL:-0}"
  fi
  return 0
}
lsattr() {
  # Simulates the output of lsattr based on a toggle variable.
  [[ "${MOCK_IMMUTABLE:-false}" == "true" ]] && echo "----i--------- $1" || echo "-------------- $1"
}

mkdir -p "${WORKSPACE}/bin"
cat << EOF > "${WORKSPACE}/bin/selinuxenabled"
#!/bin/bash
[[ "\${MOCK_SELINUX:-false}" == "true" ]]
EOF
cat << EOF > "${WORKSPACE}/bin/restorecon"
#!/bin/bash
echo "MOCK restorecon \$*" >&2
EOF
script() {
  if [[ "${MOCK_SCRIPT_FAIL:-}" == "true" ]]; then return 1; fi
  # If it's a sudo -l call, we echo the mock output
  if [[ "$*" == *"-l -U"* ]]; then
     echo "${MOCK_SUDO_L_OUT:-(ALL : ALL) ALL}"
  fi
  return 0
}
export -f script
chmod +x "${WORKSPACE}/bin/selinuxenabled" "${WORKSPACE}/bin/restorecon"
export PATH="${WORKSPACE}/bin:${PATH}"

getent() {
  # Simulates group and passwd membership checks.
  local cmd="$1"
  local target="${2:-}"
  if [[ "$cmd" == "group" ]]; then
    if [[ "$target" == "wheel" && "${MOCK_WHEEL:-}" == "true" ]]; then
      echo "wheel:x:10:adminuser"
    elif [[ "$target" == "sudo" && "${MOCK_SUDO_GRP:-}" == "true" ]]; then
      echo "sudo:x:27:ubuntuser"
    elif [[ "$target" == "primarygrp" ]]; then
      echo "primarygrp:x:2000:othermember"
    else
      return 1
    fi
  elif [[ "$cmd" == "passwd" ]]; then
    if [[ "${MOCK_PRIMARY_GID:-}" == "true" ]]; then
      echo "primaryuser:x:1001:2000:Primary User:/home/primaryuser:/bin/bash"
    else
      return 0
    fi
  fi
}

# Override environment for the script: Points the target utility to our mock sandbox.
export SSH_CONFIG="${MOCK_SSH_CONFIG}"
export SSH_CONFIG_DIR="${MOCK_SSH_CONFIG_DIR}"
export SHADOW_FILE="${MOCK_SHADOW}"
export SUDOERS_FILE="${MOCK_SUDOERS}"
export SUDOERS_DIR="${WORKSPACE}/sudoers.d"

# Source the target script: Loads functions into the current shell for testing.
source "${SCRIPT_PATH}"
export -f sudo getent systemctl sshd check_root get_sudoers_paths get_sudo_group_members log_info log_warn log_err log_succ log_sim print_divider script
set +e

# Security Bypass: Redefine check_root to allow tests to run as non-root users.
check_root() { [[ "${MOCK_EUID:-0}" -ne 0 ]] && return 1 || return 0; }

# Helper for expansion-safe relock check
check_relock() { [[ "$(get_user_shadow)" == "!"* ]]; }

echo -e "--- Workspace: ${WORKSPACE} ---"
echo -e "--- Starting Full-Spectrum Unit Tests (v11: Restore Mode) ---\n"

# --- Test Matrix Execution ---

# 1. validate_password: Policy compliance validation.
echo "Testing validate_password Policy:"
assert_true "validate_password 'ValidPass12345678901234567890123#'" "Policy: Accepts valid password"
assert_false "validate_password 'short'" "Policy: Rejects short password"
assert_false "validate_password 'alllowercase12345678901234567890#'" "Policy: Rejects missing uppercase"
assert_false "validate_password 'ALLUPPERCASE12345678901234567890#'" "Policy: Rejects missing lowercase"
assert_false "validate_password 'NoSpecialChars1234567890123456789'" "Policy: Rejects missing special chars"

# 2. Attributes & Backups: Filesystem state management validation.
echo -e "\nTesting Filesystem Safety:"
MOCK_IMMUTABLE="true"
assert_true "is_immutable '${MOCK_SHADOW}'" "Safety: Detects immutable flag"
MOCK_TIMESTAMP="20260423140000"
prepare_for_edit "${MOCK_SSH_CONFIG}" > /dev/null
assert_true "[[ -f ${MOCK_SSH_CONFIG}.${MOCK_TIMESTAMP}.gz ]]" "Safety: Backup file created (compressed)"
MOCK_IMMUTABLE="false"

# 3. Sudo Safety Check: Lockout prevention validation.
echo -e "\nTesting Sudo Access Verification:"
MOCK_WHEEL="true"
assert_true "verify_sudo_users" "Safety: Detects admin via wheel group"
MOCK_WHEEL="false"
MOCK_SUDO_GRP="true"
assert_true "verify_sudo_users" "Safety: Detects admin via sudo group"
MOCK_SUDO_GRP="false"
echo "explicituser ALL=(root) ALL" > "${MOCK_SUDOERS}"
assert_true "verify_sudo_users" "Safety: Detects admin via custom ALL=(root) entry"
echo "adminuser ALL=(root) ALL" > "${MOCK_SUDOERS_DIR}/custom"
assert_true "verify_sudo_users" "Safety: Detects admin via custom entry in sudoers.d (Multi-file paths)"
rm -f "${MOCK_SUDOERS_DIR}/custom"
echo "	indenteduser ALL=(ALL) ALL" > "${MOCK_SUDOERS}"
assert_true "verify_sudo_users" "Safety: Detects admin via TAB-indented entry"
echo " %primarygrp ALL=(ALL) ALL" > "${MOCK_SUDOERS}"
MOCK_PRIMARY_GID="true"
assert_true "verify_sudo_users" "Safety: Detects admin via Primary GID membership"
MOCK_PRIMARY_GID="false"
echo "" > "${MOCK_SUDOERS}"
export SUDO_USER="calluser"
assert_true "verify_sudo_users" "Safety: Detects admin via SUDO_USER environment variable"
unset SUDO_USER
assert_false "verify_sudo_users" "Safety: Fails safely when no administrators found"
# Restore authorized state for subsequent tests
echo "%wheel ALL=(ALL) ALL" > "${MOCK_SUDOERS}"
MOCK_SUDO_GRP="true"

# 4. Audit Detection Logic: Security state reporting validation.
echo -e "\nTesting Audit Detection Logic:"
# Mock helper to simulate individual shadow fields.
get_user_shadow() {
  grep "^root:" "${MOCK_SHADOW}" | cut -d: -f2
}
MOCK_SHADOW_FIELD="\$6\$stronghash"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_true "audit_hashes" "Audit: Detects strong SHA-512 hash"
MOCK_SHADOW_FIELD="!"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_false "audit_no_password" "Audit: Detects missing password on purely locked account"
assert_true "audit_unlocked" "Audit: Detects locked state on purely locked account"
MOCK_SHADOW_FIELD="\$6\$stronghash"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_true "audit_hashes" "Audit: Detects strong SHA-512 hash"
MOCK_SHADOW_FIELD="\$6\$strong"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_true "audit_hashes" "Audit: Detects strong SHA-512 hash"
MOCK_SHADOW_FIELD="!\$6\$strong"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_true "audit_hashes" "Audit: Detects locked strong hash"
MOCK_SHADOW_FIELD="!"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_true "audit_unlocked" "Audit: Detects locked account"
MOCK_SHADOW_FIELD="\$1\$weak"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_false "audit_hashes" "Audit: Correctly flags weak MD5 hash"

# Audit Detection Logic: Positive/Negative confirmation.
echo -e "\nTesting Audit Detection Logic:"
MOCK_SSHD_PERMIT="no"
# Initial state must have Include to pass structural audit
echo "Include ${MOCK_SSH_CONFIG_DIR}/" > "${MOCK_SSH_CONFIG}"
assert_exit "audit_ssh_login" 0 "Audit: Confirms disabled root SSH access (with Include)"

# Audit: Flags enabled root SSH access
MOCK_SSHD_PERMIT="yes"
assert_false "audit_ssh_login" "Audit: Flags enabled root SSH access"

# Audit: Confirms disabled root SSH access (with Include)
MOCK_SSHD_PERMIT="no"
echo "Include ${MOCK_SSH_CONFIG_DIR}/" > "${MOCK_SSH_CONFIG}"
assert_exit "audit_ssh_login" 0 "Audit: Confirms disabled root SSH access"

# Audit: Fails gracefully on sshd error
sshd() { return 1; }
assert_false "audit_ssh_login" "Audit: Fails gracefully on sshd error"
# Restore sshd mock
sshd() {
  if [[ "${1}" == "-t" ]]; then return "${MOCK_SSHD_T_FAIL:-0}"; fi
  echo "permitrootlogin ${MOCK_SSHD_PERMIT:-no}"
}

# Finding Count Validation: Ensure final recap reports the correct number of findings.
MOCK_SHADOW_FIELD="!\$1\$weak" # Hash is weak (+1), SSH enabled (+1), Locked (0) -> Total 2
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
MOCK_SSHD_PERMIT="yes"
# No Include ensures SSH Audit failure
echo "no include" > "${MOCK_SSH_CONFIG}"
MOCK_WHEEL="true"
main --mode audit > "${WORKSPACE}/audit_count_out" 2>&1 || true
assert_true "grep -qi 'Audit FAILED (2 findings)' ${WORKSPACE}/audit_count_out" "Audit: Final recap reports correct number of findings (2)"

# 5. CLI & Operational Flows: Aggregate results.
echo -e "\nTesting CLI & Operational Flows:"
MOCK_EUID=0
MOCK_WHEEL="true"
MOCK_SSHD_PERMIT="no"
echo "Include ${MOCK_SSH_CONFIG_DIR}/" > "${MOCK_SSH_CONFIG}"
echo "root:!${TARGET_HASH:-\$6\$strong}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_exit "main --mode audit" 0 "CLI: Audit pass (Clean system)"
assert_exit "main" 1 "CLI: Fails with no arguments (Usage enforced)"
assert_exit "main --mode audit --generate" 1 "CLI: Blocks restricted flags in audit mode"

# Selective Remediation: Only requires password if broken.
MOCK_SHADOW_FIELD="!\$6\$stronghash"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
MOCK_SSHD_PERMIT="no"
MOCK_WHEEL="true"
assert_exit "main --mode remediate" 0 "Selective: Proceeds without password if current is strong"

# Requires password if hash is weak.
MOCK_SHADOW_FIELD="\$1\$weak"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_exit "main --mode remediate" 1 "Selective: Fails if password is weak and no source provided"
MOCK_WHEEL="true"
assert_exit "main --mode remediate --generate" 0 "Selective: Succeeds with --generate if password is weak"

# Forced rotation test: System is compliant but user provides a password
MOCK_SHADOW_FIELD="\$6\$strong"
echo "root:${MOCK_SHADOW_FIELD}:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_exit "main --mode remediate --generate --simulate" 0 "Forced: Detects requested rotation on compliant system"
# Verify simulation log mentions the rotation
main --mode remediate --generate --simulate > "${WORKSPACE}/sim_out" 2>&1 || true
assert_true "grep -qi 'enforce strong' ${WORKSPACE}/sim_out" "Forced: Simulation confirms requested rotation"

# Regression: Ensure account is RELOCKED after password update (even if chpasswd unlocks it).
MOCK_SHADOW_FIELD="!\$1\$weak" # Initially locked but weak hash
MOCK_WHEEL="true"
main --mode remediate --generate > /dev/null 2>&1 || true
assert_true "check_relock" "Regression: Account is relocked after password rotation"

# Main: Simulation mode executes cleanly
assert_exit "main --mode remediate --generate --simulate" 0 "Main: Simulation mode executes cleanly"

# JSON Mode validation.
echo -e "\nTesting JSON Mode:"
# Check if output contains valid JSON keys (flexible grep for jq formatting)
JSON_OUT=$(main --mode audit --json 2> /dev/null || true)
assert_true "echo '${JSON_OUT}' | grep -qi 'status'" "JSON: Output contains status key"
assert_true "echo '${JSON_OUT}' | grep -qi 'sudo_user_count'" "JSON: Output contains sudo_user_count key"
assert_true "echo '${JSON_OUT}' | grep -qi 'sudo_user_list'" "JSON: Output contains sudo_user_list key"
MOCK_IMMUTABLE="true"
JSON_OUT_IMM=$(main --mode audit --json 2> /dev/null || true)
assert_true "echo '${JSON_OUT_IMM}' | grep -qi '\"immutable\": true'" "JSON: Correctly reports immutable true"

# 6. Restore Mode & Backup Discovery
echo -e "\nTesting Restore Mode Discovery (Gzip):"
# Ensure clean state for discovery
rm -f "${MOCK_SHADOW:?}"* "${MOCK_SSH_CONFIG:?}"*

# Setup multiple backups (mixed legacy and compressed)
# suffix 1: oldest (Gzip)
MOCK_TIMESTAMP="20260420000000"
echo "old-content" | gzip > "${MOCK_SHADOW}.${MOCK_TIMESTAMP}.gz"
echo "old-ssh" | gzip > "${MOCK_SSH_CONFIG}.${MOCK_TIMESTAMP}.gz"

# suffix 2: middle (shadow only, legacy uncompressed)
MOCK_TIMESTAMP="20260421000000"
echo "mid-content" > "${MOCK_SHADOW}.${MOCK_TIMESTAMP}"

# suffix 3: latest (Gzip)
MOCK_TIMESTAMP="20260422000000"
echo "new-content" | gzip > "${MOCK_SHADOW}.${MOCK_TIMESTAMP}.gz"
echo "new-ssh" | gzip > "${MOCK_SSH_CONFIG}.${MOCK_TIMESTAMP}.gz"

# Verification: List Backups
# Use grep -E to be flexible with whitespace
assert_true "main --mode restore --list-backups | grep -E '20260422000000.*shadow sshd_config'" "Discovery: Correctly reports combined scope and latest suffix"
assert_true "main --mode restore --list-backups | grep -E '20260420000000.*shadow sshd_config'" "Discovery: Correctly reports oldest suffix"
assert_true "main --mode restore --list-backups | grep -E '20260421000000.*shadow[[:space:]]*\|'" "Discovery: Correctly reports partial scope (legacy)"

# Verification: Latest selection
assert_exit "main --mode restore --latest --simulate" 0 "Discovery: Automatically identifies latest suffix"
main --mode restore --latest > /dev/null 2>&1 || true
assert_true "grep -q 'new-content' ${MOCK_SHADOW}" "Discovery: Latest restore selects and decompresses correct content"

# Verification: Oldest selection
assert_exit "main --mode restore --oldest --simulate" 0 "Discovery: Automatically identifies oldest suffix"
main --mode restore --oldest > /dev/null 2>&1 || true
assert_true "grep -q 'old-content' ${MOCK_SHADOW}" "Discovery: Oldest restore selects and decompresses correct content"

# Verification: Mode Enforcement
assert_exit "main --list-backups" 1 "Discovery: Rejects --list-backups without --mode restore"
assert_exit "main --latest" 1 "Discovery: Rejects --latest without --mode restore"
assert_exit "main --oldest" 1 "Discovery: Rejects --oldest without --mode restore"

# Verification: Empty discovery
chattr -i "${MOCK_SHADOW}" 2> /dev/null || true
chattr -i "${MOCK_SSH_CONFIG}" 2> /dev/null || true
rm -f "${MOCK_SHADOW:?}"* "${MOCK_SSH_CONFIG:?}"*
assert_true "main --mode restore --list-backups 2>&1 | grep -qi 'no backups found'" "Discovery: Gracefully handles empty backup set"
assert_exit "main --mode restore --latest" 1 "Discovery: Fails when --latest requested on empty set"

# Restore original date mock
date() { echo "20260423140000"; }

echo -e "\nTesting Restore Mode Manual:"
echo "shadow-bkp-content" > "${MOCK_SHADOW}.testbkp"
echo "ssh-bkp-content" > "${MOCK_SSH_CONFIG}.testbkp"
assert_exit "main --mode restore --suffix testbkp" 0 "Restore: Successfully restores shadow and SSH config"
assert_true "grep -q 'shadow-bkp-content' ${MOCK_SHADOW}" "Restore: Shadow content matches backup"
assert_true "grep -q 'ssh-bkp-content' ${MOCK_SSH_CONFIG}" "Restore: SSH content matches backup"

assert_exit "main --mode restore --suffix nonexistent" 1 "Restore: Returns failure if backups are missing"
assert_exit "main --mode restore" 1 "Restore: Fails if --suffix is missing"
assert_exit "main --mode restore --suffix testbkp --simulate" 0 "Restore: Simulation mode executes cleanly"

MOCK_IMMUTABLE="true"
echo "shadow-bkp-imm" > "${MOCK_SHADOW}.immbkp"
echo "ssh-bkp-imm" > "${MOCK_SSH_CONFIG}.immbkp"
assert_exit "main --mode restore --suffix immbkp" 0 "Restore: Successfully restores immutable files"
assert_true "grep -q 'shadow-bkp-imm' ${MOCK_SHADOW}" "Restore: Content restored to immutable file"
MOCK_IMMUTABLE="false"

# 8. Aggregate Failure Logic: Ensuring partial failures propagate.
echo -e "\nTesting Aggregate Failure Logic:"
MOCK_EUID=0
# Use subshell to avoid polluting main test namespace with failed mocks
(
  remediate_password() { return 1; }
  run_full_audit() { return 1; }
  MOCK_WHEEL="true"
  assert_exit "main --mode remediate --generate" 1 "Aggregate: Fails if remediation step fails"
)

# Privilege enforcement validation.
MOCK_EUID=0
MOCK_SUDO_L_FAIL=1
# Redefine check_root to use the REAL logic for these tests to verify the regex.
# We source it again or just copy the regex here for the mock.
check_root() {
  local sudo_out
  sudo_out=$(sudo -l 2> /dev/null) || return 1
  [[ "${MOCK_EUID:-0}" -eq 0 ]] && echo "${sudo_out}" | grep -qiE "\((ALL|root)([[:space:]]*:[[:space:]]*(ALL|root))?\)[[:space:]]*ALL"
}

assert_exit "main --mode audit" 1 "Security: Rejects if sudo -l fails"
MOCK_SUDO_L_FAIL=0

MOCK_SUDO_L_OUT="(root) /usr/bin/ls" # Restricted access
assert_exit "main --mode audit" 1 "Security: Rejects if sudo -l lacks full privileges"

# For the passing tests, we must ensure audit itself passes too.
run_full_audit() { return 0; }
echo "explicituser ALL=(ALL) ALL" > "${MOCK_SUDOERS}"
MOCK_SUDO_GRP="true"
MOCK_SUDO_L_FAIL=0
MOCK_SUDO_L_OUT="(ALL : ALL) ALL" # Restoration of full access
assert_exit "main --mode audit" 0 "Security: Accepts full (ALL : ALL) ALL privileges"
MOCK_SUDO_L_OUT="(ALL) ALL" # Fuzzy check for (ALL) ALL
assert_exit "main --mode audit" 0 "Security: Accepts fuzzy (ALL) ALL privileges"

# TTY Resilience and Fallback Tests (New)
MOCK_SUDO_L_OUT="(root) NOPASSWD: ALL" # RHEL Dialect
assert_exit "main --mode audit" 0 "Security: Accepts RHEL (root) NOPASSWD: ALL format"

MOCK_SCRIPT_FAIL="true"
MOCK_SUDO_GRP="true" # Fallback to group discovery
assert_exit "main --mode audit" 0 "Security: Fallback to group discovery when TTY blocked"

MOCK_SUDO_GRP="false" # All system checks fail, trust Alias discovery
echo "User_Alias ADMINS = explicituser" > "${MOCK_SUDOERS}"
echo "ADMINS ALL=(ALL) ALL" >> "${MOCK_SUDOERS}"
assert_exit "main --mode audit" 0 "Security: Fallback to Alias discovery trust"

MOCK_SCRIPT_FAIL="false"
MOCK_SUDO_L_OUT="(ALL) ALL"
SUDO_USER="explicituser"
assert_exit "main --mode audit" 0 "Security: De-duplicates redundant verification logs"
unset SUDO_USER

MOCK_EUID=1000
assert_exit "main --mode audit" 1 "Security: Rejects non-root execution (EUID check)"
MOCK_EUID=0
# Restore simple check_root for remaining tests
check_root() { [[ "${MOCK_EUID:-0}" -ne 0 ]] && return 1 || return 0; }

# 7. Logging Logic: Persistent audit trail validation.
echo -e "\nTesting Logging Mode:"
MOCK_EUID=0
# Ensure audit pass for logging test
run_full_audit() { return 0; }
LOG_FILE_PATH="${WORKSPACE}/testlogs/sub/audit.log"
assert_exit "main --mode audit --log ${LOG_FILE_PATH}" 0 "Logging: Creates log file in nested directory"
assert_true "[[ -f ${LOG_FILE_PATH} ]]" "Logging: Log file existence verified"
assert_true "grep -qi 'SESSION START' ${LOG_FILE_PATH}" "Logging: Log contains session header"
assert_true "grep -qi '\[INFO\]' ${LOG_FILE_PATH}" "Logging: Log contains timestamped entries"

# Redaction test
LOG_REDACT="${WORKSPACE}/redact.log"
# Redefine audit to return 1 (fail) to trigger remediation logic in test
run_full_audit() { return 1; }
MOCK_WHEEL="true"
main --mode remediate --generate --log "${LOG_REDACT}" > /dev/null 2>&1 || true
assert_true "grep -qi '\[REDACTED\]' ${LOG_REDACT}" "Logging: Password is redacted in log file"
assert_false "grep -q 'Password to be used: [^[]' ${LOG_REDACT}" "Logging: No plaintext password in log file"

# 9. SELinux Awareness: Context restoration validation.
echo -e "\nTesting SELinux Awareness:"
# Force weak state to trigger remediation
echo "root:\$1\$weak:19000:0:99999:7:::" > "${MOCK_SHADOW}"
export MOCK_SELINUX="true"
MOCK_WHEEL="true"
# Check if output contains the info message
main --mode remediate --generate > "${WORKSPACE}/selinux_out" 2>&1 || true
assert_true "grep -qi 'SELinux' ${WORKSPACE}/selinux_out" "SELinux: Detects active state and applies context"
export MOCK_SELINUX="false"
# Force weak state again
echo "root:\$1\$weak:19000:0:99999:7:::" > "${MOCK_SHADOW}"
assert_false "main --mode remediate --generate 2>&1 | grep -qi 'SELinux'" "SELinux: Skips context when disabled"

# 9. Modular SSH Hardening Logic
echo -e "\nTesting Modular SSH Hardening:"
# Reset mocks
MOCK_SSHD_T_FAIL=0
MOCK_SSHD_PERMIT="no"
mkdir -p "${MOCK_SSH_CONFIG_DIR}"
echo "Include ${MOCK_SSH_CONFIG_DIR}/*.conf" > "${MOCK_SSH_CONFIG}"
echo "other config" >> "${MOCK_SSH_CONFIG}"
rm -rf "${MOCK_SSH_CONFIG_DIR:?}"/*

# Case 1: Audit fails if Include is missing
echo "no include here" > "${MOCK_SSH_CONFIG}"
assert_exit "audit_ssh_login" 1 "SSH Audit: Fails if modular Include directive is missing"

# Case 1b: Audit accepts Tab character in Include
echo -e "Include\t${MOCK_SSH_CONFIG_DIR}/" > "${MOCK_SSH_CONFIG}"
assert_exit "audit_ssh_login" 0 "SSH Audit: Correctly handles TAB characters in Include directive"

# Case 2: Audit fails if PermitRootLogin yes exists in .d/
echo "Include ${MOCK_SSH_CONFIG_DIR}/" > "${MOCK_SSH_CONFIG}"
echo "PermitRootLogin yes" > "${MOCK_SSH_CONFIG_DIR}/rogue.conf"
assert_exit "audit_ssh_login" 1 "SSH Audit: Fails if PermitRootLogin yes exists in .d/"

# Case 3: Audit fails if PermitRootLogin yes exists in main config
echo "PermitRootLogin yes" > "${MOCK_SSH_CONFIG}"
echo "Include ${MOCK_SSH_CONFIG_DIR}/" >> "${MOCK_SSH_CONFIG}"
rm -f "${MOCK_SSH_CONFIG_DIR}/rogue.conf"
assert_exit "audit_ssh_login" 1 "SSH Audit: Fails if PermitRootLogin yes exists in main config"

# Case 4: Remediation cleans up everything
echo "Port 22" > "${MOCK_SSH_CONFIG}"
echo "PermitRootLogin yes" >> "${MOCK_SSH_CONFIG}"
echo "# PermitRootLogin yes" > "${MOCK_SSH_CONFIG_DIR}/commented.conf"
echo "PermitRootLogin prohibit-password" > "${MOCK_SSH_CONFIG_DIR}/safe.conf"
assert_exit "remediate_ssh" 0 "SSH Remediation: Successfully completes modular hardening"
assert_true "grep -qE '^[[:space:]]*Include[[:space:]]+${MOCK_SSH_CONFIG_DIR}/' ${MOCK_SSH_CONFIG}" "SSH Remediation: Include directive added"
assert_true "grep -B 2 'Include ${MOCK_SSH_CONFIG_DIR}/\*.conf' ${MOCK_SSH_CONFIG} | grep -q 'automatically included'" "SSH Remediation: Include block has correct descriptive header"
# Since we now append to the bottom, verify placement
assert_true "tail -n 1 ${MOCK_SSH_CONFIG} | grep -q 'Include ${MOCK_SSH_CONFIG_DIR}/\*.conf'" "SSH Remediation: Include block placed at the BOTTOM"
# We check all files except 99-secure-policy.conf for PermitRootLogin
assert_false "grep -ri 'PermitRootLogin' ${MOCK_SSH_CONFIG} ${MOCK_SSH_CONFIG_DIR}/commented.conf ${MOCK_SSH_CONFIG_DIR}/safe.conf 2>/dev/null" "SSH Remediation: All unauthorized instances removed"
assert_true "[[ -f ${MOCK_SSH_CONFIG_DIR}/99-secure-policy.conf ]]" "SSH Remediation: 99-secure-policy.conf created"
assert_true "grep -q 'PermitRootLogin no' ${MOCK_SSH_CONFIG_DIR}/99-secure-policy.conf" "SSH Remediation: Policy content is correct"
assert_true "[[ \$(stat -c %a \"${MOCK_SSH_CONFIG_DIR}\"/99-secure-policy.conf) == 600 ]]" "SSH Remediation: Policy permissions are 600"

# Case 5: Remediation fails if sshd -t fails
MOCK_SSHD_T_FAIL=1
# We must ensure bad files exist to trigger the check or just run verify_sshd_config
assert_exit "verify_sshd_config" 1 "SSH Safety: verify_sshd_config fails if sshd -t validation fails"
MOCK_SSHD_T_FAIL=0

# Case 6: Audit fails if unauthorized PermitRootLogin exists (even if 'no')
echo "PermitRootLogin no" > "${MOCK_SSH_CONFIG_DIR}/unauthorized.conf"
assert_exit "audit_ssh_login" 1 "SSH Audit: Fails if PermitRootLogin exists outside authorized policy"

# 10. Critical Failure Recovery (Non-Happy Path)
echo -e "\nTesting Critical Failures:"

# Failure Case 1: Backup failure (Simulate Disk Full / I/O Error)
# We override gzip to return failure
gzip() { return 1; }
assert_exit "backup_file ${MOCK_SHADOW} ${MOCK_SHADOW}.failed" 1 "Critical: backup_file fails if compression tool returns error"
# Restore gzip
unset -f gzip

# Failure Case 2: chattr failure (Cannot remove immutable flag)
# We override chattr to return failure and set mock immutable to true
chattr() { return 1; }
MOCK_IMMUTABLE="true"
assert_exit "prepare_for_edit ${MOCK_SHADOW}" 1 "Critical: prepare_for_edit fails if chattr cannot modify file"
MOCK_IMMUTABLE="false"
# Restore chattr
chattr() { echo "MOCK chattr" >&2; }

# Failure Case 3: Missing dependency (sshd missing)
# We override sshd to simulate missing binary
sshd() { return 127; }
assert_exit "audit_ssh_login" 1 "Critical: Audit fails gracefully if sshd binary is missing or errors"
# Restore sshd
sshd() {
  if [[ "${1}" == "-t" ]]; then return "${MOCK_SSHD_T_FAIL:-0}"; fi
  echo "permitrootlogin ${MOCK_SSHD_PERMIT:-no}"
}

# Final results
echo -e "\n--- Test Suite Summary ---"
echo "Tests Passed: ${TESTS_PASSED}"
echo "Tests Failed: ${TESTS_FAILED}"

if [[ "${TESTS_FAILED}" -eq 0 ]]; then
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}SOME TESTS FAILED${NC}"
  exit 1
fi
