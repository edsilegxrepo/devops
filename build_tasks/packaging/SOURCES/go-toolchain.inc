# ==============================================================================
# File:        /usr/src/packages/TEMPLATE/SOURCES/go-toolchain.inc
# Purpose:     Common toolchain validation, build, test, and QA macros for Go packages
# Usage:       %%include %%{_sourcedir}/go-toolchain.inc
#
# Objectives:
#   Standardize Go cross-compilation with enforced stripping (-s -w / -extldflags),
#   reproducibility (-trimpath -buildvcs=false), safe PIE selection per OS/CGO mode,
#   and optional Zig musl static linking for SQLite / bundled C libraries.
#
# Core Components:
#   - Tool probes & guards: has_go, go_min_ver/has_go_min_ver, has_golangci_lint,
#     has_staticcheck, has_gofumpt, has_gosec, has_govulncheck.
#   - Flag policy: go_opts, go_ldflags_core, go_cgo_pie, go_cgo_ldflags_*.
#   - Lifecycle macros: %%go_vendor_local_mod, %%go_build_target, %%go_run_tests,
#     %%go_security_audit, %%go_lint_checks.
#
# Functionality & Data Flows:
#   1. Includes pkg-common.inc and aborts rpmbuild early if Go < go_min_ver.
#   2. %%go_build_target inspects use_cgo, _go_target_os, and go_cgo_pie:
#      - Linux use_cgo=0 strips -buildmode=pie (avoids PT_INTERP dynamic ELF).
#      - Windows use_cgo=0/1 and Linux use_cgo=1 (go_cgo_pie=1) enforce PIE.
#      - use_cgo=1 invokes SOURCE10 (zig-musl.sh) for musl/windows-gnu + static libs.
#   3. Emits bin/<bin_name> (or bin/windows/<bin_name>.exe) for %%pkg_install_* / staging.
# ==============================================================================

%include %{_sourcedir}/pkg-common.inc

# ------------------------------------------------------------------------------
# 1. Toolchain & Optional QA Binary Detection
# ------------------------------------------------------------------------------
# Validate Go compiler in PATH
%global has_go          %(command -v go >/dev/null 2>&1 && echo 1 || echo 0)
%if ! %{has_go}
%{error:Go compiler (go) not found in PATH}
%endif

# Optional Go quality/security tools (check PATH and /var/opt/tools)
%global has_golangci_lint %((command -v golangci-lint >/dev/null 2>&1 || [ -x /var/opt/tools/golangci-lint ]) && echo 1 || echo 0)
%global has_staticcheck   %((command -v staticcheck >/dev/null 2>&1 || [ -x /var/opt/tools/staticcheck ]) && echo 1 || echo 0)
%global has_gofumpt       %((command -v gofumpt >/dev/null 2>&1 || [ -x /var/opt/tools/gofumpt ]) && echo 1 || echo 0)
%global has_gosec         %((command -v gosec >/dev/null 2>&1 || [ -x /var/opt/tools/gosec ]) && echo 1 || echo 0)
%global has_govulncheck   %((command -v govulncheck >/dev/null 2>&1 || [ -x /var/opt/tools/govulncheck ]) && echo 1 || echo 0)

# Shell completions directories standard paths are inherited from pkg-common.inc

# ------------------------------------------------------------------------------
# 2. Version Guards, Compiler/Linker Flag Policy & Build Defaults
# ------------------------------------------------------------------------------
# Minimum supported Go compiler version (sort -V baseline guard)
%{!?go_min_ver:%global go_min_ver 1.22}

# Detected Go compiler version string and minimum version guard
%global go_version      %(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || echo 0)
%global has_go_min_ver  %([ "$((echo '%{go_min_ver}'; echo '%{go_version}') | sort -V | head -n1)" = '%{go_min_ver}' ] && echo 1 || echo 0)
%if ! %{has_go_min_ver}
%{error:Go compiler version %{go_version} is older than required minimum %{go_min_ver}}
%endif

