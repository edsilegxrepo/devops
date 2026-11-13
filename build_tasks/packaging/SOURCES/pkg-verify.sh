#!/bin/bash
# ==============================================================================
# Script:      /usr/src/packages/TEMPLATE/SOURCES/pkg-verify.sh
# Purpose:     Toolchain-agnostic binary and package wellness verifier for static
#              Linux ELF, Windows PE32+, and Debian (.deb) artifacts (no Zig needed).
#
# Objectives:
#   Provide deterministic post-build verification during RPM %check (and standalone
#   CI runs) ensuring Linux executables are genuinely static without PT_INTERP,
#   Windows binaries are valid PE32+ executables, and .deb packages satisfy lintian.
#
# Core Components:
#   - usage()    : Prints subcommand synopsis and exits non-zero.
#   - check      : ELF static/static-pie verification + PT_INTERP check + runtime probe.
#   - check-win  : 64-bit Windows PE32+ signature check via `file`.
#   - check-deb  : `dpkg-deb -I` validation + lintian execution (advisory or strict).
#
# Functionality & Data Flows:
#   1. Dispatches on subcommand ($1): check | check-win | check-deb.
#   2. Validates artifact file existence, inspects binary headers (`file`/`readelf`)
#      or Debian metadata (`dpkg-deb`/`lintian`), and fails fast (exit 1) on violations.
#
# Synopsis:
#   1. Linux Binary Structural Verification:
#        pkg-verify.sh check <binary_path> [expected_version_string] [version_flag]
#        -> Asserts that <binary_path> is a statically linked or static-pie ELF
#           executable, confirms absence of PT_INTERP dynamic linker segment,
#           and optionally runs '<binary_path> <version_flag>' (default: --version)
#           to confirm execution and version output.
#
#   2. Windows PE Executable Verification:
#        pkg-verify.sh check-win <pe_binary_path>
#        -> Validates that <pe_binary_path> is a valid 64-bit Windows PE executable.
#
#   3. Debian (.deb) Package Verification:
#        pkg-verify.sh check-deb <deb_path> [strict] [suppress_tags]
#        -> Verifies archive readability via dpkg-deb -I and runs lintian when
#           installed (strict=1 fails on policy tags or missing lintian).
# ==============================================================================
set -eo pipefail

# Print brief usage synopsis and exit with error status
usage() {
  echo "Usage: $(basename "$0") <check|check-win|check-deb> <artifact_path> [args...]" >&2
  exit 1
}

[ $# -lt 2 ] && usage

SUBCMD="$1"
shift

# ------------------------------------------------------------------------------
# 1. Subcommand Dispatch (check | check-win | check-deb)
# ------------------------------------------------------------------------------
case "$SUBCMD" in
  # Verify Linux ELF static/static-pie linkage, absent PT_INTERP, and version probe
  check)
    BIN="$1"
    EXP_VER="${2:-}"
    VER_FLAG="${3:---version}"

    if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
      echo "ERROR: Binary '$BIN' not found!" >&2
      exit 1
    fi

    echo "==> Verifying Linux binary structure ($BIN)..."
    # Match both pure static ("statically linked") and Zig static-pie ("static-pie linked")
    FILE_OUT="$(file "$BIN")"
    grep -E -q "ELF (64|32)-bit.*static(ally|-pie)? linked" <<< "$FILE_OUT" || {
      echo "ERROR: $BIN is not a statically linked ELF binary!" >&2
      echo "$FILE_OUT" >&2
      exit 1
    }

    # Reject any binary requesting a dynamic ELF interpreter (e.g., glibc/musl ld.so)
    INTERP_OUT="$(readelf -l "$BIN" 2> /dev/null || true)"
    if grep -q "INTERP" <<< "$INTERP_OUT"; then
      echo "ERROR: $BIN contains a dynamic linker (PT_INTERP) segment!" >&2
      grep "INTERP" <<< "$INTERP_OUT" >&2
      exit 1
    fi

    # Execute runtime version check when expected substring is given (skip if VER_FLAG=none)
    if [ -n "$EXP_VER" ] && [ "$VER_FLAG" != "none" ]; then
      echo "==> Verifying binary execution ($BIN $VER_FLAG)..."
      read -r -a FLAG_ARGS <<< "$VER_FLAG"
      OUT="$("$BIN" "${FLAG_ARGS[@]}" 2>&1 || true)"
      if [[ "$OUT" != *"$EXP_VER"* ]]; then
        echo "ERROR: $BIN $VER_FLAG output does not contain expected version '$EXP_VER'!" >&2
        echo "$OUT" >&2
        exit 1
      fi
    fi

    echo "==> Binary verification passed for $BIN"
    ;;

  # Verify 64-bit Windows PE32+ executable format
  check-win)
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
    ;;

  # Verify .deb readability via dpkg-deb and run lintian (strict=1 fails on findings)
  check-deb)
    DEB="$1"
    STRICT="${2:-0}"
    SUPPRESS="${3:-}"
    if [ -z "$DEB" ] || [ ! -f "$DEB" ]; then
      echo "ERROR: Debian package '$DEB' not found!" >&2
      exit 1
    fi

    echo "==> Verifying Debian package structure ($DEB)..."
    dpkg-deb -I "$DEB" >/dev/null

    if command -v lintian >/dev/null 2>&1; then
      echo "==> Running lintian ($DEB)..."
      LINTIAN_ARGS=(--tag-display-limit 0)
      if [ -n "$SUPPRESS" ]; then
        LINTIAN_ARGS+=(--suppress-tags "$SUPPRESS")
      fi
      # Capture lintian exit status (0=clean, 2=policy tags reported, other=runtime failure)
      set +e
      LINTIAN_OUT="$(lintian "${LINTIAN_ARGS[@]}" "$DEB" 2>&1)"
      LINTIAN_RC=$?
      set -e
      [ -n "$LINTIAN_OUT" ] && printf '%s\n' "$LINTIAN_OUT"
      if [ "$LINTIAN_RC" -eq 2 ]; then
        if [ "$STRICT" = "1" ]; then
          echo "ERROR: lintian reported policy violations on $DEB (exit 2)" >&2
          exit 1
        fi
        echo "WARNING: lintian reported policy findings on $DEB (non-fatal; strict=0)" >&2
      elif [ "$LINTIAN_RC" -ne 0 ]; then
        echo "ERROR: lintian failed with exit status $LINTIAN_RC on $DEB" >&2
        exit 1
      else
        echo "==> lintian verification passed cleanly for $DEB"
      fi
    elif [ "$STRICT" = "1" ]; then
      echo "ERROR: lintian not found in PATH (required when strict=1)!" >&2
      exit 1
    else
      echo "    (lintian not installed; skipping Debian Policy checks)"
    fi
    ;;

  *)
    echo "ERROR: Unknown subcommand '$SUBCMD'" >&2
    usage
    ;;
esac

