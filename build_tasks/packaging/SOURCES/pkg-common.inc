# ==============================================================================
# File:          /usr/src/packages/TEMPLATE/SOURCES/pkg-common.inc
# Purpose:       Universal RPM package definitions, defaults, and lifecycle macros.
# Applicability: Shared across all language toolchains (Go, Rust, C/C++).
# Usage:         %%include %%{_sourcedir}/pkg-common.inc
#
# Objectives:
#   Provide a single source of truth for distro-neutral static packaging rules,
#   multi-format staging (RPM, tar.xz, Windows zip, Debian .deb), daemon assets,
#   and safe buildroot/completion handling across all spec templates.
#
# Core Components:
#   - RPM directives & defaults: _build_id_links, debug_package, __strip,
#     pkg_rel_suffix, feature toggles (is_daemon, use_cgo, use_sqlite, etc.).
#   - Metadata & arch helpers: plat_arch, sqlitever/sqlitedir/sqlitedotver,
#     dist_archive/dist_zip/dist_deb, generate_changelog, has_zig, completion paths.
#   - Lifecycle macros: %%pkg_common_buildrequires, %%pkg_clean_buildroot,
#     %%pkg_prep_staging, %%pkg_stage_completions, %%pkg_stage_archive,
#     %%pkg_stage_zip, %%pkg_build_deb, %%pkg_install_bin, %%pkg_install_completions,
#     %%pkg_install_daemon, %%pkg_check_bins, %%pkg_files_*, %%pkg_systemd_scriptlets.
#
# Functionality & Data Flows:
#   1. Included early in a spec (directly or via toolchain .inc), setting global
#      RPM behavior before package metadata is parsed.
#   2. Defines lazy overrides (%%{!?var:...}) evaluated when %%build/%%install/%%check
#      macros expand after Name, Version, gh_tag, and feature toggles are set.
#   3. Delegates heavy verification and .deb assembly out to SOURCE14 (pkg-verify.sh)
#      and SOURCE11 (pkg-deb.sh), passing CLI flags derived from spec toggles.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. RPM Build Engine Behavior Directives
# ------------------------------------------------------------------------------
# Disable build-id symlinks in /usr/lib/.build-id to prevent conflict errors
# when packaging multiple standalone static binaries.
%global _build_id_links none

# Strip numeric version/minor release suffix from %%{?dist} (e.g. .el9 / .el9_4 -> .el)
# so static musl RPMs stay cleanly distro-neutral across EL 8/9/10.
%global __os_nodigits   %(echo %{?dist} | sed -e 's/[0-9_].*$//')

# Disable automatic debuginfo package extraction for statically linked binaries
%global debug_package   %{nil}

# Packaging channel identifier suffix (e.g. 'xg')
%global __channel       xg

# Helper suffix for standard Release tag (e.g. Release: 1%%{pkg_rel_suffix})
%global pkg_rel_suffix  %{__os_nodigits}.%{__channel}

# Localize temporary build artifacts under the workspace BUILD tree
%define _tmppath        %{_topdir}/BUILD

# Override default strip command with /bin/true to prevent stripping or corrupting
# pre-stripped static musl and Windows PE binaries
%global __strip         /bin/true

# Standard feature toggles & verification defaults (overridable per spec via %%global)
%{!?is_daemon:%global is_daemon 0}
%{!?use_sqlite:%global use_sqlite 0}
%{!?use_cgo:%global use_cgo 0}
%{!?use_bundled_c_lib:%global use_bundled_c_lib 0}
%{!?bin_name:%global bin_name %{name}}
%{!?license_file:%global license_file LICENSE}
%{!?completion_cmd:%global completion_cmd %{nil}}
%{!?enable_archive:%global enable_archive 1}
%{!?enable_deb:%global enable_deb 1}
%{!?enable_windows:%global enable_windows 1}
%{!?version_flag:%global version_flag --version}
%{!?deb_section:%global deb_section utils}
%{!?pkgver:%define pkgver %{?gh_tag:%{version}-%{gh_tag}}%{!?gh_tag:%{version}}}
%{!?check_version:%define check_version %{version}}
%{!?dist_base:%define dist_base %{distpath}/%{name}-%{pkgver}}
%{!?rel_num:%define rel_num %(echo %{?release} | cut -d. -f1)}
%{!?pkg_deb_version:%define pkg_deb_version %{pkgver}-%{rel_num}.%{__channel}}

