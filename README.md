# DevOps Scripts and Utilities
# v1.1.2  2026/04/16

This repository is a centralized collection of DevOps scripts and utilities designed to streamline and automate various aspects of code and system deployments. The tools included here are robust, reusable, and well-documented to support a wide range of development and operational workflows.

## Primary Objectives

- **Automation:** Reducing manual effort and improving consistency in deployment processes.
- **Standardization:** Establishing common practices and tools for infrastructure management.
- **Efficiency:** Accelerating development cycles by providing reliable and easy-to-use utilities.
- **Isolation:** Implementing "Least Privilege" and side-by-side installations for critical system components (e.g., OpenSSL, Python).

## Repository Structure

### 1. Build & Validation Tasks (`/build_tasks`)
Automation for building, auditing, and validating core system components.
- `code_audit.sh`: Multi-tiered, polyglot static analysis and security audit framework.
- `gobuild_code-analyzers.sh`: Automation for compiling Go-based static analysis tools.
- `openssl_build.sh`: A multi-mode (RPM/Archive/All) script for isolated OpenSSL builds.
- `sqlite3_validate.sh`: A suite for verifying SQLite 3 binary builds against specs.

### 2. Git Management (`/git_repomgr`)
Tools for orchestrating large-scale repository synchronization and user management.
- `git_sync.sh`: A hardened, singleton script for complex Git sync operations.
- `git_autosync.sh`: A parallel, recursive utility for syncing entire workspace trees.
- `git_userchange.sh`: A surgical tool for rewriting Git history/authorship.

### 3. OCI & Container Tools (`/oci_tools`)
Utilities for interacting with Open Container Initiative (OCI) images without a full daemon.
- `extract_oci.sh`: Downloads, verifies, and extracts OCI image filesystems.

### 4. OS & System Configuration (`/os_sys`)
Low-level system adjustments and service delegations.
- `IISDelegationSet.ps1`: Implements granular management delegation for IIS.
- `IISDelegationUndo.ps1`: Reverts IIS management delegation for a specific group.
- `IISDelegationValidate.ps1`: Verifies the IIS management delegation for a specific group.
- `set_nomodeset.sh`: Ensures consistent headless boot parameters across OS families.

### 5. Python Engineering & Lifecycle (`/python_systools`)
A comprehensive suite for managing multi-version Python environments and package health.
- `python_build.sh`: Isolated, relocatable, and production-grade Python 3.13+ build orchestrator.
- `py_module_manager.sh`: Modular utility to manage Python package lifecycles (backup/restore/sync).
- `inspect_python.py`: Quality Auditor for newly built Python binaries (Path isolation, ELF audit).
- `python_sysdiags.py`: Comprehensive verification of Python interpreter build and OpenSSL linkage.
- `pathfix.py`: Surgical shebang correction for Python scripts.
- `python_pkg_tester.py`: Analyzes Python modules for "soundness" and best practices.
- `python_pkg_info.py`: Detailed inspection of installed Python package metadata.
- `python_pkg_upgrader.py`: Utility for bulk upgrades of outdated Python modules.
- `python_pkg_parser.py`: AST-based analysis of project dependencies.
- `check_crypto_symbols.py`: Verification of OpenSSL symbol availability in custom builds.
- `python_env.inc` / `python_jobexec.sh`: Environment isolation and job execution framework.
- `python_pkg_utils.py`: Shared backend for package analysis and metadata resolution.

### 6. Client Connectivity Tools (`/client_tools`)
Specialized utilities for end-user environment management.
- `CitrixTool.ps1`: Citrix Workspace Backup & Restore CLI Utility.

## Standards & Documentation

The codebase follows the standards:
- **Inline Documentation:** Every script contains a header detailing Objectives, Core Components, and Data Flows.
- **Error Handling:** Strict execution modes (`set -euo pipefail`) and localized scoping are enforced.
- **Idempotency:** Scripts are designed to be run repeatedly without side effects.
- **Isolation:** Heavy use of RPATH, custom SONAMEs, and isolated prefixes to prevent system-wide conflicts.