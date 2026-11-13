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
#   2. Set feature toggles below:
#        use_sqlite:  1 = build embedded SQLite amalgamation via Zig
#        is_daemon:   1 = enable systemd service/sysusers/tmpfiles/.env + deb hooks
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
#        --with testsuite (nextest/cargo test), --with lint, --with audit,
#        --with update_deps (run cargo update --recursive)
#
# TECHNICAL ARCHITECTURE:
#   - Shared lifecycle macros (%%pkg_*) come from pkg-common.inc; Rust/Cargo
#     build/lint/audit macros (%%rust_build_target, %%rust_lint_checks,
#     %%rust_security_audit, %%rust_run_tests) come from rust-toolchain.inc.
#   - %%check executes binary wellness validation via pkg-verify.sh by default;
#     linting, security audit, unit tests, and dependency updates are opt-in via --with flags.
# ==============================================================================

# Common toolchain definitions, architecture mappings, and sanity checks
%include %{_sourcedir}/rust-toolchain.inc

# Feature toggles & build target gates (overriding defaults in pkg-common.inc)
%global is_daemon          0
%global use_sqlite         0
%global enable_archive     1
%global enable_deb         1
%global enable_windows     1

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

%global gh_tag          <git_hash>
%global pkgver          %{version}-%{gh_tag}
%global src_root        %{name}-main
%global bin_name        %{name}
%global license_file    LICENSE
%global completion_cmd  %{nil}
%global version_flag    --version
%global cargo_features  <cargo_features>
%global deb_depends     <deb_depends>

# Package Sources and Shared Helpers
Source0:        %{name}-%{version}-%{gh_tag}-src.zip
%if %{use_sqlite}
Source1:        sqlite-amalgamation-%{sqlitever}.zip
%endif
Source10:       zig-musl.sh
%if %{enable_deb}
Source11:       pkg-deb.sh
%endif
Source12:       rust-toolchain.inc
Source13:       pkg-common.inc
Source14:       pkg-verify.sh

%if %{is_daemon}
Source20:       %{name}.service
Source21:       %{name}.sysusers.conf
Source22:       %{name}.tmpfiles.conf
Source23:       %{name}.env
%endif

%pkg_common_buildrequires

%description
%{pkg_desc}


%prep
%autosetup -p1 -n %{src_root}

%if %{use_sqlite}
[ -n "%{sqlitedir}" ] && rm -rf -- "../%{sqlitedir}"
unzip -q %{SOURCE1} -d ../%{sqlitedir}
%endif

%if %{with update_deps}
%{cargo_update}
%endif

%if %{with audit}
%rust_security_audit
%endif


%build
%rust_build_target linux
%pkg_stage_completions

%if %{enable_windows} && %{with windows}
%rust_build_target windows
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
%rust_lint_checks
%endif

%if %{with testsuite}
%rust_run_tests
%endif
%endif


%clean
%pkg_clean_buildroot
%if %{use_sqlite}
[ -n "%{sqlitedir}" ] && rm -rf -- "../%{sqlitedir}"
%endif


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
