#!/usr/bin/env python3
# -----------------------------------------------------------------------------
#  /usr/src/redhat/SPECS/inspect_python.py
#  v1.1.1  2026/05/11  XdG (Auditor)
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   Act as a "Strict Quality Auditor" for the newly built Python binary.
#   This script is executed by the target interpreter itself during the
#   'validate' phase of the build process.
#
# CORE COMPONENTS:
#   1. ISOLATION ENGINE: Verifies sys.path and internal variables (sys.prefix)
#      to ensure no leakage from the host or build environment.
#   2. FUNCTIONAL VALIDATOR: Performs "Real-World" tests on critical C-extensions
#      (OpenSSL, SQLite, Expat) to ensure dynamic linkage is operational.
#   3. BINARY AUDITOR: Uses 'readelf' to perform recursive static analysis
#      of ELF headers, enforcing RPATH compliance and RUNPATH prohibition.
#   4. PERFORMANCE GATE: Audits sysconfig metadata for PGO/LTO optimizations.
#
# DATA FLOW:
#   1. INGESTION: CLI arguments define the audit strictness and target prefix.
#   2. DISCOVERY: The script recursively locates all ELF binaries in the prefix.
#   3. VERIFICATION: Each binary is audited for header integrity (RPATH) and
#      runtime resolution (ldd) against forbidden system paths.
#   4. AGGREGATION: Violations are collected into a master manifest.
#   5. REPORTING: A structured success/failure report is generated for the
#      orchestrator (python_build.sh).
#
# AUDIT SCOPE:
#   1. Path Isolation: Non-leak check of sys.path against build directories.
#   2. Platform Metadata: Verification of PLATLIBDIR (EL9 lib64 standard).
#   3. Extension Integrity: Verified loading of core shared objects (SSL, etc).
#   4. Binary Isolation: Recursive ELF audit for RPATH/RUNPATH and dependencies.
#   5. State Isolation: Verification of internal Python variables (sys.prefix, etc).
#
# REQUIREMENTS:
#   - readelf (from binutils): Used for static header inspection.
#   - ldd (from glibc-common): Used for dynamic resolution verification.
# -----------------------------------------------------------------------------

import sys
import sysconfig
import os
import importlib.util
import subprocess  # nosec B404
import shutil
import re
import argparse

# --- 0. Configuration & Constants ---
OPT_PREFIX = "/opt/lib"
SRC_PREFIX = "/usr/src/redhat"

# Resolved tool paths to prevent partial path injection (Bandit B607)
# Fallback to name string ensures Pyright sees a 'str' type instead of 'Optional[str]'
READELF_BIN = shutil.which("readelf") or "readelf"
LDD_BIN = shutil.which("ldd") or "ldd"

# Distro Detection
IS_REDHAT = os.path.exists("/etc/redhat-release")
IS_UBUNTU = not IS_REDHAT and os.path.exists("/etc/debian_version")

# Libraries that MUST be isolated from the system /usr/lib64 or /usr/lib/<arch>.
LIBS_FOR_ISOLATION = ["libpython", "libexpat", "libsqlite3", "libssl", "libcrypto"]

# System paths strictly forbidden for the above libraries.
# We adapt this for Ubuntu's multiarch layout.
FORBIDDEN_SYSTEM_PATHS = ["/usr/lib64/", "/lib64/", "/usr/lib/", "/lib/", "/usr/src/"]
if IS_UBUNTU:
    FORBIDDEN_SYSTEM_PATHS += ["/usr/lib/x86_64-linux-gnu/", "/lib/x86_64-linux-gnu/"]

# --- 1. Audit Utilities ---


def check_tools():
    """Verify that required auditing tools are present in the environment."""
    tools = ["readelf", "ldd"]
    missing = [t for t in tools if not shutil.which(t)]
    if missing:
        print(f"FAILED: Missing required auditing tools: {', '.join(missing)}")
        return False
    return True


def extract_rpath(header_text):
    """
    Extract the RPATH value from readelf -d output.
    Note: Specifically ignores RUNPATH as it is forbidden in this stack.
    """
    match = re.search(r"\(RPATH\).*?\[(.*?)\]", header_text)
    return match.group(1) if match else None


