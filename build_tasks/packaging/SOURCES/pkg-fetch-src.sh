#!/bin/bash
# ==============================================================================
# Script:      /usr/src/packages/TEMPLATE/SOURCES/pkg-fetch-src.sh
# Purpose:     Fetches upstream git snapshot archives into SOURCES/<name>-<ver>-<hash>-src.zip
#              and optionally downloads sqlite-amalgamation-<sqlitever>.zip.
#
# Objectives:
#   Standardize deterministic source archive acquisition with canonical `<name>-main/`
#   root directory layout and emit exact --git-hash / --src-root flags for pkg-make.sh.
#
# Core Components:
#   - Option parser & dependency validator (`git`, `zip`, optional `curl`).
#   - Remote ref resolver (`v<ver>`, `<ver>`, or `HEAD` fallback).
#   - Canonical `git archive` packager with safe mktemp cleanup trap.
#   - SQLite amalgamation downloader synced to `pkg-common.inc` version/year defaults.
#
# Functionality & Data Flows:
#   1. Parses CLI flags -> resolves git tag/ref via `git ls-remote`.
#   2. Shallow-clones repository into mktemp workdir -> reads 7-char short SHA ->
#      writes `<topdir>/SOURCES/<name>-<ver>-<hash>-src.zip` prefixed `<name>-main/`.
#   3. If `--sqlite` is passed, reads `sqlitever`/`sqliteyear` from `pkg-common.inc`
#      and fetches `sqlite-amalgamation-<sqlitever>.zip` into `SOURCES/`.
#
# Synopsis:
#   pkg-fetch-src.sh --repo-url <url> --name <pkg> --version <ver> [options]
# ==============================================================================
set -eo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults & CLI Option Parsing
# ------------------------------------------------------------------------------
TOPDIR="${RPM_TOPDIR:-/usr/src/redhat}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_URL=""
NAME=""
VERSION=""
REF=""
SQLITE_YEAR=""
FETCH_SQLITE=0
FORCE=0

# Display CLI usage help and exit cleanly
usage() {
  cat << EOF
Usage: $(basename "$0") --repo-url <url> --name <pkg> --version <ver> [options]

Required Options:
  --repo-url <url>      Upstream git repository URL (e.g. https://github.com/owner/repo)
  --name <pkg>          Package name (used for archive naming)
  --version <ver>       Upstream semantic version (e.g. 3.3.3)

Optional Flags:
  --ref <branch|tag|sha>  Git ref to snapshot (defaults to v<version>, <version>, or HEAD)
  --topdir <path>         RPM topdir containing SOURCES/ (default: /usr/src/redhat)
  --sqlite                Also download sqlite-amalgamation-<sqlitever>.zip if missing
  --sqlite-year <YYYY>    Override SQLite release download year (defaults to sqliteyear in pkg-common.inc)
  --force                 Overwrite existing archives in SOURCES/
  -h, --help              Show this help message
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-url) REPO_URL="${2%/}"; REPO_URL="${REPO_URL%.git}"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --topdir) TOPDIR="$2"; shift 2 ;;
    --sqlite) FETCH_SQLITE=1; shift ;;
    --sqlite-year) SQLITE_YEAR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage ;;
    *)
      echo "ERROR: Unknown option '$1'" >&2
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 2. Input Validation & Temporary Workspace Setup
# ------------------------------------------------------------------------------
if [ -z "$REPO_URL" ] || [ -z "$NAME" ] || [ -z "$VERSION" ]; then
  echo "ERROR: --repo-url, --name, and --version are required." >&2
  exit 1
fi

for cmd in git zip; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Required tool '$cmd' not found in PATH." >&2
    exit 1
  }
done

SOURCES_DIR="${TOPDIR}/SOURCES"
mkdir -p "$SOURCES_DIR"

TMP_WORK="$(mktemp -d)"
# Safely remove the temporary clone directory on script exit
cleanup_tmp_work() {
  if [ -n "${TMP_WORK:-}" ] && [ "${TMP_WORK}" != "/" ] && [ -d "${TMP_WORK}" ]; then
    rm -rf -- "$TMP_WORK"
  fi
}
trap cleanup_tmp_work EXIT

