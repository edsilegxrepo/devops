#!/bin/bash
# -----------------------------------------------------------------------------
# Unit test suite for code_audit.sh (code_audit_test.sh)
# v1.0.0xg  2026/04/17  XDG
#
# -----------------------------------------------------------------------------
# OBJECTIVES:
#   1. Orchestration Validation: Verify that code_audit.sh correctly initializes 
#      and executes all registered tools across Python, Go, Node.js, and Bash.
#   2. Flag Integrity: Ensure that auto-correction flags (--fix, --write) are 
#      propagated ONLY when explicitly requested, maintaining a zero-impact default.
#   3. Environment Isolation: Provide a self-contained, high-fidelity sandbox 
#      that does not require actual security binaries to be installed.
#
# CORE COMPONENTS:
#   1. Sandbox Engine: Uses isolated TEST_ROOT and PATH injection to intercept 
#      orchestrator calls.
#   2. Mock Generator: Dynamically creates tracking binaries based on the 
#      orchestrator's internal tool registries.
#   3. Verification Matrix: Comparative logic that evaluates cumulative mock 
#      argument history against expected test vectors.
#
# FUNCTIONALITY:
#   The suite performs "Black Box" testing of the orchestrator. It extracts the 
#   official tool list from the source code, generates mock replacements, and 
#   verifies that each replacement was called with the correct environmental 
#   context and flags across all supported ecosystems (Python, Go, Node, Bash).
#
# DATA FLOW:
#   [Registry Discovery] -> [Mock Generation] -> [PATH Injection] -> 
#   [Orchestrator Execution] -> [Mock Signal Capture] -> [Result Analysis]
# -----------------------------------------------------------------------------

# Purpose: Mocks toolchain and validates orchestration logic.

set -Eeuo pipefail

# 1. Environment Setup & Configuration
# -----------------------------------------------------------------------------
CONST_SUB_MOCK="mock_bin"
CONST_SUB_WS="workspace"
CONST_SUB_MARKS="marks"
CONST_SUB_ROOT="unitests"

# We use a unique TEST_UUID to prevent collisions between parallel test runs.
if command -v uuidgen >/dev/null 2>&1; then
    TEST_UUID="$(uuidgen)"
else
    # Fallback: Use kernel random uuid if available, else use hashed timestamp
    TEST_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N | cksum | cut -d' ' -f1)
fi
# TEST_ROOT is the global sandbox where mocks, workspace, and results reside.
TEST_ROOT="${TMPDIR:-$TEMP}/$CONST_SUB_ROOT/$TEST_UUID"
export MOCK_BIN="$TEST_ROOT/$CONST_SUB_MOCK"
export WORKSPACE="$TEST_ROOT/$CONST_SUB_WS"
export MARKS="$TEST_ROOT/$CONST_SUB_MARKS"

echo "--> Initializing Test Environment: $TEST_ROOT"
mkdir -p "$MOCK_BIN" "$WORKSPACE" "$MARKS"

# Redirect all temporary file generation and tool caches to the isolated test root
export TEMP="$TEST_ROOT"
export TMP="$TEST_ROOT"
export HOME="$TEST_ROOT/fake_home"
mkdir -p "$HOME"
export TMPDIR="$TEST_ROOT"

# Ensure cleanup on exit or interruption
trap 'echo "Cleaning up test environment..."; rm -rf "$TEST_ROOT"; rmdir "$(dirname "$TEST_ROOT")" 2>/dev/null || true' EXIT INT TERM

# 2. Tool Registry Extraction & Mock Generation
# -----------------------------------------------------------------------------
# We dynamically pull the checklist from the source script to ensure 
# the test suite is always synchronized with the current tool registries.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/code_audit.sh"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: code_audit.sh not found at expected location: $SCRIPT_PATH" >&2
    exit 1
fi

