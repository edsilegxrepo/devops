#!/bin/bash
# ==============================================================================
# Script:      /usr/src/packages/TEMPLATE/SOURCES/pkg-make.sh
# Purpose:     Universal package scaffold generator for Rust and Go specfiles.
# Applicability: Automates creation of 100% static musl RPM & Debian packages.
#
# Objectives:
#   Generate ready-to-build <topdir>/SPECS/<name>-xg.spec files, canonical
#   -src.zip source archives, synced toolchain helpers, and systemd daemon files
#   from master TEMPLATE/ templates with zero manual boilerplate.
#
# Core Components:
#   - Section 1 (CLI Parser)         : Collects platform, metadata, CGO/SQLite, exclusion & daemon options.
#   - Section 2 (Validation)         : Normalizes platform, --exclude targets, goipath, git hash & Debian deps.
#   - Section 3 (Source Repackaging) : Repackages arbitrary source tarballs/zips into canonical `<name>-main/` zips.
#   - Section 4 (Helper Sync)        : Copies required *.inc/*.sh helpers into TOPDIR/SOURCES/ via sync_helper().
#   - Section 5 (Python Renderer)    : Substitutes template placeholders, renders daemon configs & target gates.
#   - Section 6 (rpmlint & Summary)  : Runs initial rpmlint validation and prints build instructions.
#
# Functionality & Data Flows:
#   1. Parses CLI flags -> validates required args and normalizes derived metadata.
#   2. Optionally converts `--source-arch` to `<topdir>/SOURCES/<name>-<ver>-<hash>-src.zip`.
#   3. Syncs shared helpers -> exports normalized PKG_* env vars -> inline Python renders
#      TEMPLATE/SPECS/pkg-<platform>-template-xg.spec and template.{service,sysusers.conf,tmpfiles.conf,env}.
#   4. Validates generated spec with `rpmlint` and outputs ready-to-run `rpmbuild` commands.
#
# Synopsis:
#   pkg-make.sh --platform <rust|go> --name <pkg> --version <ver> [options]
#
# Required Options:
#   --platform <rust|go>        : Target language compilation ecosystem
#   --name <package>            : Package name (lowercase alphanumeric + hyphens)
#   --version <version>         : Upstream semantic version (e.g. 1.4.0)
#
# Source Options (at least one recommended):
#   --repo-url <url>            : Upstream repository URL (e.g. https://github.com/owner/repo)
#   --source-arch <path>        : Path to source archive (.zip, .tar.gz, .tar.xz)
#   --git-hash <hash>           : Short commit hash (auto-detected if omitted)
#
# Package Metadata Options:
#   --release <number>          : Package release revision number (default: 1)
#   --summary <summary>         : Short single-line summary
#   --description <desc>        : Detailed description (or @path/to/desc.txt)
#   --license <spdx>            : SPDX license identifier (default: Apache-2.0)
#   --group <group>             : RPM package group (default: Applications/System)
#   --buildrequires <pkg...>    : Additional BuildRequires packages (space/multi-flag)
#   --requires <pkg...>         : Additional runtime Requires packages (space/multi-flag)
#   --deb-depends <pkg...>      : Additional Debian runtime dependencies (e.g. "systemd (>= 239)")
#   --exclude <targets...>      : Exclude packaging targets (windows, deb, rpm, archive)
#
# Daemon & Service Scaffolding:
#   --daemon                    : Scaffolds .service, .sysusers.conf, .tmpfiles.conf, .env
#                                 and activates systemd integration in the specfile
#
# Database & Native Library Options:
#   --sqlite                    : Enables embedded SQLite amalgamation (use_sqlite 1)
#
# Go Specific Options:
#   --cgo                       : Enables CGO static musl compilation (use_cgo 1)
#   --bundled-c-lib             : Enables bundled static C library (e.g. libxcrypt)
#   --goipath <path>            : Go import path (defaults to repo-url without https://)
#   --cmd-path <path>           : Relative package path to main package (default: .)
#   --tags <tags>               : Go build tags (e.g. "libsqlite3")
#
# Rust Specific Options:
#   --features <features>       : Cargo feature flags (e.g. "clipboard,pcre2")
# ==============================================================================
set -eo pipefail

TOPDIR="${RPM_TOPDIR:-/usr/src/redhat}"
SPECS_DIR="${TOPDIR}/SPECS"
SOURCES_DIR="${TOPDIR}/SOURCES"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEMPLATE_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
TEMPLATE_SPECS_DIR="${TEMPLATE_ROOT}/SPECS"
TEMPLATE_SOURCES_DIR="${TEMPLATE_ROOT}/SOURCES"

