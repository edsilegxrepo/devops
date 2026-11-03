# ==============================================================================
# RPM Spec Template for Rust Projects (Static Musl + Multi-Distribution)
# ==============================================================================
#
# INSTRUCTIONS FOR CREATING A NEW PACKAGE:
#   TIP: To automate scaffolding, use SOURCES/pkg-make.sh:
#        SOURCES/pkg-make.sh --platform rust --name <name> --version <ver> [options]
#
#   Manual Steps:
#   1. Copy this template to SPECS/<name>-xg.spec:
#        cp SPECS/pkg-rust-template-xg.spec SPECS/<name>-xg.spec
#   2. Replace all placeholder tags:
#        <name>             Package name (lowercase, e.g. ripgrep)
#        <version>          Upstream semantic version (e.g. 14.1.0)
#        <release_num>      Internal package revision number (e.g. 10)
#        <summary>          Single-line short summary
#        <description>      Multi-line detailed description
#        <license>          SPDX license identifier (e.g. MIT, Apache-2.0)
#        <url>              Upstream project homepage or GitHub repository
#        <git_hash>         Short git commit hash (e.g. 79d84f5)
#        <cargo_features>   Cargo feature flags (e.g. --features "clipboard"), or leave empty
#   3. Optional Daemon Setup:
#        If packaging a daemon service, copy template.service, template.sysusers.conf,
#        and template.tmpfiles.conf to <name>.service/conf, enable Source20-22,
#        and uncomment the systemd sections in %%install, %%files, and scriptlets.
#   4. Place source archive in SOURCES/<name>-<version>-<git_hash>-src.zip
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
#   - Static Compilation: Compiles 100% static musl ELF binary via Zig 0.17+
#     (zero runtime glibc dependency, runs on RHEL 8-9-10 and Ubuntu 24.04/26.04).
#   - Cross-compilation: Supports Windows PE32+ (x86_64-pc-windows-gnu) via MinGW.
#   - Packaging Pipeline: Automatically produces RPM, Debian (.deb), Linux tar.xz,
#     and Windows zipball with consistent metadata, changelogs, and permissions.
#   - Binary Verification vs Testsuite:
#       * %%check executes binary wellness validation by default (inspects static ELF
#         structure, asserts absence of PT_INTERP dynamic linker segment, and validates
#         --version execution output).
#       * Upstream unit testsuite (cargo test) is DISABLED by default (enable via --with testsuite).
#
# ==============================================================================

# Common toolchain definitions, architecture mappings, and sanity checks
%include %{_sourcedir}/rust-toolchain.inc

# ==============================================================================
# Compilation Mode Configuration Toggles
# ==============================================================================
%global use_sqlite         0

# Optional SQLite Amalgamation Settings (if use_sqlite is 1)
%global sqlitever       3540100
%global sqlitedir       sqlite-src-%(echo %{sqlitever} | cut -c1-3)
%global sqlitedotver    %(echo %{sqlitever} | awk '{maj=substr($0,1,1); min=substr($0,2,2)+0; rel=substr($0,4,2)+0; patch=substr($0,6,2)+0; print maj "." min "." rel (patch > 0 ? "." patch : "")}')

# Build condition flags
%bcond_without rpm
%bcond_with windows
%bcond_with archive
%bcond_with deb
%bcond_without check
%bcond_with testsuite

# Early Windows target toolchain validation (if --with windows is passed)
%if %{with windows} && ! %{has_win_std}
%{error:Rust standard library for x86_64-pc-windows-gnu is not installed. Please run /opt/scripts/rust_upgrade.sh to install it.}
%endif

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

%global git_hash        <git_hash>
%global pkgver          %{version}-%{git_hash}
%global dist_base       %{distpath}/%{name}-%{pkgver}
%global rel_num         %(echo %{release} | cut -d. -f1)

# Debian Package Runtime Dependencies (passed to pkg-deb.sh --depends)
%global deb_depends     <deb_depends>

# Package Sources and Shared Helpers
Source0:        %{name}-%{version}-%{git_hash}-src.zip
%if %{use_sqlite}
Source1:        sqlite-amalgamation-%{sqlitever}.zip
%endif
# Source2:        <optional_config_or_profile_script>
Source10:       zig-musl.sh
Source11:       pkg-deb.sh
Source12:       rust-toolchain.inc
Source13:       pkg-common.inc
# Patch0:         <optional_compat.patch>

# Optional systemd / configuration sources
# Source20:       %%{name}.service
# Source21:       %%{name}.sysusers.conf
# Source22:       %%{name}.tmpfiles.conf
# Source23:       %%{name}.env

BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildRequires:  tar
BuildRequires:  file binutils
%if %{use_sqlite}
BuildRequires:  unzip
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

