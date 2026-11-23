# `build_tasks/` Modularization & DRY Architecture Plan

This document defines the phased plan to harden the shared client packaging framework under `build_tasks/lib/`, eliminate remaining duplication inside current consumers, and migrate standalone packaging/upgrade scripts onto shared primitives **without introducing exit-code, logging-stream, performance, or version-comparison regressions**.

---

## 1. Library Architecture & Entrypoints

```text
build_tasks/
├── client_package_common.sh   # 26-line facade sourcing all 4 modules in dependency order
└── lib/
    ├── pkg_core.sh            # Platform/PATH guard, logging, path engine, safe_rm_*, workspaces, mkdir locks, traps, CLI/CSV/UI helpers
    ├── pkg_transfer.sh        # HTTPS/file URL guard, sha256/sha512 verifier, download_asset, fetch_text, GitHub Releases API (gh_*)
    ├── pkg_archive.sh         # Archive integrity, extraction, WSL permission-preserving repacking, semver/pruning, atomic_publish_file/atomic_stage_package
    └── pkg_pipeline.sh        # High-level dual-platform packaging pipeline (run_dual_platform_package)
```

### Facade Policy (`client_package_common.sh` vs. Direct `lib/pkg_*.sh`)
- **Full packagers & multi-platform upgraders** (`antigravity_package.sh`, `bun_upgrade.sh`, `citools_package.sh`, `craftapps_package.sh`, `dotnet_packaging.sh`, `vscode_package.sh`, `chromium_upgrade.sh`, `build_python_win.sh`) source `client_package_common.sh` so they do not duplicate ordered `source` statements across four modules.
- **Minimal / specialized utilities** (e.g., `rust_cachemgr.sh`, `jdk_packaging.sh`, `tomcat_packaging.sh`) may source only the required module(s) (`lib/pkg_core.sh`, and optionally `lib/pkg_archive.sh`), avoiding unused transfer/pipeline code.
- **`build.inc` boundary:** Go/RPM/DEB compiler pipelines (`build_go.sh`, `build_go_exec.sh`, `build_orchestrate.sh`, `shellcheck_build.sh`, `gobuild_code-analyzers.sh`) stay on `build.inc` rather than mixing two competing `EXIT` trap and `EXIT_*` constant models.

---

## 2. Pre-Migration Behavioral Invariants (Regression Checklist)

Before migrating or modifying any script, verify and preserve all five contracts:

