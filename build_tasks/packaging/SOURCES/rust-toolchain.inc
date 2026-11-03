# ==============================================================================
# Common toolchain validation and definitions for static Rust/musl packages
# ==============================================================================

%include %{_sourcedir}/pkg-common.inc

# Validate toolchain binaries and target standard libraries
%global has_cargo       %(command -v cargo >/dev/null 2>&1 && echo 1 || echo 0)
%global has_rustc       %(command -v rustc >/dev/null 2>&1 && echo 1 || echo 0)
%global has_musl_std    %(target_dir=$(rustc --target %{_arch}-unknown-linux-musl --print target-libdir 2>/dev/null); [ -d "${target_dir}" ] && echo 1 || echo 0)
%global has_win_std     %(target_dir=$(rustc --target x86_64-pc-windows-gnu --print target-libdir 2>/dev/null); [ -d "${target_dir}" ] && echo 1 || echo 0)

# Standard Rust compilation flags for bit-for-bit reproducible builds
%{!?rustflags_core:%global rustflags_core -C strip=symbols --remap-path-prefix ${PWD}=.}

# Canonical Rust target triples
%{!?rust_target_linux:%global rust_target_linux %{_arch}-unknown-linux-musl}
%{!?rust_target_win:%global rust_target_win     x86_64-pc-windows-gnu}

# Standard Cargo dependency update command
%{!?cargo_update:%global cargo_update cargo update --recursive}

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
