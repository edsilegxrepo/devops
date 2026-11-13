#!/bin/bash
# ==============================================================================
# Script:      /usr/src/packages/TEMPLATE/SOURCES/zig-musl.sh
# Purpose:     Multi-call Zig wrapper providing static musl compilation,
#              Windows PE cross-compilation, static C/SQLite archiving, Cargo
#              environment setup, and legacy ELF/PE verification forwarding.
#
# Objectives:
#   Provide hermetic C/C++/linker/archiver shims over Zig (`zig cc`, `zig c++`,
#   `zig ar`, `zig ranlib`) so Go CGO and Rust builds emit static musl Linux or
#   Windows GNU binaries without host glibc/toolchain leakage.
#
# Core Components:
#   - find_zig()      : Locates zig across $PATH and standard enterprise paths.
#   - cargo           : Exports CARGO_TARGET_* / CC_* / CXX_* / AR_* and runs cargo.
#   - build-sqlite    : Compiles static `libsqlite3.a` from amalgamation source.
#   - build-autotools : Static cross-compile + install for autotools C libraries.
#   - check/check-win : Legacy verification aliases delegating to `pkg-verify.sh`.
#   - ar/ranlib/cc/c++: Multi-call compiler/linker dispatcher normalizing targets.
#
# Functionality & Data Flows:
#   1. Resolves ZIG_BIN up front; falls back to $CC/$CXX/$AR/MinGW when appropriate.
#   2. Subcommand dispatch (`$1`) routes `cargo`, `build-sqlite`, `build-autotools`,
#      or `check*`; otherwise argv[0]/`$1` acts as `ar`, `ranlib`, `c++`, or `cc`.
#   3. Compiler dispatch strips incompatible flags (`-Wl,--unresolved-symbols*`),
#      deduplicates `--target`/`-target` args, and execs `zig <subcmd> -target ...`.
#
# Synopsis:
#   1. Cargo Build Wrapper:
#        zig-musl.sh cargo <cargo_subcommand> [cargo_flags...]
#        -> Automatically detects target triple, sets CARGO_TARGET_<KEY>_RUSTFLAGS,
#           CC_<target>, CXX_<target>, and AR_<target>, then invokes cargo.
#           Seamlessly handles both Linux musl and Windows PE targets.
#
#   2. Static SQLite Amalgamation Helper:
#        zig-musl.sh build-sqlite <target_triple> <sqlite_src_dir> <out_libdir> [cflags...]
#        -> Compiles sqlite3.c and archives libsqlite3.a via Zig for the target.
#
#   3. Static Autotools C Library Helper:
#        zig-musl.sh build-autotools <target_triple> <src_dir> <install_dir> [configure_args...]
#        -> Cross-compiles an autotools C project statically via Zig and installs into <install_dir>.
#
#   4. Linux / Windows Binary Verification (legacy wrapper; delegates to pkg-verify.sh):
#        zig-musl.sh check <binary_path> [expected_version_string] [version_flag]
#        zig-musl.sh check-win <pe_binary_path>
#
#   5. Multi-call Compiler / Linker / Archiver:
#        Invoked directly as a linker, compiler, or archiver (via symlink or argument):
#        - ar                  -> runs 'zig ar "$@"' (or $AR)
#        - ranlib              -> runs 'zig ranlib "$@"' (or $RANLIB)
#        - c++ | *clang++*     -> runs 'zig c++ -target <arch>-<os> "$@"' (or $CXX)
#        - cc  | * (default)   -> runs 'zig cc  -target <arch>-<os> "$@"' (or $CC)
#
# Environment Variables:
#   TARGET_TRIPLE : Target Rust triple (e.g. x86_64-unknown-linux-musl, x86_64-pc-windows-gnu)
#   TARGET_ARCH   : Target architecture (e.g. x86_64, aarch64; defaults to uname -m)
#   CC / CXX / AR : Fallback toolchain commands honored if Zig is not found in PATH
# ==============================================================================
set -eo pipefail

# ------------------------------------------------------------------------------
# 0. Toolchain Discovery
# ------------------------------------------------------------------------------
CMD="$(basename "$0")"

# Locate zig binary across PATH and standard enterprise system locations
find_zig() {
  if command -v zig > /dev/null 2>&1; then
    command -v zig
  elif [ -x "/var/opt/zig/zig" ]; then
    echo "/var/opt/zig/zig"
  elif [ -x "/u01/zig/zig" ]; then
    echo "/u01/zig/zig"
  elif [ -x "/usr/local/bin/zig" ]; then
    echo "/usr/local/bin/zig"
  elif [ -x "/opt/zig/zig" ]; then
    echo "/opt/zig/zig"
  else
    echo ""
  fi
}

ZIG_BIN="$(find_zig)"