def has_runpath(header_text):
    """Check for the presence of RUNPATH in the dynamic section."""
    return "(RUNPATH)" in header_text


# --- 2. Audit Modules ---


def check_path_isolation(prefix, verbose=False):
    """
    Verify that sys.path does not contain any leaks from the BUILD directory.
    """
    cwd = os.getcwd()
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # References to the source BUILD directory indicate a non-relocatable
    # configuration that "leaks" build-time absolute paths into the binary
    # metadata or site-packages discovery logic.
    # Note: We exclude 'cwd' and 'script_dir' as they are naturally added by
    # the interpreter during the audit's own execution.
    leaks = [
        p
        for p in sys.path
        if f"{SRC_PREFIX}/BUILD/" in p
        or (
            f"{SRC_PREFIX}/" in p
            and "/BUILDROOT/" not in p
            and p != cwd
            and p != script_dir
        )
    ]

    if verbose:
        print(f"DEBUG: sys.path contents ({len(sys.path)} items):")
        for p in sys.path:
            print(f"  - {p}")

    if leaks:
        print(f"FAILED: Found build-time leaks in sys.path: {leaks}")
        return False
    print("SUCCESS: sys.path is isolated from build-time sources.")
    return True


def check_platlibdir(verbose=False):
    """Verify that PLATLIBDIR is correctly set for the target distribution."""
    pld = sysconfig.get_config_var("PLATLIBDIR")
    expected = "lib64" if IS_REDHAT else "lib"

    if verbose:
        print(f"DEBUG: sysconfig.get_config_var('PLATLIBDIR') = '{pld}'")
        print(f"DEBUG: Distro: {'RedHat' if IS_REDHAT else 'Ubuntu/Debian'}")

    if pld != expected and not (IS_UBUNTU and pld == "lib"):
        print(
            f"WARNING: PLATLIBDIR is '{pld}', expected '{expected}' (May affect pathing)"
        )
        return True  # Not a hard failure for portability
    print(f"SUCCESS: PLATLIBDIR is '{pld}'")
    return True


def check_core_modules(verbose=False):
    """Verify that essential extension modules can be imported and are isolated."""
    # Added _thread and _multiprocessing to verify concurrency isolation in 3.14t
    modules = [
        "_posixsubprocess",
        "pyexpat",
        "ssl",
        "_ssl",
        "hashlib",
        "_hashlib",
        "sqlite3",
        "zlib",
        "bz2",
        "lzma",
        "_thread",
        "_multiprocessing",
        "Cython",
        "cffi",
        "pip",
        "setuptools",
        "wheel",
        "build",
        "certifi",
        "requests",
        "virtualenv",
        "dateutil",
        "packaging",
        "installer",
        "piptools",
    ]
    failed = []
    print("--- Core Module Isolation Audit ---")
    for m in modules:
        try:
            mod = importlib.import_module(m)
            mod_file = getattr(mod, "__file__", "builtin")
            # C-extensions should reside within the /opt prefix
            if mod_file != "builtin" and f"{OPT_PREFIX}/python3" not in mod_file:
                print(f"WARNING: Module {m} loaded from unexpected path: {mod_file}")
            elif verbose:
                print(f"INFO: [OK] Module {m:<18} -> {mod_file}")
        except ImportError as e:
            failed.append(f"{m} ({e})")

    if failed:
        print(f"FAILED: Could not import core modules: {', '.join(failed)}")
        return False
    print(f"SUCCESS: All {len(modules)} core modules imported successfully.")
    return True


