# DevOps Scripts and Utilities

This repository is a centralized collection of DevOps scripts and utilities designed to streamline and automate various aspects of code and system deployments. The tools included here are robust, reusable, and well-documented to support a wide range of development and operational workflows.

## Primary Objectives

- **Automation:** Reducing manual effort and improving consistency in deployment processes.
- **Standardization:** Establishing common practices and tools for infrastructure management.
- **Efficiency:** Accelerating development cycles by providing reliable and easy-to-use utilities.
- **Isolation:** Implementing "Least Privilege" and side-by-side installations for critical system components (e.g., OpenSSL, Python).

## Repository Structure

### 1. Security and Code Audit (`/audit`)
Hardened frameworks for system security and code quality assurance.
- `code_audit.sh`: Multi-tiered, polyglot static analysis and security audit framework.
- `root_audit.sh`: System-level security audit and remediation for the root account.
- `pslint.ps1`: PowerShell Linter Wrapper for PSScriptAnalyzer (Audit and Auto-Fix).
- `shlint.sh`: Bash script hygiene tool enforcing formatting (shfmt) and static analysis (shellcheck).
- `detect_priv.sh`: Privileged user detection auditing administrative rights via the `sudo` policy engine.
- `generate_diffs.sh`: High-performance, concurrent script diff generator with fuzzy rename and extension change detection.

### 2. Build & Validation Tasks (`/build_tasks`)
Automation for building, packaging, and validating core system components.
- `antigravity_package.sh`: Cross-platform release monitoring, license/locale pruning, `xz -9 -T0` Linux transcoding, and transactional library/upload staging pipeline for Google Antigravity CLI, Agent, and IDE distributions.
- `build_orchestrate.sh`: Top-level orchestrator (backed by `build.inc`) for parallel module compilation, template governance (`.gitignore`, `SECURITY.md`, `LICENSE`), release code signing, and Git synchronizations across sub-projects.
- `build_go.sh`: Go compilation, static analysis (`go vet`, `golangci-lint`), vulnerability scanning (`govulncheck`, `gosec`), ASLR PIE binary hardening, and distribution packaging with automated `SHA256SUMS` generation.
- `build_go_exec.sh`: Orchestration wrapper preparing, patching, configuring, and executing Go projects (supporting `git-clone` and `local` modes) with non-interactive overlay patch staging and handover to `build_go.sh`.
- `build_python_win.sh`: Packaging for Windows Python distributions, focusing on a minimal binary only archive.
- `bun_upgrade.sh`: Automated lifecycle management, installation, upgrading, caching, and package registry tool for the Bun JavaScript runtime across Windows (Cygwin/MSYS2) and Linux environments.
- `chartdb-setup.sh`: Repeatable deployment, automated security remediation, and build orchestration framework for the ChartDB database visualization suite (integrating `chartdb-patch.py` for CVE patching, dependency overrides, Vite/Monaco compatibility shims, and SPA dev/production serving).
- `chromium_upgrade.sh`: Automates downloading, locale-pruning, repackaging, and deploying Chromium browser builds across Windows (Cygwin/MSYS2) and Linux environments.
- `client_package_common.sh`: Shared cross-platform foundation library providing Cygwin/MSYS2/WSL/Linux path normalization, defensive deletion guards, checksum validation, locale pruning, WSL permission-preserving `xz -9 -T0` repacking, and atomic `.tmp` staging.
- `craftapps_package.sh`: Cross-platform packaging and release automation pipeline for Storytold desktop applications (monitoring GitHub releases, validating Linux/Windows binaries, pruning redundant packaging artifacts, bundling unified multi-platform archives, deploying locally via `--deploy`, and atomically synchronizing libraries and upload staging).
- `dotnet_packaging.sh`: Cross-platform `.NET` Windows installer bundle synchronization and staging pipeline supporting explicit channels (`--version`) and local archive discovery (`--auto` for `major >= 8`), official `releases.json` resolution, SHA-512 verification, incremental component reuse, and atomic staging across Cygwin, MSYS2, and Linux/WSL.
- `javacmd_build.sh`: Unified, generic Java compilation and packaging wrapper integrating Checkstyle, PMD, and SpotBugs validation.
- `jdk_packaging.sh`: Automates Azul Zulu JDK repackaging, footprint minimization, Maven integration, and JTLSTester diagnostic injection.
- `tomcat_packaging.sh`: Reconstructs, customizes, and packages Apache Tomcat layouts, applying configuration patches and resolving external database drivers.
- `tomcat_probe_build.sh`: Automates retrieval, compilation, customization, and secure packaging of the `psi-probe` monitoring tool for `javax` namespace Tomcat environments.
- `gobuild_code-analyzers.sh`: Parallel build orchestrator compiling, hardening (PIE, `-buildvcs=false`), cross-compiling (Zig/musl for Linux & native Windows AMD64), flat/tree packaging, and platform-deploying (`--deploy`) 21 Go static analysis and developer tools.
- `openssl_build.sh`: A multi-mode (RPM/Archive/All) script for isolated OpenSSL builds.
- `sqlite3_validate.sh`: A suite for verifying SQLite 3 binary builds against specs.
- `rust_upgrade.sh`: Automated management of Rust toolchain deployments and target libraries.
- `rust_upgrade_win.sh`: Unified, parallelized Rust toolchain deployment, linter compilation, and environment detection manager for Windows (Cygwin/MSYS2).
- `rust_cachemgr.sh`: Safety-critical caching manager and pruning optimizer for Cargo and compiler caches.
- `shellcheck_build.sh`: Cross-target `koalaman/shellcheck` source builder producing statically linked Linux `amd64` binaries (`builders/linux.x86_64`) and standalone Windows `x86_64` executables (`builders/windows.x86_64`) from Cygwin/MSYS2 via WSL Docker or native Linux, embedding the 7-character Git commit SHA in release archives.
- `vscode_package.sh`: Automated Microsoft Visual Studio Code stable release pipeline downloading and SHA-256 verifying `vscode_cli` and `vscode` IDE archives, pruning redundant licenses/locales/policies, transcoding Linux archives via WSL/Linux ext4 (`xz -9 -T0`) preserving setuid permissions, and atomically staging packages.
- `gosanitize/`: Cross-platform Go utility (`main.go`) that autodetects Linux ELF and Windows PE binaries and safely strips embedded Go `buildinfo` metadata in-place with atomic writes, Authenticode guards, and optional backup preservation.
- `packaging/`: Multi-distribution packaging framework for universal Rust and Go applications, automating static musl compilation, Zig cross-compilation, and unified RPM, Debian (.deb), Linux (.tar.xz), and Windows (.zip) artifact generation.