# ------------------------------------------------------------------------------
# 2. Target Artifact Locations & Packaging Metadata
# ------------------------------------------------------------------------------
# Directory where non-RPM staging artifacts (tarball, zip, deb) are generated
%global distpath        %{?_distpath}%{!?_distpath:%{_topdir}/STAGING}

# Standard documentation files packaged across distributions (override per spec if needed)
%global doclist         README.md

# Embedded SQLite Amalgamation version metadata (used when use_sqlite is 1)
%{!?sqlitever:%global sqlitever       3540100}
%{!?sqliteyear:%global sqliteyear     2026}
%{!?sqlitedir:%global sqlitedir       sqlite-src-%(echo %{sqlitever} | cut -c1-3)}
%{!?sqlitedotver:%global sqlitedotver %(echo %{sqlitever} | awk '{maj=substr($0,1,1); min=substr($0,2,2)+0; rel=substr($0,4,2)+0; patch=substr($0,6,2)+0; print maj "." min "." rel (patch > 0 ? "." patch : "")}')}

# Package maintainer metadata applied to RPM and Debian control headers
%global maintainer      Mis Center <support@criticalsys.net>

# Canonical multi-architecture platform mapping for Debian (.deb) packaging:
# Maps RPM architecture naming (%%{_arch}) to Debian canonical arch strings
# (x86_64 -> amd64, aarch64 -> arm64, i[3-6]86 -> i386, armv7* -> armhf)
%global plat_arch       %(echo %{_arch} | sed -e "s/x86_64/amd64/" -e "s/aarch64/arm64/" -e "s/i.86/i386/" -e "s/armv7.*/armhf/" -e "s/ppc64le/ppc64el/")

# Canonical artifact staging naming patterns (Linux tarball, Windows zip, Debian deb)
# Uses %%define for lazy evaluation after spec sets Name, Version, and optional gh_tag
%{!?dist_archive:%define dist_archive %{dist_base}-linux_%{plat_arch}.tar.xz}
%{!?dist_zip:%define dist_zip         %{dist_base}-windows_%{plat_arch}.zip}
%{!?dist_deb:%define dist_deb         %{dist_base}-linux_%{plat_arch}.deb}

# Standard changelog generator macro (populates changelog.txt for staging payloads)
%define generate_changelog() printf '* %%s %%s - %%s-%%s\n- Packages updated to latest upstream release\n' "$(LC_ALL=C date '+%%a %%b %%d %%Y')" '%{maintainer}' '%{version}' '%{rel_num}' > changelog.txt

# Toolchain helper: detect Zig compiler in PATH or standard enterprise locations
%{!?has_zig:%global has_zig %(command -v zig >/dev/null 2>&1 || [ -x /var/opt/zig/zig ] || [ -x /u01/zig/zig ] || [ -x /usr/local/bin/zig ] || [ -x /opt/zig/zig ] && echo 1 || echo 0)}

# ------------------------------------------------------------------------------
# 3. Standard Shell Completions Directories
# ------------------------------------------------------------------------------
# Provides unified shell completion target paths across Rust, Go, and C CLIs
%{!?bash_completions_dir:%global bash_completions_dir %{_datadir}/bash-completion/completions}
%{!?zsh_completions_dir:%global zsh_completions_dir %{_datadir}/zsh/site-functions}
%{!?fish_completions_dir:%global fish_completions_dir %{_datadir}/fish/vendor_completions.d}

# ------------------------------------------------------------------------------
# 4. Standard Systemd Unit & Configuration Directories
# ------------------------------------------------------------------------------
# Defensive macro fallbacks for daemon service, sysusers, and tmpfiles installation
%{!?_unitdir:%global _unitdir %{_prefix}/lib/systemd/system}
%{!?_sysusersdir:%global _sysusersdir %{_prefix}/lib/sysusers.d}
%{!?_tmpfilesdir:%global _tmpfilesdir %{_prefix}/lib/tmpfiles.d}

