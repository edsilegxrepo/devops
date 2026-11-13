# ShellCheck Cross-Target Builder (`shellcheck_build.sh`)

Builds up-to-date `shellcheck` binaries directly from the latest commit of [koalaman/shellcheck](https://github.com/koalaman/shellcheck) using upstream's official Docker builders (`builders/linux.x86_64` and `builders/windows.x86_64`):
- **Linux `amd64` (statically linked ELF):** Built via `builders/linux.x86_64` (Alpine/musl) and verified with `file`, `ldd`, and `--version`.
- **Windows `x86_64` (`shellcheck.exe`):** Built via `builders/windows.x86_64` without requiring any Haskell toolchain on the host.

Fully compatible with both:
- **Windows Cygwin / MSYS2 / Git Bash:** Executes Docker cleanly through WSL (`wsl.exe`).
- **Native Linux:** Executes Docker directly on the host.

Every build clones the latest commit on `master` into an isolated ephemeral workspace under `$TEMP` -> `$TMP` -> `$TMPDIR` -> `/tmp` (cleaned automatically on exit) and embeds the exact 7-character Git commit SHA in generated release archives (`shellcheck-v<ver>-<sha7>-...`) for traceability.

## Prerequisites

- **On Windows (Cygwin / MSYS2 / Git Bash):**
  - `git` and `wsl.exe` with a Docker-enabled WSL distribution (Rancher Desktop, Docker Desktop WSL integration, or `dockerd` inside WSL), plus `zip` and `xz` in WSL for default archive packaging.
- **On Native Linux:**
  - `git`, `docker` daemon access, `tar`/`xz`, and `zip` for default archive packaging.

## Usage

```bash
# Build latest master for both static Linux amd64 and Windows x86_64 + traceable archives (default)
./shellcheck_build.sh --all --out-dir=d:/stage/shellcheck

# Build only static Linux amd64 (unpacked binary only, skipping .tar.xz archive)
./shellcheck_build.sh --linux --no-package --out-dir=./dist/shellcheck

# Preview resolved paths and operations without building
./shellcheck_build.sh --all --dry-run
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `--linux` | `false` | Build static Linux `amd64` `shellcheck` ELF binary (`builders/linux.x86_64`) |
| `--windows` | `false` | Build Windows `x86_64` `shellcheck.exe` (`builders/windows.x86_64`) |
| `--all` | `false` | Build both Linux `amd64` and Windows `x86_64` |
| `--out-dir=<path>` | `./dist/shellcheck` | Output directory for packages (or binaries with `--no-package`) |
| `--no-package` | `false` | Skip `.tar.xz` and `.zip` release archives and keep unpacked binaries |
| `--no-cache` | `false` | Pass `--no-cache` to Docker image builds |
| `--dry-run` | `false` | Print planned operations without executing builds |

## Outputs

Under `--out-dir`:
- **Default** (release archives stamped with version + 7-char commit SHA `<sha7>`; unpacked subdirectories are purged once archived):
  - `shellcheck-v<ver>-<sha7>-linux-amd64-static.tar.xz` (+ `.sha256`)
  - `shellcheck-v<ver>-<sha7>-windows-amd64.zip` (+ `.sha256`)
- **With `--no-package`** (unpacked binaries retained):
  - `linux-amd64/shellcheck` + `linux-amd64/shellcheck.sha256`
  - `windows-amd64/shellcheck.exe` + `windows-amd64/shellcheck.exe.sha256`