# Dynamically extract all registered tools from the orchestrator source code.
# The regex captures everything inside the parentheses of any AUDIT_*_TOOLS array.
TOOLS="$(grep -E "AUDIT_.*_TOOLS=\(" "$SCRIPT_PATH" | sed 's/.*(\([^)]*\)).*/\1/' | tr -d '"' | tr ' ' '\n' | sort -u | grep -v '^$')"
TOOLS="$TOOLS uv go npm curl" # Add core installation/bootstrap tools to registry

generate_mocks() {
    echo "--> Generating Mock Binaries with Execution/Flag Tracking..."
    mkdir -p "$MOCK_BIN"
    for tool in $TOOLS; do
        # Functional Mock: Every mock records its own execution into $MARKS.
        # $tool.args captures the cumulative command line string for later verification.
        bin_path="$MOCK_BIN/$tool"
        case "$tool" in
            "nilness")
                printf "#!/bin/bash\necho \"\$*\" >> \"$MARKS/nilness.args\"\necho \"0\" > \"$MARKS/nilness\"\nif [[ \"\$*\" == *\"-V=full\"* ]]; then echo \"nilness version devel buildID=ce7dad79295bbba0c591668e9fe38c31efc94c4cfbf3d8c5e8f6034703567209\"; fi\n" > "$bin_path" ;;
            *)
                cat << EOF > "$bin_path"
#!/bin/bash
# Mock binary for $tool
[ "\$1" = "--version" ] && echo "Mock $tool version 1.0.0"
if [ -n "\$MARKS" ]; then
    echo "0" > "\$MARKS/$tool"
    echo "\$*" >> "\$MARKS/$tool.args"
fi
# Specal case for curl | sh pipes
if [ "$tool" = "curl" ]; then
    echo "echo 'Mock shim executed'"
fi
exit 0
EOF
                ;;
        esac
        chmod +x "$bin_path"
    done
}

generate_mocks

# 3. Project Seeding
echo "--> Seeding Workspace..."
touch "$WORKSPACE/main.py" "$WORKSPACE/requirements.txt" "$WORKSPACE/main.go" "$WORKSPACE/go.mod" "$WORKSPACE/package.json" "$WORKSPACE/index.js"

# 4. PATH Injection
# We prepend MOCK_BIN to the PATH so the orchestrator calls our mocks 
# instead of searching for system-installed binaries.
export OLD_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"

# 5. Test Suite Execution
FAILED_TESTS=0

# Helper to assert that a command fails (returns non-zero)
# shellcheck disable=SC2329
test_fails() {
    ! "$@"
}