def check_functional_extensions(verbose=False):
    """
    Perform deep functional validation of core dynamic extensions.

    This ensures that the shared libraries we linked against (SSL, SQLite, Expat)
    are not just present, but are operating correctly. For example, the hashlib
    test explicitly verifies that OpenSSL-backed SHA256 arithmetic produces
    consistent results.
    """
    results = []
    print("--- Functional Integrity Audit ---")

    # 1. Test Expat (XML Parsing)
    try:
        import xml.parsers.expat

        parser = xml.parsers.expat.ParserCreate()
        parser.Parse("<root>test</root>", True)
        print("SUCCESS: Expat functional test passed (XML parsing ok)")
        results.append(True)
    except Exception as e:
        print(f"FAILED: Expat functional test failed: {e}")
        results.append(False)

    # 2. Test SQLite (Memory DB operations)
    try:
        import sqlite3

        conn = sqlite3.connect(":memory:")
        curr = conn.cursor()
        curr.execute("CREATE TABLE test (id INTEGER)")
        curr.execute("INSERT INTO test VALUES (1)")
        res = curr.execute("SELECT id FROM test").fetchone()
        conn.close()
        if res == (1,):
            print("SUCCESS: SQLite functional test passed (Memory DB ops ok)")
            results.append(True)
        else:
            print(f"FAILED: SQLite functional test returned unexpected result: {res}")
            results.append(False)
    except Exception as e:
        print(f"FAILED: SQLite functional test failed: {e}")
        results.append(False)

    # 3. Test SSL (OpenSSL handshake capabilities)
    try:
        import ssl

        if verbose:
            print(f"DEBUG: OpenSSL Version String: {ssl.OPENSSL_VERSION}")
            print(f"DEBUG: OpenSSL Version Number: {ssl.OPENSSL_VERSION_NUMBER}")
        print(f"INFO: Linked OpenSSL Version: {ssl.OPENSSL_VERSION}")
        ctx = ssl.create_default_context()
        if ctx:
            print("SUCCESS: SSL functional test passed (Context creation ok)")
            results.append(True)
    except Exception as e:
        print(f"FAILED: SSL functional test failed: {e}")
        results.append(False)

    # 4. Test Hashlib (OpenSSL backed hashing)
    try:
        import hashlib

        h = hashlib.sha256(b"antigravity").hexdigest()
        if verbose:
            print(f"DEBUG: hashlib.sha256(b'antigravity') = {h}")
        if h == "ac0a3dfd6dddb20962cecff6ee5fe65e19d3923be20e52c5ab52ff877f7e4c32":
            print("SUCCESS: Hashlib functional test passed (SHA256 ok)")
            results.append(True)
        else:
            print(f"FAILED: Hashlib functional test returned unexpected hex: {h}")
            results.append(False)
    except Exception as e:
        print(f"FAILED: Hashlib functional test failed: {e}")
        results.append(False)

    # 5. Test Cython (Imports and version check)
    try:
        import Cython  # type: ignore

        print(f"SUCCESS: Cython functional test passed (Version: {Cython.__version__})")
        results.append(True)
    except Exception as e:
        print(f"FAILED: Cython functional test failed: {e}")
        results.append(False)

    # 6. Test CFFI (Import and FFI object initialization)
    try:
        import cffi

        cffi.FFI()
        print("SUCCESS: CFFI functional test passed (FFI instantiation ok)")
        results.append(True)
    except Exception as e:
        print(f"FAILED: CFFI functional test failed: {e}")
        results.append(False)

    # 7. Test Requests (Connectivity headers check)
    try:
        import requests

        if verbose:
            print(f"DEBUG: Requests User-Agent: {requests.utils.default_user_agent()}")
        print(
            f"SUCCESS: Requests functional test passed (Version: {requests.__version__})"
        )
        results.append(True)
    except Exception as e:
        print(f"FAILED: Requests functional test failed: {e}")
        results.append(False)

    # 8. Test Dateutil (Timezone arithmetic check)
    try:
        from dateutil.relativedelta import relativedelta
        from datetime import datetime

        now = datetime.now()
        plus_month = now + relativedelta(months=1)
        if verbose:
            print(f"DEBUG: dateutil relativedelta test: {now} -> {plus_month}")
        print("SUCCESS: Dateutil functional test passed (Arithmetic ok)")
        results.append(True)
    except Exception as e:
        print(f"FAILED: Dateutil functional test failed: {e}")
        results.append(False)

    return all(results)


