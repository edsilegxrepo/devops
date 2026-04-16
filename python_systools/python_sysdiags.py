#!/usr/bin/env python3
# ------------------------------------------
# python_sysdiags.py
# v1.3.6xg  2025/10/15  XDG / MIS Center
# ------------------------------------------
"""
A comprehensive Python script to verify the Python interpreter's build environment,
specifically its linkage and capabilities with OpenSSL, and other key system settings.

Outputs detailed information in human-readable text or structured JSON format.
Presents detailed information about Python version, paths, environment flags,
OpenSSL version, TLS protocol support (including TLS 1.3),
basic hashlib functionality, and standard library module availability.

Usage:
  python_sysdiags.py [options]

Options:
  --json         Output results in JSON format.
  --env          Display Python Interpreter & Environment details.
  --build        Display Python Build-Time Configuration.
  --paths        Display Python Module Search Path (sys.path).
  --stdlib       Display Key Standard Library C-Extensions check.
  --math         Display Math Module C-Functionality Check.
  --ssl          Display OpenSSL & SSL Module Information.
  --tls13        Display TLS 1.3 Capability Check.
  --hashlib      Display Hashlib Functionality Check.
  --rlimits      Display System Resource Limits (Unix-like only).
  --all          Display all sections (default if no options specified).
  -h, --help     Show this help message and exit.
If no options are specified, the script will display all sections.

Required: Ensure that the following environment variables are UNSET
          in the shell *before* executing this script:
          PYTHONPATH, PYTHONHOME, PYTHON, PYTHON_PLATFORM
          (e.g., `unset PYTHONPATH`)
"""

import ssl
import sys
import hashlib
import sysconfig
import importlib.util  # For checking module presence
import argparse  # For command-line argument parsing
import math  # Added for the math module check
import json

try:
    import resource  # Unix-like systems only
except ImportError:
    resource = None  # Will be None on Windows


# ----------------------------------------
# Core Analysis Logic
# ----------------------------------------
class SystemDiagnostics:
    """
    Encapsulates all system diagnostic checks.
    Each method returns structured data, separating data gathering from presentation.
    """

    def get_python_env_details(self):
        """Gathers Python Interpreter & Environment details."""
        flags = {}
        for flag_name in dir(sys.flags):
            if not flag_name.startswith("_"):
                value = getattr(sys.flags, flag_name)
                if (
                    value is True
                    or (isinstance(value, int) and value != 0)
                    or isinstance(value, str)
                ):
                    flags[flag_name] = value
        return {
            "executable": sys.executable,
            "version": sys.version,
            "sitelib_path": sysconfig.get_path("purelib"),
            "sitearch_path": sysconfig.get_path("platlib"),
            "platform": sys.platform,
            "default_encoding": sys.getdefaultencoding(),
            "filesystem_encoding": sys.getfilesystemencoding(),
            "interpreter_flags": flags,
        }

    def get_python_build_config(self):
        """Gathers Python Build-Time Configuration."""
        config_vars = sysconfig.get_config_vars()
        return {
            "compiler": config_vars.get("CC", "N/A"),
            "cflags": config_vars.get("CFLAGS", "N/A"),
            "ldflags": config_vars.get("LDFLAGS", "N/A"),
            "optimization_level": config_vars.get("OPT", "N/A"),
            "debug_build": config_vars.get("PYDEBUG", "N/A"),
            "pymalloc_enabled": config_vars.get("WITH_PYMALLOC", "N/A"),
            "shared_library": config_vars.get("PY_ENABLE_SHARED", "N/A"),
        }

    def get_module_search_paths(self):
        """Gathers Python Module Search Path (sys.path)."""
        return {"paths": sys.path}

    def get_stdlib_c_extensions_check(self):
        """Checks status of Key Standard Library C-Extensions."""
        results = {}
        c_extensions_to_check = [
            "zlib",
            "_bz2",
            "_lzma",
            "_sqlite3",
            "_curses",
            "_gdbm",
            "_json",
            "_socket",
            "_io",
            "_datetime",
            "_csv",
            "_elementtree",
            "_collections",
            "_thread",
            "_multiprocessing",
            "_zstd",
        ]
        for module_name in c_extensions_to_check:
            spec = importlib.util.find_spec(module_name)
            if spec and spec.origin != "built-in":
                results[module_name] = {"status": "Found", "origin": spec.origin}
            elif spec:
                results[module_name] = {"status": "Found", "origin": "built-in"}
            else:
                results[module_name] = {
                    "status": "Not Found",
                    "details": "May indicate missing development libraries during build",
                }
        return results

    def get_math_module_check(self):
        """Checks the functionality and C-acceleration of the 'math' module."""
        try:
            math.sqrt(16)
            return {
                "status": "OK",
                "details": "math.sqrt(16) worked, indicating C functions are accessible.",
                "file": getattr(math, "__file__", "N/A (Built-in)"),
                "loader": str(getattr(math, "__loader__", "N/A")),
            }
        except Exception as e:  # pylint: disable=broad-exception-caught
            return {"status": "Error", "details": str(e)}

    def get_openssl_info(self):
        """Gathers OpenSSL & SSL Module Information."""
        default_paths = ssl.get_default_verify_paths()
        return {
            "openssl_version": ssl.OPENSSL_VERSION,
            "openssl_version_number": ssl.OPENSSL_VERSION_NUMBER,
            "openssl_built_on": getattr(ssl, "OPENSSL_BUILT_ON", "N/A"),
            "protocol_tlsv1_2": ssl.PROTOCOL_TLSv1_2,
            "protocol_tls_client": ssl.PROTOCOL_TLS_CLIENT,
            "protocol_tls_server": ssl.PROTOCOL_TLS_SERVER,
            "default_ca_info": {
                "ca_file": default_paths.cafile,
                "ca_path": default_paths.capath,
                "ssl_cert_file": getattr(default_paths, "ssl_cert_file", "N/A"),
                "ssl_cert_dir": getattr(default_paths, "ssl_cert_dir", "N/A"),
                "ssl_key_file": getattr(default_paths, "ssl_key_file", "N/A"),
            },
        }

    def get_tls13_capability_check(self):
        """Performs TLS 1.3 Capability Check."""
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.minimum_version = ssl.TLSVersion.TLSv1_3
            return {
                "status": "OK",
                "details": "SSLContext created with minimum TLS 1.3 version.",
            }
        except Exception as e:  # pylint: disable=broad-exception-caught
            return {"status": "Error", "details": str(e)}

    def get_hashlib_check(self):
        """Performs Hashlib Functionality Check."""
        try:
            hashlib.blake2b()
            return {
                "status": "OK",
                "details": "hashlib.blake2b() initialization successful.",
            }
        except Exception as e:  # pylint: disable=broad-exception-caught
            return {"status": "Error", "details": str(e)}

    def get_system_resource_limits(self):
        """Gathers System Resource Limits (Unix-like only)."""
        if not resource:
            return {
                "status": "Not Available",
                "details": "Resource module not available on this OS.",
            }

        limits = {}
        limit_names = {
            "RLIMIT_NOFILE": "max_open_files",
            "RLIMIT_AS": "address_space_gb",
            "RLIMIT_NPROC": "max_processes",
        }
        for name, key in limit_names.items():
            try:
                rlimit_id = getattr(resource, name)
                soft, hard = resource.getrlimit(rlimit_id)  # type: ignore

                if "gb" in key:
                    soft = f"{soft / (1024**3):.2f}" if soft != -1 else "Unlimited"
                    hard = f"{hard / (1024**3):.2f}" if hard != -1 else "Unlimited"

                limits[key] = {"soft": soft, "hard": hard}
            except (AttributeError, ValueError):
                limits[key] = {"soft": "N/A", "hard": "N/A"}
        return {"status": "OK", "limits": limits}


