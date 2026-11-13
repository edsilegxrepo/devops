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
#   2. Set feature toggles below:
#        use_cgo:            0 = pure Go (CGO_ENABLED=0, Zig NOT used/required)
#                            1 = static CGO musl via Zig (e.g. SQLite / C libs)
#        use_sqlite:         1 = build embedded SQLite amalgamation via Zig
#        use_bundled_c_lib:  1 = build bundled autotools C lib (e.g. libxcrypt) via Zig
#        is_daemon:          1 = enable systemd service/sysusers/tmpfiles/.env + deb hooks
#   3. Replace all <placeholder> tags and place SOURCES/<name>-<version>-<git_hash>-src.zip
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
#   Optional QA / Dependency Flags:
#        --with testsuite (Go unit tests via %%go_run_tests), --with lint,
#        --with audit, --with update_deps (run go get -u && go mod tidy)
#
# TECHNICAL ARCHITECTURE:
#   - Shared lifecycle macros (%%pkg_*) come from pkg-common.inc; Go build/patch
#     macros (%%go_build_target, %%go_run_tests, %%go_vendor_local_mod,
#     %%go_update_tree, %%go_lint_checks, %%go_security_audit) come from go-toolchain.inc.
#   - %%check executes binary wellness validation via pkg-verify.sh by default;
#     linting, security audit, unit tests, and dependency updates are opt-in via --with flags.
# ==============================================================================

# Common Go toolchain validation, completion paths, and package definitions
%include %{_sourcedir}/go-toolchain.inc

# Feature toggles & build target gates (overriding defaults in pkg-common.inc / go-toolchain.inc)
%global is_daemon          0
# 0 = Pure Go (CGO_ENABLED=0, no Zig, no -buildmode=pie on Linux); 1 = Static CGO via Zig (musl static-pie on Linux)
%global use_cgo            0
# Enable static-pie on Linux CGO by default; set 0 only if non-PIC C/asm archives fail linking
%global go_cgo_pie         1
%global use_sqlite         0
%global use_bundled_c_lib  0
%global enable_archive     1
%global enable_deb         1
%global enable_windows     1

%if %{use_cgo} && ! %{has_zig}
%{error:Zig compiler (0.17+) not found in PATH for static CGO musl linking}
%endif

# Build condition flags
%bcond_without rpm
%bcond_with windows
%bcond_with archive
%bcond_with deb
%bcond_without check
%bcond_with testsuite
%bcond_with lint
%bcond_with audit
%bcond_with update_deps

# Package Descriptions (Shared between RPM and Debian control)
%global pkg_summary     <summary>
%global pkg_desc        <description>\
<description_line_2>\
<description_line_3>

# Package Metadata
Name:           <name>
Version:        <version>
Release:        <release_num>%{pkg_rel_suffix}
Summary:        %{pkg_summary}
Group:          Applications/System
License:        <license>
URL:            <url>
Provides:       %{name} = %{version}-%{release}

# Go Import Path, Binary, Source Root & Versioning Metadata
%global goipath         <goipath>
%global gh_tag          <git_hash>
%global pkgver          %{version}-%{gh_tag}
%global src_root        %{name}-main
%global bin_name        %{name}
%global license_file    LICENSE
%global completion_cmd  %{nil}
%global version_flag    --version
%global go_cmd_path     <cmd_path>
# Package pattern passed to %%go_run_tests (e.g. ./... or ./cmd/...)
%global go_test_pkgs    ./...
%global go_build_tags   <build_tags>
%global go_version_ldflags <version_ldflags>
%global deb_depends     <deb_depends>

# Package Sources and Shared Helpers
Source0:        %{name}-%{version}-%{gh_tag}-src.zip
%if %{use_sqlite}
Source1:        sqlite-amalgamation-%{sqlitever}.zip
%endif
%if %{use_bundled_c_lib}
Source2:        libxcrypt-%{xcryptver}.tar.xz
%endif

%if %{use_cgo}
Source10:       zig-musl.sh
%endif
%if %{enable_deb}
Source11:       pkg-deb.sh
%endif
Source12:       go-toolchain.inc
Source13:       pkg-common.inc
Source14:       pkg-verify.sh

%if %{is_daemon}
Source20:       %{name}.service
Source21:       %{name}.sysusers.conf
Source22:       %{name}.tmpfiles.conf
Source23:       %{name}.env
%endif

BuildRequires:  golang >= 1.22
%pkg_common_buildrequires

%description
%{pkg_desc}


%prep
%autosetup -p1 -n %{src_root}

%if %{use_sqlite}
[ -n "%{sqlitedir}" ] && rm -rf -- "../%{sqlitedir}"
unzip -q %{SOURCE1} -d ../%{sqlitedir}
%endif

%if %{use_bundled_c_lib}
[ -n "%{xcryptver}" ] && rm -rf -- "../libxcrypt-%{xcryptver}"
tar -xf %{SOURCE2} -C ..
%endif


%build
export GOPROXY="%{go_proxy}"

%if %{with update_deps}
%if %{with testsuite}
%{go_update_tree_tests}
%else
%{go_update_tree}
%endif
%endif

%if %{with audit}
%go_security_audit
%endif

%go_build_target linux
%pkg_stage_completions

%if %{enable_windows} && %{with windows}
%go_build_target windows
%endif

%if %{enable_archive} && %{with archive}
%pkg_stage_archive
%endif

%if %{enable_windows} && %{with windows}
%pkg_stage_zip
%endif

%if %{enable_deb} && %{with deb}
%pkg_build_deb
%endif


%install
%pkg_clean_buildroot

%if %{with rpm}
%pkg_install_bin
%pkg_install_completions
%pkg_install_daemon
%endif


%if %{with check}
%check
%pkg_check_bins

%if %{with lint}
%go_lint_checks
%endif

%if %{with testsuite}
%go_run_tests
%endif
%endif


%clean
%pkg_clean_buildroot


%if %{with rpm}
%if "%{?completion_cmd}" != ""
%files -f completions.files
%else
%files
%endif
%defattr(-,root,root,-)
%license %{license_file}
%doc %{doclist}
%{_bindir}/%{bin_name}
%pkg_files_daemon
%endif

%pkg_systemd_scriptlets


%changelog
* <changelog_date> <maintainer> - <version>-<release_num>
- Updated to latest upstream release
