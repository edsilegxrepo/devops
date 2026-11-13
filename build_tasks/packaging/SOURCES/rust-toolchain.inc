# ==============================================================================
# File:        /usr/src/packages/TEMPLATE/SOURCES/rust-toolchain.inc
# Purpose:     Common toolchain validation and definitions for static Rust/musl packages
# Usage:       %%include %%{_sourcedir}/rust-toolchain.inc
#
# Objectives:
#   Enforce bit-for-bit reproducible static Rust compilation via Zig musl and
#   Windows GNU cross-compilation, fail fast on missing stdlib targets, and
#   provide uniform test, security audit, and static analysis hooks.
#
# Core Components:
#   - Probes & guards: has_cargo, has_rustc, has_musl_std, has_win_std,
#     has_zig (from pkg-common.inc), plus optional cargo-{clippy,fmt,audit,...}.
#   - Configuration: rustflags_core, rust_target_linux, rust_target_win,
#     cargo_features, cargo_update.
#   - Lifecycle macros: %%rust_build_target, %%rust_security_audit,
#     %%rust_lint_checks, %%rust_run_tests.
#
# Functionality & Data Flows:
#   1. Includes pkg-common.inc and validates cargo, rustc, zig >= 0.17, and
#      musl/windows target sysroots at spec parse time.
#   2. %%rust_build_target optionally compiles static SQLite via SOURCE10 (zig-musl.sh
#      build-sqlite), exports SQLITE3_* / RUSTFLAGS, and invokes zig-musl.sh cargo.
#   3. Copies release artifacts to bin/<bin_name> or bin/windows/<bin_name>.exe.
# ==============================================================================

%include %{_sourcedir}/pkg-common.inc

# ------------------------------------------------------------------------------
# 1. Toolchain, Target Stdlib & Optional QA Tool Detection
# ------------------------------------------------------------------------------
# Validate core Rust toolchain binaries and installed target standard libraries
%global has_cargo         %(command -v cargo >/dev/null 2>&1 && echo 1 || echo 0)
%global has_rustc         %(command -v rustc >/dev/null 2>&1 && echo 1 || echo 0)
%global has_musl_std      %(target_dir=$(rustc --target %{_arch}-unknown-linux-musl --print target-libdir 2>/dev/null); [ -d "${target_dir}" ] && echo 1 || echo 0)
%global has_win_std       %(target_dir=$(rustc --target x86_64-pc-windows-gnu --print target-libdir 2>/dev/null); [ -d "${target_dir}" ] && echo 1 || echo 0)

# Optional installed Rust lint, audit, and test tooling
%global has_cargo_clippy  %(command -v cargo-clippy >/dev/null 2>&1 && echo 1 || echo 0)
%global has_cargo_fmt     %(command -v cargo-fmt >/dev/null 2>&1 && echo 1 || echo 0)
%global has_cargo_audit   %(command -v cargo-audit >/dev/null 2>&1 && echo 1 || echo 0)
%global has_cargo_deny    %(command -v cargo-deny >/dev/null 2>&1 && echo 1 || echo 0)
%global has_cargo_machete %(command -v cargo-machete >/dev/null 2>&1 && echo 1 || echo 0)
%global has_cargo_nextest %(command -v cargo-nextest >/dev/null 2>&1 && echo 1 || echo 0)
%global has_cargo_bloat   %(command -v cargo-bloat >/dev/null 2>&1 && echo 1 || echo 0)

# ------------------------------------------------------------------------------
# 2. Compiler Flag Policy, Target Triples & Preflight Guards
# ------------------------------------------------------------------------------
# Standard Rust compilation flags for symbol stripping and reproducible paths
%{!?rustflags_core:%global rustflags_core -C strip=symbols --remap-path-prefix ${PWD}=.}

# Canonical Rust target triples (overridable per spec)
%{!?rust_target_linux:%global rust_target_linux %{_arch}-unknown-linux-musl}
%{!?rust_target_win:%global rust_target_win     x86_64-pc-windows-gnu}
%{!?cargo_features:%global cargo_features       %{nil}}

# Standard Cargo dependency update command (fault-tolerant fallback for offline/locked builds)
%{!?cargo_update:%global cargo_update cargo update --recursive >/dev/null 2>&1 || :}

# Preflight toolchain assertions (abort rpmbuild early on missing dependencies)
%if ! %{has_cargo} || ! %{has_rustc}
%{error:Rust toolchain (cargo/rustc) not found in PATH}
%endif

%if ! %{has_zig}
%{error:Zig compiler (0.17+) not found in PATH for static musl linking}
%endif

%if ! %{has_musl_std}
%{error:Rust standard library for %{_arch}-unknown-linux-musl is not installed. Please run /opt/scripts/rust_upgrade.sh to install it.}
%endif

%if 0%{?_with_windows:1} && ! %{has_win_std}
%{error:Rust standard library for %{rust_target_win} is not installed. Please run /opt/scripts/rust_upgrade.sh to install it.}
%endif

