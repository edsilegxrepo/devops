# Python Quality Auditor: inspect_python.py

`inspect_python.py` is a specialized "Strict Quality Auditor" designed to verify the integrity and isolation of a newly built Python binary. It is intended to be executed by the target interpreter during the `validate` phase of the build process (e.g., within an RPM spec or a build orchestration script).

## Primary Objectives

The auditor ensures that the Python build is **production-ready**, **fully isolated**, and **relocatable** by performing deep inspections at multiple levels:

1.  **Binary Isolation**: Verifies that every ELF binary (`python3`, extension modules) has correct `RPATH`/`RUNPATH` headers pointing to isolated `/opt` paths and uses `$ORIGIN` for relocatability.
2.  **State Isolation**: Audits internal Python variables (`sys.prefix`, `sysconfig` paths) to ensure no build-time leaks or system path dependencies.
3.  **Path Isolation**: Confirms `sys.path` is free from references to the source build directory.
4.  **Functional Integrity**: Validates that core extensions (SSL, SQLite, Expat, Hashlib) and core packages (Cython, CFFI, Requests, Dateutil) are not only importable but also functionally operational.
5.  **Free-Threading (MT) Audit**: Detects and reports the GIL status and Free-Threading flags for compatibility verification (Python 3.13+).

---

## Technical Audit Layers

### 1. Deep Binary Isolation Audit
The auditor recursively scans the installation prefix for all ELF files and performs the following checks:
- **Header Integrity & Dependency-Aware Isolation**: Uses `readelf -d` to verify `RPATH` markers. The auditor intelligently distinguishes between binaries that **REQUiRE** isolation (those linking against **libpython**, **libssl**, **libcrypto**, **libexpat**, **libsqlite3**) and those that only link against standard OS libs (like `libc`). This prevents false positives on third-party extension modules.
- **Dynamic Dependency Audit**: Uses `ldd` simulation to verify that critical libraries resolve to the isolated prefix and **never** to system paths like `/usr/lib64/`.

### 2. Internal State Audit
Verifies that the interpreter's internal state reflects its isolated location:
- **Prefix Consistency**: Ensures `sys.prefix`, `sys.base_prefix`, and `sys.executable` are rooted in the target installation directory.
- **Path Registry**: Audits `sysconfig` paths (stdlib, platlib, etc.) to prevent leakage into the host OS.

### 3. Functional Verification
Executes real-world operations for mission-critical modules:
- **SSL/TLS**: Creates a default context and validates the linked OpenSSL version.
- **Hashlib**: Performs a SHA256 consistency check (verified against `ac0a3dfd...`).
- **SQLite**: Executes memory-based database operations.
- **Expat**: Parses sample XML to confirm parser integrity.
- **IT Business Bundle**: Verifies successful initialization of 25 core modules, including **Cython**, **CFFI**, **Requests**, **Dateutil**, **pip-tools** (`piptools`), and concurrency modules (**_thread**, **_multiprocessing**) for free-threading (MT) environments.

---

## Usage & Execution

### Execution Example
The script must be executed by the **target interpreter** (the one being validated) to ensure the audit reflects the actual runtime state. 

To confirm total isolation, always execute with an unset `LD_LIBRARY_PATH`. For detailed engineering reviews, use the **`--verbose`** flag:

```bash
# Explicitly clear environment libraries
unset LD_LIBRARY_PATH

# Run the auditor with detailed engineering logs
/opt/lib/python3/bin/python3.13 /usr/src/redhat/SPECS/inspect_python.py --verbose
```

### Understanding the Output

The auditor produces a structured report categorized by audit scope:

#### 1. Core Environment Report
Displays the version and `sysconfig` paths. This confirms that the interpreter has correctly registered the `/opt/lib/python3` prefix and is looking for its standard library in the correct, isolated locations (`lib64/python3.13`).

#### 2. Path & Metadata Isolation
- **`SUCCESS: All 25 core modules imported successfully.`**: Confirms successful initialization of the standard library and the "IT Business Bundle" (Cython, CFFI, Requests, pip-tools, etc.), including critical concurrency modules for 3.14+ MT builds.
- **`SUCCESS: PLATLIBDIR is 'lib64'`**: Verifies adherence to the EL-type standard for architecture-specific modules.

#### 3. Functional Integrity Tests
- **`SUCCESS: ... functional test passed`**: Executes real-world XML parsing (Expat), DB operations (SQLite), and cryptographic hands-hakes (SSL/Hashlib). This proves that the binary is not just "present" but "functional" and correctly linked to its private libraries.

