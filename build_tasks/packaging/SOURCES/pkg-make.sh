#!/bin/bash
# ==============================================================================
# Script:      /usr/src/redhat/SOURCES/pkg-make.sh
# Purpose:     Universal package scaffold generator for Rust and Go specfiles.
# Applicability: Automates creation of 100% static musl RPM & Debian packages.
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
BUILD_REQUIRES=()
REQUIRES=()
DEB_DEPENDS=""
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

[ -z "$SUMMARY" ] && SUMMARY="${NAME} application"
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

# Auto-detect or generate git commit hash
if [ -z "$GIT_HASH" ]; then
  if [ -n "$SOURCE_ARCH" ]; then
    detected="$(basename "$SOURCE_ARCH" | grep -o -E '[0-9a-f]{7,8}' | tail -n 1 || true)"
    if [ -n "$detected" ]; then
      GIT_HASH="$detected"
    else
      GIT_HASH="src"
    fi
  else
    GIT_HASH="main"
  fi
fi

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
if [ -n "$SOURCE_ARCH" ] && [ -f "$SOURCE_ARCH" ]; then
  echo "==> Preparing canonical source zip with ${NAME}-main root..."
  TMP_SRC_DIR="$(mktemp -d -t "src_convert_XXXXXX")"
  trap 'rm -rf "${TMP_SRC_DIR}"' EXIT
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
  rm -rf "$TMP_SRC_DIR"
  trap - EXIT
  echo "==> Created canonical source zip: $TARGET_SOURCE"
else
  if [ ! -f "$TARGET_SOURCE" ]; then
    echo "NOTICE: Source archive not yet present at: $TARGET_SOURCE"
    echo "        Place source files in $TARGET_SOURCE before running rpmbuild."
  fi
fi

# ------------------------------------------------------------------------------
# 4. Optional Daemon Scaffolding Setup
# ------------------------------------------------------------------------------
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
  TEMPLATE_FILE="${SPECS_DIR}/pkg-rust-template-xg.spec"
else
  TEMPLATE_FILE="${SPECS_DIR}/pkg-go-template-xg.spec"
fi

export PKG_SOURCES_DIR="${SOURCES_DIR}"
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

# Replace metadata
content = content.replace("<name>", name)
content = content.replace("<version>", version)
content = content.replace("<release_num>", release)
content = content.replace("<summary>", summary)
content = content.replace("<license>", license_str)
content = content.replace("<url>", repo_url)
content = content.replace("<git_hash>", git_hash)
deb_replacement = deb_depends if deb_depends else "%{nil}"
content = content.replace("<deb_depends>", deb_replacement)
content = content.replace("Group:          Applications/System", f"Group:          {group}")

# Multi-line description formatting with backslashes
desc_lines = [l.replace("\\", "") for l in desc.strip().splitlines()]
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
    feat_repl = f"--features \"{cargo_feat}\"" if cargo_feat else ""
    content = content.replace("<cargo_features>", feat_repl)
    content = re.sub(r"%global use_sqlite\s+\d+", f"%global use_sqlite         {use_sqlite}", content)
else:
    content = content.replace("<goipath>", goipath)
    content = content.replace("<cmd_path>", cmd_path)
    content = content.replace("<build_tags>", build_tags)
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
    content = content.replace("BuildRequires:  tar\n", inject_str + "BuildRequires:  tar\n", 1)

