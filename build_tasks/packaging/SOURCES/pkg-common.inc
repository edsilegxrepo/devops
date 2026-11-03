# ==============================================================================
# File:        /usr/src/redhat/SOURCES/pkg-common.inc
# Purpose:     Universal RPM package definitions, macros, and directory mappings.
# Applicability: Shared across all language toolchains (Rust, Go, C/C++).
# Usage:       %%include %%{_sourcedir}/pkg-common.inc
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. RPM Build Engine Behavior Directives
# ------------------------------------------------------------------------------
# Disable build-id symlinks in /usr/lib/.build-id to prevent conflict errors
# when packaging multiple standalone static binaries.
%global _build_id_links none

# Target OS distribution identifier suffix (defaults to 'el' for Enterprise Linux)
%global __osver         %{?_osver}%{!?_osver:el}

# Disable automatic debuginfo package extraction for statically linked binaries
%global debug_package   %{nil}

# Packaging channel identifier suffix (e.g. 'xg')
%global __channel       xg

# Localize temporary build artifacts under the workspace BUILD tree
%define _tmppath        %{_topdir}/BUILD

# Override default strip command with /bin/true to prevent stripping or corrupting
# pre-stripped static musl and Windows PE binaries
%global __strip         /bin/true

# ------------------------------------------------------------------------------
# 2. Target Artifact Locations & Packaging Metadata
# ------------------------------------------------------------------------------
# Directory where non-RPM staging artifacts (tarball, zip, deb) are generated
%global distpath        %{?_distpath}%{!?_distpath:%{_topdir}/STAGING}

# Standard documentation files packaged across distributions
%global doclist         CHANGELOG.md README.md

# Package maintainer metadata applied to RPM and Debian control headers
%global maintainer      Mis Center <support@criticalsys.net>

# Canonical multi-architecture platform mapping for Debian (.deb) packaging:
# Maps RPM architecture naming (%%{_arch}) to Debian canonical arch strings
# (x86_64 -> amd64, aarch64 -> arm64, i[3-6]86 -> i386, armv7* -> armhf)
%global plat_arch       %(echo %{_arch} | sed -e "s/x86_64/amd64/" -e "s/aarch64/arm64/" -e "s/i.86/i386/" -e "s/armv7.*/armhf/" -e "s/ppc64le/ppc64el/")

# Canonical artifact staging naming patterns (Linux tarball, Windows zip, Debian deb)
%{!?dist_archive:%global dist_archive %{dist_base}-linux_%{plat_arch}.tar.xz}
%{!?dist_zip:%global dist_zip         %{dist_base}-windows_%{plat_arch}.zip}
%{!?dist_deb:%global dist_deb         %{dist_base}-linux_%{plat_arch}.deb}

# Standard changelog generator macro (populates changelog.txt for staging payloads)
%define generate_changelog() cat << "EOF" > changelog.txt\
* %(LC_ALL=C date '+%%a %%b %%d %%Y') %{maintainer} - %{version}-%{?rel_num}%{!?rel_num:1}\
- Packages updated to latest upstream release\
EOF

# Toolchain helper: detect Zig compiler in PATH or standard enterprise locations
%global has_zig         %(command -v zig >/dev/null 2>&1 || [ -x /var/opt/zig/zig ] || [ -x /u01/zig/zig ] || [ -x /usr/local/bin/zig ] || [ -x /opt/zig/zig ] && echo 1 || echo 0)

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