# ------------------------------------------------------------------------------
# 1. Cargo Wrapper Subcommand
# ------------------------------------------------------------------------------
# Ingests cargo arguments, resolves target triple, sets musl/windows environment
# variables, and executes cargo with zig-musl configured as linker and C/C++ compiler.
if [ "$1" = "cargo" ]; then
  shift

  # Dynamically detect target triple from CLI args if not already exported
  if [ -z "$TARGET_TRIPLE" ]; then
    prev=""
    for arg in "$@"; do
      if [[ "$arg" == --target=* ]]; then
        TARGET_TRIPLE="${arg#--target=}"
      elif [ "$prev" = "--target" ]; then
        TARGET_TRIPLE="$arg"
      fi
      prev="$arg"
    done
  fi
  TARGET_TRIPLE="${TARGET_TRIPLE:-${TARGET_ARCH:-$(uname -m)}-unknown-linux-musl}"
  TARGET_SNAKE=$(echo "${TARGET_TRIPLE}" | tr '-' '_')
  CARGO_TARGET_KEY=$(echo "${TARGET_TRIPLE}" | tr '[:lower:]-' '[:upper:]_')

  SELF="$(readlink -f "$0")"
  export TARGET_TRIPLE

  if [[ "$TARGET_TRIPLE" == *windows* ]]; then
    # For Rust Windows target, allow cargo to link via MinGW GCC if available
    WIN_ARCH_PREFIX="${TARGET_TRIPLE%%-*}"
    if command -v "${WIN_ARCH_PREFIX}-w64-mingw32-gcc" > /dev/null 2>&1; then
      export "CC_${TARGET_SNAKE}=${WIN_ARCH_PREFIX}-w64-mingw32-gcc"
      export "CXX_${TARGET_SNAKE}=${WIN_ARCH_PREFIX}-w64-mingw32-g++"
      export "AR_${TARGET_SNAKE}=${WIN_ARCH_PREFIX}-w64-mingw32-ar"
    fi
  else
    export "CARGO_TARGET_${CARGO_TARGET_KEY}_RUSTFLAGS=-C linker=${SELF} -C link-self-contained=no"
    export "CC_${TARGET_SNAKE}=${SELF}"
    export "TARGET_CC=${SELF}"
    export "CXX_${TARGET_SNAKE}=${SELF} c++"
    export "TARGET_CXX=${SELF} c++"
    export "AR_${TARGET_SNAKE}=${SELF} ar"
    export "TARGET_AR=${SELF} ar"
  fi

  exec cargo "$@"
fi

# ------------------------------------------------------------------------------
# 2. Static SQLite Amalgamation Helper
# ------------------------------------------------------------------------------
if [ "$1" = "build-sqlite" ]; then
  shift
  CC_TARGET="$1"
  SQLITE_SRC="$2"
  OUT_LIBDIR="$3"
  shift 3 || {
    echo "Usage: $(basename "$0") build-sqlite <target_triple> <sqlite_src_dir> <out_libdir> [cflags...]" >&2
    exit 1
  }
  if [ -z "$ZIG_BIN" ]; then
    echo "ERROR: zig compiler not found in PATH for build-sqlite!" >&2
    exit 1
  fi
  if [ ! -f "${SQLITE_SRC}/sqlite3.c" ]; then
    echo "ERROR: sqlite3.c not found in '${SQLITE_SRC}'!" >&2
    exit 1
  fi
  mkdir -p "${OUT_LIBDIR}"
  "$ZIG_BIN" cc -target "${CC_TARGET}" "$@" -c "${SQLITE_SRC}/sqlite3.c" -o "${OUT_LIBDIR}/sqlite3.o"
  "$ZIG_BIN" ar rcs "${OUT_LIBDIR}/libsqlite3.a" "${OUT_LIBDIR}/sqlite3.o"
  exit 0
fi

