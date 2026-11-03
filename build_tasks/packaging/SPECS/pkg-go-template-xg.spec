# ==============================================================================
# RPM Spec Template for Go Projects (Static Musl + Pure Go or CGO + Bundled C Libs)
# ==============================================================================
#
# INSTRUCTIONS FOR CREATING A NEW GO PACKAGE:
#   TIP: To automate scaffolding, use SOURCES/pkg-make.sh:
#        SOURCES/pkg-make.sh --platform go --name <name> --version <ver> [options]
#
#   Manual Steps:
#   1. Copy this template to SPECS/<name>-xg.spec:
#        cp SPECS/pkg-go-template-xg.spec SPECS/<name>-xg.spec
#   2. Choose your compilation mode via the toggles below:
#        use_cgo:            Set to 0 for pure Go (default, like Caddy)
#                            Set to 1 if Go requires C libraries (like SFTPGo)
#        use_sqlite:         Set to 1 to build embedded SQLite amalgamation via Zig
#        use_bundled_c_lib:  Set to 1 to statically compile an autotools C lib (e.g. libxcrypt)
#   3. Replace all placeholder tags:
#        <name>             Package name (lowercase, e.g. caddy, sftpgo, fzf)
#        <version>          Upstream semantic version (e.g. 2.7.6)
#        <release_num>      Internal package revision number (e.g. 10)
#        <summary>          Single-line short summary
#        <description>      Multi-line detailed description
#        <license>          SPDX license identifier (e.g. Apache-2.0, MIT, AGPL-3.0-only)
#        <url>              Upstream project homepage or GitHub repository
#        <git_hash>         Short git commit hash (e.g. 9712163)
#        <goipath>          Go import path (e.g. github.com/owner/repo/v2)
#        <cmd_path>         Relative path to main package (e.g. . or ./cmd/<name>)
#        <build_tags>       Optional Go build tags (e.g. "libsqlite3"), or leave empty
#   4. Optional Daemon Setup:
#        If packaging a daemon service (like Caddy or SFTPGo), copy template.service,
#        template.sysusers.conf, and template.tmpfiles.conf to <name>.service/conf,
#        enable Source20-22, and uncomment the systemd sections in %%install, %%files, and scriptlets.
#   5. Place source archive in SOURCES/<name>-<version>-<git_hash>-src.zip
#
# BUILDING INSTRUCTIONS:
#   1. Default Linux Target Build (produces Linux binary and RPM package):
#        rpmbuild -ba SPECS/<name>-xg.spec
#   2. Build Linux Generic Tarball in STAGING in addition to RPM:
#        rpmbuild --with archive -ba SPECS/<name>-xg.spec
#   3. Build Windows Zipball in STAGING in addition to Linux RPM:
#        rpmbuild --with windows -ba SPECS/<name>-xg.spec
#   4. Build Debian Package in STAGING in addition to Linux RPM:
#        rpmbuild --with deb -ba SPECS/<name>-xg.spec
#   5. Build All Targets (RPM + Linux Tarball + Windows Zipball + Debian Package):
#        rpmbuild --with windows --with archive --with deb -ba SPECS/<name>-xg.spec
#
# TECHNICAL ARCHITECTURE:
#   - Pure Go Mode (use_cgo 0):
#       * Builds 100% static binaries via CGO_ENABLED=0.
#       * Windows cross-compilation is built directly into Go (GOOS=windows).
#   - CGO + Zig Musl Mode (use_cgo 1):
#       * Cross-compiles C/C++ dependencies using Zig 0.17+ as a static cross-compiler:
#           Linux:   zig cc -target %%{_arch}-linux-musl with -extldflags '-static'
#           Windows: zig cc -target %%{_arch}-windows-gnu
#       * Generates 100% static musl ELF binary deployable on all Linux distros
#         (RHEL 8-9-10, Ubuntu 24.04/26.04) with zero runtime glibc/shared lib dependencies.
#   - Bundled C Libraries (SQLite amalgamation & autotools C libraries):
#       * Demonstrates compiling embedded SQLite amalgamation (sqlite3.c -> libsqlite3.a)
#         and standalone autotools C libraries (e.g. libxcrypt) on-the-fly via Zig.
#   - Binary Verification vs Testsuite:
#       * %%check executes binary wellness validation by default (inspects static ELF
#         structure, asserts absence of PT_INTERP dynamic linker segment, and validates
#         --version execution output).
#       * Upstream unit testsuite (go test) is DISABLED by default (enable via --with testsuite).
#
# ==============================================================================

# Common Go toolchain validation, completion paths, and package definitions
%include %{_sourcedir}/go-toolchain.inc

# ==============================================================================
# Compilation Mode Configuration Toggles
# ==============================================================================
%global use_cgo            0
%global use_sqlite         0
%global use_bundled_c_lib  0