PLATFORM=""
NAME=""
VERSION=""
RELEASE="1"
REPO_URL=""
SOURCE_ARCH=""
SUMMARY=""
DESC=""
LICENSE="Apache-2.0"
GROUP="Applications/System"
GIT_HASH=""
SRC_ROOT=""
BIN_NAME=""
LICENSE_FILE=""
COMPLETION_CMD=""
VERSION_FLAG="--version"
VERSION_LDFLAGS=""
DOCLIST=""
BUILD_REQUIRES=()
REQUIRES=()
DEB_DEPENDS=""
DEB_SECTION=""
CHECK_VERSION=""
EXCLUDES=()
IS_DAEMON=0

# Go specific flags
USE_CGO=0
USE_SQLITE=0
USE_BUNDLED_C_LIB=0
GOIPATH=""
CMD_PATH="."
BUILD_TAGS=""

# Rust specific flags
CARGO_FEATURES=""

# Show detailed CLI help message and exit non-zero
usage() {
  cat << EOF
Usage: $(basename "$0") --platform <rust|go> --name <package> --version <version> [options]

Required Options:
  --platform <rust|go>        Target language platform
  --name <package>            Package name (lowercase alphanumeric + hyphens)
  --version <version>         Upstream semantic version (e.g. 1.4.0)

Source Options:
  --repo-url <url>            Upstream repository URL (e.g. https://github.com/owner/repo)
  --source-arch <path>        Path to source archive (.zip, .tar.gz, .tar.xz)
  --git-hash <hash>           Short commit hash (auto-detected if omitted)

Package Metadata:
  --release <number>          Internal package release number (default: 1)
  --summary <summary>         Short single-line description
  --description <desc>        Detailed description (or @path/to/file.txt)
  --license <spdx>            SPDX license identifier (default: Apache-2.0)
  --group <group>             RPM package group (default: Applications/System)
  --buildrequires <pkg...>    Additional BuildRequires package (repeatable or space-separated)
  --requires <pkg...>         Additional Requires package (repeatable or space-separated)
  --deb-depends <deps>        Explicit Debian runtime dependencies (e.g. "systemd (>= 239)")
  --deb-section <section>     Debian package section (default: utils, e.g. net, httpd)
  --exclude <targets...>      Exclude packaging targets (comma-separated: windows, deb, rpm, archive)

Daemon & Service Scaffolding:
  --daemon                    Automatically scaffold systemd service, sysusers, tmpfiles,
                              and environment file from templates and enable in spec

Database & Native Library Options:
  --sqlite                    Enable embedded SQLite amalgamation via Zig (use_sqlite 1)

Go Specific Options:
  --cgo                       Enable CGO static compilation via Zig musl (use_cgo 1)
  --bundled-c-lib             Enable bundled static C library (e.g. libxcrypt)
  --goipath <path>            Go import path (defaults to repo-url without https://)
  --cmd-path <path>           Relative package path to main (default: .)
  --tags <tags>               Go build tags (e.g. "libsqlite3")

Rust Specific Options:
  --features <features>       Cargo feature flags (e.g. "clipboard,pcre2")

  --version-flag <flag>       Version flag for %check (default: --version, or 'none')
  --check-version <ver>       Expected version substring in %check (default: %{version})
  --version-ldflags <flags>   Extra Go -ldflags version injection (e.g. "-X 'main.version=%{pkgver}'")
  --src-root <dir>            Top-level folder name inside source archive (default: <name>-main)
  --bin-name <name>           Compiled executable basename if different from <name>
  --license-file <file>       License filename inside source tree (default: LICENSE)
  --completion-cmd <cmd>      CLI subcommand emitting completions (e.g. "completion" -> stages bash/zsh/fish)
  --doclist <files>           Space-separated doc files for %doc (default: README.md)

Help:
  -h, --help                  Show this help message
EOF
  exit 1
}

# ------------------------------------------------------------------------------
# 1. Argument Parsing
# ------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      PLATFORM="$2"
      shift 2
      ;;
    --name)
      NAME="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --release)
      RELEASE="$2"
      shift 2
      ;;
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --source-arch)
      SOURCE_ARCH="$2"
      shift 2
      ;;
    --git-hash)
      GIT_HASH="$2"
      shift 2
      ;;
    --summary)
      SUMMARY="$2"
      shift 2
      ;;
    --description)
      DESC="$2"
      shift 2
      ;;
    --license)
      LICENSE="$2"
      shift 2
      ;;
    --group)
      GROUP="$2"
      shift 2
      ;;
    --deb-depends)
      DEB_DEPENDS="$2"
      shift 2
      ;;
    --deb-section)
      DEB_SECTION="$2"
      shift 2
      ;;
    --check-version)
      CHECK_VERSION="$2"
      shift 2
      ;;
    --exclude)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        IFS=',' read -ra ADDR <<< "$1"
        for item in "${ADDR[@]}"; do
          item="$(echo "$item" | tr '[:upper:]' '[:lower:]' | xargs)"
          [ -n "$item" ] && EXCLUDES+=("$item")
        done
        shift
      done
      ;;
    --daemon)
      IS_DAEMON=1
      shift
      ;;
    --cgo)
      USE_CGO=1
      shift
      ;;
    --sqlite)
      USE_SQLITE=1
      USE_CGO=1
      shift
      ;;
    --bundled-c-lib)
      USE_BUNDLED_C_LIB=1
      USE_CGO=1
      shift
      ;;
    --goipath)
      GOIPATH="$2"
      shift 2
      ;;
    --cmd-path)
      CMD_PATH="$2"
      shift 2
      ;;
    --tags)
      BUILD_TAGS="$2"
      shift 2
      ;;
    --features)
      CARGO_FEATURES="$2"
      shift 2
      ;;
    --version-flag)
      VERSION_FLAG="$2"
      shift 2
      ;;
    --version-ldflags)
      VERSION_LDFLAGS="$2"
      shift 2
      ;;
    --src-root)
      SRC_ROOT="$2"
      shift 2
      ;;
    --bin-name)
      BIN_NAME="$2"
      shift 2
      ;;
    --license-file)
      LICENSE_FILE="$2"
      shift 2
      ;;
    --completion-cmd)
      COMPLETION_CMD="$2"
      shift 2
      ;;
    --doclist)
      DOCLIST="$2"
      shift 2
      ;;
    --buildrequires)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do BUILD_REQUIRES+=("$item"); done
        shift
      done
      ;;
    --requires)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do REQUIRES+=("$item"); done
        shift
      done
      ;;
    -h | --help) usage ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 2. Validation & Normalization