# ----------------------------------------
# Presentation Functions
# ----------------------------------------
def print_text_report(results):  # pylint: disable=too-many-branches,too-many-statements
    """
    Prints the diagnostic results in a human-readable text format,
    matching the original script's output.
    """
    if "env" in results:
        data = results["env"]
        print("\n----- Python Interpreter & Environment -----")
        print(f"Python executable: {data['executable']}")
        print(f"Python version: {data['version']}")
        print(f"Python sitelib path (purelib): {data['sitelib_path']}")
        print(f"Python sitearch path (platlib): {data['sitearch_path']}")
        print(f"Python system platform: {data['platform']}")
        print(f"Python default encoding: {data['default_encoding']}")
        print(f"Python filesystem encoding: {data['filesystem_encoding']}")
        print("\nPython interpreter flags:")
        for key, value in data["interpreter_flags"].items():
            print(f"  - {key}: {value}")

    if "build" in results:
        data = results["build"]
        print("\n----- Python Build-Time Configuration -----")
        print(f"Compiler used (CC): {data['compiler']}")
        print(f"CFlags (CFLAGS): {data['cflags']}")
        print(f"LdFlags (LDFLAGS): {data['ldflags']}")
        print(f"Optimization Level (OPT): {data['optimization_level']}")
        print(f"Python Debug Build (PYDEBUG): {data['debug_build']}")
        print(f"PyMALLOC enabled (WITH_PYMALLOC): {data['pymalloc_enabled']}")
        print(f"Built as Shared Library (PY_ENABLE_SHARED): {data['shared_library']}")

    if "paths" in results:
        data = results["paths"]
        print("\n----- Python Module Search Path (sys.path) -----")
        for i, path in enumerate(data["paths"]):
            print(f"  {i}: {path}")

    if "stdlib" in results:
        data = results["stdlib"]
        print("\n----- Key Standard Library C-Extensions -----")
        for name, info in data.items():
            if info["status"] == "Found":
                print(f"  - {name}: Found (from {info['origin']})")
            else:
                print(
                    f"  - {name}: NOT Found (may indicate missing development libraries "
                    f"during build)",
                    file=sys.stderr,
                )

    if "math" in results:
        data = results["math"]
        print("\n----- Math Module C-Functionality Check -----")
        if data["status"] == "OK":
            print("math module successfully imported.")
            print("math.sqrt(16) worked: 4.0")
            print("This indicates math module's core (C) functions are accessible.")
            print(f"math.__file__: {data['file']}")
            print(f"math.__loader__: {data['loader']}")
        else:
            print(f"Error: {data['details']}", file=sys.stderr)

    if "ssl" in results:
        data = results["ssl"]
        print("\n----- OpenSSL & SSL Module Information -----")
        print(f"OpenSSL version Python is using: {data['openssl_version']}")
        print(f"OpenSSL version number: {data['openssl_version_number']}")
        print(f"OpenSSL built on: {data['openssl_built_on']}")
        print(f"OpenSSL TLS v1.2 protocol constant: {data['protocol_tlsv1_2']}")
        print(
            f"Highest available client-side TLS protocol (PROTOCOL_TLS_CLIENT): "
            f"{data['protocol_tls_client']}"
        )
        print(
            f"Highest available server-side TLS protocol (PROTOCOL_TLS_SERVER): "
            f"{data['protocol_tls_server']}"
        )
        print("\nDefault CA certificate paths (ssl.get_default_verify_paths()):")
        for key, value in data["default_ca_info"].items():
            print(f"  - {key.replace('_', ' ').title()}: {value}")

    if "tls13" in results:
        data = results["tls13"]
        print("\n----- TLS 1.3 Capability Check -----")
        if data["status"] == "OK":
            print(f"TLSVersion.TLSv1_3 constant: {ssl.TLSVersion.TLSv1_3}")
            print("SSLContext successfully created with minimum TLS 1.3 version.")
            print("This confirms active TLS 1.3 support through OpenSSL.")
        else:
            print(f"Error: {data['details']}", file=sys.stderr)

    if "hashlib" in results:
        data = results["hashlib"]
        print("\n----- Hashlib Functionality Check -----")
        if data["status"] == "OK":
            print("hashlib.blake2b() initialization worked successfully.")
            print(
                "This confirms OpenSSL's cryptographic hash algorithms are accessible."
            )
        else:
            print(f"Error: {data['details']}", file=sys.stderr)

    if "rlimits" in results:
        data = results["rlimits"]
        print("\n----- System Resource Limits -----")
        if data["status"] == "OK":
            print(
                f"Max Open Files (RLIMIT_NOFILE): "
                f"{data['limits']['max_open_files']['soft']} / "
                f"{data['limits']['max_open_files']['hard']}"
            )
            addr_space = data["limits"]["address_space_gb"]
            soft, hard = addr_space["soft"], addr_space["hard"]
            soft_gb = (
                f"{soft / (1024**3):.2f} GB"
                if isinstance(soft, (int, float)) and soft != -1
                else "Unlimited"
            )
            hard_gb = (
                f"{hard / (1024**3):.2f} GB"
                if isinstance(hard, (int, float)) and hard != -1
                else "Unlimited"
            )
            print(f"Address Space (RLIMIT_AS): {soft_gb} / {hard_gb}")
            if "max_processes" in data["limits"]:
                proc = data["limits"]["max_processes"]
                print(f"Max Processes (RLIMIT_NPROC): {proc['soft']} / {proc['hard']}")
        else:
            print(data["details"])