# If CGO is enabled, validate that Zig compiler is available in PATH
%if %{use_cgo}
%global has_zig %(command -v zig >/dev/null 2>&1 || [ -x /var/opt/zig/zig ] || [ -x /u01/zig/zig ] || [ -x /usr/local/bin/zig ] || [ -x /opt/zig/zig ] && echo 1 || echo 0)
%if ! %{has_zig}
%{error:Zig compiler (0.17+) not found in PATH for static CGO musl linking}
%endif
%endif

# Build condition flags
%bcond_without rpm
%bcond_with windows
%bcond_with archive
%bcond_with deb
%bcond_without check
%bcond_with testsuite

# Package Descriptions (Shared between RPM and Debian control)
# Note: Use single backslash '\' at line ends to preserve line wrapping without leaking literal backslashes.
%global pkg_summary     <summary>
%global pkg_desc        <description>\
<description_line_2>\
<description_line_3>

# Package Metadata
Name:           <name>
Version:        <version>
Release:        <release_num>.%{__osver}.%{__channel}
Summary:        %{pkg_summary}
Group:          Applications/System
License:        <license>
URL:            <url>
Provides:       %{name} = %{version}-%{release}

# Go Import Path & Versioning Metadata
%global goipath         <goipath>
%global gh_tag          <git_hash>
%global pkgver          %{version}-%{gh_tag}
%global dist_base       %{distpath}/%{name}-%{pkgver}
%global rel_num         %(echo %{release} | cut -d. -f1)

# Debian Package Runtime Dependencies (passed to pkg-deb.sh --depends)
%global deb_depends     <deb_depends>

# Go Compiler Flags (go_opts and go_ldflags_core default from go-toolchain.inc)
%global go_ldflags      %{go_ldflags_core} -X '%{goipath}/internal/version.version=%{version}' -X '%{goipath}/internal/version.commit=%{gh_tag}'
%{!?go_opts:%global go_opts -buildmode=pie -trimpath -buildvcs=false}

# Optional SQLite Amalgamation Settings (if use_sqlite is 1)
%global sqlitever       3540100
%global sqlitedir       sqlite-src-%(echo %{sqlitever} | cut -c1-3)
%global sqlitedotver    %(echo %{sqlitever} | awk '{maj=substr($0,1,1); min=substr($0,2,2)+0; rel=substr($0,4,2)+0; patch=substr($0,6,2)+0; print maj "." min "." rel (patch > 0 ? "." patch : "")}')

# Optional Bundled C Library Settings (e.g. libxcrypt, if use_bundled_c_lib is 1)
%global xcryptver       4.5.2

# Package Sources and Shared Helpers
Source0:        %{name}-%{version}-%{gh_tag}-src.zip
%if %{use_sqlite}
Source1:        sqlite-amalgamation-%{sqlitever}.zip
%endif
%if %{use_bundled_c_lib}
Source2:        libxcrypt-%{xcryptver}.tar.xz
%endif

# Shared tooling helpers from SOURCES
Source10:       zig-musl.sh
Source11:       pkg-deb.sh
Source12:       go-toolchain.inc
Source13:       pkg-common.inc

# Optional systemd / configuration sources
# Source20:       %%{name}.service
# Source21:       %%{name}.sysusers.conf
# Source22:       %%{name}.tmpfiles.conf
# Source23:       %%{name}.env

BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildRequires:  golang >= 1.22
BuildRequires:  tar
BuildRequires:  file binutils
%if %{use_cgo}
BuildRequires:  make
%endif
%if %{with archive}
BuildRequires:  xz
%endif
%if %{with deb}
BuildRequires:  dpkg
%endif
%if %{with windows}
BuildRequires:  zip unix2dos
%endif

%description
%{pkg_desc}


%prep
%autosetup -p1 -n %{name}-main

# Optional: Unpack SQLite amalgamation into parent directory
%if %{use_sqlite}
rm -rf ../%{sqlitedir}
unzip -q %{SOURCE1} -d ../%{sqlitedir}
%endif

# Optional: Unpack bundled C library (e.g. libxcrypt) into parent directory
%if %{use_bundled_c_lib}
rm -rf ../libxcrypt-%{xcryptver}
tar -xf %{SOURCE2} -C ..
%endif


%build
chmod +x %{SOURCE10} %{SOURCE11} 2>/dev/null || :
export GOPROXY="%{go_proxy}"

# Security compliance: auto-update Go dependencies within module constraints
%{go_update_tree}

mkdir -p bin