# ------------------------------------------------------------------------------
# 3. Build, Security Audit, Static Analysis & Testsuite Macros
# ------------------------------------------------------------------------------
# Compile target binary (usage: %%rust_build_target linux | %%rust_build_target windows)
%define rust_build_target() \
_rs_target_os="%{1}" \
mkdir -p bin \
chmod +x %{SOURCE10} 2>/dev/null || : \
export RUSTFLAGS="%{rustflags_core}" \
if [ "${_rs_target_os}" = "windows" ]; then \
  _rs_triple="%{rust_target_win}" \
  _rs_zig_arch="${_rs_triple%%%%-*}" \
  _rs_zig_triple="${_rs_zig_arch}-windows-gnu" \
  _rs_ext=".exe" \
else \
  _rs_triple="%{rust_target_linux}" \
  _rs_zig_triple="%{_arch}-linux-musl" \
  _rs_ext="" \
fi \
%if %{use_sqlite} \
_rs_sqlite_src="$(cd ../%{sqlitedir}/sqlite-amalgamation-* 2>/dev/null && pwd)" \
_rs_sqlite_lib="$(pwd)/.sqlite_lib_${_rs_target_os}" \
echo "==> [${_rs_target_os}] Compiling static SQLite %{sqlitedotver} via Zig (target: ${_rs_zig_triple})..." \
bash %{SOURCE10} build-sqlite "${_rs_zig_triple}" "${_rs_sqlite_src}" "${_rs_sqlite_lib}" %{sqlite_amalgamation_cflags} \
export SQLITE3_LIB_DIR="${_rs_sqlite_lib}" \
export SQLITE3_INCLUDE_DIR="${_rs_sqlite_src}" \
export SQLITE3_STATIC=1 \
if [ "${_rs_target_os}" = "linux" ]; then export CFLAGS="%{sqlite_amalgamation_cflags}"; fi \
%endif \
echo "==> [${_rs_target_os}] Compiling static %{bin_name} binary with Zig + cargo (${_rs_triple})..." \
%{SOURCE10} cargo build --release --target "${_rs_triple}" %{?cargo_features:%{cargo_features}} \
if [ "${_rs_target_os}" = "windows" ]; then \
  mkdir -p bin/windows \
  cp -af "target/${_rs_triple}/release/%{bin_name}.exe" "bin/windows/" \
else \
  cp -af "target/${_rs_triple}/release/%{bin_name}" "bin/%{bin_name}" \
  chmod 0755 "bin/%{bin_name}" \
fi

# Security & license audit (opt-in via --with audit)
%define rust_security_audit \
if [ "%{has_cargo_audit}" = "1" ] && [ -f Cargo.lock ]; then \
  echo "==> Running cargo audit..." \
  cargo audit --no-fetch 2>/dev/null || cargo audit || echo "NOTICE: cargo audit advisory check incomplete (offline or uncached advisory-db)" \
fi \
if [ "%{has_cargo_deny}" = "1" ]; then \
  echo "==> Running cargo deny..." \
  if [ -f deny.toml ]; then \
    cargo deny check || : \
  else \
    cargo deny check advisories --offline 2>/dev/null || true \
  fi \
fi

# Static code, unused dependency, and binary footprint checks (opt-in via --with lint)
%define rust_lint_checks \
chmod +x %{SOURCE10} 2>/dev/null || : \
if [ "%{has_cargo_fmt}" = "1" ]; then \
  echo "==> Running cargo fmt --check..." \
  cargo fmt --check || echo "NOTICE: upstream formatting differs from rustfmt defaults" \
fi \
if [ "%{has_cargo_clippy}" = "1" ]; then \
  echo "==> Running cargo clippy (target: %{rust_target_linux})..." \
  %{SOURCE10} cargo clippy --target "%{rust_target_linux}" %{?cargo_features:%{cargo_features}} -- -W clippy::all || : \
fi \
if [ "%{has_cargo_machete}" = "1" ]; then \
  echo "==> Running cargo machete..." \
  cargo machete || : \
fi \
if [ "%{has_cargo_bloat}" = "1" ]; then \
  echo "==> Running cargo bloat (top 10 symbols)..." \
  %{SOURCE10} cargo bloat --release --target "%{rust_target_linux}" %{?cargo_features:%{cargo_features}} -n 10 || : \
fi

# Testsuite runner (prefers cargo-nextest when available, falls back to cargo test)
%define rust_run_tests \
chmod +x %{SOURCE10} 2>/dev/null || : \
if [ "%{has_cargo_nextest}" = "1" ]; then \
  %{SOURCE10} cargo nextest run --target "%{rust_target_linux}" %{?cargo_features:%{cargo_features}} \
else \
  %{SOURCE10} cargo test --release --target "%{rust_target_linux}" %{?cargo_features:%{cargo_features}} \
fi
