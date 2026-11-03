# ==============================================================================
# Common toolchain validation and definitions for Go packages
# ==============================================================================

%include %{_sourcedir}/pkg-common.inc

# Validate Go compiler in PATH
%global has_go          %(command -v go >/dev/null 2>&1 && echo 1 || echo 0)
%if ! %{has_go}
%{error:Go compiler (go) not found in PATH}
%endif

# Shell completions directories standard paths are inherited from pkg-common.inc

# Minimum supported Go compiler version
%{!?go_min_ver:%global go_min_ver 1.22}

# Detected Go compiler version string
%global go_version      %(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || echo 0)

# Default Go module proxy
%{!?go_proxy:%global go_proxy https://proxy.golang.org,direct}

# Standard Go compiler options (PIE, path trimming, reproducible build metadata)
%{!?go_opts:%global go_opts -buildmode=pie -trimpath -buildvcs=false}

# Core Go linker flags (strip symbol and DWARF debugging information)
%{!?go_ldflags_core:%global go_ldflags_core -s -w}

# Standard CGO external linker flags for static musl PIE and Windows PE
%{!?go_cgo_ldflags_linux:%global go_cgo_ldflags_linux -linkmode=external -extldflags '-static-pie'}
%{!?go_cgo_ldflags_win:%global go_cgo_ldflags_win     -linkmode=external -extldflags '-static'}

# Standard Go dependency update and tidy command for security compliance
%{!?go_update_tree:%global go_update_tree go get -u -t ./... >/dev/null 2>&1 || :; go mod tidy >/dev/null 2>&1 || :}