# Default Go module proxy
%{!?go_proxy:%global go_proxy https://proxy.golang.org,direct}

# Standard Go compiler options (PIE where statically supported, path trimming, reproducible build metadata)
%{!?go_opts:%global go_opts -buildmode=pie -trimpath -buildvcs=false}

# Core Go linker flags (strip symbol and DWARF debugging information)
%{!?go_ldflags_core:%global go_ldflags_core -s -w}

# Enable static-pie (-buildmode=pie + -static-pie) for Linux CGO by default (set go_cgo_pie 0 if a spec links non-PIC C/asm archives)
%{!?go_cgo_pie:%global go_cgo_pie 1}

# Standard CGO external linker flags for static musl (PIE or non-PIE) and Windows PE
%{!?go_cgo_ldflags_linux:%global go_cgo_ldflags_linux -linkmode=external -extldflags '-static-pie -s'}
%{!?go_cgo_ldflags_linux_nopie:%global go_cgo_ldflags_linux_nopie -linkmode=external -extldflags '-static -s'}
%{!?go_cgo_ldflags_win:%global go_cgo_ldflags_win     -linkmode=external -extldflags '-static -s'}

# Standard Go dependency update and tidy commands for security compliance
%{!?go_update_tree:%global go_update_tree go get -u ./... || :; go mod tidy || :}
%{!?go_update_tree_tests:%global go_update_tree_tests go get -u -t ./... || :; go mod tidy || :}

# Defaults for Go build dispatch (overridable per spec)
%{!?go_cmd_path:%global go_cmd_path .}
%{!?go_test_pkgs:%global go_test_pkgs ./...}
%{!?go_build_tags:%global go_build_tags %{nil}}
%{!?go_version_ldflags:%global go_version_ldflags %{nil}}
%{!?go_ldflags:%define go_ldflags %{go_ldflags_core}%{?go_version_ldflags: %{go_version_ldflags}}}
%{!?xcryptver:%global xcryptver 4.5.2}

# ------------------------------------------------------------------------------
# 3. Module Staging & Target Compilation Macros
# ------------------------------------------------------------------------------
# Copy a Go module from the Go module cache to a local writable directory and register go.mod replace
%define go_vendor_local_mod() \
[ -n "%{2}" ] && [ "%{2}" != "." ] && [ "%{2}" != ".." ] && [[ "%{2}" != /* ]] || { echo "ERROR: Invalid local vendor directory '%{2}'" >&2; exit 1; } \
rm -rf -- "./%{2}" \
cp -a "$(go list -m -f '{{.Dir}}' %{1})" "./%{2}" \
chmod -R u+w "./%{2}" \
go mod edit -replace "%{1}=./%{2}"

# Compile target binary (usage: %%go_build_target linux | %%go_build_target windows)
%define go_build_target() \
_go_target_os="%{1}" \
_go_ext="" \
if [ "${_go_target_os}" = "windows" ]; then \
  _go_ext=".exe" \
fi \
mkdir -p bin \
if [ "${_go_target_os}" = "windows" ]; then \
  mkdir -p bin/windows \
fi \
_go_final_opts="%{go_opts}" \
[[ " ${_go_final_opts} " != *" -trimpath "* ]] && _go_final_opts="-trimpath ${_go_final_opts}" \
[[ " ${_go_final_opts} " != *" -buildvcs=false "* ]] && _go_final_opts="-buildvcs=false ${_go_final_opts}" \
_go_final_ldflags="%{go_ldflags}" \
[[ " ${_go_final_ldflags} " != *" -s "* ]] && _go_final_ldflags="-s ${_go_final_ldflags}" \
[[ " ${_go_final_ldflags} " != *" -w "* ]] && _go_final_ldflags="-w ${_go_final_ldflags}" \
%if ! %{use_cgo} \
echo "==> [${_go_target_os}] Compiling pure Go binary (CGO_ENABLED=0, native Go only)..." \
if [ "${_go_target_os}" = "linux" ]; then \
  _go_final_opts="$(echo "${_go_final_opts}" | sed 's/-buildmode=pie//g')" \
elif [[ " ${_go_final_opts} " != *" -buildmode=pie "* ]]; then \
  _go_final_opts="-buildmode=pie ${_go_final_opts}" \
fi \
_go_tags="%{?go_build_tags}" \
CGO_ENABLED=0 GOOS="${_go_target_os}" go build ${_go_tags:+-tags "${_go_tags}"} ${_go_final_opts} \\\
    -ldflags "${_go_final_ldflags}" \\\
    -o "bin/%{bin_name}${_go_ext}" %{go_cmd_path} \
%else \
export CGO_ENABLED=1 \
export GOOS="${_go_target_os}" \
chmod +x %{SOURCE10} 2>/dev/null || : \
if [ "${_go_target_os}" = "windows" ]; then \
  _go_cc_target="%{_arch}-windows-gnu" \
  _go_extra_ldflags="%{go_cgo_ldflags_win}" \
  [[ " ${_go_final_opts} " != *" -buildmode=pie "* ]] && _go_final_opts="-buildmode=pie ${_go_final_opts}" \
else \
  _go_cc_target="%{_arch}-linux-musl" \
  if [ "%{go_cgo_pie}" = "1" ]; then \
    _go_extra_ldflags="%{go_cgo_ldflags_linux}" \
    [[ " ${_go_final_opts} " != *" -buildmode=pie "* ]] && _go_final_opts="-buildmode=pie ${_go_final_opts}" \
  else \
    _go_extra_ldflags="%{go_cgo_ldflags_linux_nopie}" \
    _go_final_opts="$(echo "${_go_final_opts}" | sed 's/-buildmode=pie//g')" \
  fi \
fi \
_go_cgo_cflags="" \
_go_cgo_ldflags="" \
_go_tags="%{?go_build_tags}" \
_go_libdir="$(pwd)/.clibs_${_go_target_os}" \
mkdir -p "${_go_libdir}" \
%if %{use_sqlite} \
_go_sqlite_src="$(cd ../%{sqlitedir}/sqlite-amalgamation-* 2>/dev/null && pwd)" \
echo "==> [${_go_target_os}] Compiling static SQLite %{sqlitedotver} via Zig (target: ${_go_cc_target})..." \
bash %{SOURCE10} build-sqlite "${_go_cc_target}" "${_go_sqlite_src}" "${_go_libdir}" %{sqlite_amalgamation_cflags} \
_go_cgo_cflags="${_go_cgo_cflags} -I${_go_sqlite_src}" \
_go_cgo_ldflags="${_go_cgo_ldflags} -L${_go_libdir} -lsqlite3" \
_go_tags="${_go_tags:+${_go_tags} }libsqlite3" \
%endif \
%if %{use_bundled_c_lib} \
if [ "${_go_target_os}" = "linux" ]; then \
  _go_clib_src="$(cd ../libxcrypt-%{xcryptver} 2>/dev/null && pwd)" \
  _go_clib_inst="$(pwd)/.clib_install_${_go_target_os}" \
  echo "==> [${_go_target_os}] Compiling static libxcrypt %{xcryptver} via Zig (target: ${_go_cc_target})..." \
  bash %{SOURCE10} build-autotools "${_go_cc_target}" "${_go_clib_src}" "${_go_clib_inst}" --enable-hashes=all --disable-werror \
  _go_cgo_cflags="${_go_cgo_cflags} -I${_go_clib_inst}/include" \
  _go_cgo_ldflags="${_go_cgo_ldflags} -L${_go_clib_inst}/lib -lcrypt" \
fi \
%endif \
echo "==> [${_go_target_os}] Compiling static CGO binary with Zig (target: ${_go_cc_target})..." \
CGO_CFLAGS="${_go_cgo_cflags}" \\\
CGO_LDFLAGS="${_go_cgo_ldflags}" \\\
CC="%{SOURCE10} cc -target ${_go_cc_target}" \\\
CXX="%{SOURCE10} c++ -target ${_go_cc_target}" \\\
go build ${_go_tags:+-tags "${_go_tags}"} ${_go_final_opts} \\\
    -ldflags "${_go_extra_ldflags} ${_go_final_ldflags}" \\\
    -o "bin/%{bin_name}${_go_ext}" %{go_cmd_path} \
%endif \
if [ "${_go_target_os}" = "windows" ]; then \
  cp -af "bin/%{bin_name}.exe" "bin/windows/" \
else \
  chmod 0755 "bin/%{bin_name}" \
fi

# ------------------------------------------------------------------------------
# 4. Unit Test, Security Audit & Static Analysis Macros
# ------------------------------------------------------------------------------
# Run unit tests honoring Pure Go vs static CGO/SQLite/libxcrypt and build tags (opt-in via --with testsuite)
%define go_run_tests \
_go_tags="%{?go_build_tags}" \
%if ! %{use_cgo} \
CGO_ENABLED=0 go test -trimpath -buildvcs=false -short ${_go_tags:+-tags "${_go_tags}"} %{go_test_pkgs} \
%else \
chmod +x %{SOURCE10} 2>/dev/null || : \
_go_cc_target="%{_arch}-linux-musl" \
if [ "%{go_cgo_pie}" = "1" ]; then \
  _go_test_ldflags="%{go_cgo_ldflags_linux}" \
else \
  _go_test_ldflags="%{go_cgo_ldflags_linux_nopie}" \
fi \
_go_cgo_cflags="" \
_go_cgo_ldflags="" \
_go_libdir="$(pwd)/.clibs_linux" \
mkdir -p "${_go_libdir}" \
%if %{use_sqlite} \
_go_sqlite_src="$(cd ../%{sqlitedir}/sqlite-amalgamation-* 2>/dev/null && pwd)" \
if [ ! -f "${_go_libdir}/libsqlite3.a" ]; then \
  bash %{SOURCE10} build-sqlite "${_go_cc_target}" "${_go_sqlite_src}" "${_go_libdir}" %{sqlite_amalgamation_cflags} \
fi \
_go_cgo_cflags="${_go_cgo_cflags} -I${_go_sqlite_src}" \
_go_cgo_ldflags="${_go_cgo_ldflags} -L${_go_libdir} -lsqlite3" \
_go_tags="${_go_tags:+${_go_tags} }libsqlite3" \
%endif \
%if %{use_bundled_c_lib} \
_go_clib_inst="$(pwd)/.clib_install_linux" \
_go_cgo_cflags="${_go_cgo_cflags} -I${_go_clib_inst}/include" \
_go_cgo_ldflags="${_go_cgo_ldflags} -L${_go_clib_inst}/lib -lcrypt" \
%endif \
CGO_ENABLED=1 \
CGO_CFLAGS="${_go_cgo_cflags}" \
CGO_LDFLAGS="${_go_cgo_ldflags}" \
CC="%{SOURCE10} cc -target ${_go_cc_target}" \
CXX="%{SOURCE10} c++ -target ${_go_cc_target}" \
go test -trimpath -buildvcs=false -short ${_go_tags:+-tags "${_go_tags}"} -ldflags "${_go_test_ldflags}" %{go_test_pkgs} \
%endif

# Security & vulnerability audit (opt-in via --with audit)
%define go_security_audit \
export PATH="${PATH}:/var/opt/tools" \
_go_tags="%{?go_build_tags}" \
if [ "%{has_govulncheck}" = "1" ]; then \
  echo "==> Running govulncheck..." \
  govulncheck ${_go_tags:+-tags="${_go_tags}"} ./... || echo "NOTICE: govulncheck reported advisories or offline database unavailability" \
fi \
if [ "%{has_gosec}" = "1" ]; then \
  echo "==> Running gosec..." \
  gosec -quiet ${_go_tags:+-tags="${_go_tags}"} ./... || : \
fi

# Static analysis & formatting checks (opt-in via --with lint)
%define go_lint_checks \
export PATH="${PATH}:/var/opt/tools" \
_go_tags="%{?go_build_tags}" \
echo "==> Running go vet..." \
go vet ${_go_tags:+-tags="${_go_tags}"} ./... \
if [ "%{has_gofumpt}" = "1" ]; then \
  echo "==> Running gofumpt -l..." \
  _fmt_diff="$(gofumpt -l . || true)" \
  if [ -n "${_fmt_diff}" ]; then \
    echo "NOTICE: upstream formatting differs from gofumpt:" \
    echo "${_fmt_diff}" | head -n 20 \
  fi \
fi \
if [ "%{has_golangci_lint}" = "1" ]; then \
  echo "==> Running golangci-lint..." \
  golangci-lint run ${_go_tags:+--build-tags="${_go_tags}"} ./... || : \
fi \
if [ "%{has_staticcheck}" = "1" ]; then \
  echo "==> Running staticcheck..." \
  staticcheck ${_go_tags:+-tags "${_go_tags}"} ./... || : \
fi

