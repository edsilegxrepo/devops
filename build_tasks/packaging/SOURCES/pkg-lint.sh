#!/bin/bash
# ==============================================================================
# Script:      /usr/src/packages/TEMPLATE/SOURCES/pkg-lint.sh
# Purpose:     Pre-flight validator for spec files, RPM macro expansion, helper
#              shell syntax, pkg-make.sh template rendering, and TEMPLATE sync.
#
# Objectives:
#   Catch shell syntax errors, TEMPLATE/live drift, broken RPM macro expansions,
#   rpmlint/lintian issues, and optional language/security findings prior to build.
#
# Core Components:
#   - Check helpers (`fail`, `warn`, `check_rpmspec`) with clean mktemp trap.
#   - Stage [1/4]: bash -n, +x mode, and shellcheck on TEMPLATE/SOURCES and TOPDIR/SOURCES.
#   - Stage [2/4]: Byte-for-byte sync check (cmp -s) of shared helpers/includes.
#   - Stage [3/4-3c]: rpmspec -P across live specs + pkg-make.sh rendered Go/Rust smoke specs.
#   - Stage [4/4]: rpmlint on specs, lintian on STAGING/*.deb, optional --go-dir/--rust-dir/--scan.
#
# Functionality & Data Flows:
#   1. Parses options (--topdir, --strict, --go-dir, --rust-dir, --deb, --scan, specs).
#   2. Runs stages [1/4]-[4/4] accumulating FAILURES and WARNINGS without aborting early.
#   3. Prints Lint summary and exits non-zero if FAILURES > 0 (or WARNINGS > 0 under --strict).
#
# Synopsis:
#   pkg-lint.sh [--topdir <path>] [--strict] [--go-dir <path>] [--rust-dir <path>]
#               [--deb <file.deb>] [--scan <path>] [specfile ...]
# ==============================================================================
set -eo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults & CLI Option Parsing
# ------------------------------------------------------------------------------
TOPDIR="${RPM_TOPDIR:-/usr/src/redhat}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEMPLATE_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
export PATH="${PATH}:/var/opt/tools"
STRICT=0
SPECS=()
RUST_DIRS=()
GO_DIRS=()
SCAN_PATHS=()
DEB_FILES=()