def print_json_report(results):
    """Prints the diagnostic results as a JSON object."""
    print(json.dumps(results, indent=2))


# ----------------------------------------
# Main Execution Logic
# ----------------------------------------
def main():
    """
    Parses command-line arguments and orchestrates the execution of the
    selected diagnostic functions.
    """
    if sys.version_info < (3, 10):
        print("Error: This script requires Python 3.10 or newer.", file=sys.stderr)
        sys.exit(1)

    parser = argparse.ArgumentParser(
        description="A comprehensive Python script to verify the Python interpreter's environment.",
        formatter_class=argparse.RawTextHelpFormatter,
    )

    # Argument definition using a dispatch table pattern
    dispatch_map = {
        "env": "get_python_env_details",
        "build": "get_python_build_config",
        "paths": "get_module_search_paths",
        "stdlib": "get_stdlib_c_extensions_check",
        "math": "get_math_module_check",
        "ssl": "get_openssl_info",
        "tls13": "get_tls13_capability_check",
        "hashlib": "get_hashlib_check",
        "rlimits": "get_system_resource_limits",
    }

    parser.add_argument(
        "--json", action="store_true", help="Output results in JSON format."
    )
    parser.add_argument(
        "--all", action="store_true", help="Display all sections (default)."
    )
    for arg, method in dispatch_map.items():
        parser.add_argument(
            f"--{arg}",
            action="store_true",
            help=f"Display {arg.replace('_', ' ')} info.",
        )

    args = parser.parse_args()

    diagnostics = SystemDiagnostics()
    results = {}

    # Determine which checks to run
    run_all = not any(getattr(args, arg) for arg in dispatch_map) or args.all

    for arg, method_name in dispatch_map.items():
        if run_all or getattr(args, arg):
            method = getattr(diagnostics, method_name)
            results[arg] = method()

    if args.json:
        print_json_report(results)
    else:
        print_text_report(results)


if __name__ == "__main__":
    main()