### 3. Git Management (`/git_repomgr`)
Tools for orchestrating large-scale repository synchronization and user management.
- `git_sync.sh`: A hardened, singleton script for complex Git sync operations.
- `git_autosync.sh`: A parallel, recursive utility for syncing entire workspace trees.
- `git_userchange.sh`: A surgical tool for rewriting Git history/authorship.

### 4. OCI & Container Tools (`/oci_tools`)
Utilities for interacting with Open Container Initiative (OCI) images without a full daemon.
- `extract_oci.sh`: Downloads, verifies, and extracts OCI image filesystems.

### 5. OS & System Configuration (`/os_sys`)
Low-level system adjustments and service delegations.
- `IISDelegationSet.ps1`: Implements granular management delegation for IIS.
- `IISDelegationUndo.ps1`: Reverts IIS management delegation for a specific group.
- `IISDelegationValidate.ps1`: Verifies the IIS management delegation for a specific group.
- `set_nomodeset.sh`: Ensures consistent headless boot parameters across OS families.
- `dnsmgr.ps1`: Robust, headless utility for Windows DNS server and search suffix management.
- `winposix_update.ps1`: Automated, headless update utility for Cygwin and MSYS2 environments.
- `defender_setup.ps1`: Audits and manages coexistence, passive mode, and uninstallation of Microsoft Defender on systems with SentinelOne.
- `ntlmctl.ps1`: NTLM Protocol & Audit Manager controlling NTLM authentication enforcement (disabling NTLMv1/LM via `LmCompatibilityLevel = 5`), incoming authentication auditing (`AuditReceiptEvents`), and event log channel enablement.
- `procmgr.ps1`: Comprehensive PowerShell process management utility for listing, diagnosing, setting priority/affinity, and terminating processes.
- `winsvc/svcmgr.ps1`: Extensible plugin-based service control CLI (backed by `ProcessControl` and JSON service descriptors) for managing user-space Windows services (`nginx`, `gitea`, `sftpgo`) without administrator privileges.
- `os_service_account.sh`: Provisions unprivileged OS service accounts (e.g., `gfaudit`) for compliance audit automation.
- `ubuntu_upgrade.sh`: Orchestrates non-interactive system package updates, telemetry/ESM disabling, parallel Flatpak upgrades, and mainline kernel updates.
- `ubuntu_kernel_updater.sh`: Detects, installs, and manages mainline upstream kernels bypassing APT dependency checks, and purges older kernels.
- `proxmox_update.sh`: Proxmox VE update orchestrator with pre-flight storage gating, early archive purging, strict dist-upgrade semantics, kernel lifecycle management, and bootloader synchronization.
- `proxmox_tune.sh`: Idempotent Proxmox VE `proxmox-widget-toolkit` subscription notice patcher.
- `lib/`: Shared 3-tier OS abstraction library (`system.sh`, `debian_sys.sh`, `rhel_sys.sh`) providing common logging, distro detection, and package management helpers.
- `max_root.sh`: Cross-platform pre-upgrade storage maximization utility reclaiming disk space across systemd journals, logs, caches, and package manager databases.
- `disktemp.sh`: Enterprise storage hardware temperature audit utility supporting NVMe, SATA, SAS, and USB drives across RHEL, Debian, and Proxmox with JSON telemetry export.
- `list_disks.sh`: Storage topology, hardware asset inventory, and health audit utility correlating filesystem mounts, ZFS pools, LVM groups, SMART health, and SSD endurance metrics.
- `dnf_check.sh`: DNF wrapper with cross-version SQLite integrity checks, safe cache clearing, and post-transaction kernel sync.
- `kernel-default.sh`: Deterministic GRUB boot kernel manager and cleanup utility for Enterprise Linux.
- `cloudmgr/vm-backup-gdrive.sh`: Virtual Machine snapshot and disaster recovery orchestrator managing live SQLite backups, system manifests, streaming zstd/AES-256 GPG encryption, Google Drive sync, and dual retention.
- `cloudmgr/check-container-updates.sh`: Container lifecycle monitor and update automation tool for systemd Quadlets with registry dry-run inspection and email alerts.
- `cloudmgr/check-pkg-updates.sh`: Non-intrusive upstream repository inspection tool correlating security errata, bugfixes, and HTML advisory notifications for Enterprise Linux.