run_test() {
    local label="$1"
    shift
    echo "---------------------------------------------------------"
    echo "TEST: $label"
    local out_file
    out_file="$(mktemp)"
    if "$@" > "$out_file" 2>&1; then
        cat "$out_file"
        echo "RESULT: PASS"
        rm -f "$out_file"
        return 0
    else
        echo "RESULT: FAIL"
        echo "--- OUTPUT SNIPPET (START) ---"
        head -n 20 "$out_file"
        echo "--- OUTPUT SNIPPET (END) ---"
        tail -n 20 "$out_file"
        echo "----------------------"
        rm -f "$out_file"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Coverage Verification Helper
# Dynamically extracts tool lists from code_audit.sh to ensure tests are self-healing.
# shellcheck disable=SC2329
extract_registry() {
    local name="$1"
    grep "AUDIT_${name}_TOOLS=(" "$SCRIPT_PATH" | cut -d'(' -f2 | cut -d')' -f1 | tr -d '"'
}

# Specialized check for inverted/mandatory flags.
# shellcheck disable=SC2329
verify_flag_present() {
    local tool="$1"
    local expected_flag="$2"
    local args=""
    [ -f "$MARKS/$tool.args" ] && args="$(cat "$MARKS/$tool.args")"
    if [[ "$args" == *"$expected_flag"* ]]; then
        printf "  [✓] %-15s : Correctly received '%s'\n" "$tool" "$expected_flag"
        return 0
    else
        printf "  [✗] %-15s : MISSING expected flag '%s'. Got: '%s'\n" "$tool" "$expected_flag" "$args"
        return 1
    fi
}

# shellcheck disable=SC2329
verify_language_coverage() {
    local lang="$1"
    local reg_name="$2"
    local tools
    tools="$(extract_registry "$reg_name")"
    local all_success=0
    local status
    
    echo "---------------------------------------------------------"
    echo "  CHECKLIST: $lang"
    echo "---------------------------------------------------------"
    for tool in $tools; do
        if [ "$tool" == "node" ]; then continue; fi # Node is detection-only
        if [ -f "$MARKS/$tool" ]; then
            status="$(cat "$MARKS/$tool")"
            if [ "$status" -eq 0 ]; then
                printf "  [✓] %-15s : EXECUTED, PASS\n" "$tool"
            else
                printf "  [✗] %-15s : EXECUTED, FAIL\n" "$tool"
                all_success=1
            fi
        else
            printf "  [✗] %-15s : NOT CALLED\n" "$tool"
            all_success=1
        fi
    done
    echo "---------------------------------------------------------"
    return "$all_success"
}

# Helper to verify specific isolation logic
# shellcheck disable=SC2329
verify_isolation() {
    local lang_label="$1"
    shift
    bash "$SCRIPT_PATH" "$@" | grep "$lang_label" > /dev/null
}

# Test 1: Diagnostic Readiness
run_test "Tool Detection Report" bash "$SCRIPT_PATH" --detect

# Test 2: Full Integration & Coverage Matrix
run_test "Full Polyglot Coverage Execution" bash "$SCRIPT_PATH" --path "$WORKSPACE" --auto --extended --extra-scan

# Verify Language Packages (Dynamic Extraction)
run_test "Python Toolset Coverage" verify_language_coverage Python PYTHON
run_test "Golang Toolset Coverage" verify_language_coverage Golang GOLANG
run_test "Node.js Toolset Coverage" verify_language_coverage Node.js NODEJS
run_test "General Security Coverage" verify_language_coverage Security GENERAL

# Test Logic: pip-audit Manifest Targeting
run_test "pip-audit: Correctly targets requirements.txt" verify_flag_present pip-audit "-r requirements.txt"

run_test "pip-audit: Informative warning on missing manifest" bash -c "rm -f $WORKSPACE/requirements.txt $WORKSPACE/pyproject.toml; bash $SCRIPT_PATH --path $WORKSPACE --python --run-supplychain 2>&1 | grep 'WARNING'"
# Reseed workspace after destructive test to restore baseline for downstream verification
touch "$WORKSPACE/requirements.txt" "$WORKSPACE/pyproject.toml"

# Test Logic: Bandit Security Scan
run_test "Bandit: Correctly receives security flags" verify_flag_present bandit "-q -r -l -iii"

# Test Logic: ast-grep Rule-Based Scanning
# We verify that ast-grep leverages the rules/ directory instead of inline patterns.
echo " --> Verifying ast-grep Rule-Based Scan Trigger..."
rm -f "$MARKS"/ast-grep*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --python --run-logic > /dev/null 2>&1
run_test "ast-grep: Correctly triggers python-audit.yml" verify_flag_present ast-grep "scan --config"
run_test "ast-grep: Targeted config verified" verify_flag_present ast-grep "python-audit.yml"

# Test 3: Flag Integrity & Fix Mode Logic
# We verify that 'Fix' flags are ONLY propagated when --fix is set.
# shellcheck disable=SC2329
verify_fix_flags() {
    local mode="$1"
    local tool="$2"
    local expected_flag="$3"
    local args=""
    [ -f "$MARKS/$tool.args" ] && args="$(cat "$MARKS/$tool.args")"
    
    # We use grep-style matching because tools might be called multiple times (e.g. ruff)
    if [[ "$mode" == "FIX_ON" ]]; then
        if [[ "$args" == *"$expected_flag"* ]]; then
            printf "  [✓] %-15s : Correctly received '%s'\n" "$tool" "$expected_flag"
            return 0
        else
            printf "  [✗] %-15s : MISSING expected flag '%s'. Got: '%s'\n" "$tool" "$expected_flag" "$args"
            return 1
        fi
    else
        if [[ "$args" == *"$expected_flag"* ]]; then
            printf "  [✗] %-15s : INCORRECTLY received '%s' in check-only mode!\n" "$tool" "$expected_flag"
            return 1
        else
            printf "  [✓] %-15s : Correctly omitted '%s'\n" "$tool" "$expected_flag"
            return 0
        fi
    fi
}

# Specialized check for inverted/mandatory flags.
# shellcheck disable=SC2329

echo "--> Verifying Default Mode (Check-Only)..."
rm -f "$MARKS"/*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --auto > /dev/null 2>&1
run_test "Fix Safeguard: ruff check (No --fix)" verify_fix_flags FIX_OFF ruff --fix
run_test "Fix Safeguard: biome check (No --write)" verify_fix_flags FIX_OFF biome --write
run_test "Fix Safeguard: gofumpt (Check-Only -> -l)" verify_flag_present gofumpt -l
run_test "Fix Safeguard: oxfmt (Check-Only -> --check)" verify_flag_present oxfmt --check

echo "--> Verifying Fix Mode (Active Corrections)..."
rm -f "$MARKS"/*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --auto --fix > /dev/null 2>&1
run_test "Fix Propagation: ruff check --fix" verify_fix_flags FIX_ON ruff --fix
run_test "Fix Propagation: biome check --write" verify_fix_flags FIX_ON biome --write
run_test "Fix Propagation: oxlint --fix" verify_fix_flags FIX_ON oxlint --fix
run_test "Fix Propagation: gofumpt -l -w" verify_fix_flags FIX_ON gofumpt -w
run_test "Fix Propagation: golangci-lint --fix" verify_fix_flags FIX_ON golangci-lint --fix
run_test "Fix Propagation: semgrep --autofix" verify_fix_flags FIX_ON semgrep --autofix
run_test "Fix Propagation: pip-audit --fix" verify_fix_flags FIX_ON pip-audit --fix
run_test "Fix Propagation: oxfmt (Fix -> omit --check)" verify_fix_flags FIX_OFF oxfmt --check

# Test 4: Isolation Logic
run_test "Python Isolation" verify_isolation "[Python]" --path "$WORKSPACE" --python
run_test "Golang Isolation" verify_isolation "[Golang]" --path "$WORKSPACE" --golang

# Test 5: Go Core Security Promotion
echo " --> Verifying Go Core Security Promotion (Non-Extended)..."
rm -f "$MARKS"/*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --golang > /dev/null 2>&1
run_test "Go Core Security: gosec executed" test -f "$MARKS/gosec"
run_test "Go Core Security: govulncheck executed" test -f "$MARKS/govulncheck"
run_test "Go Core Security: nilaway skipped (Extended-only)" test ! -f "$MARKS/nilaway"

# Test 5: Selective Phase Execution & Applicability
echo "--> Verifying Selective Phase: Quality Logic..."
rm -f "$MARKS"/*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --run-quality > /dev/null 2>&1
run_test "Selective Quality: Ruff Called" test -f "$MARKS/ruff"
run_test "Selective Quality: TruffleHog Skipped" test ! -f "$MARKS/trufflehog"

echo "--> Verifying Selective Phase: Logic/Safety..."
rm -f "$MARKS"/*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --run-logic > /dev/null 2>&1
run_test "Selective Logic: Semgrep Called" test -f "$MARKS/semgrep"
run_test "Selective Logic: Ruff Skipped" test ! -f "$MARKS/ruff"

echo "--> Verifying Selective Phase: Secrets Logic..."
rm -f "$MARKS"/*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --run-detectsecrets > /dev/null 2>&1
run_test "Selective Secrets: TruffleHog Called" test -f "$MARKS/trufflehog"
run_test "Selective Secrets: Ruff Skipped" test ! -f "$MARKS/ruff"

echo "--> Verifying Selective Phase: Supply Chain..."
rm -f "$MARKS"/*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --run-supplychain > /dev/null 2>&1
run_test "Selective SupplyChain: Grype Called" test -f "$MARKS/grype"
run_test "Selective SupplyChain: Ruff Skipped" test ! -f "$MARKS/ruff"

echo "--> Verifying Applicability Warning: Cleanup on Golang..."
rm -f "$MARKS"/*
bash "$SCRIPT_PATH" --path "$WORKSPACE" --run-cleanup --golang > "$TEST_ROOT/app_warn" 2>&1
run_test "Applicability INFO: Cleanup correctly skipped for Go" grep "INFO: Phase 3 (Cleanup) is currently only applicable for Python projects." "$TEST_ROOT/app_warn"

# Test 6: Installation Logic & Scope Validation
echo " --> Verifying Scope Validation for Installation..."
# Flag --install without scope should fail
run_test "Install Rejection: Missing Scope" test_fails bash "$SCRIPT_PATH" --path "$WORKSPACE" --install

# We use a restricted path to ensure the orchestrator doesn't find real system tools.
RESTRICTED_PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/c/Windows/system32"

echo " --> Verifying Installation Trigger: Python (UV)..."
rm -f "$MOCK_BIN/vulture" # Simulate missing tool to trigger install
rm -f "$MARKS"/*
PATH="$RESTRICTED_PATH" bash "$SCRIPT_PATH" --path "$WORKSPACE" --python --install-only > "$TEST_ROOT/install_debug" 2>&1
run_test "Installation: uv tool called" grep 'tool install' "$MARKS/uv.args"
run_test "Installation: pip fallback avoided (mock uv exists)" test_fails grep 'pip install' "$MARKS/python3.args"

echo " --> Verifying Installation Trigger: Node (NPM Prefix)..."
rm -f "$MOCK_BIN/biome" # Simulate missing tool
rm -f "$MARKS"/*
PATH="$RESTRICTED_PATH" bash "$SCRIPT_PATH" --path "$WORKSPACE" --nodejs --install-only > /dev/null 2>&1
run_test "Installation: npm prefix configured" grep 'config set prefix' "$MARKS/npm.args"
run_test "Installation: npm global install called" grep 'install -g' "$MARKS/npm.args"

echo " --> Verifying Installation Trigger: Golang..."
rm -f "$MOCK_BIN/govulncheck" # Simulate missing tool
rm -f "$MARKS"/*
PATH="$RESTRICTED_PATH" bash "$SCRIPT_PATH" --path "$WORKSPACE" --golang --install-only > /dev/null 2>&1
run_test "Installation: go install called" grep 'install' "$MARKS/go.args"

echo " --> Verifying Installation Trigger: General (Script)..."
rm -f "$MOCK_BIN/grype" "$MOCK_BIN/syft" "$MOCK_BIN/trufflehog" "$MOCK_BIN/trivy" # Simulate missing tools
rm -f "$MARKS"/*
PATH="$RESTRICTED_PATH" bash "$SCRIPT_PATH" --path "$WORKSPACE" --general --install-only > /dev/null 2>&1
run_test "Installation: curl script called for grype/syft/trufflehog/trivy" grep "raw.githubusercontent.com" "$MARKS/curl.args"

# 7. Update Lifecycle
# -----------------------------------------------------------------------------
echo "--> Verifying Update Resilience: Local vs Global..."

# Restore any mocks removed by previous tests
generate_mocks

# Setup global bin simulation
GLOBAL_MOCK_BIN="$TEST_ROOT/global_bin"
mkdir -p "$GLOBAL_MOCK_BIN"
cp "$MOCK_BIN/ruff" "$GLOBAL_MOCK_BIN/"

# Setup local node simulation
LOCAL_NODE_BIN="$HOME/.npm-global/bin"
mkdir -p "$LOCAL_NODE_BIN"
cp "$MOCK_BIN/biome" "$LOCAL_NODE_BIN/"

# We use a PATH that includes our global mock bin first, then our local mocks.
# In the real script, it appends local bins, so we need to be careful.
# Actually, the script checks if $(command -v tool) starts with local prefix.
# If we put ruff in GLOBAL_MOCK_BIN and put GLOBAL_MOCK_BIN in PATH, command -v ruff returns global path.

echo " --> Verifying Update Trigger: Local (Biome)..."
rm -f "$MARKS"/*
PATH="$LOCAL_NODE_BIN:$RESTRICTED_PATH" bash "$SCRIPT_PATH" --path "$WORKSPACE" --nodejs --update-only > /dev/null 2>&1
run_test "Update: Local tool (biome) triggered npm" grep 'install -g @biomejs/biome' "$MARKS/npm.args"

echo " --> Verifying Update Skip: Global (Ruff)..."
rm -f "$MARKS"/*
# We put ruff in global bin and ensure it's found there.
PATH="$GLOBAL_MOCK_BIN:$RESTRICTED_PATH" bash "$SCRIPT_PATH" --path "$WORKSPACE" --python --update-only > /dev/null 2>&1
run_test "Update: Global tool (ruff) skipped uv" test ! -f "$MARKS/uv.args"

# 8. Final Summary
# -----------------------------------------------------------------------------
echo ""
echo "---------------------------------------------------------"
if [ "$FAILED_TESTS" -eq 0 ]; then
    echo "SUCCESS: All unit tests passed with 100% tool coverage."
    echo "Cleaning up test environment..."
    exit 0
else
    echo "FAILURE: $FAILED_TESTS tests failed."
    exit 1
fi