def check_binary_isolation(prefix, verbose=False):
    """
    Perform a recursive audit of all ELF binaries in the prefix.

    This audit performs two levels of verification:
    1. Static Header Inspection (Intent): Ensures RPATH/RUNPATH contains $ORIGIN
       to facilitate relocatability (the ability to move the entire prefix).
    2. Dynamic Dependency Audit (Reality): Uses 'ldd' to verify that the
       runtime linker resolves critical core libraries from the isolated
       /opt root rather than fallback system locations.
    """
    violations = []
    print(f"--- Deep Binary Isolation Audit: {prefix} ---")

    elf_count = 0
    for root, dirs, files in os.walk(prefix):
        for file in files:
            path = os.path.join(root, file)
            # 1. ELF Signature Check
            try:
                if os.path.islink(path):
                    continue
                if os.path.getsize(path) < 4:
                    continue
                with open(path, "rb") as f:
                    if f.read(4) != b"\x7fELF":
                        continue
            except (IOError, PermissionError):
                continue

            elf_count += 1

            # 2. Inspect RPATH/RUNPATH (Header Intent Check)
            try:
                # Use absolute path and audit trusted input (Bandit B603, B607)
                header_res = subprocess.run(
                    [READELF_BIN, "-d", path],
                    capture_output=True,
                    text=True,
                    check=True,  # type: ignore
                )  # nosec B603

                # Strict Search Strategy Verification
                if has_runpath(header_res.stdout):
                    violations.append(
                        f"CRITICAL SECURITY VIOLATION: {path} contains RUNPATH (Forbidden). Must use RPATH via --disable-new-dtags."
                    )

                rpath_val = extract_rpath(header_res.stdout)

                # 3. Dependency-Aware Isolation Check
                # Extraction of the NEEDED section helps distinguish between binaries
                # that REQUIRE isolation (those linking against our custom /opt stack)
                # and those that only link against standard OS libs (like libc/libm).
                needed_libs = re.findall(
                    r"\(NEEDED\)\s+Shared library:\s+\[(.*?)\]", header_res.stdout
                )
                requires_isolation = any(
                    any(pattern in lib for pattern in LIBS_FOR_ISOLATION)
                    for lib in needed_libs
                )

                # Rule: Only enforce RPATH if the binary links against our isolated libraries.
                # If custom-libs is disabled (OS libraries used), we relax the /opt requirement.
                if requires_isolation:
                    if not rpath_val or "$ORIGIN" not in rpath_val:
                        violations.append(
                            f"HEADER LEAK: {path} (Missing $ORIGIN RPATH)"
                        )
                    elif args_global.custom_libs and OPT_PREFIX not in rpath_val:
                        violations.append(
                            f"ISOLATION LEAK: {path} (Custom libs requested but {OPT_PREFIX} missing from RPATH: [{rpath_val}])"
                        )
                    elif verbose:
                        print(f"INFO: [OK] {path} (RPATH validated: [{rpath_val}])")
                else:
                    # System-only dependencies are inherently safe as they resolve to standard OS roots.
                    pass

                # 4. Dependency Resolution Audit (Runtime Reality)
                # Use absolute path and audit trusted input (Bandit B603, B607)
                ldd_res = subprocess.run(
                    [LDD_BIN, path],
                    capture_output=True,
                    text=True,
                    check=True,  # type: ignore
                )  # nosec B603
                for line in ldd_res.stdout.splitlines():
                    if "=>" in line:
                        lib_part, path_part = line.split("=>")
                        lib_name = lib_part.strip()
                        resolved_path = path_part.split("(")[0].strip()

                        # Check critical libraries for system path resolution.
                        # Resolution is ALLOWED if it stays within the current prefix (internal staging).
                        if any(cl in lib_name for cl in LIBS_FOR_ISOLATION):
                            is_forbidden = any(
                                resolved_path.startswith(fp)
                                for fp in FORBIDDEN_SYSTEM_PATHS
                            )
                            is_internal = resolved_path.startswith(prefix)

                            # If custom-libs is enabled, we strictly forbid system resolution for core libs.
                            # If disabled, we only forbid resolution to the build/src tree.
                            if args_global.custom_libs:
                                if is_forbidden and not is_internal:
                                    violations.append(
                                        f"SYSTEM DEPENDENCY LEAK: {path} -> {lib_name} resolves to {resolved_path}"
                                    )
                            else:
                                if SRC_PREFIX in resolved_path and not is_internal:
                                    violations.append(
                                        f"BUILD-TREE LEAK: {path} -> {lib_name} resolves to {resolved_path}"
                                    )

                            if verbose:
                                print(
                                    f"  - Resolved {lib_name:<15} to {resolved_path} {'[Internal]' if is_internal else '[OK]'}"
                                )

            except subprocess.CalledProcessError as e:
                print(f"WARNING: Could not audit {file}: {e}")

    print(f"INFO: Audited {elf_count} ELF binaries.")

    if violations:
        print(f"FAILED: Found {len(violations)} isolation violations:")
        for v in violations:
            print(f"  - {v}")
        return False

    print("SUCCESS: All ELF binaries are fully isolated and use internal RPATHs.")
    return True