# ------------------------------------------------------------------------------
# 2b. Static Autotools Cross-Compile Helper
# ------------------------------------------------------------------------------
if [ "$1" = "build-autotools" ]; then
  shift
  CC_TARGET="$1"
  CLIB_SRC="$2"
  INSTALL_DIR="$3"
  shift 3 || {
    echo "Usage: $(basename "$0") build-autotools <target_triple> <src_dir> <install_dir> [configure_args...]" >&2
    exit 1
  }
  if [ -z "$ZIG_BIN" ]; then
    echo "ERROR: zig compiler not found in PATH for build-autotools!" >&2
    exit 1
  fi
  if [ -z "$CC_TARGET" ] || [ -z "$INSTALL_DIR" ]; then
    echo "ERROR: build-autotools requires non-empty <target_triple> and <install_dir>!" >&2
    exit 1
  fi
  # Guard against destructive rm -rf on empty or system-critical paths
  case "$INSTALL_DIR" in
    "/"|"."|".."|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/sys"|"/tmp"|"/u01"|"/usr"|"/var")
      echo "ERROR: Refusing unsafe INSTALL_DIR '${INSTALL_DIR}'!" >&2
      exit 1
      ;;
  esac
  if [ ! -f "${CLIB_SRC}/configure" ]; then
    echo "ERROR: configure script not found in '${CLIB_SRC}'!" >&2
    exit 1
  fi
  CLIB_BUILD="${CLIB_SRC}/build-${CC_TARGET}"
  rm -rf -- "${CLIB_BUILD}" "${INSTALL_DIR}"
  mkdir -p "${CLIB_BUILD}" "${INSTALL_DIR}"
  pushd "${CLIB_BUILD}" >/dev/null
  # Default -fPIC so generated static archives link cleanly under Linux CGO -static-pie
  CC="${ZIG_BIN} cc -target ${CC_TARGET}" \
  CXX="${ZIG_BIN} c++ -target ${CC_TARGET}" \
  AR="${ZIG_BIN} ar" \
  RANLIB="${ZIG_BIN} ranlib" \
  CFLAGS="${CFLAGS:--O2 -fPIC}" \
  "${CLIB_SRC}/configure" --host="${CC_TARGET}" \
    --prefix="${INSTALL_DIR}" \
    --libdir="${INSTALL_DIR}/lib" \
    --enable-static \
    --disable-shared \
    "$@" >/dev/null 2>&1
  make -j"$(nproc)" >/dev/null 2>&1
  make install >/dev/null 2>&1
  popd >/dev/null
  exit 0
fi

