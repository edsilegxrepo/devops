# Packaging Methodology: Static SQLite with Musl and CGO (CGO_ENABLED=1)
### Enterprise Engineering Guide for 100% Static Multi-Target Go Packaging via Zig and SQLite Amalgamation

---

## 1. Executive Summary & Objective

In enterprise data pipelines, server daemons, and command-line interfaces (such as **SFTPGo**, **Sling CLI**, and **sq**), SQLite is frequently utilized as either an embedded application database, a state store, or an active ETL/query execution target.

In the Go ecosystem, the premier SQLite driver is [`github.com/mattn/go-sqlite3`](https://github.com/mattn/go-sqlite3). Because SQLite is written in C, compiling Go applications with `go-sqlite3` requires **CGO** (`CGO_ENABLED=1`).

### The Traditional Packaging Dilemma:
1. **Dynamic Linking & Glibc Lock-in**: Standard CGO compilation links dynamically against the host machine's C library (`glibc`). Binaries built on modern enterprise distributions (e.g. RHEL 9 with `glibc 2.34`, or Ubuntu 24.04 with `glibc 2.39`) immediately fail when deployed to older distributions (e.g. RHEL 8 or Debian 11) with symbol errors (`GLIBC_X.XX not found`).
2. **Bundled SQLite Code Inconsistencies**: By default, `mattn/go-sqlite3` compiles an internal, bundled copy of `sqlite3-binding.c`. This bundled source lacks critical enterprise extensions (such as FTS5, RTREE, Session, GeoPoly, and Column Metadata), or requires passing multiple fragmented Go build tags that are difficult to standardize across packaging targets.
3. **Pure Go Fallbacks Lack Compatibility**: Setting `CGO_ENABLED=0` disables CGO completely. Any package importing Arrow C Data Interface (`arrow/cdata`), DuckDB, or native C drivers will fail with:
   ```text
   build constraints exclude all Go files in .../arrow/cdata
   ```

### The Solution:
This framework implements a standardized, reproducible methodology that enables **`CGO_ENABLED=1`** while still producing **100% statically linked ELF binaries (musl libc)** on Linux and standalone PE executables on Windows.

By utilizing **Zig 0.17+** as a static cross-compiler via the [`zig-musl.sh`](./SOURCES/zig-musl.sh) multi-call wrapper, alongside the standalone official **SQLite Amalgamation** (`sqlite3.c` + `sqlite3.h`), the build pipeline compiles a production-hardened `libsqlite3.a` archive on-the-fly and statically embeds it into the final Go binary.

---

## 2. Technical Architecture & Blueprint

```
+---------------------------------------------------------------------------------------+
|                                    RPM BUILD ROOT                                     |
|                                                                                       |
|   1. SOURCES/sqlite-amalgamation-3540100.zip                                          |
|      +-- Extracted in %prep outside Go module tree: ../sqlite-src-354/                |
|          +-- sqlite3.c                                                                |
|          +-- sqlite3.h                                                                |
|                                                                                       |
|   2. SOURCES/pkg-common.inc                                                           |
|      +-- Ingests enterprise SQLite compilation flags (%{sqlite_amalgamation_cflags})  |
|          (-DSQLITE_ENABLE_FTS5=1, -DSQLITE_ENABLE_RTREE=1, -DSQLITE_THREADSAFE=1 ...) |
|                                                                                       |
|   3. SOURCES/zig-musl.sh (Multi-Call Compiler / Archiver / Linker Wrapper)            |
|      +-- Dispatches to Zig compiler (resolving /var/opt/zig, /u01/zig, or PATH)       |
|      +-- Linux Target:   %{SOURCE10} cc -target %{_arch}-linux-musl                   |
|      +-- Windows Target: %{SOURCE10} cc -target %{_arch}-windows-gnu                  |
|                                                                                       |
|   4. On-The-Fly Compilation Step (per target OS):                                     |
|      +-- %{SOURCE10} cc -target <target> ${SQLITE_CFLAGS} -c sqlite3.c -o sqlite3.o   |
|      +-- %{SOURCE10} ar rcs .sqlite_lib_<target>/libsqlite3.a sqlite3.o               |
|                                                                                       |
|   5. Go Compiler Invocation:                                                          |
|      +-- CGO_ENABLED=1                                                                |
|      +-- CGO_CFLAGS="-I${SQLITE_DIR}"                                                 |
|      +-- CGO_LDFLAGS="-L$(pwd)/.sqlite_lib_<target> -lsqlite3"                        |
|      +-- CC="%{SOURCE10} cc -target <target>"                                         |
|      +-- CXX="%{SOURCE10} c++ -target <target>"                                       |
|      +-- go build -tags "libsqlite3" -ldflags "-s -w -linkmode=external               |
|                           -extldflags '-static-pie'"                                  |
|                                                                                       |
|   6. Resulting Artifact:                                                              |
|      +-- 100% Statically Linked Musl ELF Binary (Zero Glibc / Zero Dynamic Linker)    |
|      +-- Validated via: %{SOURCE10} check "bin/<name>" "<version>"                    |
+---------------------------------------------------------------------------------------+
```

---

## 3. Step-by-Step Implementation Guide

> [!TIP]
> **Using the Master Spec Template (`pkg-go-template-xg.spec`):**
> For new packages, [`pkg-go-template-xg.spec`](./SPECS/pkg-go-template-xg.spec) (or [`pkg-make.sh --platform go --sqlite`](./SOURCES/pkg-make.sh)) automates all steps below via `%global use_cgo 1`, `%global use_sqlite 1`, `%go_build_target`, `%go_run_tests`, and `%pkg_check_bins` (`pkg-verify.sh`). The walkthrough below documents the underlying mechanics for custom specs and debugging.

Follow this exact blueprint when packaging any Go project that imports `mattn/go-sqlite3`.

### Step 1: Ingest Common Includes & Validate Toolchains

At the start of your spec file, load the toolchain definitions from [`go-toolchain.inc`](./SOURCES/go-toolchain.inc) (which automatically includes [`pkg-common.inc`](./SOURCES/pkg-common.inc)):

```spec
# ------------------------------------------------------------------------------
# 1. Toolchain Integration & Multi-Target Build Condition Flags
# ------------------------------------------------------------------------------
%include %{_sourcedir}/go-toolchain.inc

# Distribution artifact build condition flags
%bcond_without rpm
%bcond_with    windows
%bcond_with    archive
%bcond_with    deb
%bcond_without check
%bcond_with    testsuite
```

> [!NOTE]
> [`go-toolchain.inc`](./SOURCES/go-toolchain.inc) automatically includes [`pkg-common.inc`](./SOURCES/pkg-common.inc). Together, these enterprise includes provide:
> - **RPM Build Directives**: Disables build-id collision links (`%global _build_id_links none`), disables debuginfo extraction on static binaries (`%global debug_package %{nil}`), and overrides the host strip binary with `/bin/true` (`%global __strip /bin/true`) to protect static-pie and Windows PE executables from corruption.
> - **Multi-Architecture Canonical Mapping**: Establishes `%global plat_arch %(echo %{_arch} | sed ...)` mapping `x86_64` to `amd64`, `aarch64` to `arm64`, and `armv7*` to `armhf`.
> - **Shared Linker Flags**: Defines standard external static CGO linker flags `%{go_cgo_ldflags_linux}` (`-linkmode=external -extldflags '-static-pie'`) and `%{go_cgo_ldflags_win}` (`-linkmode=external -extldflags '-static'`).
> - **Amalgamation CFLAGS**: Ingests the hardened compilation macro `%{sqlite_amalgamation_cflags}`.

---

### Step 2: Define SQLite Metadata Macros

In Section 4 of your spec file, define the SQLite amalgamation version, directory name, and formatted semantic version:

```spec
# ------------------------------------------------------------------------------
# 4. Go Module Path, Versioning & Artifact Naming Definitions
# ------------------------------------------------------------------------------
%global goipath         github.com/owner/repository
%global gh_tag          39d4fb0
%global pkgver          %{version}-%{gh_tag}
%global dist_base       %{distpath}/%{name}-%{pkgver}
%global rel_num         %(echo %{release} | cut -d. -f1)

# Embedded SQLite amalgamation metadata definitions
%global sqlitever       3540100
%global sqlitedir       sqlite-src-%(echo %{sqlitever} | cut -c1-3)
%global sqlitedotver    %(echo %{sqlitever} | awk '{maj=substr($0,1,1); min=substr($0,2,2)+0; rel=substr($0,4,2)+0; patch=substr($0,6,2)+0; print maj "." min "." rel (patch > 0 ? "." patch : "")}')
```

> **Calculation Explanation**:
> - `3540100` translates to SQLite **3.54.1**.
> - `sqlitedir` resolves to `sqlite-src-354`.
> - `sqlitedotver` resolves to `3.54.1`.

---

### Step 3: Declare Sources and Build-Time Dependencies

Register the SQLite amalgamation archive as `Source1` and ensure `unzip` is listed in `BuildRequires`:

```spec
# ------------------------------------------------------------------------------
# 6. Package Sources & Shared Pipeline Scripts
# ------------------------------------------------------------------------------
Source0:        %{name}-%{version}-%{gh_tag}-src.zip
Source1:        sqlite-amalgamation-%{sqlitever}.zip
Source10:       zig-musl.sh
Source11:       pkg-deb.sh
Source12:       go-toolchain.inc
Source13:       pkg-common.inc

# ------------------------------------------------------------------------------
# 7. Build-Time Dependencies
# ------------------------------------------------------------------------------
BuildRequires:  golang >= 1.22
BuildRequires:  unzip
BuildRequires:  tar
BuildRequires:  file binutils
%if %{with archive}
BuildRequires:  xz
%endif
%if %{with deb}
BuildRequires:  dpkg
%endif
%if %{with windows}
BuildRequires:  zip unix2dos
%endif
```

---

### Step 4: Unpack Amalgamation in `%prep`

In the `%prep` phase, unpack the main application into `%{name}-main` (or `%{name}-master`), and unpack the SQLite amalgamation into the **parent directory** `../%{sqlitedir}`:

```spec
# ------------------------------------------------------------------------------
# 8. Source Unpacking & Preparation Phase
# ------------------------------------------------------------------------------
%prep
%autosetup -p1 -n %{name}-main

# Optional: Clean up upstream development workstation replace directives
go mod edit -dropreplace='github.com/flarco/g' go.mod 2>/dev/null || :
go mod edit -dropreplace='github.com/slingdata-io/sling' go.mod 2>/dev/null || :
go mod edit -droprequire='github.com/slingdata-io/sling' go.mod 2>/dev/null || :

# Unpack SQLite amalgamation into parent build tree
[ -n "%{sqlitedir}" ] && rm -rf -- "../%{sqlitedir}"
unzip -q %{SOURCE1} -d ../%{sqlitedir}
```

> [!IMPORTANT]
> Always unpack the SQLite amalgamation into `../%{sqlitedir}` (outside the Go module checkout). If unpacked inside the Go module root, the Go compiler will attempt to treat the C files as part of the Go package, triggering compilation failures.

---

### Step 5: Configure Compilation and Target Build Function in `%build`

Configure `%build` to locate the SQLite source files and compile the static library per target:

```spec
# ------------------------------------------------------------------------------
# 9. Compilation & Multi-Target Packaging Phase
# ------------------------------------------------------------------------------
%build
chmod +x %{SOURCE10} %{SOURCE11} 2>/dev/null || :
export GOPROXY="%{go_proxy}"
export CGO_ENABLED=1

# Security compliance: auto-update Go dependencies within module constraints
%{go_update_tree}

# Locate SQLite Amalgamation directory
SQLITE_DIR="$(cd ../%{sqlitedir}/sqlite-amalgamation-* 2>/dev/null && pwd)"
[ -d "${SQLITE_DIR}" ] || { echo "ERROR: SQLite amalgamation directory not found in ../%{sqlitedir}" >&2; exit 1; }

SQLITE_CFLAGS="%{sqlite_amalgamation_cflags}"

mkdir -p bin

# Target compilation function for Linux static musl and Windows PE
build_target() {
    local target_os="$1"
    export GOOS="${target_os}"
    export GOARCH="%{plat_arch}"
    local ext=""
    local cc_target=""
    local cxx_target=""
    local extra_ldflags=""
    local tags="libsqlite3"
    local target_libdir="$(pwd)/.sqlite_lib_${target_os}"
    local cgo_cflags="-I${SQLITE_DIR}"
    local cgo_ldflags="-L${target_libdir} -lsqlite3"

    # Ensure a pristine library output directory for this target
    [ -n "${target_libdir}" ] && rm -rf -- "${target_libdir}"
    mkdir -p "${target_libdir}"

    if [ "$target_os" = "windows" ]; then
        ext=".exe"
        cc_target="%{_arch}-windows-gnu"
        extra_ldflags="%{go_cgo_ldflags_win}"
    else
        cc_target="%{_arch}-linux-musl"
        extra_ldflags="%{go_cgo_ldflags_linux}"
    fi
    cxx_target="${cc_target}"

    # 1. Compile SQLite Amalgamation into static object file via Zig
    echo "==> [${target_os}] Compiling static SQLite %{sqlitedotver} with Zig (target: ${cc_target})..."
    %{SOURCE10} cc -target "${cc_target}" ${SQLITE_CFLAGS} \
        -c "${SQLITE_DIR}/sqlite3.c" -o "${target_libdir}/sqlite3.o"

    # 2. Archive object file into static library archive (libsqlite3.a)
    %{SOURCE10} ar rcs "${target_libdir}/libsqlite3.a" "${target_libdir}/sqlite3.o"

    # 3. Compile Go binary with external CGO linking against libsqlite3.a
    echo "==> [${target_os}] Compiling static binary with Zig (target: ${cc_target})..."
    CGO_CFLAGS="${cgo_cflags}" \
    CGO_LDFLAGS="${cgo_ldflags}" \
    CC="%{SOURCE10} cc -target ${cc_target}" \
    CXX="%{SOURCE10} c++ -target ${cxx_target}" \
    go build -tags "${tags}" %{go_opts} \
        -ldflags "-s -w ${extra_ldflags} %{go_ldflags}" \
        -o "bin/%{name}${ext}" .
}

# 1. Primary Target: Compile 100% static musl Linux binary
build_target linux
chmod 0755 "bin/%{name}"

# 2. Secondary Target: Cross-compile Windows 64-bit PE executable (if enabled)
%if %{with windows}
mkdir -p bin/windows
build_target windows
cp -af "bin/%{name}.exe" "bin/windows/"
%endif
```

---

### Step 6: Validate Binary Wellness in `%check`

Because the binary is statically linked against musl libc, `zig-musl.sh check` inspects the ELF header to assert the complete absence of a dynamic linker (`PT_INTERP` segment):

```spec
# ------------------------------------------------------------------------------
# 11. Validation Phase (Binary Wellness Integrity & Upstream Testsuite)
# ------------------------------------------------------------------------------
%if %{with check}
%check
# 1. Static ELF integrity inspection (asserts no PT_INTERP) and version execution
%{SOURCE10} check "bin/%{name}" "%{version}"
%if %{with windows}
%{SOURCE10} check-win "bin/windows/%{name}.exe"
%endif

# 2. Optional: Upstream unit testsuite (DISABLED by default; enable with --with testsuite)
%if %{with testsuite}
go test -short -tags "libsqlite3" ./...
%endif
%endif
```

---

## 4. In-Depth Analysis: The SQLite Amalgamation CFLAGS

The shared compilation flags defined in `%{sqlite_amalgamation_cflags}` (located in [`pkg-common.inc`](./SOURCES/pkg-common.inc)) represent a production-hardened, high-performance configuration:

| Flag | Purpose & Technical Benefit |
| :--- | :--- |
| `-O2 -std=gnu99 -fPIC` | Production optimization level, C99/GNU standards, and Position Independent Code for static PIE binaries. |
| `-DSQLITE_THREADSAFE=1` | Configures SQLite in Multi-Threaded serialized mode, ensuring thread safety across Go goroutines. |
| `-DSQLITE_ENABLE_FTS5=1` | Enables **Full-Text Search 5**, permitting tokenized virtual table indexing and complex search queries. |
| `-DSQLITE_ENABLE_RTREE=1` | Enables the **R\*Tree index extension**, required for spatial and multidimensional bounding-box queries. |
| `-DSQLITE_ENABLE_GEOPOLY=1` | Enables the **GeoPoly extension** for geospatial polygon operations using GeoJSON structures. |
| `-DSQLITE_ENABLE_MATH_FUNCTIONS=1` | Embeds standard mathematical functions (`sin`, `cos`, `log`, `sqrt`, `ceil`, `floor`) into the SQL engine. |
| `-DSQLITE_ENABLE_COLUMN_METADATA=1` | Exposes metadata APIs (`sqlite3_column_database_name`, etc.), required by database query inspectors and ETL tools. |
| `-DSQLITE_ENABLE_DBSTAT_VTAB=1` | Provides the `dbstat` virtual table to inspect B-Tree depth and page allocation for performance tuning. |
| `-DSQLITE_ENABLE_STMTVTAB=1` | Exposes the `bytecode` and `tables_used` virtual tables for query plan debugging. |
| `-DSQLITE_ENABLE_PREUPDATE_HOOK=1` | Enables pre-update notification hooks, required by Change Data Capture (CDC) and replication engines. |
| `-DSQLITE_ENABLE_SESSION=1` | Enables the SQLite session extension to record changesets, compute inverted diffs, and apply patches. |
| `-DSQLITE_ENABLE_UNLOCK_NOTIFY=1` | Enables non-busy waiting on locked databases when shared cache or multi-process access is enabled. |
| `-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1` | Sets Write-Ahead Log (WAL) mode synchronous level to `NORMAL`, maximizing write throughput safely. |
| `-DSQLITE_DEFAULT_CACHE_SIZE=-4000` | Sets default memory cache size to 4000 KiB (~4MB) per connection instead of 2000 pages (~2MB), improving query performance in data-heavy pipelines. |
| `-DSQLITE_ENABLE_BATCH_ATOMIC_WRITE=1` | Enables atomic batch writes on supported filesystems (e.g. NVMe F2FS/ext4), reducing WAL write amplification and sync overhead. |
| `-DSQLITE_LIKE_DOESNT_MATCH_BLOBS=1` | Optimizes `LIKE` and `GLOB` operators to avoid scanning binary BLOBs, accelerating text filter operations. |
| `-DSQLITE_DEFAULT_MEMSTATUS=0` | Disables internal memory tracking APIs (`sqlite3_status()`), eliminating global mutex contention in high-throughput applications. |
| `-DSQLITE_USE_ALLOCA=1` | Allocates temporary scratch memory on the stack via `alloca()` rather than heap allocations. |
| `-DSQLITE_OMIT_SHARED_CACHE=1` | Disables deprecated shared cache mode, enforcing independent connection isolation per goroutine. |
| `-DSQLITE_DISABLE_DIRSYNC=1` | Avoids redundant directory synchronization calls during journal/WAL deletions on POSIX filesystems. |
| `-DSQLITE_DQS=0` | Enforces SQL standard strictness: string literals must use single quotes (`'string'`), preventing double-quoted typo ambiguities. |
| `-DSQLITE_DEFAULT_FOREIGN_KEYS=1` | Automatically enables foreign key constraint enforcement by default on all database connections. |
| `-DSQLITE_OMIT_DEPRECATED=1` | Strips legacy and deprecated C APIs to shrink the binary footprint and prevent insecure API usage. |

---

## 5. How `mattn/go-sqlite3` Interacts with `-tags "libsqlite3"`

Understanding the internal build tags of `mattn/go-sqlite3` is critical:

1. **Default Mode (No Tags)**:
   - Compiles `sqlite3-binding.c` bundled inside the Go module cache.
   - Bypasses any external compiler settings.
   - Requires compilation from scratch for every clean build.

2. **External Link Mode (`-tags "libsqlite3"`)**:
   - In `mattn/go-sqlite3/sqlite3_libsqlite3.go`:
     ```go
     //go:build libsqlite3
     // +build libsqlite3

     package sqlite3

     /*
     #cgo CFLAGS: -DUSE_LIBSQLITE3
     #cgo linux LDFLAGS: -lsqlite3
     #cgo darwin LDFLAGS: -lsqlite3
     #cgo windows LDFLAGS: -lsqlite3
     */
     import "C"
     ```
   - When `-tags "libsqlite3"` is present:
     - `sqlite3_libsqlite3.go` emits `#cgo CFLAGS: -DUSE_LIBSQLITE3`.
     - In `mattn/go-sqlite3/sqlite3-binding.c`, the entire 9.5 MB bundled source is wrapped in a preprocessor conditional:
       ```c
       #ifndef USE_LIBSQLITE3
       /* Bundled 9.5 MB SQLite C source code */
       #else // USE_LIBSQLITE3
       // If users really want to link against the system sqlite3 we
       // need to make this file a noop.
       #endif
       ```
       Because `USE_LIBSQLITE3` is defined, `sqlite3-binding.c` becomes an empty NOOP translation unit. This completely eliminates duplicate symbol collisions and shaves minutes off the Go build time.
     - CGO instructs the linker to resolve all SQLite C symbols against `-lsqlite3`.
     - Passing `CGO_CFLAGS="-I${SQLITE_DIR}"` directs `#include <sqlite3.h>` across `sqlite3.go` and all optional driver files to our amalgamation headers.
     - Passing `CGO_LDFLAGS="-L${target_libdir} -lsqlite3"` resolves `-lsqlite3` against our pre-compiled `${target_libdir}/libsqlite3.a`.

3. **Composing Driver Tags for Go-Level Extensions**:
   In addition to C-level amalgamation compilation, `mattn/go-sqlite3` provides optional Go APIs (such as Go-implemented virtual tables, statistical planners, and analytical functions). These are activated via `sqlite_*` Go build tags:
   - `sqlite_vtable` / `vtable`: Enables registering custom virtual tables implemented directly in Go.
   - `sqlite_stat4` / `stat4`: Enables SQLite `SQLITE_ENABLE_STAT4` query planner optimizer integration.
   - `sqlite_fts5` / `fts5`: Activates Go FTS5 helper utilities.
   - `sqlite_math_functions`: Registers Go math bindings.
   - `sqlite_introspect`: Exposes internal schema introspection hooks.

   Every optional file in `go-sqlite3` (e.g. `sqlite3_opt_vtable.go`) checks:
   ```c
   #ifndef USE_LIBSQLITE3
   #include "sqlite3-binding.h"
   #else
   #include <sqlite3.h>
   #endif
   ```
   Therefore, you can freely combine `libsqlite3` with any upstream Go driver tags:
   ```spec
   # Example from sq-xg.spec:
   local tags="libsqlite3 sqlite_vtable sqlite_stat4 sqlite_fts5 sqlite_introspect sqlite_json sqlite_math_functions"
   ```
   All optional Go wrappers compile cleanly against the external `sqlite3.h` and static `libsqlite3.a`.

4. **External Linker Delegation (`-linkmode=external`)**:
   - Go's internal linker cannot link against static C archives (`.a`) when CGO is enabled.
   - Passing `-linkmode=external` in `-ldflags` delegates the final executable creation to `CC` (`zig-musl.sh cc`).
   - For Linux: `-extldflags '-static-pie'` directs Zig's embedded LLD linker to emit a static Position-Independent Executable (`ET_DYN`) with all musl runtime code self-contained and zero `PT_INTERP` dynamic linker segments.
   - For Windows: `-extldflags '-static'` instructs Zig's LLD linker to emit a standalone PE32+ executable without runtime DLL dependencies.

---

## 6. The `zig-musl.sh` Multi-Call Wrapper Architecture

The [`zig-musl.sh`](./SOURCES/zig-musl.sh) script is a multi-call dispatch utility acting as a compiler, linker, static archiver, and ELF/PE verifier.

### Discovery Logic
`zig-musl.sh` automatically searches the host filesystem in prioritized order to discover the Zig binary:
1. `command -v zig` (in active `$PATH`)
2. `/var/opt/zig/zig` (standard enterprise symlink)
3. `/u01/zig/zig` (enterprise root installation)
4. `/usr/local/bin/zig`
5. `/opt/zig/zig`

### Argument Filtering & Normalization
When Go external linking invokes `zig-musl.sh cc -target x86_64-linux-musl`, the script intercepts and normalizes flags:
- Converts `--target` flags into Zig-compatible `-target <arch>-<os>` triples.
- Drops GNU-specific linker options that cause Zig LLD to fail (e.g. `-Wl,--unresolved-symbols*`).
- Bypasses redundant options to prevent linker syntax errors.

### Structural ELF Verification (`check` subcommand)
During `%check`, `pkg-verify.sh check <binary> [version] [version_flag]` (also reachable via legacy `zig-musl.sh check` delegation) verifies:
1. Binary exists and is non-empty.
2. File output matches `ELF (64|32)-bit.*static(ally|-pie)? linked`.
3. `readelf -l <binary>` contains **zero occurrences of `INTERP`** (verifying that no dynamic linker dependency exists).
4. Unless `version_flag` is `none`, executes `<binary> <version_flag>` (default `--version`) and asserts that the semantic version string is present.

---

## 7. Reference Real-World Implementations

Review these production specs in the repository to observe the exact methodology in practice:

1. **[`sftpgo-xg.spec`]**:
   - Full enterprise daemon using SQLite for authentication and virtual filesystem metadata.
   - Combines SQLite amalgamation with bundled static `libxcrypt`.
2. **[`sling-cli-xg.spec`]**:
   - High-throughput database ETL and replication CLI tool.
   - Uses SQLite amalgamation alongside Apache Arrow ADBC drivers and DuckDB.
3. **[`sq-xg.spec`]**:
   - Multi-database data wrangling CLI.
   - Links SQLite amalgamation while consuming static DuckDB from [`libduckdb-static-xg.spec`].
   - Generates native shell completions and man pages.
4. **[`libduckdb-static-xg.spec`]**:
   - Modular C++ static library package compiling DuckDB 2.0+ and all 7 bundled extensions for static musl CGO linking via Zig.
   - Decoupled from consuming Go packages to optimize build time and foster cross-toolchain reuse.
5. **[`pkg-go-template-xg.spec`]**:
   - Master enterprise Go spec template implementing standard multi-target conditions, systemd macros, and staging pipelines.

---

## 8. Troubleshooting & Common Pitfalls Checklist

| Symptom / Error | Root Cause | Solution |
| :--- | :--- | :--- |
| `sqlite3.h: No such file or directory` | `CGO_CFLAGS` missing or pointing to the wrong directory. | Ensure `CGO_CFLAGS="-I${SQLITE_DIR}"` is passed to `go build` and `SQLITE_DIR` contains `sqlite3.h`. |
| `undefined reference to sqlite3_open_v2` | Linker cannot find `libsqlite3.a`. | Ensure `CGO_LDFLAGS="-L${target_libdir} -lsqlite3"` points to the directory containing `libsqlite3.a`. |
| `build constraints exclude all Go files in .../cdata` | `CGO_ENABLED` is set to `0`. | Set `export CGO_ENABLED=1`. C-binding packages require CGO enabled. |
| `error: unsupported linker arg: --unresolved-symbols` | Third-party Go driver emits GNU ld-specific flags. | Ensure [`zig-musl.sh`](./SOURCES/zig-musl.sh) includes the `-Wl,--unresolved-symbols*)` filter case. |
| `ERROR: bin/<name> contains a dynamic linker (PT_INTERP) segment!` | Binary was linked dynamically against host `glibc` instead of static musl. | Ensure `-linkmode=external -extldflags '-static-pie'` (or `-static`) is passed in `-ldflags`, and `CC` points to `zig-musl.sh cc -target <arch>-linux-musl`. |
| `Invalid Info.Version value: <ver>` (in `sq`) | Version string injected into `buildinfo` lacked the leading `v`. | In `sq`, `golang.org/x/mod/semver` enforces `v` prefix. Use `-X '%{goipath}/cli/buildinfo.Version=v%{version}'`. |
| Duplicate symbol errors (`sqlite3_...`) during link | Both bundled SQLite and external `libsqlite3` were compiled. | Ensure `-tags "libsqlite3"` is passed to `go build`. |
| `relocation R_X86_64_32 against ... cannot be used when making a PIE object` | Static `sqlite3.o` was compiled without Position Independent Code. | Verify that `-fPIC` is present in `SQLITE_CFLAGS` (included by default in `%{sqlite_amalgamation_cflags}`). |
| `replacement directory ../... does not exist` | Upstream committed local workstation `replace` directives in `go.mod`. | Clean them up in `%prep` using `go mod edit -dropreplace=... 2>/dev/null \|\| :`. |
| `u.GoDriver undefined (type *dburl.URL has no field or method GoDriver)` | `%{go_update_tree}` (`go get -u`) bumped `github.com/xo/dburl` to `v0.27+` / `v0.57.0` where `GoDriver` was removed, breaking `github.com/xo/usql v0.21.6`. | Pin `github.com/xo/dburl@v0.26.1` using `go mod edit -require=github.com/xo/dburl@v0.26.1` and `go mod tidy` right after `%{go_update_tree}`. |
| Windows PE binary fails with missing runtime symbols | Binary was linked dynamically instead of statically. | Pass `extra_ldflags="%{go_cgo_ldflags_win}"` (`-linkmode=external -extldflags '-static'`) so `zig cc` statically embeds its self-contained C runtime into the standalone PE executable. |
| `ld.lld: error: undefined symbol: std::__cxx11::...` in C++ static archives (e.g. DuckDB) | Precompiled static libraries were compiled with GCC against GNU `libstdc++`, but Zig musl uses LLVM `libc++` (`std::__1::`). | Compile C++ source natively with `zig c++ -target <arch>-linux-musl` via CMake/Ninja to ensure standard library ABI homogeneity and static musl compatibility. |
| `ld.lld: error: relocation R_X86_64_64 cannot be used against symbol ...; recompile with -fPIC` | Helper C objects (e.g. `static_extension_loader.o`) compiled without `-fPIC` when targeting `-static-pie`. | Always pass `-fPIC` to `zig-musl.sh cc` when compiling static C/C++ helper objects for position-independent static executables. |
| `The install of the duckdb target requires changing an RPATH ... not supported with the Ninja generator unless on an ELF-based ... platform` | When cross-compiling for Windows (`x86_64-windows-gnu`) with CMake/Ninja on Linux, CMake defaults `CMAKE_SYSTEM_NAME` to `Linux` and attempts ELF RPATH modification on PE-COFF binaries. | Pass `-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_SKIP_RPATH=ON` to the CMake configuration command when `target_os="windows"`. |