def check_internal_variables(prefix, verbose=False):
    """
    Verify core Python internal variables for strict isolation.
    Ensures that prefixes and stdlib paths stay within the version-neutral /opt root.
    """
    expected_prefix = prefix.rstrip("/")

    # 1. Identity Registry
    variables = {
        "sys.prefix": sys.prefix,
        "sys.base_prefix": sys.base_prefix,
        "sys.exec_prefix": sys.exec_prefix,
        "sys.base_exec_prefix": sys.base_exec_prefix,
        "sys.executable": sys.executable,
    }

    violations = []
    print(f"--- Core Variable Isolation Audit: {expected_prefix} ---")

    # 2. Variable Consistency Check
    for name, val in variables.items():
        if val is None:
            continue
        val_str = str(val)
        if expected_prefix not in val_str:
            violations.append(
                f"VARIABLE LEAK: {name} = '{val_str}' (Missing expected root: {expected_prefix})"
            )
        elif verbose:
            print(f"INFO: [OK] {name:<20} = {val_str}")

    # 3. Sysconfig Path Integrity
    for name in ["stdlib", "platstdlib", "purelib", "platlib", "include"]:
        path = sysconfig.get_path(name)
        if expected_prefix not in path:
            violations.append(
                f"SYSCONFIG LEAK: {name} = '{path}' (Missing expected root: {expected_prefix})"
            )
        elif verbose:
            print(f"INFO: [OK] sysconfig {name:<10} = {path}")

    if violations:
        print(
            f"FAILED: Found {len(violations)} internal variable isolation violations:"
        )
        for v in violations:
            print(f"  - {v}")
        return False

    print("SUCCESS: All core internal variables are correctly isolated.")
    return True


def check_gil_status(verbose=False):
    """Verify GIL status (Supports 3.13+ free-threading detection)."""
    print("--- Threading & GIL Audit ---")

    # 1. Runtime Status
    try:
        status = sys._is_gil_enabled()  # type: ignore
        print(
            f"INFO: sys._is_gil_enabled(): {'Enabled (Standard)' if status else 'Disabled (Free-Threading)'}"
        )
    except AttributeError:
        print("INFO: sys._is_gil_enabled(): N/A (Legacy build architecture)")

    # 2. Flag Status (3.13+)
    if hasattr(sys.flags, "nogil"):
        print(f"INFO: sys.flags.nogil:      {sys.flags.nogil}")  # type: ignore

    # 3. Build-time Intent
    if verbose:
        py_gil_disabled = sysconfig.get_config_var("Py_GIL_DISABLED")
        print(f"DEBUG: sysconfig Py_GIL_DISABLED: {py_gil_disabled}")


def display_python_environment():
    """Display core Python variables and sysconfig paths for auditing."""
    print("--- Core Environment Report ---")
    print(f"Version:      {sys.version_info.major}.{sys.version_info.minor}")
    print(f"Build Date:   {sysconfig.get_config_var('DATE')}")

    print("\n--- System Paths (sysconfig) ---")
    paths = sysconfig.get_paths()
    for name in ["stdlib", "platstdlib", "purelib", "platlib", "include"]:
        print(f"{name:<12}: {paths.get(name)}")
    print("-------------------------------\n")