# ------------------------------------------------------------------------------
# Build Dispatch Function (handles Linux static musl and Windows PE)
# ------------------------------------------------------------------------------
build_target() {
    local target_os="$1"
    local ext=""
    [ "$target_os" = "windows" ] && ext=".exe"

%if ! %{use_cgo}
    # --------------------------------------------------------------------------
    # PATTERN A: Pure Go (CGO_ENABLED=0, zero external C dependencies)
    # --------------------------------------------------------------------------
    echo "==> [${target_os}] Compiling pure Go binary (CGO_ENABLED=0)..."
    CGO_ENABLED=0 GOOS="${target_os}" go build %{go_opts} \
        -ldflags "%{go_ldflags}" \
        -o "bin/%{name}${ext}" <cmd_path>

%else
    # --------------------------------------------------------------------------
    # PATTERN B: Static CGO with Zig + Bundled C Libraries (SQLite / libxcrypt)
    # --------------------------------------------------------------------------
    export CGO_ENABLED=1
    export GOOS="${target_os}"
    local cc_target=""
    local cxx_target=""
    local extra_ldflags=""
    local cgo_cflags=""
    local cgo_ldflags=""
    local tags="<build_tags>"
    local target_libdir="$(pwd)/.clibs_${target_os}"
    mkdir -p "${target_libdir}"

    if [ "$target_os" = "windows" ]; then
        cc_target="%{_arch}-windows-gnu"
        extra_ldflags="%{go_cgo_ldflags_win}"
    else
        cc_target="%{_arch}-linux-musl"
        extra_ldflags="%{go_cgo_ldflags_linux}"
    fi
    cxx_target="${cc_target}"

    # Example 1: Compile embedded SQLite amalgamation on-the-fly via Zig
%if %{use_sqlite}
    local sqlite_src="$(cd ../%{sqlitedir}/sqlite-amalgamation-* 2>/dev/null && pwd)"
    echo "==> [${target_os}] Compiling static SQLite %{sqlitedotver} via Zig (target: ${cc_target})..."
    zig cc -target "${cc_target}" %{sqlite_amalgamation_cflags} \
        -c "${sqlite_src}/sqlite3.c" -o "${target_libdir}/sqlite3.o"
    zig ar rcs "${target_libdir}/libsqlite3.a" "${target_libdir}/sqlite3.o"
    cgo_cflags="${cgo_cflags} -I${sqlite_src}"
    cgo_ldflags="${cgo_ldflags} -L${target_libdir} -lsqlite3"
    tags="${tags:+$tags }libsqlite3"
%endif

    # Example 2: Compile bundled C library (e.g. libxcrypt) via Zig
%if %{use_bundled_c_lib}
    if [ "$target_os" = "linux" ]; then
        local clib_src="$(cd ../libxcrypt-%{xcryptver} 2>/dev/null && pwd)"
        local clib_build="${clib_src}/build-${target_os}"
        echo "==> [${target_os}] Compiling static libxcrypt %{xcryptver} via Zig (target: ${cc_target})..."
        rm -rf "${clib_build}"
        mkdir -p "${clib_build}"
        pushd "${clib_build}" >/dev/null
        CC="zig cc -target ${cc_target}" \
        CFLAGS="-O2 -fPIC" \
        ../configure --host="${cc_target}" \
            --prefix="$(pwd)/install" \
            --libdir="$(pwd)/install/lib" \
            --enable-static \
            --disable-shared \
            --enable-hashes=all \
            --disable-werror >/dev/null 2>&1
        make -j$(nproc) >/dev/null 2>&1
        make install >/dev/null 2>&1
        popd >/dev/null
        cgo_cflags="${cgo_cflags} -I${clib_build}/install/include"
        cgo_ldflags="${cgo_ldflags} -L${clib_build}/install/lib -lcrypt"
    fi
%endif

    echo "==> [${target_os}] Compiling static CGO binary with Zig (target: ${cc_target})..."
    CGO_CFLAGS="${cgo_cflags}" \
    CGO_LDFLAGS="${cgo_ldflags}" \
    CC="zig cc -target ${cc_target}" \
    CXX="zig c++ -target ${cxx_target}" \
    go build ${tags:+-tags "${tags}"} %{go_opts} \
        -ldflags "-s -w ${extra_ldflags} %{go_ldflags}" \
        -o "bin/%{name}${ext}" <cmd_path>
%endif
}

# 1. Compile Linux binary (100% static musl or pure Go)
build_target linux
chmod 0755 "bin/%{name}"

# 2. If conditional Windows target is set, cross-compile for Windows PE
%if %{with windows}
mkdir -p bin/windows
build_target windows
cp -af "bin/%{name}.exe" "bin/windows/"
%endif

# Prepare release staging directory and shared changelog
mkdir -p %{distpath}
%generate_changelog