# Daemon systemd services & directives activation
if is_daemon == 1:
    sources_dir = os.environ["PKG_SOURCES_DIR"]
    svc_out = os.path.join(sources_dir, f"{name}.service")
    sys_out = os.path.join(sources_dir, f"{name}.sysusers.conf")
    tmp_out = os.path.join(sources_dir, f"{name}.tmpfiles.conf")

    # Render template.service
    with open(os.path.join(sources_dir, "template.service"), "r") as f:
        svc_txt = f.read()
    svc_txt = svc_txt.replace("<name>", name).replace("<summary_description>", summary).replace("<url>", repo_url)
    with open(svc_out, "w") as f:
        f.write(svc_txt)
    os.chmod(svc_out, 0o644)

    # Render template.sysusers.conf
    with open(os.path.join(sources_dir, "template.sysusers.conf"), "r") as f:
        sys_txt = f.read()
    sys_txt = sys_txt.replace("<name>", name).replace("<summary_description>", summary).replace("<description_of_daemon>", summary)
    with open(sys_out, "w") as f:
        f.write(sys_txt)
    os.chmod(sys_out, 0o644)

    # Render template.tmpfiles.conf
    with open(os.path.join(sources_dir, "template.tmpfiles.conf"), "r") as f:
        tmp_txt = f.read()
    tmp_txt = tmp_txt.replace("<name>", name)
    with open(tmp_out, "w") as f:
        f.write(tmp_txt)
    os.chmod(tmp_out, 0o644)

    # Render template.env
    env_out = os.path.join(sources_dir, f"{name}.env")
    with open(os.path.join(sources_dir, "template.env"), "r") as f:
        env_txt = f.read()
    env_txt = env_txt.replace("<name>", name)
    with open(env_out, "w") as f:
        f.write(env_txt)
    os.chmod(env_out, 0o644)

    # Activate daemon directives in specfile
    content = re.sub(r"# Source20:\s+(\S+)", "Source20:       %{name}.service", content)
    content = re.sub(r"# Source21:\s+(\S+)", "Source21:       %{name}.sysusers.conf", content)
    content = re.sub(r"# Source22:\s+(\S+)", "Source22:       %{name}.tmpfiles.conf", content)
    content = re.sub(r"# Source23:\s+(\S+)", "Source23:       %{name}.env", content)
    content = re.sub(
        r"#\s*(install -D -p -m 0644\s+)%%\{(SOURCE2[0-2])\}\s+%%\{buildroot\}%%\{(_unitdir|_sysusersdir|_tmpfilesdir)\}/%%\{name\}\.(service|conf)",
        r"\1%{\2} %{buildroot}%{\3}/%{name}.\4",
        content
    )
    content = content.replace(
        "# install -D -p -m 0640 %%{SOURCE23} %%{buildroot}%%{_sysconfdir}/%%{name}/%%{name}.env",
        "install -D -p -m 0640 %{SOURCE23} %{buildroot}%{_sysconfdir}/%{name}/%{name}.env"
    )
    content = content.replace("# %%{_unitdir}/%%{name}.service", "%{_unitdir}/%{name}.service")
    content = content.replace("# %%{_sysusersdir}/%%{name}.conf", "%{_sysusersdir}/%{name}.conf")
    content = content.replace("# %%{_tmpfilesdir}/%%{name}.conf", "%{_tmpfilesdir}/%{name}.conf")
    content = content.replace(
        "# %%dir %%attr(0750,%%{name},%%{name}) %%{_sysconfdir}/%%{name}",
        "%dir %attr(0750,%{name},%{name}) %{_sysconfdir}/%{name}"
    )
    content = content.replace(
        "# %%config(noreplace) %%attr(0640,%%{name},%%{name}) %%{_sysconfdir}/%%{name}/%%{name}.env",
        "%config(noreplace) %attr(0640,%{name},%{name}) %{_sysconfdir}/%{name}/%{name}.env"
    )
    content = content.replace("# %%post\n# %%systemd_post %%{name}.service", "%post\n%systemd_post %{name}.service")
    content = content.replace("# %%preun\n# %%systemd_preun %%{name}.service", "%preun\n%systemd_preun %{name}.service")
    content = content.replace("# %%postun\n# %%systemd_postun_with_restart %%{name}.service", "%postun\n%systemd_postun_with_restart %{name}.service")
    content = content.replace(
        '  --bin "bin/%{name}" \\\n',
        '  --bin "bin/%{name}" \\\n  --dir "/etc/%{name}:0750" \\\n  --service %{SOURCE20} \\\n  --sysusers %{SOURCE21} \\\n  --tmpfiles %{SOURCE22} \\\n  --conffile %{SOURCE23}:etc/%{name}/%{name}.env \\\n'
    )

# ------------------------------------------------------------------------------
# Handle Packaging Exclusions (--exclude windows,deb,rpm,archive)
# ------------------------------------------------------------------------------
if "windows" in excludes:
    content = re.sub(r"%bcond_with windows\n+", "", content)
    content = re.sub(r"# Early Windows target toolchain validation.*?\n%endif\n+", "", content, flags=re.DOTALL)
    content = re.sub(r"%if %\{with windows\}\s*\nBuildRequires:\s+zip unix2dos\s*\n%endif\n+", "", content)
    content = re.sub(r"# (?:2\.\s+)?If conditional Windows target is set, cross-compile for Windows PE\s*\n%if %\{with windows\}.*?\n(?:mkdir -p bin/windows\s*\n)?cp -af [^\n]+bin/windows[^\n]*\n%endif\n+", "", content, flags=re.DOTALL)
    content = re.sub(r"# If conditional Windows target is set, package Windows ZIP archive\s*\n%if %\{with windows\}.*?%endif\n+", "", content, flags=re.DOTALL)
    content = re.sub(r"%if %\{with windows\}\s*\n%\{SOURCE10\} check-win \"[^\"]+\"\s*\n%endif\n+", "", content)

if "deb" in excludes:
    content = re.sub(r"%bcond_with deb\n+", "", content)
    content = re.sub(r"# Debian Package Runtime Dependencies.*?\n%global deb_depends.*?\n+", "", content)
    content = re.sub(r"Source11:\s+pkg-deb\.sh\n+", "", content)
    content = re.sub(r"%if %\{with deb\}\s*\nBuildRequires:\s+dpkg\s*\n%endif\n+", "", content)
    content = content.replace("chmod +x %{SOURCE10} %{SOURCE11}", "chmod +x %{SOURCE10}")
    content = re.sub(r"# If conditional DEB target is set, package Debian \.deb\s*\n%if %\{with deb\}.*?%endif\n+", "", content, flags=re.DOTALL)

if "archive" in excludes:
    content = re.sub(r"%bcond_with archive\n+", "", content)
    content = re.sub(r"%if %\{with archive\}\s*\nBuildRequires:\s+xz\s*\n%endif\n+", "", content)
    content = re.sub(r"# If conditional archive target is set, package Linux generic tarball\s*\n%if %\{with archive\}.*?%endif\n+", "", content, flags=re.DOTALL)

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