# ------------------------------------------------------------------------------
# 3. Git Ref Resolution & Canonical Source Archiving
# ------------------------------------------------------------------------------
if [ -z "$REF" ]; then
  if git ls-remote --exit-code --tags "${REPO_URL}.git" "refs/tags/v${VERSION}" >/dev/null 2>&1; then
    REF="v${VERSION}"
  elif git ls-remote --exit-code --tags "${REPO_URL}.git" "refs/tags/${VERSION}" >/dev/null 2>&1; then
    REF="${VERSION}"
  else
    REF="HEAD"
  fi
fi

echo "==> Cloning ${REPO_URL} (ref: ${REF})..."
if [ "$REF" = "HEAD" ]; then
  git clone --depth 1 "${REPO_URL}.git" "${TMP_WORK}/repo"
else
  # Attempt shallow tag/branch clone first; fall back to full clone when --ref is a commit SHA
  git clone --depth 1 --branch "$REF" "${REPO_URL}.git" "${TMP_WORK}/repo" 2>/dev/null \
    || { git clone "${REPO_URL}.git" "${TMP_WORK}/repo" && git -C "${TMP_WORK}/repo" checkout -q "$REF"; }
fi

GIT_HASH="$(git -C "${TMP_WORK}/repo" rev-parse --short=7 HEAD)"
SRC_ROOT="${NAME}-main"
OUT_ZIP="${SOURCES_DIR}/${NAME}-${VERSION}-${GIT_HASH}-src.zip"

if [ -f "$OUT_ZIP" ] && [ "$FORCE" -ne 1 ]; then
  echo "NOTICE: Archive already exists: $OUT_ZIP (use --force to overwrite)"
else
  echo "==> Creating clean source snapshot ${OUT_ZIP} (prefix: ${SRC_ROOT}/)..."
  git -C "${TMP_WORK}/repo" archive --format=zip --prefix="${SRC_ROOT}/" -o "$OUT_ZIP" HEAD
fi

# ------------------------------------------------------------------------------
# 4. Optional SQLite Amalgamation Acquisition
# ------------------------------------------------------------------------------
if [ "$FETCH_SQLITE" -eq 1 ]; then
  SQLITE_VER="3540100"
  DEF_YEAR="2026"
  # Read sqlitever and sqliteyear from pkg-common.inc so downloaded archives match spec macros
  COMMON_INC="${SOURCES_DIR}/pkg-common.inc"
  [ -f "$COMMON_INC" ] || COMMON_INC="${SCRIPT_DIR}/pkg-common.inc"
  if [ -f "$COMMON_INC" ]; then
    PARSED_VER="$(awk '/sqlitever/{gsub(/[^0-9]/,"",$NF); print $NF; exit}' "$COMMON_INC")"
    [ -n "$PARSED_VER" ] && SQLITE_VER="$PARSED_VER"
    PARSED_YEAR="$(awk '/sqliteyear/{gsub(/[^0-9]/,"",$NF); print $NF; exit}' "$COMMON_INC")"
    [ -n "$PARSED_YEAR" ] && DEF_YEAR="$PARSED_YEAR"
  fi
  YEAR="${SQLITE_YEAR:-$DEF_YEAR}"
  SQLITE_ZIP="${SOURCES_DIR}/sqlite-amalgamation-${SQLITE_VER}.zip"
  if [ -f "$SQLITE_ZIP" ] && [ "$FORCE" -ne 1 ]; then
    echo "NOTICE: SQLite amalgamation already exists: $SQLITE_ZIP"
  else
    command -v curl >/dev/null 2>&1 || {
      echo "ERROR: 'curl' is required to download SQLite amalgamation." >&2
      exit 1
    }
    SQLITE_URL="https://www.sqlite.org/${YEAR}/sqlite-amalgamation-${SQLITE_VER}.zip"
    echo "==> Downloading ${SQLITE_URL}..."
    curl -fsSL "$SQLITE_URL" -o "$SQLITE_ZIP"
  fi
fi

# ------------------------------------------------------------------------------
# 5. Summary & pkg-make.sh Handoff Output
# ------------------------------------------------------------------------------
echo ""
echo "================================================================================"
echo "Source snapshot ready!"
echo "  Archive:    ${OUT_ZIP}"
echo "  --git-hash: ${GIT_HASH}"
echo "  --src-root: ${SRC_ROOT}"
echo ""
echo "Next step:"
echo "  pkg-make.sh --name ${NAME} --version ${VERSION} --repo-url ${REPO_URL} --git-hash ${GIT_HASH} --src-root ${SRC_ROOT} ..."
echo "================================================================================"