1. **Shell Options & `ERR` Traps:**
   - Scripts intentionally running without `set -u` or `set -e` (e.g., `rust_upgrade.sh`) must not break when sourcing `lib/pkg_core.sh`; never blindly inject `set -Eeuo pipefail` or `enable_err_trap` without auditing every variable and non-zero return path.
   - Functions that return non-zero as expected control flow (like `dotnet_packaging.sh`'s `fail_channel`) must clearly guard callers or avoid tripping `ERR` traps.
2. **Exit-Code Contracts:**
   - Library helpers must **return `1`** (or honor configurable exit-code parameters) rather than hardcoding `exit 1` when callers rely on granular triage codes (e.g., `chromium_upgrade.sh` uses `1` = up-to-date skip, `2` = CLI args, `3` = prerequisites, `4..7` = stage failures; `bun_upgrade.sh` uses `3`/`5`/`7`; `rust_cachemgr.sh` uses `6`).
3. **`stdout` vs. `stderr` & Log File Formatting:**
   - Scripts whose `stdout` is parsed as JSON or data tables (`rust_cachemgr.sh`, `dotnet_packaging.sh`) **must** set `LOG_INFO_TO_STDERR=1`.
   - Switching `LOG_INFO_TO_STDERR` or enabling `init_log_file` (`tee`) must disable ANSI color escapes cleanly so log files never capture raw escape sequences.
4. **Version Comparison & Asset Discovery Semantics:**
   - Do **not** blindly replace custom version comparators with `sort -V` (`is_version_newer`) when build-tag suffixes differ (e.g., `chromium_upgrade.sh` checks `[ "$remote" != "$local_v" ]` for Chromium build/revision tags).
   - Do **not** drop HTML-scraping fallbacks or unverified-repo handling when replacing bespoke GitHub API helpers with `gh_*`.
5. **Windows NTFS Deletion Performance & Env Vars:**
   - Massive directory trees on Windows (`rust_upgrade_win.sh` toolchains/Cargo caches) depend on atomic rename + background `cmd.exe /c rmdir /s /q` fast-paths; do not regress them to synchronous `rm -rf`.
   - Preserve exported `TEMP`/`TMP`/`HOME` conventions expected by native child tools (`7z.exe`, `powershell.exe`).

---

## 3. Phased Execution Plan

### Phase 0 — Harden `build_tasks/lib/` Contracts (Prerequisite — Done)

Fix known bugs and contract gaps in the shared library before touching additional scripts:

- [x] **`lib/pkg_core.sh` — Dynamic color refresh (`_init_colors` / `init_log_file`):** Re-evaluate color variables when `init_log_file` redirects streams via `tee` or when `LOG_INFO_TO_STDERR` changes after sourcing.
- [x] **`lib/pkg_core.sh` — Lock reaper & `safe_rm_rf` hardening:**
  - Store owner PID + age expiry inside `${lock_dir}.reap` so a `SIGKILL`ed reaper never leaves an orphaned `.reap` lock directory.
  - Make `acquire_lock` return `1` on lock contention/failure (moving `exit` decisions to callers like `dotnet_packaging.sh` or JSON handling in `rust_cachemgr.sh`).
  - Resolve `safe_rm_rf` paths via `realpath -m` (matching `validate_safe_dir` canonicalization) and add an opt-in fast Windows `rmdir` helper/flag (`safe_rm_rf --fast-win`) for massive NTFS trees.
- [x] **`lib/pkg_core.sh` — Configurable exit codes on CLI/tool helpers:** Allow optional exit-code override (defaulting to `1`) in `verify_required_tools` and `require_opt_arg`.
- [x] **`lib/pkg_transfer.sh` — Unified HTTP fetch & subshell-safe cleanup:**
  - Extract a single `_curl_fetch` / `fetch_text` helper with consistent timeouts/retries, `validate_download_url` enforcement, and local error-file cleanup (`trap ... RETURN` / explicit `rm -f` independent of parent `EXIT` globals inside `$()` subshells).
  - Deduplicate raw `curl` calls in `gh_fetch_releases_json`, `gh_fetch_release_checksums`, and `gh_lookup_asset_sha256`.
  - Add a shared `write_sha256_manifest` helper (for `SHA256SUMS` generation).
- [x] **`lib/pkg_archive.sh` — Complete archive verification & atomic recompression:**
  - Extend `verify_archive_integrity` (and `extract_archive` where applicable) to verify `.tar.gz`/`.tgz` (`gzip -t` / `tar -tzf`), `.tar` (`tar -tf`), and optional `.7z` (`7z t` when `7z` is configured), rather than silently returning `0` on `*)`.
  - Make `recompress_folder_to_tar_xz` normalize timestamps and write via a sibling `.tmp` file before replacing `$dest_tar_xz`.

### Phase 1 — Finish Remaining Duplication in Current Consumers (Low Risk — Done)

- [x] **`bun_upgrade.sh`:** Replace bare `curl` in install/detect (`L135`, `L356`) with `download_asset` / `fetch_text` (preserving timeouts, retries, and exit codes).
- [x] **`antigravity_package.sh` & `vscode_package.sh`:** Remove local `fetch_text` / raw `curl` wrappers (`antigravity_package.sh:66-81`, `vscode_package.sh:197`) in favor of `lib/pkg_transfer.sh:fetch_text`.
- [x] **`craftapps_package.sh`:**
  - Migrate `fetch_github_release` + `extract_asset_urls` to `gh_resolve_release` / `gh_find_asset` + `gh_download_verified_asset` (adding `gh auth token` fallback, release caching, and SHA-256 verification when digests exist).
  - Replace deploy workspace/curl/prune boilerplate (`L563`, `L579`, `L620`, `L1100`) with `create_temp_workdir`, `fetch_text`, and `download_asset`.

### Phase 2 — Migrate Tier-1 Standalone Scripts (Smallest -> Largest — Done)

- [x] **`build_python_win.sh` (~665 -> 603 lines):**
   - Replaced `to_posix_path`, `to_win_path`, `log_*`, `cleanup_workspace`, `create_temp_workspace`, `unzip -tq`, `promote_archive`, and `SHA256SUMS` generation with `client_package_common.sh` (`LOG_INFO_TO_STDERR=1`, `atomic_publish_file`, `write_sha256_manifest`, `verify_required_tools --exit-code 3`).
- [x] **`rust_cachemgr.sh` (648 -> 597 lines):**
   - Sourced `lib/pkg_core.sh` directly (`LOG_INFO_TO_STDERR=1`).
   - Replaced custom `to_posix_path` and non-atomic `echo "$$" > "$LOCK_FILE"` with `acquire_lock` / `release_lock`, preserving JSON error formatting and `exit 6` on lock contention.
- [x] **`chromium_upgrade.sh` (1,451 -> 1,342 lines):**
   - Sourced `client_package_common.sh` (`LOG_INFO_TO_STDERR=1`, `trap - ERR`) and renamed `PLATFORM` -> `TARGET_PLATFORM` (`IS_WINDOWS` -> `is_windows_platform`).
   - Replaced platform/path helpers (`format_path` -> `to_mixed_path`, `to_posix_path`, `win_to_wsl_path` -> `to_wsl_path`), logging, `safe_rm_rf`, `create_temp_workspace` (`create_temp_workdir`), raw `curl` calls (`fetch_text`/`download_asset`), and `finalize_package_archive` (`atomic_publish_file`).
   - **Preserved:** granular exit codes (`1..7`), strict-inequality build-tag version check, GitHub HTML scraping fallback on rate limit, `.7z` handling, and locale `en-US*` retention.
- [x] **`rust_upgrade_win.sh` (1,487 -> 1,420 lines) & `rust_upgrade.sh` (1,273 lines):**
   - Replaced platform/PATH guards, path helpers (`to_mixed_path` + `to_syspath`/`to_posix_path` delegation), temp root resolution (`detect_temp_root`), `safe_delete` (`safe_rm_rf --fast-win`), `cleanup` traps chained onto `cleanup_workspace`, and manifest `fetch_text` calls.
   - **Preserved:** fast background `rmdir /s /q` deletion in `rust_upgrade_win.sh`, `exit 9`/`exit 99` contracts, parallel/resumable archive transfers, and `rust_upgrade.sh`'s shell-option compatibility.

### Phase 3 — Selective Adoption & `build.inc` Boundary Cleanups (Done)

- [x] **`jdk_packaging.sh` (416 -> 423 lines) & `tomcat_packaging.sh` (542 -> 562 lines):**
  - Sourced `lib/pkg_core.sh` + `lib/pkg_archive.sh` directly (`LOG_INFO_TO_STDERR=0`) for safe directory deletion (`safe_rm_rf`, `tomcat_rm_rf` scoped wrapper preserving `pkg_core.sh` non-shadowing), standardized archive extraction (`extract_archive` in `jdk_packaging.sh`), and verified atomic `.tar.xz`/`.zip` publishing (`atomic_publish_file` without stripping original package timestamps or symlinks); allowed env overrides (`PKG_DIR`, `BASE_DIR`) for isolated E2E tests.
- [x] **`build.inc` & `shellcheck_build.sh`:** Added `normalize_to_posix_path()` to `build.inc` and removed the redundant `to_posix_path()` definition from `shellcheck_build.sh` (`475 -> 465` lines), keeping `build_go*` / `gobuild_code-analyzers.sh` on `build.inc`.

---

## 4. Mandatory Verification Gate (Per Phase / PR)

Every change batch must pass before moving to the next script:

1. **Static Analysis:** `bash -n` and `shellcheck -x` inside `build_tasks/` with **0 warnings/errors** on all touched modules and callers.
2. **CLI & Flag Smoke Tests:** `--help`, `--detect`, `--list*`, and `--dry-run` checks verifying exit codes and `stdout` vs. `stderr` separation (especially `--json` outputs).
3. **Unit & Offline E2E Harness:** Run assertions in an isolated `/tmp` sandbox covering:
   - Lock contention (live PID block + stale `.lock.d` & `.reap` recovery)
   - Path/traversal guards (`validate_safe_dir`, `safe_rm_rf`)
   - Failure-path exit codes and ANSI-free log-file output
   - Offline `file://` or mock-JSON package build -> corrupt pre-rename rejection -> staging-failure recovery without `--force` (mirroring the `dotnet_packaging.sh` E2E suite).

---

## 5. Current Progress

- **Completed:** Modular split of `client_package_common.sh` into `lib/pkg_{core,transfer,archive,pipeline}.sh`; migrated `dotnet_packaging.sh` (`964 -> 650` lines); updated callers off `to_cygpath`; completed **Phase 0** (`lib/pkg_*` contract & `.7z`/`to_mixed_path` hardening), **Phase 1** (`bun_upgrade.sh`, `antigravity_package.sh`, `vscode_package.sh`, `craftapps_package.sh`), **Phase 2** (`build_python_win.sh`, `rust_cachemgr.sh`, `chromium_upgrade.sh`, `rust_upgrade_win.sh`, `rust_upgrade.sh`), and **Phase 3** (`jdk_packaging.sh`, `tomcat_packaging.sh`, `build.inc`, `shellcheck_build.sh`), verified via `bash -n`, `shellcheck -x` across all 20 files, CLI smoke checks, and offline E2E suites.
- **Next:** Ready to review `git diff` and commit Phases 0–3 changes.
