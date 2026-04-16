#!/usr/bin/env python3
# ----------------------------------------------
# check_crypto_symbols.py
# v1.0.1xg  2025/12/09  XDG / MIS Center
# ----------------------------------------------
# Requirements: Python 3.10 or newer.

"""
Script to check for specific OpenSSL symbols in a custom libcrypto library
and verify hashlib functionality.
"""

import sys
import argparse
import ctypes
import os
import hashlib
import json
import ssl
from typing import Dict, Any

# Constants defining the minimum required Python version
MIN_PYTHON_MAJOR = 3
MIN_PYTHON_MINOR = 10

# Constants for symbol names
BLAKE2B_SYMBOL_NAME = "EVP_blake2b"
BLAKE2B512_SYMBOL_NAME = "EVP_blake2b512"


def check_python_version() -> None:
    """
    Enforce a minimum Python version to ensure compatibility with
    modern features and specific library behaviors.
    Exits the script if the version requirement is not met.
    """
    if sys.version_info < (MIN_PYTHON_MAJOR, MIN_PYTHON_MINOR):
        sys.exit(
            f"Error: Python {MIN_PYTHON_MAJOR}.{MIN_PYTHON_MINOR} or newer "
            "is required to run this script."
        )


def get_library_version_string(libcrypto: ctypes.CDLL) -> str:
    """
    Attempt to retrieve the version string from the loaded library.
    Tries OpenSSL_version (1.1.0+) and SSLeay_version (older).
    """
    try:
        # OpenSSL 1.1.0+ uses OpenSSL_version
        if hasattr(libcrypto, "OpenSSL_version"):
            libcrypto.OpenSSL_version.restype = ctypes.c_char_p
            libcrypto.OpenSSL_version.argtypes = [ctypes.c_int]
            # OPENSSL_VERSION = 0
            ver = libcrypto.OpenSSL_version(0)
            return ver.decode("utf-8")

        # Older versions use SSLeay_version
        if hasattr(libcrypto, "SSLeay_version"):
            libcrypto.SSLeay_version.restype = ctypes.c_char_p
            libcrypto.SSLeay_version.argtypes = [ctypes.c_int]
            ver = libcrypto.SSLeay_version(0)
            return ver.decode("utf-8")

        return "Unknown (Version symbols not found)"
    except Exception as e:  # pylint: disable=broad-exception-caught
        return f"Error retrieving version: {e}"


def inspect_library(libcrypto_path: str) -> Dict[str, Any]:
    """
    Load the specified shared library and check for OpenSSL symbols and version.
    Returns a dictionary with the results.
    """
    result = {
        "success": False,
        "path": libcrypto_path,
        "loaded": False,
        "version": None,
        "symbols": {},
        "error": None,
    }

    # Security: Validate file existence before loading
    if not os.path.isfile(libcrypto_path):
        result["error"] = f"File not found at {libcrypto_path}"
        return result

    try:
        # Load the custom libcrypto library using ctypes.
        libcrypto = ctypes.CDLL(libcrypto_path)
        result["loaded"] = True

        # Get Version
        result["version"] = get_library_version_string(libcrypto)

        # Check for symbols
        result["symbols"][BLAKE2B_SYMBOL_NAME] = hasattr(libcrypto, BLAKE2B_SYMBOL_NAME)
        result["symbols"][BLAKE2B512_SYMBOL_NAME] = hasattr(
            libcrypto, BLAKE2B512_SYMBOL_NAME
        )

        # Determine success: we primarily look for EVP_blake2b, but finding
        # either is 'some' success.
        # Strict success depends on requirements, but generally finding the
        # standard one is key.
        if result["symbols"].get(BLAKE2B_SYMBOL_NAME):
            result["success"] = True
        elif result["symbols"].get(BLAKE2B512_SYMBOL_NAME):
            # Partial success if variant found? Let's say yes for diagnostic purposes.
            result["success"] = True

    except OSError as e:
        result["error"] = f"Error loading library: {e}"
    except Exception as e:  # pylint: disable=broad-exception-caught
        result["error"] = f"Unexpected error: {e}"

    return result


def check_hashlib_blake2b() -> Dict[str, Any]:
    """
    Verify if Python's built-in hashlib module can successfully access
    the BLAKE2b implementation.
    """
    result = {"success": False, "functional": False, "error": None}

    try:
        # Attempt to create a blake2b hash object
        hashlib.blake2b(b"test")
        result["functional"] = True
        result["success"] = True
    except AttributeError:
        result["error"] = "AttributeError: hashlib.blake2b() failed."
    except ValueError as e:
        result["error"] = f"ValueError: {e}."
    except Exception as e:  # pylint: disable=broad-exception-caught
        result["error"] = f"Unexpected error: {e}"

    return result


def print_text_report(results: Dict[str, Any]) -> None:
    """Print the results in the original human-readable format."""
    # Python SSL Info
    print(f"Python Linked OpenSSL: {results['python_linked_openssl']}")

    # Library Check
    lib_res = results["library_check"]
    print("\n--- Checking for OpenSSL symbols ---")
    print(f"Attempting to load library: {lib_res['path']}")

    if lib_res["error"]:
        print(f"[FAIL] {lib_res['error']}")
    elif lib_res["loaded"]:
        print("Library loaded successfully.")
        print(f"Detected Library Version: {lib_res['version']}")

        for sym, found in lib_res["symbols"].items():
            status = "[PASS]" if found else "[FAIL]"
            msg = "found in" if found else "not found in"
            print(f"{status} Symbol '{sym}' {msg} the library.")

    # Hashlib Check
    hash_res = results["hashlib_check"]
    print("\n--- Checking hashlib behavior ---")
    print("hashlib module loaded successfully.")

    if hash_res["functional"]:
        print("[PASS] hashlib.blake2b() call succeeded.")
    else:
        print(f"[FAIL] {hash_res['error']}")

    # Overall Status
    if results["overall_success"]:
        print("\nAll checks PASSED.")
    else:
        print("\nSome checks FAILED.")


def main() -> None:
    """
    Main execution entry point.
    """
    check_python_version()

    parser = argparse.ArgumentParser(
        description="Check for specific OpenSSL symbols in a custom libcrypto library"
    )
    parser.add_argument(
        "libcrypto_path", help="Full path to the custom libcrypto library"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results in JSON format instead of plain text",
    )
    args = parser.parse_args()

    # Initialize Results Structure
    results = {
        "python_linked_openssl": ssl.OPENSSL_VERSION,
        "library_check": {},
        "hashlib_check": {},
        "overall_success": False,
    }

    # 1. Inspect Library
    results["library_check"] = inspect_library(args.libcrypto_path)

    # 2. Check Hashlib
    results["hashlib_check"] = check_hashlib_blake2b()

    # Determine Overall Success
    # Both library check and hashlib check must be successful
    if results["library_check"].get("success") and results["hashlib_check"].get(
        "success"
    ):
        results["overall_success"] = True

    # Output
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print_text_report(results)

    # Exit Code
    sys.exit(0 if results["overall_success"] else 1)


if __name__ == "__main__":
    main()