# Print CLI help message and exit cleanly
usage() {
  cat << EOF
Usage: $(basename "$0") [--topdir <path>] [--strict] [--go-dir <path>] [--rust-dir <path>] [--deb <file.deb>] [--scan <path>] [specfile ...]

Validates:
  1. Bash syntax (bash -n), +x mode, and shellcheck (when installed) on helper scripts in TEMPLATE/SOURCES and TOPDIR/SOURCES.
  2. File synchronization (cmp -s) of shared helpers/includes between TEMPLATE and TOPDIR.
  3. RPM macro expansion (rpmspec -P) on concrete specs and pkg-make.sh rendered templates.
  4. Package lint checks via rpmlint (when installed) and Debian package checks via lintian (--deb or STAGING/*.deb, when installed).
  5. Go module lint/security checks (--go-dir, repeatable: go vet, gofumpt, golangci-lint, staticcheck, gosec, govulncheck).
  6. Rust workspace/crate lint/audit checks (--rust-dir, repeatable).
  7. Filesystem vulnerability & secret scanning (--scan, repeatable: trivy, trufflehog).
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --topdir) TOPDIR="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --go-dir) GO_DIRS+=("$2"); shift 2 ;;
    --rust-dir) RUST_DIRS+=("$2"); shift 2 ;;
    --deb) DEB_FILES+=("$2"); shift 2 ;;
    --scan) SCAN_PATHS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    -*)
      echo "ERROR: Unknown option '$1'" >&2
      exit 1
      ;;
    *)
      SPECS+=("$1")
      shift
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 2. Reporting & Spec Expansion Helpers
# ------------------------------------------------------------------------------
FAILURES=0
WARNINGS=0

# Record an error finding and increment FAILURES counter
fail() {
  echo "ERROR: $1" >&2
  FAILURES=$((FAILURES + 1))
}

# Record a warning finding and increment WARNINGS counter
warn() {
  echo "WARNING: $1" >&2
  WARNINGS=$((WARNINGS + 1))
}

# Expand an RPM spec under both default and full multi-target flags to catch macro errors
check_rpmspec() {
  local spec="$1"
  local spec_top="$2"
  local spec_src="$3"
  local mode
  for mode in "default" "--with windows --with archive --with deb --with testsuite --with lint --with audit"; do
    read -r -a mode_args <<< "${mode#default}"
    if ! err_out="$(rpmspec -P --define "_topdir ${spec_top}" --define "_sourcedir ${spec_src}" "${mode_args[@]}" "$spec" 2>&1 >/dev/null)"; then
      fail "rpmspec -P failed for $spec (${mode}): ${err_out}"
    fi
  done
}

# ------------------------------------------------------------------------------
# 3. Stage [1/4]: Shell Script Syntax, Execute Permissions & ShellCheck
# ------------------------------------------------------------------------------

echo "==> [1/4] Checking shell script syntax (bash -n / shellcheck)..."
for dir in "${TEMPLATE_ROOT}/SOURCES" "${TOPDIR}/SOURCES"; do
  [ -d "$dir" ] || continue
  for sh in "$dir"/*.sh; do
    [ -e "$sh" ] || continue
    if ! bash -n "$sh"; then
      fail "Syntax error in $sh"
    fi
    if [ ! -x "$sh" ]; then
      warn "Script is not executable (+x): $sh"
    fi
    if command -v shellcheck >/dev/null 2>&1 && [ -x "$(command -v shellcheck)" ]; then
      if ! shellcheck -S warning "$sh"; then
        warn "shellcheck reported warnings in $sh"
      fi
    fi
  done
done

# ------------------------------------------------------------------------------
# 4. Stage [2/4]: TEMPLATE <-> TOPDIR Synchronization Check
# ------------------------------------------------------------------------------
echo "==> [2/4] Checking TEMPLATE <-> ${TOPDIR}/SOURCES synchronization..."
SHARED_FILES=(
  "pkg-common.inc"
  "go-toolchain.inc"
  "rust-toolchain.inc"
  "pkg-deb.sh"
  "pkg-verify.sh"
  "zig-musl.sh"
  "pkg-make.sh"
  "pkg-fetch-src.sh"
)
for f in "${SHARED_FILES[@]}"; do
  tmpl="${TEMPLATE_ROOT}/SOURCES/${f}"
  live="${TOPDIR}/SOURCES/${f}"
  [ -f "$tmpl" ] || { fail "Missing template helper: $tmpl"; continue; }
  if [ -f "$live" ]; then
    if ! cmp -s "$tmpl" "$live"; then
      fail "Out of sync: $live differs from $tmpl"
    fi
  else
    echo "    (skipped optional absent live helper: $live)"
  fi
done

if [ ${#SPECS[@]} -eq 0 ]; then
  for s in "${TOPDIR}/SPECS"/*.spec; do
    [ -e "$s" ] && SPECS+=("$s")
  done
fi

# ------------------------------------------------------------------------------
# 5. Stage [3/4]: RPM Macro Expansion & Template Smoke Rendering
# ------------------------------------------------------------------------------
echo "==> [3/4] Validating RPM macro expansion (rpmspec -P) on ${#SPECS[@]} concrete spec(s)..."
for spec in "${SPECS[@]}"; do
  [ -f "$spec" ] || { fail "Spec not found: $spec"; continue; }
  check_rpmspec "$spec" "$TOPDIR" "${TOPDIR}/SOURCES"
done

TMP_RENDER="$(mktemp -d)"
# Safely clean temporary template rendering directory on exit
# shellcheck disable=SC2329  # Invoked indirectly via trap EXIT
cleanup_tmp_render() {
  if [ -n "${TMP_RENDER:-}" ] && [ "${TMP_RENDER}" != "/" ] && [ -d "${TMP_RENDER}" ]; then
    rm -rf -- "$TMP_RENDER"
  fi
}
trap cleanup_tmp_render EXIT
mkdir -p "${TMP_RENDER}/SPECS" "${TMP_RENDER}/SOURCES"
if command -v go >/dev/null 2>&1; then
  echo "==> [3b/4] Smoke-testing pkg-make.sh rendering + rpmspec -P (Go pure + daemon + completions + exclude)..."
  if RPM_TOPDIR="$TMP_RENDER" bash "${TEMPLATE_ROOT}/SOURCES/pkg-make.sh" \
      --platform go --name lintgo --version 1.0.0 --git-hash abc1234 --daemon \
      --bin-name lintgobin --license-file COPYING --completion-cmd completion \
      --exclude windows --repo-url https://github.com/example/lintgo --deb-section net >/dev/null 2>&1; then
    check_rpmspec "${TMP_RENDER}/SPECS/lintgo-xg.spec" "$TMP_RENDER" "${TMP_RENDER}/SOURCES"
  else
    fail "pkg-make.sh failed rendering Go daemon test spec"
  fi
fi
if command -v zig >/dev/null 2>&1 || [ -x /var/opt/zig/zig ] || [ -x /u01/zig/zig ] || [ -x /usr/local/bin/zig ] || [ -x /opt/zig/zig ]; then
  if command -v go >/dev/null 2>&1; then
    echo "==> [3b2/4] Smoke-testing pkg-make.sh rendering + rpmspec -P (Go CGO + SQLite)..."
    if RPM_TOPDIR="$TMP_RENDER" bash "${TEMPLATE_ROOT}/SOURCES/pkg-make.sh" \
        --platform go --name lintgocgo --version 1.0.0 --git-hash abc1234 \
        --cgo --sqlite --exclude deb --repo-url https://github.com/example/lintgocgo >/dev/null 2>&1; then
      check_rpmspec "${TMP_RENDER}/SPECS/lintgocgo-xg.spec" "$TMP_RENDER" "${TMP_RENDER}/SOURCES"
    else
      fail "pkg-make.sh failed rendering Go CGO+SQLite test spec"
    fi
  fi
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    echo "==> [3c/4] Smoke-testing pkg-make.sh rendering + rpmspec -P (Rust CLI)..."
    if RPM_TOPDIR="$TMP_RENDER" bash "${TEMPLATE_ROOT}/SOURCES/pkg-make.sh" \
        --platform rust --name lintrs --version 1.0.0 --git-hash abc1234 --sqlite \
        --completion-cmd "completions" --repo-url https://github.com/example/lintrs >/dev/null 2>&1; then
      check_rpmspec "${TMP_RENDER}/SPECS/lintrs-xg.spec" "$TMP_RENDER" "${TMP_RENDER}/SOURCES"
    else
      fail "pkg-make.sh failed rendering Rust test spec"
    fi
  fi
else
  echo "    (Zig not present in current PATH; skipped Rust/CGO template rpmspec smoke test)"
fi

# ------------------------------------------------------------------------------
# 6. Stage [4/4]: Spec (rpmlint), Rust, Go, Debian (lintian) & Artifact Scans
# ------------------------------------------------------------------------------
echo "==> [4/4] Running rpmlint..."
if command -v rpmlint >/dev/null 2>&1; then
  for spec in "${SPECS[@]}"; do
    [ -f "$spec" ] || continue
    lint_out="$(rpmlint "$spec" 2>&1 || true)"
# Filter known false positives from RPM_SOURCE_DIR / partial query mode
    filtered="$(echo "$lint_out" | grep -vE "use-of-RPM_SOURCE_DIR|specfile-error error: query of specfile" || true)"
    if grep -qE "^.+: E: " <<< "$filtered"; then
      echo "$filtered" >&2
      fail "rpmlint reported errors for $spec"
    elif grep -qE "^.+: W: " <<< "$filtered"; then
      echo "$filtered"
      warn "rpmlint reported warnings for $spec"
    fi
  done
else
  echo "    (rpmlint not installed; skipped)"
fi

if [ ${#RUST_DIRS[@]} -gt 0 ]; then
  echo "==> Checking Rust workspaces/crates (--rust-dir)..."
  for rust_dir in "${RUST_DIRS[@]}"; do
    if [ ! -f "${rust_dir}/Cargo.toml" ]; then
      fail "Rust Cargo.toml not found in ${rust_dir}"
      continue
    fi
    echo "    -> ${rust_dir}"
    (
      cd "$rust_dir" || exit 1
      if cargo fmt --version >/dev/null 2>&1; then
        if ! cargo fmt --all -- --check; then
          exit 10
        fi
      fi
    )
    rc=$?
    if [ "$rc" -eq 10 ]; then
      fail "cargo fmt --check failed in ${rust_dir}"
    elif [ "$rc" -ne 0 ]; then
      fail "failed to enter ${rust_dir}"
      continue
    fi

    (
      cd "$rust_dir" || exit 1
      if cargo clippy --version >/dev/null 2>&1; then
        if [ "$STRICT" -eq 1 ]; then
          cargo clippy --all-targets -- -D warnings
        else
          cargo clippy --all-targets -- -W clippy::all
        fi
      fi
    ) || fail "cargo clippy failed in ${rust_dir}"

    if command -v cargo-machete >/dev/null 2>&1; then
      (
        cd "$rust_dir" || exit 1
        cargo machete
      ) || warn "cargo machete reported unused dependencies in ${rust_dir}"
    fi

    if command -v cargo-audit >/dev/null 2>&1; then
      if [ -f "${rust_dir}/Cargo.lock" ]; then
        if ! (cd "$rust_dir" && cargo audit 2>/dev/null || cargo audit --no-fetch 2>/dev/null); then
          warn "cargo audit could not verify advisories in ${rust_dir} (missing advisory-db, offline, or advisories present)"
        fi
      else
        echo "    (cargo audit skipped in ${rust_dir}: Cargo.lock not generated yet)"
      fi
    fi

    if command -v cargo-deny >/dev/null 2>&1; then
      if [ -f "${rust_dir}/deny.toml" ] || [ -f "${rust_dir}/.cargo/deny.toml" ]; then
        (
          cd "$rust_dir" || exit 1
          cargo deny check
        ) || fail "cargo deny check failed in ${rust_dir}"
      else
        echo "    (cargo deny skipped in ${rust_dir}: no deny.toml)"
      fi
    fi

    if cargo outdated --version >/dev/null 2>&1; then
      if ! (cd "$rust_dir" && cargo outdated --root-deps-only --exit-code 1 2>/dev/null); then
        warn "cargo outdated reported outdated dependencies or offline registry in ${rust_dir}"
      fi
    fi

    if command -v cargo-geiger >/dev/null 2>&1; then
      if [ -f "${rust_dir}/Cargo.lock" ]; then
        (
          cd "$rust_dir" || exit 1
          cargo geiger --quiet || true
        )
      fi
    fi

    if command -v cargo-semver-checks >/dev/null 2>&1; then
      if grep -q '^\[lib\]' "${rust_dir}/Cargo.toml" || [ -f "${rust_dir}/src/lib.rs" ]; then
        (
          cd "$rust_dir" || exit 1
          cargo semver-checks check-release || true
        )
      fi
    fi
  done
fi

if [ ${#GO_DIRS[@]} -gt 0 ]; then
  echo "==> Checking Go modules (--go-dir)..."
  for go_dir in "${GO_DIRS[@]}"; do
    if [ ! -f "${go_dir}/go.mod" ]; then
      fail "Go go.mod not found in ${go_dir}"
      continue
    fi
    echo "    -> ${go_dir}"
    (
      cd "$go_dir" || exit 1
      go vet ./...
    ) || fail "go vet failed in ${go_dir}"

    if command -v gofumpt >/dev/null 2>&1 && [ -x "$(command -v gofumpt)" ]; then
      fmt_out="$(cd "$go_dir" && gofumpt -l . || true)"
      if [ -n "$fmt_out" ]; then
        echo "$fmt_out" | head -n 20
        warn "gofumpt reported unformatted files in ${go_dir}"
      fi
    fi

    if command -v golangci-lint >/dev/null 2>&1 && [ -x "$(command -v golangci-lint)" ]; then
      (
        cd "$go_dir" || exit 1
        golangci-lint run ./...
      ) || fail "golangci-lint reported issues in ${go_dir}"
    fi

    if command -v staticcheck >/dev/null 2>&1 && [ -x "$(command -v staticcheck)" ]; then
      (
        cd "$go_dir" || exit 1
        staticcheck ./...
      ) || warn "staticcheck reported findings in ${go_dir}"
    fi

    if command -v gosec >/dev/null 2>&1 && [ -x "$(command -v gosec)" ]; then
      (
        cd "$go_dir" || exit 1
        gosec -quiet ./...
      ) || warn "gosec reported security findings in ${go_dir}"
    fi

    if command -v govulncheck >/dev/null 2>&1 && [ -x "$(command -v govulncheck)" ]; then
      if ! (cd "$go_dir" && govulncheck ./...); then
        warn "govulncheck reported vulnerabilities or offline DB in ${go_dir}"
      fi
    fi
  done
fi

if [ ${#DEB_FILES[@]} -eq 0 ] && [ -d "${TOPDIR}/STAGING" ]; then
  for _deb in "${TOPDIR}/STAGING"/*.deb; do
    [ -e "$_deb" ] && DEB_FILES+=("$_deb")
  done
fi

if [ ${#DEB_FILES[@]} -gt 0 ]; then
  echo "==> Checking Debian packages (lintian)..."
  if command -v lintian >/dev/null 2>&1; then
    for deb_file in "${DEB_FILES[@]}"; do
      if [ ! -f "$deb_file" ]; then
        fail "Debian package not found: ${deb_file}"
        continue
      fi
      echo "    -> ${deb_file}"
      set +e
      lintian_out="$(lintian --tag-display-limit 0 "$deb_file" 2>&1)"
      lintian_rc=$?
      set -e
      [ -n "$lintian_out" ] && printf '%s\n' "$lintian_out"
      if [ "$lintian_rc" -eq 2 ]; then
        warn "lintian reported policy findings in ${deb_file}"
      elif [ "$lintian_rc" -ne 0 ]; then
        fail "lintian failed with exit status ${lintian_rc} on ${deb_file}"
      fi
    done
  else
    echo "    (lintian not installed; skipped)"
  fi
fi

if [ ${#SCAN_PATHS[@]} -gt 0 ]; then
  echo "==> Scanning filesystem/artifacts (--scan)..."
  for scan_path in "${SCAN_PATHS[@]}"; do
    if [ ! -e "$scan_path" ]; then
      fail "Scan target not found: ${scan_path}"
      continue
    fi
    echo "    -> ${scan_path}"
    if command -v trivy >/dev/null 2>&1 && [ -x "$(command -v trivy)" ]; then
      trivy fs --quiet --severity HIGH,CRITICAL "$scan_path" || warn "trivy reported findings in ${scan_path}"
    fi
    if command -v trufflehog >/dev/null 2>&1 && [ -x "$(command -v trufflehog)" ]; then
      trufflehog filesystem --no-update --fail "$scan_path" || fail "trufflehog detected secrets in ${scan_path}"
    fi
  done
fi

# ------------------------------------------------------------------------------
# 7. Final Lint Summary & Exit Status
# ------------------------------------------------------------------------------
echo ""
echo "==> Lint summary: ${FAILURES} error(s), ${WARNINGS} warning(s)."
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$WARNINGS" -gt 0 ]; then
  exit 1
fi
exit 0