# ------------------------------------------------------------------------------
if [ -z "$PLATFORM" ] || [ -z "$NAME" ] || [ -z "$VERSION" ]; then
  echo "ERROR: --platform, --name, and --version are required." >&2
  usage
fi

PLATFORM="$(echo "$PLATFORM" | tr '[:upper:]' '[:lower:]')"
if [ "$PLATFORM" != "rust" ] && [ "$PLATFORM" != "go" ]; then
  echo "ERROR: --platform must be either 'rust' or 'go'." >&2
  exit 1
fi

for item in "${EXCLUDES[@]}"; do
  case "$item" in
    windows | win | deb | debian | rpm | archive | tarball | tar) ;;
    *)
      echo "ERROR: Unknown target in --exclude: '$item'." >&2
      echo "       Supported targets: windows, deb, rpm, archive" >&2
      exit 1
      ;;
  esac
done

[ -z "$SUMMARY" ] && SUMMARY="Static ${PLATFORM^} service and utility"
if [ -z "$DESC" ]; then
  DESC="${NAME} - packaged via Antigravity static packaging framework."
elif [[ "$DESC" == @* ]]; then
  file_path="${DESC#@}"
  if [ -f "$file_path" ]; then
    DESC="$(cat "$file_path")"
  else
    echo "WARNING: Description file '$file_path' not found. Using literal text." >&2
  fi
fi

if [ -z "$REPO_URL" ] && [ -n "$SOURCE_ARCH" ]; then
  REPO_URL="https://github.com/local/${NAME}"
elif [ -z "$REPO_URL" ]; then
  REPO_URL="https://github.com/example/${NAME}"
fi

# Auto-derive Go import path if not specified
if [ "$PLATFORM" = "go" ] && [ -z "$GOIPATH" ]; then
  GOIPATH="$(echo "$REPO_URL" | sed -e 's|https://||' -e 's|http://||' -e 's|\.git$||')"
fi

# Auto-detect or generate git commit hash (strip package name/version prefix first)
if [ -z "$GIT_HASH" ]; then
  if [ -n "$SOURCE_ARCH" ]; then
    base_arch="$(basename "$SOURCE_ARCH")"
    stripped="${base_arch#"${NAME}"-}"
    stripped="${stripped#"${VERSION}"-}"
    detected="$(echo "$stripped" | grep -o -E '[0-9a-f]{7,8}' | tail -n 1 || true)"
    if [ -n "$detected" ]; then
      GIT_HASH="$detected"
    else
      GIT_HASH="src"
    fi
  else
    GIT_HASH="main"
  fi