- **`SUCCESS: Cython/CFFI functional test passed`**: Confirms that the high-level language interfaces and FFI backends are correctly integrated into the isolated environment.

#### 4. Deep Binary Isolation Audit
- **`INFO: Audited XX ELF binaries`**: Confirms a recursive scan of all `.so` and executable files in the prefix.
- **`INFO: [OK] ... (System dependencies only; no RPATH required: [...])`**: Indicates the dependency-aware auditor identified a safe system binary and bypassed redundant RPATH checks.
- **`SUCCESS: All ELF binaries are fully isolated...`**: Verifies that headers contain `$ORIGIN` and that dynamic resolution avoids `/usr/lib64/` and `/usr/src/`. any failure here indicates a non-portable build.

#### 5. Core Variable Isolation Audit
- **`SUCCESS: All core internal variables are correctly isolated`**: Confirms that internal state variables like `sys.prefix` and `sys.base_prefix` are correctly rooted, preventing the interpreter from "wandering" into system directories.

#### 6. Threading & GIL Audit (3.13+)
- **`INFO: sys._is_gil_enabled(): ...`**: Reports the runtime GIL status (Standard vs. Free-Threading).
- **`INFO: sys.flags.nogil: ...`**: Reports the state of the `--nogil` runtime flag (if available).
- **`DEBUG: sysconfig Py_GIL_DISABLED: ...`**: (Verbose only) Reports the build-time configuration intent.

### Final Result
- **`FINAL RESULT: VERIFICATION PASSED`**: The build is fully compliant and ready for redistribution.
- **`FINAL RESULT: VERIFICATION FAILED`**: One or more audits failed. The build is contaminated and should be rejected.

### Sample Audit Output

Below is an example of a successful audit pass on a compliant Python 3.13.13 build:

```text
--- Core Environment Report ---
Version:      3.13
Build Date:   None

--- System Paths (sysconfig) ---
stdlib      : /opt/lib/python3/lib64/python3.13
platstdlib  : /opt/lib/python3/lib64/python3.13
purelib     : /opt/lib/python3/lib/python3.13/site-packages
platlib     : /opt/lib/python3/lib64/python3.13/site-packages
include     : /opt/lib/python3/include/python3.13
-------------------------------

--- Python Build deep-inspection: 3.13.13 ---
Interpreter: /opt/lib/python3/bin/python3.13
Prefix:      /opt/lib/python3
SUCCESS: sys.path is isolated from build-time sources.
SUCCESS: PLATLIBDIR is 'lib64'
SUCCESS: All 25 core modules imported successfully.
SUCCESS: Expat functional test passed (XML parsing ok)
SUCCESS: SQLite functional test passed (Memory DB ops ok)
INFO: Linked OpenSSL Version: OpenSSL 3.6.2 7 Apr 2026
SUCCESS: SSL functional test passed (Context creation ok)
SUCCESS: Hashlib functional test passed (SHA256 ok)
SUCCESS: Cython functional test passed (Version: 3.2.4)
SUCCESS: CFFI functional test passed (FFI instantiation ok)
SUCCESS: Requests functional test passed (Version: 2.33.1)
SUCCESS: Dateutil functional test passed (Arithmetic ok)
--- Deep Binary Isolation Audit: /opt/lib/python3 ---
INFO: Audited 86 ELF binaries.
SUCCESS: All ELF binaries are fully isolated and use internal RPATHs.
--- Core Variable Isolation Audit: /opt/lib/python3 ---
SUCCESS: All core internal variables are correctly isolated.
INFO: sys._is_gil_enabled(): Enabled (Standard)
-------------------------------------------
FINAL RESULT: VERIFICATION PASSED
```

### Exit Codes
- **0**: All audits passed successfully.
- **1**: One or more critical isolation violations detected (Build-blocking failure).

---

## Maintainability & Best Practices

The script follows modern Python standards (PEP 8) and includes several robustness features:
- **Pre-flight Checks**: Verifies availability of system tools (`readelf`, `ldd`) before starting.
- **Centralized Configuration**: Core isolation lists and forbidden paths are defined as top-level constants for easy adjustment.
- **Safe Subprocess Handling**: Uses `subprocess.run` with list-based arguments to avoid shell injection and ensure reliable output capture.
- **Resilient Walking**: Handles permission errors and symbolic links gracefully during recursive scans.