# ------------------------------------------------------------------------------
# 5. Embedded SQLite Amalgamation Compilation Flags
# ------------------------------------------------------------------------------
# Production-hardened compilation flags for building the static SQLite amalgamation
# (sqlite3.c -> libsqlite3.a) via Zig musl across Linux and Windows targets.
%{!?sqlite_amalgamation_cflags:%global sqlite_amalgamation_cflags -O2 -std=gnu99 -fPIC \\\
    -DSQLITE_THREADSAFE=1 \\\
    -DSQLITE_DEFAULT_MEMSTATUS=0 \\\
    -DSQLITE_USE_ALLOCA=1 \\\
    -DSQLITE_OMIT_SHARED_CACHE=1 \\\
    -DSQLITE_DISABLE_DIRSYNC=1 \\\
    -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \\\
    -DSQLITE_DEFAULT_CACHE_SIZE=-4000 \\\
    -DSQLITE_ENABLE_BATCH_ATOMIC_WRITE=1 \\\
    -DSQLITE_LIKE_DOESNT_MATCH_BLOBS=1 \\\
    -DSQLITE_DQS=0 \\\
    -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \\\
    -DSQLITE_OMIT_DEPRECATED=1 \\\
    -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 \\\
    -DSQLITE_ENABLE_COLUMN_METADATA=1 \\\
    -DSQLITE_ENABLE_DBSTAT_VTAB=1 \\\
    -DSQLITE_ENABLE_STMTVTAB=1 \\\
    -DSQLITE_ENABLE_FTS5=1 \\\
    -DSQLITE_ENABLE_RTREE=1 \\\
    -DSQLITE_ENABLE_GEOPOLY=1 \\\
    -DSQLITE_ENABLE_MATH_FUNCTIONS=1 \\\
    -DSQLITE_ENABLE_PREUPDATE_HOOK=1 \\\
    -DSQLITE_ENABLE_SESSION=1}

# ------------------------------------------------------------------------------
# 6. DRY Spec Lifecycle Macros (BuildRequires, Staging, Install, Check, Daemon)
# ------------------------------------------------------------------------------
# Inject BuildRoot plus baseline and conditional BuildRequires driven by spec toggles
%define pkg_common_buildrequires \
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n) \
BuildRequires:  tar patch \
BuildRequires:  file binutils \
%if %{with rpm} && %{is_daemon} \
%{?SOURCE21:%{?sysusers_requires_compat}} \
%endif \
%if %{use_cgo} \
BuildRequires:  make \
%endif \
%if %{use_sqlite} \
BuildRequires:  unzip \
%endif \
%if %{enable_archive} && %{with archive} \
BuildRequires:  xz \
%endif \
%if %{enable_deb} && %{with deb} \
BuildRequires:  dpkg \
%if %{with lint} \
BuildRequires:  lintian \
%endif \
%endif \
%if %{enable_windows} && %{with windows} \
BuildRequires:  zip unix2dos \
%endif

# Safely clean %%{buildroot} after validating against root/system directory paths
%define pkg_clean_buildroot \
case "%{buildroot}" in \
  ""|"/"|"."|".."|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/sys"|"/tmp"|"/usr"|"/var") \
    echo "ERROR: Refusing unsafe buildroot path '%{buildroot}'" >&2; exit 1 ;; \
  *) \
    [ -d "%{buildroot}" ] && rm -rf -- "%{buildroot}" || : ;; \
esac

# Initialize staging output directory and generate changelog.txt for archives/zips
%define pkg_prep_staging \
mkdir -p %{distpath} \
%generate_changelog

# Generate bash/zsh/fish shell completions into staging_completions/ (skipped if empty)
%define pkg_stage_completions() \
_comp_cmd="%{?1}%{!?1:%{?completion_cmd}}" \
if [ -n "${_comp_cmd}" ]; then \
  mkdir -p staging_completions \
  read -r -a _comp_args <<< "${_comp_cmd}" \
  ./bin/%{bin_name} "${_comp_args[@]}" bash > staging_completions/%{bin_name}.bash 2>/dev/null || : \
  [ -s staging_completions/%{bin_name}.bash ] || rm -f -- staging_completions/%{bin_name}.bash \
  ./bin/%{bin_name} "${_comp_args[@]}" zsh  > staging_completions/_%{bin_name} 2>/dev/null || : \
  [ -s staging_completions/_%{bin_name} ] || rm -f -- staging_completions/_%{bin_name} \
  ./bin/%{bin_name} "${_comp_args[@]}" fish > staging_completions/%{bin_name}.fish 2>/dev/null || : \
  [ -s staging_completions/%{bin_name}.fish ] || rm -f -- staging_completions/%{bin_name}.fish \
fi