### 6. Python Engineering & Lifecycle (`/python_systools`)
A comprehensive suite for managing multi-version Python environments and package health.
- `python_build.sh`: Isolated, relocatable, and production-grade Python 3.13+ build orchestrator.
- `python_buildenv.sh`: Centralized orchestration layer for Python RPM packaging and metadata synchronization.
- `py_module_manager.sh`: Modular utility to manage Python package lifecycles (backup/restore/sync).
- `inspect_python.py`: Quality Auditor for newly built Python binaries (Path isolation, ELF audit).
- `python_sysdiags.py`: Comprehensive verification of Python interpreter build and OpenSSL linkage.
- `pathfix.py`: Efficient shebang correction for Python scripts.
- `python_pkg_tester.py`: Analyzes Python modules for "soundness" and best practices.
- `python_pkg_info.py`: Detailed inspection of installed Python package metadata.
- `python_pkg_upgrader.py`: Utility for bulk upgrades of outdated Python modules.
- `python_pkg_parser.py`: AST-based analysis of project dependencies.
- `check_crypto_symbols.py`: Verification of OpenSSL symbol availability in custom builds.
- `python_env.inc` / `python_jobexec.sh`: Environment isolation and job execution framework.
- `python_pkg_utils.py`: Shared backend for package analysis and metadata resolution.

### 7. Client Connectivity Tools (`/client_tools`)
Specialized utilities for end-user environment management.
- `CitrixTool.ps1`: Citrix Workspace Backup & Restore CLI Utility.
- `md2pdf.sh`: High-performance, concurrent Markdown to PDF batch converter (using a custom Node.js compiler with Puppeteer browser rendering).
- `generate_pdf.sh`: High-performance, concurrent Office to PDF batch converter (using LibreOffice headless rendering, preserving original file modification timestamps for compliance auditing, and outputting NDJSON logs).
- `pdf_text-extractor.sh`: High-performance, concurrent layout-preserved plain text extractor from PDF documents, supporting single-file/batch operations, throttle concurrency, and NDJSON logging.

### 8. Network & Diagnostic Tools (`/diags`)
Specialized network probing and cryptographic validation diagnostics.
- `jtlstester/JTLSTester.java`: High-performance, concurrent Java-based TLS diagnostics, trust chain validation, and cartesian target probing utility.

## Standards & Documentation

The codebase follows the standards:
- **Inline Documentation:** Every script contains a header detailing Objectives, Core Components, and Data Flows.
- **Error Handling:** Strict execution modes (`set -euo pipefail`) and localized scoping are enforced.
- **Idempotency:** Scripts are designed to be run repeatedly without side effects.
- **Isolation:** Heavy use of RPATH, custom SONAMEs, and isolated prefixes to prevent system-wide conflicts.