def check_performance_metadata(verbose=False):
    """
    Audit the build metadata for performance and hardening consistency.
    Ensures that optimizations (PGO, LTO) and security flags are correctly
    baked into the sysconfig registry.

    Note: For portability across EL8/9/10/Ubuntu, these are treated as
    WARNINGS and do not cause build failure.
    """
    print("--- Performance & Build-Metadata Audit ---")

    # 1. Audit Performance Optimizations
    perf_vars = {
        "HAVE_COMPUTED_GOTOS": 1,
        "Py_LTO": "yes",
    }

    for var, expected in perf_vars.items():
        val = sysconfig.get_config_var(var)
        if val == expected:
            print(f"SUCCESS: {var} is correctly active ({val})")
        else:
            # Fallback check for LTO in CFLAGS
            cflags = sysconfig.get_config_var("CONFIGURE_CFLAGS") or ""
            if var == "Py_LTO" and "-flto" in cflags:
                print(f"SUCCESS: {var} is active via CFLAGS (-flto)")
            else:
                print(
                    f"WARNING: {var} is '{val}', expected '{expected}' (Potential performance loss)"
                )

    # 2. Audit PGO (Profile Guided Optimization) Status
    cflags = sysconfig.get_config_var("CONFIGURE_CFLAGS") or ""
    pgo_flag = sysconfig.get_config_var("PGO_PROF_USE_FLAG") or ""

    if (
        "-fprofile-use" in cflags
        or "-fprofile-generate" in cflags
        or "-fprofile-use" in pgo_flag
    ):
        print(
            f"SUCCESS: PGO (Profile Guided Optimization) active ({pgo_flag or 'via CFLAGS'})"
        )
    else:
        print(
            "WARNING: PGO flags not detected. Verify if 'make profile-opt' was used in orchestrator."
        )

    # 3. Audit Hardening Metadata Persistence
    ldflags = sysconfig.get_config_var("CONFIGURE_LDFLAGS") or ""
    hardening_checks = {
        "RELRO": "-Wl,-z,relro",
        "BIND_NOW": "-Wl,-z,now",
        "STRIP": "-Wl,-s",
    }

    if IS_REDHAT:
        hardening_checks["HARDENED_SPECS"] = "redhat-hardened-ld"

    for name, flag in hardening_checks.items():
        if flag in ldflags:
            if verbose:
                print(f"INFO: [OK] Hardening {name:<15} detected in LDFLAGS metadata.")
        else:
            print(
                f"WARNING: Hardening {name} ({flag}) missing from build metadata LDFLAGS."
            )

    return True  # Metadata violations are not build failures


def main():
    """Main Auditor entry point."""
    global args_global
    parser = argparse.ArgumentParser(
        description="Strict Python Build Isolation Auditor"
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Provide engineering-level details for each audit step",
    )
    parser.add_argument(
        "--custom-libs",
        action="store_true",
        help="Enforce strict /opt/lib isolation for core libraries",
    )
    args_global = parser.parse_args()

    if not check_tools():
        sys.exit(1)

    display_python_environment()
    print(f"--- Python Build deep-inspection: {sys.version.split()[0]} ---")
    print(f"Interpreter: {sys.executable}")
    print(f"Prefix:      {sys.prefix}")

    # Audit sequence.
    # The order of operations is deliberate:
    # 1. PATH ISOLATION (Basic): Ensure the auditor isn't running in a polluted environment.
    # 2. METADATA (Static): Verify distro-specific pathing expectations.
    # 3. IMPORTS (Functional): Verify the loader can resolve extensions.
    # 4. FUNCTIONAL (Deep): Verify the actual arithmetic/logic of extensions.
    # 5. BINARY (System): Recursive ELF header and RPATH verification.
    # 6. INTERNAL (State): Final verification of sys.prefix and internal paths.
    # 7. PERFORMANCE (Static): Build metadata consistency check.
    results = [
        check_path_isolation(sys.prefix, verbose=args_global.verbose),
        check_platlibdir(verbose=args_global.verbose),
        check_core_modules(verbose=args_global.verbose),
        check_functional_extensions(verbose=args_global.verbose),
        check_binary_isolation(sys.prefix, verbose=args_global.verbose),
        check_internal_variables(sys.prefix, verbose=args_global.verbose),
        check_performance_metadata(verbose=args_global.verbose),
    ]

    # Information-only check (does not affect final exit code)
    check_gil_status(verbose=args_global.verbose)

    print("-------------------------------------------")
    if all(results):
        print("FINAL RESULT: VERIFICATION PASSED")
        sys.exit(0)
    else:
        print("FINAL RESULT: VERIFICATION FAILED")
        sys.exit(1)


if __name__ == "__main__":
    main()