# Package Linux static binary, docs, systemd unit, and changelog into STAGING .tar.xz
%define pkg_stage_archive \
%pkg_prep_staging \
rm -f -- %{dist_archive} \
rm -rf -- staging_archive \
mkdir -p staging_archive/doc \
cp -af bin/%{bin_name} staging_archive/ \
chmod 0755 staging_archive/%{bin_name} \
if [ "%{is_daemon}" = "1" ]; then %{?SOURCE20:cp -af %{SOURCE20} staging_archive/doc/ 2>/dev/null || :}; fi \
cp -af %{license_file} %{doclist} changelog.txt staging_archive/doc/ 2>/dev/null || : \
(cd staging_archive && tar -Jcvf %{dist_archive} *) \
rm -rf -- staging_archive

# Package Windows .exe and CRLF-converted docs/changelog into STAGING .zip
%define pkg_stage_zip \
%pkg_prep_staging \
rm -f -- %{dist_zip} \
rm -rf -- staging_windows \
mkdir -p staging_windows/doc \
cp -af bin/windows/%{bin_name}.exe staging_windows/ \
cp -af %{license_file} %{doclist} changelog.txt staging_windows/doc/ 2>/dev/null || : \
unix2dos -k -q staging_windows/doc/* 2>/dev/null || : \
(cd staging_windows && zip -9r %{dist_zip} *) \
rm -rf -- staging_windows

# Build STAGING .deb via pkg-deb.sh (delegates post-build lintian to %%check when enabled)
%define pkg_build_deb \
mkdir -p %{distpath} \
_deb_upstream_chg="" \
for _cand in CHANGELOG.md CHANGELOG NEWS.md NEWS; do \
  if [ -f "$_cand" ]; then _deb_upstream_chg="$_cand"; break; fi \
done \
set -- \\\
  --name "%{name}" \\\
  --version "%{pkg_deb_version}" \\\
  --arch "%{plat_arch}" \\\
  --maintainer "%{maintainer}" \\\
  --summary "%{?pkg_summary}%{!?pkg_summary:%{summary}}" \\\
  --desc "%{pkg_desc}" \\\
  --homepage "%{url}" \\\
  --section "%{deb_section}" \\\
  --bin "bin/%{bin_name}" \\\
  --doc %{license_file} %{doclist} \\\
  --out "%{dist_deb}" \
[ -n "$_deb_upstream_chg" ] && set -- "$@" --changelog "$_deb_upstream_chg" \
if [ -n "%{?deb_depends}" ]; then \
  set -- "$@" --depends "%{deb_depends}" \
fi \
if [ "%{is_daemon}" = "1" ]; then \
  set -- "$@" --dir "/etc/%{name}:0750" %{?SOURCE20:--service "%{SOURCE20}"} %{?SOURCE21:--sysusers "%{SOURCE21}"} %{?SOURCE22:--tmpfiles "%{SOURCE22}"} %{?SOURCE23:--conffile "%{SOURCE23}:etc/%{name}/%{name}.env:0640"} \
fi \
if [ -d staging_completions ]; then \
  if [ -f "staging_completions/%{bin_name}.bash" ]; then set -- "$@" --completion-bash "staging_completions/%{bin_name}.bash"; fi \
  if [ -f "staging_completions/_%{bin_name}" ]; then set -- "$@" --completion-zsh "staging_completions/_%{bin_name}"; fi \
  if [ -f "staging_completions/%{bin_name}.fish" ]; then set -- "$@" --completion-fish "staging_completions/%{bin_name}.fish"; fi \
fi \
if [ -n "%{?deb_lintian_suppress}" ]; then \
  set -- "$@" --lintian-suppress "%{deb_lintian_suppress}" \
fi \
%if %{with check} \
set -- "$@" --no-lintian \
%else \
%if %{with lint} \
set -- "$@" --lintian \
%endif \
%endif \
bash %{SOURCE11} "$@"

# Install compiled Linux binary into %%{buildroot}%%{_bindir}/%%{bin_name}
%define pkg_install_bin \
mkdir -p %{buildroot}%{_bindir} \
cp -af bin/%{bin_name} %{buildroot}%{_bindir}/%{bin_name} \
chmod 0755 %{buildroot}%{_bindir}/%{bin_name}

# Install non-empty shell completions into %%{buildroot} and record paths in completions.files
%define pkg_install_completions \
: > completions.files \
if [ -d staging_completions ]; then \
  if [ -s "staging_completions/%{bin_name}.bash" ]; then \
    install -D -p -m 0644 "staging_completions/%{bin_name}.bash" "%{buildroot}%{bash_completions_dir}/%{bin_name}" \
    echo "%{bash_completions_dir}/%{bin_name}" >> completions.files \
  fi \
  if [ -s "staging_completions/_%{bin_name}" ]; then \
    install -D -p -m 0644 "staging_completions/_%{bin_name}" "%{buildroot}%{zsh_completions_dir}/_%{bin_name}" \
    echo "%{zsh_completions_dir}/_%{bin_name}" >> completions.files \
  fi \
  if [ -s "staging_completions/%{bin_name}.fish" ]; then \
    install -D -p -m 0644 "staging_completions/%{bin_name}.fish" "%{buildroot}%{fish_completions_dir}/%{bin_name}.fish" \
    echo "%{fish_completions_dir}/%{bin_name}.fish" >> completions.files \
  fi \
fi

# Install systemd unit, sysusers, tmpfiles, and restricted .env file when is_daemon=1
%define pkg_install_daemon \
%if %{is_daemon} \
%{?SOURCE20:install -D -p -m 0644 %{SOURCE20} %{buildroot}%{_unitdir}/%{name}.service} \
%{?SOURCE21:install -D -p -m 0644 %{SOURCE21} %{buildroot}%{_sysusersdir}/%{name}.conf} \
%{?SOURCE22:install -D -p -m 0644 %{SOURCE22} %{buildroot}%{_tmpfilesdir}/%{name}.conf} \
%{?SOURCE23:install -D -p -m 0640 %{SOURCE23} %{buildroot}%{_sysconfdir}/%{name}/%{name}.env} \
%endif

# Verify static ELF (no PT_INTERP), optional Windows PE32+, and optional .deb via pkg-verify.sh
%define pkg_check_bins \
bash %{SOURCE14} check "bin/%{bin_name}" "%{check_version}" "%{version_flag}" \
%if %{enable_windows} && %{with windows} \
bash %{SOURCE14} check-win "bin/windows/%{bin_name}.exe" \
%endif \
%if %{enable_deb} && %{with deb} \
%if %{with lint} \
bash %{SOURCE14} check-deb "%{dist_deb}" 1 "%{?deb_lintian_suppress}" \
%else \
bash %{SOURCE14} check-deb "%{dist_deb}" 0 "%{?deb_lintian_suppress}" \
%endif \
%endif

# Static completion paths for %%files (dynamic alternative uses %%files -f completions.files)
%define pkg_files_completions \
%if "%{?completion_cmd}" != "" \
%{bash_completions_dir}/%{bin_name} \
%{zsh_completions_dir}/_%{bin_name} \
%{fish_completions_dir}/%{bin_name}.fish \
%endif

# Daemon %%files manifest entries (unit, sysusers, tmpfiles, 0750 root:<name> config dir, 0640 root:<name> .env)
# Ownership root:<name> lets root write configs, daemon read them, and prevents systemd-tmpfiles unsafe path transitions
%define pkg_files_daemon \
%if %{is_daemon} \
%{?SOURCE20:%{_unitdir}/%{name}.service} \
%{?SOURCE21:%{_sysusersdir}/%{name}.conf} \
%{?SOURCE22:%{_tmpfilesdir}/%{name}.conf} \
%dir %attr(0750,root,%{name}) %{_sysconfdir}/%{name} \
%{?SOURCE23:%config(noreplace) %attr(0640,root,%{name}) %{_sysconfdir}/%{name}/%{name}.env} \
%endif

# Emit RPM %%pre/%%post/%%preun/%%postun systemd scriptlets when rpm and is_daemon are active
#   - %%pre creates the system group/user before RPM unpacks root:<name> files (idempotent on upgrades)
#   - %%post runs %%systemd_post (applies unit preset only on new install $1 -eq 1)
#   - %%preun runs %%systemd_preun (stops/disables service only on final erase $1 -eq 0)
#   - %%postun runs %%systemd_postun_with_restart (try-restart only on upgrade $1 -ge 1)
%define pkg_systemd_scriptlets \
%if %{with rpm} && %{is_daemon} \
%pre \
%{?SOURCE21:%{?sysusers_create_compat:%sysusers_create_compat %{SOURCE21}}} \
\
%post \
%systemd_post %{name}.service \
\
%preun \
%systemd_preun %{name}.service \
\
%postun \
%systemd_postun_with_restart %{name}.service \
%endif
