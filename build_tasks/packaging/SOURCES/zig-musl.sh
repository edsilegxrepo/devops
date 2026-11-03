#!/bin/bash
# ==============================================================================
# Script:      /usr/src/redhat/SOURCES/zig-musl.sh
# Purpose:     Multi-call Zig wrapper providing static musl compilation,
#              Windows PE cross-compilation, linking, static archiving, cargo
#              environment configuration, and structural ELF/PE verification.
#              Honors $CC / $CXX / $AR fallback if Zig is unavailable.
#
# Synopsis:
#   1. Cargo Build Wrapper:
#        zig-musl.sh cargo <cargo_subcommand> [cargo_flags...]
#        -> Automatically detects target triple, sets CARGO_TARGET_<KEY>_RUSTFLAGS,
#           CC_<target>, CXX_<target>, and AR_<target>, then invokes cargo.
#           Seamlessly handles both Linux musl and Windows PE targets.
#
#   2. Linux Binary Structural Verification:
#        zig-musl.sh check <binary_path> [expected_version_string]
#        -> Asserts that <binary_path> is a 100% statically linked or static-pie
#           ELF executable, confirms the absence of PT_INTERP dynamic linker segment,
#           and optionally runs '<binary_path> --version' to verify execution.
#
#   3. Windows PE Executable Verification:
#        zig-musl.sh check-win <pe_binary_path>
#        -> Validates that <pe_binary_path> is a valid 64-bit Windows PE executable.
#
#   4. Multi-call Compiler / Linker / Archiver:
#        Invoked directly as a linker, compiler, or archiver (via symlink or argument):
#        - ar                  -> runs 'zig ar "$@"' (or $AR)
#        - c++ | *clang++*     -> runs 'zig c++ -target <arch>-<os> "$@"' (or $CXX)
#        - cc  | * (default)   -> runs 'zig cc  -target <arch>-<os> "$@"' (or $CC)
#
# Environment Variables:
#   TARGET_TRIPLE : Target Rust triple (e.g. x86_64-unknown-linux-musl, x86_64-pc-windows-gnu)
#   TARGET_ARCH   : Target architecture (e.g. x86_64, aarch64; defaults to uname -m)
#   CC / CXX / AR : Fallback toolchain commands honored if Zig is not found in PATH
# ==============================================================================
set -eo pipefail

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
    if command -v x86_64-w64-mingw32-gcc > /dev/null 2>&1; then
      export "CC_${TARGET_SNAKE}=x86_64-w64-mingw32-gcc"
      export "CXX_${TARGET_SNAKE}=x86_64-w64-mingw32-g++"
      export "AR_${TARGET_SNAKE}=x86_64-w64-mingw32-ar"
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
# 2. Linux Binary Inspection Subcommand
# ------------------------------------------------------------------------------
# Validates that a binary is 100% static musl ELF (standard or static-pie)
# with no PT_INTERP headers
if [ "$1" = "check" ]; then
  shift
  BIN="$1"
  EXP_VER="$2"
  if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
    echo "ERROR: Binary '$BIN' not found!" >&2
    exit 1
  fi
  echo "==> Verifying Linux binary structure ($BIN)..."
  file "$BIN" | grep -E -q "ELF (64|32)-bit.*static(ally|-pie)? linked" || {
    echo "ERROR: $BIN is not a statically linked ELF binary!" >&2
    file "$BIN" >&2
    exit 1
  }
  if readelf -l "$BIN" 2> /dev/null | grep -q "INTERP"; then
    echo "ERROR: $BIN contains a dynamic linker (PT_INTERP) segment!" >&2
    readelf -l "$BIN" | grep "INTERP" >&2
    exit 1
  fi
  if [ -n "$EXP_VER" ]; then
    echo "==> Verifying binary execution ($BIN --version)..."
    [[ "$("$BIN" --version 2>&1)" == *"$EXP_VER"* ]] || {
      echo "ERROR: $BIN version output does not contain expected version '$EXP_VER'!" >&2
      "$BIN" --version >&2
      exit 1
    }
  fi
  echo "==> Binary verification passed for $BIN"
  exit 0
fi

# ------------------------------------------------------------------------------
# 3. Windows PE Binary Inspection Subcommand
# ------------------------------------------------------------------------------
# Validates that a cross-compiled binary is a 64-bit Windows PE executable
if [ "$1" = "check-win" ]; then
  shift
  BIN="$1"
  if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
    echo "ERROR: Windows binary '$BIN' not found!" >&2
    exit 1
  fi
  echo "==> Verifying Windows binary structure ($BIN)..."
  file "$BIN" | grep -E -q "PE32\+ executable.*for MS Windows" || {
    echo "ERROR: $BIN is not a valid 64-bit Windows PE executable!" >&2
    file "$BIN" >&2
    exit 1
  }
  echo "==> Windows binary verification passed for $BIN"
  exit 0
fi

# ------------------------------------------------------------------------------
# 4. Archiver Dispatch
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
  echo "ERROR: zig compiler not found in PATH (/var/opt/zig, /u01/zig) and no CC fallback available!" >&2
  exit 1
fi