fi

[ -z "$SRC_ROOT" ] && SRC_ROOT="${NAME}-main"

# Default Debian dependencies if not explicitly specified
if [ -z "$DEB_DEPENDS" ] && [ "$IS_DAEMON" -eq 1 ]; then
  DEB_DEPENDS="systemd (>= 239)"
fi

TARGET_SPEC="${SPECS_DIR}/${NAME}-xg.spec"
TARGET_SOURCE="${SOURCES_DIR}/${NAME}-${VERSION}-${GIT_HASH}-src.zip"

echo "==> Scaffolding ${PLATFORM^^} package: ${NAME} (${VERSION}-${RELEASE})"

# ------------------------------------------------------------------------------
# 3. Source Archive Handling
# ------------------------------------------------------------------------------
# Safely remove temporary source repackaging workspace if defined
cleanup_tmp_src() {
  if [ -n "${TMP_SRC_DIR:-}" ] && [ "${TMP_SRC_DIR}" != "/" ] && [ -d "${TMP_SRC_DIR}" ]; then
    rm -rf -- "${TMP_SRC_DIR}"
  fi
}

if [ -n "$SOURCE_ARCH" ] && [ -f "$SOURCE_ARCH" ]; then
  echo "==> Preparing canonical source zip with ${NAME}-main root..."
  TMP_SRC_DIR="$(mktemp -d -t "src_convert_XXXXXX")"
  trap cleanup_tmp_src EXIT
  if [[ "$SOURCE_ARCH" == *.zip ]]; then
    unzip -q "$SOURCE_ARCH" -d "$TMP_SRC_DIR"
  else
    tar -xf "$SOURCE_ARCH" -C "$TMP_SRC_DIR"
  fi
  entries=("$TMP_SRC_DIR"/*)
  if [ ${#entries[@]} -eq 1 ] && [ -d "${entries[0]}" ]; then
    if [ "$(basename "${entries[0]}")" != "${NAME}-main" ]; then
      mv "${entries[0]}" "$TMP_SRC_DIR/${NAME}-main"
    fi
  elif [ ${#entries[@]} -gt 1 ]; then
    mkdir -p "$TMP_SRC_DIR/${NAME}-main"
    for e in "${entries[@]}"; do
      [ "$e" != "$TMP_SRC_DIR/${NAME}-main" ] && mv "$e" "$TMP_SRC_DIR/${NAME}-main/"
    done
  fi
  (cd "$TMP_SRC_DIR" && zip -9qr "$TARGET_SOURCE" .)
  cleanup_tmp_src
  trap - EXIT
  echo "==> Created canonical source zip: $TARGET_SOURCE"
else
  if [ ! -f "$TARGET_SOURCE" ]; then
    echo "NOTICE: Source archive not yet present at: $TARGET_SOURCE"
    echo "        Place source files in $TARGET_SOURCE before running rpmbuild."
  fi
fi

# ------------------------------------------------------------------------------
# 4. Sync Shared Helpers & Optional Daemon Scaffolding Setup
# ------------------------------------------------------------------------------
mkdir -p "${SPECS_DIR}" "${SOURCES_DIR}"

# Copy a shared helper from TEMPLATE/SOURCES into TOPDIR/SOURCES if distinct
sync_helper() {
  local fname="$1"
  local src_file=""
  if [ -f "${TEMPLATE_SOURCES_DIR}/${fname}" ]; then
    src_file="${TEMPLATE_SOURCES_DIR}/${fname}"
  fi
  if [ -n "$src_file" ] && [ "$src_file" != "${SOURCES_DIR}/${fname}" ]; then
    cp -af "$src_file" "${SOURCES_DIR}/${fname}"
  fi
}

sync_helper "pkg-common.inc"
sync_helper "pkg-verify.sh"
if [ "$PLATFORM" = "rust" ]; then
  sync_helper "rust-toolchain.inc"
  sync_helper "zig-musl.sh"
else
  sync_helper "go-toolchain.inc"
  [ "$USE_CGO" -eq 1 ] && sync_helper "zig-musl.sh"
fi
if [[ ! " ${EXCLUDES[*]} " =~ " deb " ]] && [[ ! " ${EXCLUDES[*]} " =~ " debian " ]]; then
  sync_helper "pkg-deb.sh"
fi

if [ "$IS_DAEMON" -eq 1 ]; then
  SVC_OUT="${SOURCES_DIR}/${NAME}.service"
  SYS_OUT="${SOURCES_DIR}/${NAME}.sysusers.conf"
  TMP_OUT="${SOURCES_DIR}/${NAME}.tmpfiles.conf"
  ENV_OUT="${SOURCES_DIR}/${NAME}.env"
fi

# ------------------------------------------------------------------------------
# 5. Spec & Service Generation from Templates via Python Engine
# ------------------------------------------------------------------------------
if [ "$PLATFORM" = "rust" ]; then
  TEMPLATE_BASENAME="pkg-rust-template-xg.spec"
else
  TEMPLATE_BASENAME="pkg-go-template-xg.spec"
fi

if [ -f "${TEMPLATE_SPECS_DIR}/${TEMPLATE_BASENAME}" ]; then
  TEMPLATE_FILE="${TEMPLATE_SPECS_DIR}/${TEMPLATE_BASENAME}"
elif [ -f "${SPECS_DIR}/${TEMPLATE_BASENAME}" ]; then
  TEMPLATE_FILE="${SPECS_DIR}/${TEMPLATE_BASENAME}"
else
  echo "ERROR: Template '${TEMPLATE_BASENAME}' not found in ${TEMPLATE_SPECS_DIR} or ${SPECS_DIR}" >&2
  exit 1
fi

export PKG_SOURCES_DIR="${SOURCES_DIR}"
export PKG_TEMPLATE_SOURCES_DIR="${TEMPLATE_SOURCES_DIR}"
export PKG_TEMPLATE_FILE="${TEMPLATE_FILE}"
export PKG_TARGET_SPEC="${TARGET_SPEC}"
export PKG_PLATFORM="${PLATFORM}"
export PKG_NAME="${NAME}"
export PKG_VERSION="${VERSION}"
export PKG_RELEASE="${RELEASE}"
export PKG_SUMMARY="${SUMMARY}"
export PKG_DESC="${DESC}"
export PKG_LICENSE="${LICENSE}"
export PKG_REPO_URL="${REPO_URL}"
export PKG_GIT_HASH="${GIT_HASH}"
export PKG_SRC_ROOT="${SRC_ROOT}"
export PKG_BIN_NAME="${BIN_NAME}"
export PKG_LICENSE_FILE="${LICENSE_FILE}"
export PKG_COMPLETION_CMD="${COMPLETION_CMD}"
export PKG_VERSION_FLAG="${VERSION_FLAG}"
export PKG_CHECK_VERSION="${CHECK_VERSION}"
export PKG_VERSION_LDFLAGS="${VERSION_LDFLAGS}"
export PKG_DOCLIST="${DOCLIST}"
export PKG_DEB_SECTION="${DEB_SECTION}"
PKG_CHANGELOG_DATE="$(LC_ALL=C date '+%a %b %d %Y')"
export PKG_CHANGELOG_DATE
export PKG_GROUP="${GROUP}"
export PKG_CARGO_FEATURES="${CARGO_FEATURES}"
export PKG_GOIPATH="${GOIPATH}"
export PKG_CMD_PATH="${CMD_PATH}"
export PKG_BUILD_TAGS="${BUILD_TAGS}"
export PKG_USE_CGO="${USE_CGO}"
export PKG_USE_SQLITE="${USE_SQLITE}"
export PKG_USE_BUNDLED_C_LIB="${USE_BUNDLED_C_LIB}"
export PKG_IS_DAEMON="${IS_DAEMON}"
export PKG_EXTRA_BUILD_REQUIRES="${BUILD_REQUIRES[*]}"
export PKG_EXTRA_REQUIRES="${REQUIRES[*]}"
export PKG_DEB_DEPENDS="${DEB_DEPENDS}"
export PKG_EXCLUDES="${EXCLUDES[*]}"

python3 << 'PYEOF'
import os, re, sys

template_file = os.environ["PKG_TEMPLATE_FILE"]
target_spec   = os.environ["PKG_TARGET_SPEC"]
platform      = os.environ["PKG_PLATFORM"]
name          = os.environ["PKG_NAME"]
version       = os.environ["PKG_VERSION"]
release       = os.environ["PKG_RELEASE"]
summary       = os.environ["PKG_SUMMARY"]
desc          = os.environ["PKG_DESC"]
license_str   = os.environ["PKG_LICENSE"]
repo_url      = os.environ["PKG_REPO_URL"]
git_hash      = os.environ["PKG_GIT_HASH"]
src_root      = os.environ["PKG_SRC_ROOT"]
bin_name      = os.environ.get("PKG_BIN_NAME", "").strip()
license_file  = os.environ.get("PKG_LICENSE_FILE", "").strip()
completion_cmd = os.environ.get("PKG_COMPLETION_CMD", "").strip()
version_flag  = os.environ["PKG_VERSION_FLAG"]
check_version = os.environ["PKG_CHECK_VERSION"]
ver_ldflags   = os.environ["PKG_VERSION_LDFLAGS"]
doclist       = os.environ["PKG_DOCLIST"]
deb_section   = os.environ["PKG_DEB_SECTION"]
chg_date      = os.environ["PKG_CHANGELOG_DATE"]
group         = os.environ["PKG_GROUP"]
cargo_feat    = os.environ["PKG_CARGO_FEATURES"]
goipath       = os.environ["PKG_GOIPATH"]
cmd_path      = os.environ["PKG_CMD_PATH"]
build_tags    = os.environ["PKG_BUILD_TAGS"]
use_cgo       = os.environ["PKG_USE_CGO"]
use_sqlite    = os.environ["PKG_USE_SQLITE"]
use_clib      = os.environ["PKG_USE_BUNDLED_C_LIB"]
is_daemon     = int(os.environ["PKG_IS_DAEMON"])
b_reqs        = os.environ["PKG_EXTRA_BUILD_REQUIRES"].split()
reqs          = os.environ["PKG_EXTRA_REQUIRES"].split()
deb_depends   = os.environ["PKG_DEB_DEPENDS"]
raw_excludes  = os.environ.get("PKG_EXCLUDES", "").split()

# Read maintainer from pkg-common.inc if present
maintainer = "Mis Center <support@criticalsys.net>"
common_inc = os.path.join(os.environ["PKG_SOURCES_DIR"], "pkg-common.inc")
if os.path.exists(common_inc):
    with open(common_inc, "r") as cf:
        m = re.search(r"^%global\s+maintainer\s+(.+)$", cf.read(), re.MULTILINE)
        if m:
            maintainer = m.group(1).strip()

excludes = set()
for e in raw_excludes:
    e = e.strip().lower()
    if e in ("windows", "win"):
        excludes.add("windows")
    elif e in ("deb", "debian"):
        excludes.add("deb")
    elif e in ("rpm",):
        excludes.add("rpm")
    elif e in ("archive", "tarball", "tar"):
        excludes.add("archive")

with open(template_file, "r") as f:
    content = f.read()

# Normalize RPM %global pkg_summary / pkg_desc percent signs so RPM avoids macro expansion errors
def escape_rpm_pct(s):
    return re.sub(r"%(?![{%])", "%%", s)

# Replace metadata
safe_summary = escape_rpm_pct(summary)
content = content.replace("<name>", name)
content = content.replace("<version>", version)
content = content.replace("<release_num>", release)
content = content.replace("<summary>", safe_summary)
content = content.replace("<license>", license_str)
content = content.replace("<url>", repo_url)
content = content.replace("<git_hash>", git_hash)
content = content.replace("<changelog_date>", chg_date)
content = content.replace("<maintainer>", maintainer)
deb_replacement = deb_depends if deb_depends else "%{nil}"
content = content.replace("<deb_depends>", deb_replacement)
content = content.replace("Group:          Applications/System", f"Group:          {group}")
if src_root != f"{name}-main":
    content = re.sub(r"%global src_root\s+\S+", f"%global src_root        {src_root}", content)
if bin_name:
    content = re.sub(r"%global bin_name\s+\S+", f"%global bin_name        {bin_name}", content)
if license_file:
    content = re.sub(r"%global license_file\s+\S+", f"%global license_file    {license_file}", content)
if completion_cmd:
    content = re.sub(r"%global completion_cmd\s+\S+", f"%global completion_cmd  {completion_cmd}", content)
if version_flag != "--version":
    content = re.sub(r"%global version_flag\s+\S+", f"%global version_flag    {version_flag}", content)
extra_globals = []
if check_version:
    extra_globals.append(f"%global check_version   {check_version}")
if doclist:
    extra_globals.append(f"%global doclist         {doclist}")
if deb_section:
    extra_globals.append(f"%global deb_section     {deb_section}")
if extra_globals:
    content = re.sub(r"(%global pkgver[^\n]+\n)", r"\1" + "\n".join(extra_globals) + "\n", content, count=1)

# Multi-line description formatting with backslashes
desc_lines = [escape_rpm_pct(l.replace("\\", "")) for l in desc.strip().splitlines()]
formatted_desc = "\\\n".join(desc_lines)
desc_replacement = f"%global pkg_desc        {formatted_desc}"

# Replace the entire description block
content = re.sub(
    r"%global pkg_desc\s+<description>\\(\r?\n)<description_line_2>\\(\r?\n)<description_line_3>",
    desc_replacement,
    content
)

# Platform specific substitutions
if platform == "rust":
    feat_repl = f"--features \"{cargo_feat}\"" if cargo_feat else "%{nil}"
    content = content.replace("<cargo_features>", feat_repl)
    content = re.sub(r"%global use_sqlite\s+\d+", f"%global use_sqlite         {use_sqlite}", content)
else:
    content = content.replace("<goipath>", goipath)
    content = content.replace("<cmd_path>", cmd_path)
    content = content.replace("<build_tags>", build_tags if build_tags else "%{nil}")
    content = content.replace("<version_ldflags>", ver_ldflags if ver_ldflags else "%{nil}")
    content = re.sub(r"%global use_cgo\s+\d+", f"%global use_cgo            {use_cgo}", content)
    content = re.sub(r"%global use_sqlite\s+\d+", f"%global use_sqlite         {use_sqlite}", content)
    content = re.sub(r"%global use_bundled_c_lib\s+\d+", f"%global use_bundled_c_lib  {use_clib}", content)

# Inject extra BuildRequires / Requires
extra_deps = []
for br in b_reqs:
    extra_deps.append(f"BuildRequires:  {br}")
for r in reqs:
    extra_deps.append(f"Requires:       {r}")
if extra_deps:
    inject_str = "\n".join(extra_deps) + "\n"
    content = content.replace("%pkg_common_buildrequires", inject_str + "%pkg_common_buildrequires", 1)

# Daemon systemd services & directives activation
if is_daemon == 1:
    sources_dir = os.environ["PKG_SOURCES_DIR"]
    tmpl_sources_dir = os.environ["PKG_TEMPLATE_SOURCES_DIR"]
    def find_tmpl(fname):
        p = os.path.join(sources_dir, fname)
        return p if os.path.exists(p) else os.path.join(tmpl_sources_dir, fname)

    svc_out = os.path.join(sources_dir, f"{name}.service")
    sys_out = os.path.join(sources_dir, f"{name}.sysusers.conf")
    tmp_out = os.path.join(sources_dir, f"{name}.tmpfiles.conf")

    # Render template.service
    with open(find_tmpl("template.service"), "r") as f:
        svc_txt = f.read()
    svc_txt = svc_txt.replace("<name>", name).replace("<summary_description>", summary).replace("<url>", repo_url)
    with open(svc_out, "w") as f:
        f.write(svc_txt)
    os.chmod(svc_out, 0o644)

    # Render template.sysusers.conf (sanitize quotes inside GECOS)
    gecos_summary = summary.replace('"', "'")
    with open(find_tmpl("template.sysusers.conf"), "r") as f:
        sys_txt = f.read()
    sys_txt = sys_txt.replace("<name>", name).replace("<summary_description>", gecos_summary).replace("<description_of_daemon>", gecos_summary)
    with open(sys_out, "w") as f:
        f.write(sys_txt)
    os.chmod(sys_out, 0o644)

    # Render template.tmpfiles.conf
    with open(find_tmpl("template.tmpfiles.conf"), "r") as f:
        tmp_txt = f.read()
    tmp_txt = tmp_txt.replace("<name>", name)
    with open(tmp_out, "w") as f:
        f.write(tmp_txt)
    os.chmod(tmp_out, 0o644)

    # Render template.env
    env_out = os.path.join(sources_dir, f"{name}.env")
    with open(find_tmpl("template.env"), "r") as f:
        env_txt = f.read()
    env_txt = env_txt.replace("<name>", name)
    with open(env_out, "w") as f:
        f.write(env_txt)
    os.chmod(env_out, 0o644)

    # Activate daemon toggle in specfile
    content = re.sub(r"%global is_daemon\s+\d+", "%global is_daemon          1", content)

# ------------------------------------------------------------------------------
# Handle Packaging Exclusions (--exclude windows,deb,rpm,archive)
# ------------------------------------------------------------------------------
if "windows" in excludes:
    content = re.sub(r"%global enable_windows\s+\d+", "%global enable_windows     0", content)

if "deb" in excludes:
    content = re.sub(r"%global enable_deb\s+\d+", "%global enable_deb         0", content)

if "archive" in excludes:
    content = re.sub(r"%global enable_archive\s+\d+", "%global enable_archive     0", content)

if "rpm" in excludes:
    content = content.replace("%bcond_without rpm\n", "%bcond_with rpm\n")

# Update Building Instructions comment in spec header based on exclusions
inst_lines = ["# BUILDING INSTRUCTIONS:"]
inst_idx = 1
if "rpm" not in excludes:
    inst_lines.append(f"#   {inst_idx}. Linux RPM Build:\n#        rpmbuild -ba SPECS/{name}-xg.spec")
    inst_idx += 1
if "archive" not in excludes:
    inst_lines.append(f"#   {inst_idx}. Build Linux Generic Tarball in STAGING:\n#        rpmbuild --with archive -ba SPECS/{name}-xg.spec")
    inst_idx += 1
if "deb" not in excludes:
    inst_lines.append(f"#   {inst_idx}. Build Debian Package in STAGING:\n#        rpmbuild --with deb -ba SPECS/{name}-xg.spec")
    inst_idx += 1
if "windows" not in excludes:
    inst_lines.append(f"#   {inst_idx}. Build Windows Zipball in STAGING:\n#        rpmbuild --with windows -ba SPECS/{name}-xg.spec")
    inst_idx += 1

active_flags = []
if "archive" not in excludes: active_flags.append("--with archive")
if "deb" not in excludes: active_flags.append("--with deb")
if "windows" not in excludes: active_flags.append("--with windows")

if active_flags:
    flag_str = " ".join(active_flags)
    inst_lines.append(f"#   {inst_idx}. Build All Active Targets:\n#        rpmbuild {flag_str} -ba SPECS/{name}-xg.spec")
inst_lines.append("#   Optional QA / Dependency Flags:\n#        --with testsuite, --with lint, --with audit, --with update_deps")

inst_block = "\n".join(inst_lines)
content = re.sub(r"# BUILDING INSTRUCTIONS:.*?(?=# TECHNICAL ARCHITECTURE:)", inst_block + "\n#\n", content, flags=re.DOTALL)

with open(target_spec, "w") as f:
    f.write(content)
PYEOF

chmod 0644 "$TARGET_SPEC"
echo "==> Successfully generated spec file: $TARGET_SPEC"

# ------------------------------------------------------------------------------
# 6. Spec Verification via rpmlint
# ------------------------------------------------------------------------------
if command -v rpmlint > /dev/null 2>&1; then
  echo "==> Running rpmlint validation on ${TARGET_SPEC}..."
  rpmlint "$TARGET_SPEC" || true
fi

# ------------------------------------------------------------------------------
# 7. Active Target Summary & Build Command Output
# ------------------------------------------------------------------------------
# Calculate active release targets and build flags
active_targets=()
build_flags=()

if [[ ! " ${EXCLUDES[*]} " =~ " rpm " ]]; then
  active_targets+=("RPM")
fi

if [[ ! " ${EXCLUDES[*]} " =~ " deb " ]] && [[ ! " ${EXCLUDES[*]} " =~ " debian " ]]; then
  active_targets+=("Debian .deb")
  build_flags+=("--with deb")
fi

if [[ ! " ${EXCLUDES[*]} " =~ " archive " ]] && [[ ! " ${EXCLUDES[*]} " =~ " tarball " ]] && [[ ! " ${EXCLUDES[*]} " =~ " tar " ]]; then
  active_targets+=("Linux tarball")
  build_flags+=("--with archive")
fi

if [[ ! " ${EXCLUDES[*]} " =~ " windows " ]] && [[ ! " ${EXCLUDES[*]} " =~ " win " ]]; then
  active_targets+=("Windows zipball")
  build_flags+=("--with windows")
fi

targets_str=""
for t in "${active_targets[@]}"; do
  [ -n "$targets_str" ] && targets_str="${targets_str}, "
  targets_str="${targets_str}${t}"
done
flags_str="${build_flags[*]}"

echo ""
echo "================================================================================"
echo "Package ${NAME} scaffolded successfully via pkg-make.sh!"
echo "================================================================================"
echo "Specfile:        $TARGET_SPEC"
[ -f "$TARGET_SOURCE" ] && echo "Source Archive:  $TARGET_SOURCE" || echo "Source Archive:  (Pending) Place source in $TARGET_SOURCE"
if [ "$IS_DAEMON" -eq 1 ]; then
  echo "Systemd Service: $SVC_OUT"
  echo "Sysusers Config: $SYS_OUT"
  echo "Tmpfiles Config: $TMP_OUT"
  echo "Environment Cfg: $ENV_OUT"
fi
if [ ${#EXCLUDES[@]} -gt 0 ]; then
  echo "Excluded:        ${EXCLUDES[*]}"
fi
echo ""
if [ ${#active_targets[@]} -gt 0 ]; then
  echo "To build active release targets (${targets_str}):"
  echo "  rpmbuild ${flags_str:+${flags_str} }-ba $TARGET_SPEC"
else
  echo "To compile binary (packaging excluded):"
  echo "  rpmbuild -bc $TARGET_SPEC"
fi
echo "================================================================================"