# ------------------------------------------------------------------------------
# 3. Binary Verification Subcommands (delegates to pkg-verify.sh when present)
# ------------------------------------------------------------------------------
if [ "$1" = "check" ] || [ "$1" = "check-win" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
  if [ -x "${SCRIPT_DIR}/pkg-verify.sh" ]; then
    exec "${SCRIPT_DIR}/pkg-verify.sh" "$@"
  elif [ -f "${SCRIPT_DIR}/pkg-verify.sh" ]; then
    exec bash "${SCRIPT_DIR}/pkg-verify.sh" "$@"
  fi
fi

if [ "$1" = "check" ]; then
  shift
  BIN="$1"
  EXP_VER="$2"
  VER_FLAG="${3:---version}"
  if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
    echo "ERROR: Binary '$BIN' not found!" >&2
    exit 1
  fi
  echo "==> Verifying Linux binary structure ($BIN)..."
  FILE_OUT="$(file "$BIN")"
  grep -E -q "ELF (64|32)-bit.*static(ally|-pie)? linked" <<< "$FILE_OUT" || {
    echo "ERROR: $BIN is not a statically linked ELF binary!" >&2
    echo "$FILE_OUT" >&2
    exit 1
  }
  INTERP_OUT="$(readelf -l "$BIN" 2> /dev/null || true)"
  if grep -q "INTERP" <<< "$INTERP_OUT"; then
    echo "ERROR: $BIN contains a dynamic linker (PT_INTERP) segment!" >&2
    grep "INTERP" <<< "$INTERP_OUT" >&2
    exit 1
  fi
  if [ -n "$EXP_VER" ] && [ "$VER_FLAG" != "none" ]; then
    echo "==> Verifying binary execution ($BIN $VER_FLAG)..."
    read -r -a FLAG_ARGS <<< "$VER_FLAG"
    OUT="$("$BIN" "${FLAG_ARGS[@]}" 2>&1 || true)"
    [[ "$OUT" == *"$EXP_VER"* ]] || {
      echo "ERROR: $BIN $VER_FLAG output does not contain expected version '$EXP_VER'!" >&2
      echo "$OUT" >&2
      exit 1
    }
  fi
  echo "==> Binary verification passed for $BIN"
  exit 0
fi

if [ "$1" = "check-win" ]; then
  shift
  BIN="$1"
  if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
    echo "ERROR: Windows binary '$BIN' not found!" >&2
    exit 1
  fi
  echo "==> Verifying Windows binary structure ($BIN)..."
  FILE_OUT="$(file "$BIN")"
  grep -E -q "PE32\+ executable.*for MS Windows" <<< "$FILE_OUT" || {
    echo "ERROR: $BIN is not a valid 64-bit Windows PE executable!" >&2
    echo "$FILE_OUT" >&2
    exit 1
  }
  echo "==> Windows binary verification passed for $BIN"
  exit 0
fi

# ------------------------------------------------------------------------------
# 4. Archiver / Ranlib Dispatch
# ------------------------------------------------------------------------------
if [[ "$CMD" =~ (^|[-_])ar([.-]|$) ]] || [ "$1" = "ar" ]; then
  [ "$1" = "ar" ] && shift
  if [ -n "$ZIG_BIN" ]; then
    exec "$ZIG_BIN" ar "$@"
  elif [ -n "$AR" ]; then
    echo "NOTICE: zig not found; honoring AR=${AR}" >&2
    exec "$AR" "$@"
  elif command -v ar > /dev/null 2>&1; then
    exec ar "$@"
  else
    echo "ERROR: Neither zig nor ar found in PATH!" >&2
    exit 1
  fi
fi

if [[ "$CMD" =~ (^|[-_])ranlib([.-]|$) ]] || [ "$1" = "ranlib" ]; then
  [ "$1" = "ranlib" ] && shift
  if [ -n "$ZIG_BIN" ]; then
    exec "$ZIG_BIN" ranlib "$@"
  elif [ -n "$RANLIB" ]; then
    echo "NOTICE: zig not found; honoring RANLIB=${RANLIB}" >&2
    exec "$RANLIB" "$@"
  elif command -v ranlib > /dev/null 2>&1; then
    exec ranlib "$@"
  else
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
# 5. C++ / C Compiler Dispatch
# ------------------------------------------------------------------------------
if [[ "$CMD" =~ (^|[-_])(c\+\+|g\+\+|clang\+\+)([.-]|$) ]] || [ "$1" = "c++" ]; then
  [ "$1" = "c++" ] && shift
  SUB_CMD="c++"
  FALLBACK_CC="${CXX:-g++}"
else
  [ "$1" = "cc" ] && shift
  SUB_CMD="cc"
  FALLBACK_CC="${CC:-gcc}"
fi

# ------------------------------------------------------------------------------
# 6. C Compiler / Linker Dispatch with Target Triple Normalization
# ------------------------------------------------------------------------------
# Normalizes architecture and OS target (linux-musl or windows-gnu), avoiding
# redundant flags and dispatching to Zig or honoring $CC / $CXX fallback.
ARCH="${TARGET_ARCH:-$(uname -m)}"
TARGET_OS="linux-musl"
if [[ "$TARGET_TRIPLE" == *windows* ]] || [[ "$TARGET_TRIPLE" == *mingw* ]]; then
  TARGET_OS="windows-gnu"
fi

ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --target=* | -target=*)
      TARGET_VAL="${1#*=}"
      if [[ "$TARGET_VAL" == *windows* ]] || [[ "$TARGET_VAL" == *mingw* ]]; then
        DETECTED_ARCH="${TARGET_VAL%%-*}"
        [ -n "$DETECTED_ARCH" ] && ARCH="$DETECTED_ARCH"
        TARGET_OS="windows-gnu"
      elif [[ "$TARGET_VAL" == *musl* ]] || [[ "$TARGET_VAL" == *-unknown-* ]]; then
        DETECTED_ARCH="${TARGET_VAL%%-*}"
        [ -n "$DETECTED_ARCH" ] && ARCH="$DETECTED_ARCH"
        TARGET_OS="linux-musl"
      else
        ARGS+=("$1")
      fi
      shift
      ;;
    --target | -target)
      if [ -n "$2" ] && [[ "$2" == *windows* || "$2" == *mingw* ]]; then
        DETECTED_ARCH="${2%%-*}"
        [ -n "$DETECTED_ARCH" ] && ARCH="$DETECTED_ARCH"
        TARGET_OS="windows-gnu"
        shift 2
      elif [ -n "$2" ] && [[ "$2" == *musl* || "$2" == *-unknown-* ]]; then
        DETECTED_ARCH="${2%%-*}"
        [ -n "$DETECTED_ARCH" ] && ARCH="$DETECTED_ARCH"
        TARGET_OS="linux-musl"
        shift 2
      else
        ARGS+=("$1")
        shift
      fi
      ;;
    -Wl,--unresolved-symbols*)
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -n "$ZIG_BIN" ]; then
  exec "$ZIG_BIN" "${SUB_CMD}" -target "${ARCH}-${TARGET_OS}" "${ARGS[@]}"
elif [ -n "$CC" ] && [ "$SUB_CMD" = "cc" ]; then
  echo "NOTICE: zig not found; honoring CC=${CC}" >&2
  exec "$CC" "${ARGS[@]}"
elif [ -n "$CXX" ] && [ "$SUB_CMD" = "c++" ]; then
  echo "NOTICE: zig not found; honoring CXX=${CXX}" >&2
  exec "$CXX" "${ARGS[@]}"
elif command -v "$FALLBACK_CC" > /dev/null 2>&1; then
  echo "NOTICE: zig not found; falling back to system ${FALLBACK_CC}" >&2
  exec "$FALLBACK_CC" "${ARGS[@]}"
else
  echo "ERROR: zig compiler not found in PATH (/var/opt/zig, /u01/zig, /usr/local/bin, /opt/zig) and no CC fallback available!" >&2
  exit 1
fi