%if %{use_sqlite}
# Unpack SQLite amalgamation into parent build tree
rm -rf ../%{sqlitedir}
unzip -q %{SOURCE1} -d ../%{sqlitedir}
%endif

%{cargo_update}


%build
chmod +x %{SOURCE10} %{SOURCE11} 2>/dev/null || :
mkdir -p bin

# Bit-for-bit reproducible build flags: strip symbols and remap host builder paths
export RUSTFLAGS="%{rustflags_core}"

%if %{use_sqlite}
# Compile static SQLite amalgamation on-the-fly via Zig for Linux target
SQLITE_SRC="$(cd ../%{sqlitedir}/sqlite-amalgamation-* 2>/dev/null && pwd)"
SQLITE_LIB_LINUX="$(pwd)/.sqlite_lib_linux"
mkdir -p "${SQLITE_LIB_LINUX}"
echo "==> Compiling static SQLite %{sqlitedotver} via Zig (target: %{_arch}-linux-musl)..."
zig cc -target "%{_arch}-linux-musl" %{sqlite_amalgamation_cflags} \
    -c "${SQLITE_SRC}/sqlite3.c" -o "${SQLITE_LIB_LINUX}/sqlite3.o"
zig ar rcs "${SQLITE_LIB_LINUX}/libsqlite3.a" "${SQLITE_LIB_LINUX}/sqlite3.o"
export SQLITE3_LIB_DIR="${SQLITE_LIB_LINUX}"
export SQLITE3_INCLUDE_DIR="${SQLITE_SRC}"
export SQLITE3_STATIC=1
export CFLAGS="%{sqlite_amalgamation_cflags}"
%endif

echo "==> Compiling static %{name} binary with Zig + musl (%{rust_target_linux})..."
%{SOURCE10} cargo build --release --target "%{rust_target_linux}" <cargo_features>

cp -af "target/%{rust_target_linux}/release/%{name}" "bin/%{name}"
chmod 0755 "bin/%{name}"

# If conditional Windows target is set, cross-compile for Windows PE
%if %{with windows}
%if %{use_sqlite}
# Compile static SQLite amalgamation on-the-fly via Zig for Windows target
SQLITE_LIB_WIN="$(pwd)/.sqlite_lib_win"
mkdir -p "${SQLITE_LIB_WIN}"
echo "==> Compiling static SQLite %{sqlitedotver} via Zig (target: %{_arch}-windows-gnu)..."
zig cc -target "%{_arch}-windows-gnu" %{sqlite_amalgamation_cflags} \
    -c "${SQLITE_SRC}/sqlite3.c" -o "${SQLITE_LIB_WIN}/sqlite3.o"
zig ar rcs "${SQLITE_LIB_WIN}/libsqlite3.a" "${SQLITE_LIB_WIN}/sqlite3.o"
export SQLITE3_LIB_DIR="${SQLITE_LIB_WIN}"
export SQLITE3_INCLUDE_DIR="${SQLITE_SRC}"
export SQLITE3_STATIC=1
%endif

echo "==> Cross-compiling %{name} for Windows PE (%{rust_target_win})..."
%{SOURCE10} cargo build --release --target "%{rust_target_win}" <cargo_features>
mkdir -p bin/windows
cp -af "target/%{rust_target_win}/release/%{name}.exe" "bin/windows/"
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
# cp -af %%{SOURCE1} staging_archive/etc/... 2>/dev/null || :
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
# install -m 644 %%{SOURCE1} %%{buildroot}%%{_sysconfdir}/...

# Optional: Install systemd service, sysusers, tmpfiles, and environment config
# install -D -p -m 0644 %%{SOURCE20} %%{buildroot}%%{_unitdir}/%%{name}.service
# install -D -p -m 0644 %%{SOURCE21} %%{buildroot}%%{_sysusersdir}/%%{name}.conf
# install -D -p -m 0644 %%{SOURCE22} %%{buildroot}%%{_tmpfilesdir}/%%{name}.conf
# install -D -p -m 0640 %%{SOURCE23} %%{buildroot}%%{_sysconfdir}/%%{name}/%%{name}.env
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
%{SOURCE10} cargo test --release --target "%{rust_target_linux}" <cargo_features>
%endif
%endif


%clean
[ "%{buildroot}" != "/" ] && [ -d "%{buildroot}" ] && rm -rf "%{buildroot}"
%if %{use_sqlite}
rm -rf ../%{sqlitedir}
%endif


%if %{with rpm}
%files
%defattr(-,root,root,-)
%license LICENSE
%doc %{doclist}
%{_bindir}/%{name}
# %%config(noreplace) %%{_sysconfdir}/...

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