# If conditional archive target is set, package Linux generic tarball
%if %{with archive}
rm -f %{dist_archive}
rm -rf staging_archive
mkdir -p staging_archive/doc
cp -af bin/%{name} staging_archive/
chmod 0755 staging_archive/%{name}
# cp -af %%{SOURCE20} staging_archive/doc/ 2>/dev/null || :
cp -af LICENSE %{doclist} changelog.txt staging_archive/doc/ 2>/dev/null || :
(cd staging_archive && tar -Jcvf %{dist_archive} *)
rm -rf staging_archive
%endif

# If conditional Windows target is set, package Windows ZIP archive
%if %{with windows}
rm -f %{dist_zip}
rm -rf staging_windows
mkdir -p staging_windows/doc
cp -af bin/windows/%{name}.exe staging_windows/
cp -af LICENSE %{doclist} changelog.txt staging_windows/doc/ 2>/dev/null || :
unix2dos -k -q staging_windows/doc/* 2>/dev/null || :
(cd staging_windows && zip -9r %{dist_zip} *)
rm -rf staging_windows
%endif

# If conditional DEB target is set, package Debian .deb
%if %{with deb}
%{SOURCE11} \
  --name "%{name}" \
  --version "%{pkgver}-%{release}" \
  --arch "%{plat_arch}" \
  --maintainer "%{maintainer}" \
  --summary "%{pkg_summary}" \
  --desc "%{pkg_desc}" \
  --homepage "%{url}" \
  --bin "bin/%{name}" \
  %{?deb_depends:--depends "%{deb_depends}"} \
  --doc LICENSE %{doclist} \
  --changelog changelog.txt \
  --out "%{dist_deb}"
%endif


%install
[ "%{buildroot}" != "/" ] && [ -d "%{buildroot}" ] && rm -rf "%{buildroot}"

%if %{with rpm}
mkdir -p %{buildroot}%{_bindir}
cp -af bin/%{name} %{buildroot}%{_bindir}/%{name}
chmod 0755 %{buildroot}%{_bindir}/%{name}

# Optional: Install systemd service, sysusers, tmpfiles, and environment config
# install -D -p -m 0644 %%{SOURCE20} %%{buildroot}%%{_unitdir}/%%{name}.service
# install -D -p -m 0644 %%{SOURCE21} %%{buildroot}%%{_sysusersdir}/%%{name}.conf
# install -D -p -m 0644 %%{SOURCE22} %%{buildroot}%%{_tmpfilesdir}/%%{name}.conf
# install -D -p -m 0640 %%{SOURCE23} %%{buildroot}%%{_sysconfdir}/%%{name}/%%{name}.env

# Optional: Shell completion generation (for tools supporting completion subcommands)
# install -d -m 0755 %%{buildroot}%%{bash_completions_dir} %%{buildroot}%%{zsh_completions_dir} %%{buildroot}%%{fish_completions_dir}
# ./bin/%%{name} completion bash > %%{buildroot}%%{bash_completions_dir}/%%{name} 2>/dev/null || :
# ./bin/%%{name} completion zsh  > %%{buildroot}%%{zsh_completions_dir}/_%%{name} 2>/dev/null || :
# ./bin/%%{name} completion fish > %%{buildroot}%%{fish_completions_dir}/%%{name}.fish 2>/dev/null || :
%endif


%if %{with check}
%check
# 1. Binary wellness validation (structural static ELF integrity and execution)
%{SOURCE10} check "bin/%{name}" "%{version}"
%if %{with windows}
%{SOURCE10} check-win "bin/windows/%{name}.exe"
%endif

# 2. Optional: Upstream unit testsuite (DISABLED by default; enable with --with testsuite)
%if %{with testsuite}
go test -short ./...
%endif
%endif


%clean
[ "%{buildroot}" != "/" ] && [ -d "%{buildroot}" ] && rm -rf "%{buildroot}"


%if %{with rpm}
%files
%defattr(-,root,root,-)
%license LICENSE
%doc %{doclist}
%{_bindir}/%{name}

# Optional: Package systemd, sysusers, tmpfiles, and environment config
# %%{_unitdir}/%%{name}.service
# %%{_sysusersdir}/%%{name}.conf
# %%{_tmpfilesdir}/%%{name}.conf
# %%dir %%attr(0750,%%{name},%%{name}) %%{_sysconfdir}/%%{name}
# %%config(noreplace) %%attr(0640,%%{name},%%{name}) %%{_sysconfdir}/%%{name}/%%{name}.env
%endif

# Optional: Systemd RPM scriptlets for daemon packages
# %%post
# %%systemd_post %%{name}.service
#
# %%preun
# %%systemd_preun %%{name}.service
#
# %%postun
# %%systemd_postun_with_restart %%{name}.service


%changelog
* Mon Nov 02 2026 %{maintainer} - %{version}-%{rel_num}
- Updated to latest upstream release
