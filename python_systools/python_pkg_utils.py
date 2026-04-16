#!/usr/bin/env python3
# ----------------------------------------------
# python_pkg_utils.py
# v1.0.0xg  2025/12/08  XDG / MIS Center
# ----------------------------------------------
"""
Overview:
This module provides a centralized set of utility functions for Python package analysis and
metadata resolution. It serves as a shared backend for various Python system tools, abstracting
the complexities of package introspection. Key functionalities include resolving package
installation paths, categorizing package locations (system, user, custom), determining module
types (pure Python vs. compiled), and fetching the latest version from PyPI.

Core Design Principles:
1. Reliability: Uses the standard `importlib.metadata` library for robust metadata access and
   employs a multi-step heuristic to reliably determine a package's on-disk location.
2. Modularity: Consolidates shared logic to avoid code duplication across different tools.
3. Graceful Degradation: Includes a dummy `requests` class to prevent crashes if the library
   is not installed, allowing network-dependent functions to fail gracefully.
4. Python Version Guard: Explicitly checks for the minimum required Python version (3.8+)
   to ensure compatibility with `importlib.metadata`.
"""

import importlib.metadata
import importlib.util
import os
import sys
from pathlib import Path
import site


# Define a dummy class to gracefully handle the absence of the 'requests' library.
# This prevents the entire script from failing if 'requests' is not installed,
# allowing other non-network functionalities to proceed.
class DummyRequests:  # pylint: disable=too-few-public-methods
    """A dummy class that mimics the `requests` library's interface for PyPI lookups."""

    @staticmethod
    def get(url, timeout):  # pylint: disable=unused-argument
        """Simulates a failed GET request, returning a 503 status code."""

        class DummyResponse:  # pylint: disable=too-few-public-methods,missing-class-docstring
            status_code = 503  # Service Unavailable

            @staticmethod
            def json():
                """Returns a JSON object indicating the error."""
                return {"info": {"version": "Error: requests not installed"}}

        return DummyResponse()


# Attempt to import the 'requests' library for network operations. If it fails,
# substitute it with the DummyRequests class to ensure the script remains operational.
try:
    import requests
except ImportError:
    requests = DummyRequests()

# ====================================================================
# CONFIGURATION CONSTANTS
# ====================================================================

# The minimum required Python version (3.8) is necessary because `importlib.metadata`
# was introduced as a standard library module in that version.
MIN_PYTHON_VERSION_TUPLE = (3, 8)

# The official PyPI JSON API endpoint for fetching package metadata.
PYPI_JSON_URL = "https://pypi.org/pypi/{package_name}/json"

# A global flag to enable or disable verbose debugging output for troubleshooting.
DEBUG_MODE = False


def set_debug_mode(enabled: bool):
    """
    Globally sets the debug mode for this module.

    Args:
        enabled (bool): True to enable debug prints, False to disable.
    """
    global DEBUG_MODE  # pylint: disable=global-statement
    DEBUG_MODE = enabled


# ====================================================================
# SHARED FUNCTIONS
# ====================================================================


def get_package_location_category(install_path):  # pylint: disable=too-many-return-statements,too-many-branches
    """
    Categorizes a package's installation path into 'user', 'system', or 'custom'.

    This function determines the nature of a package's installation location by checking
    it against standard Python and environment-defined paths in a specific order of precedence:
    1. Custom paths (MODULEPATH, PYTHONPATH)
    2. User-specific site-packages
    3. System-level or virtual environment site-packages

    Args:
        install_path (str): The absolute path to the package's installation directory.

    Returns:
        str: The category of the location ('custom', 'user', 'system', or 'unknown').
    """
    if not install_path or not os.path.exists(install_path):
        return "unknown"

    real_install_path = os.path.realpath(install_path)

    # 1. Custom: Check MODULEPATH (Priority 1)
    module_path_env = os.environ.get("MODULEPATH")
    if module_path_env:
        for path in module_path_env.split(os.pathsep):
            if path and real_install_path.startswith(os.path.realpath(path)):
                return "custom"

    # 2. Custom: Check PYTHONPATH (Priority 2)
    pythonpath = os.environ.get("PYTHONPATH")
    if pythonpath:
        for path in pythonpath.split(os.pathsep):
            if path and real_install_path.startswith(os.path.realpath(path)):
                return "custom"

    # 3. User: Check user's home directory site packages
    try:
        user_site = site.getusersitepackages()
        user_paths = (
            [user_site]
            if isinstance(user_site, str)
            else (user_site if user_site else [])
        )
        for path in user_paths:
            if real_install_path.startswith(os.path.realpath(path)):
                return "user"
    except (AttributeError, TypeError):
        # Fallback to home dir check if site.getusersitepackages is problematic
        home_dir = os.path.expanduser("~")
        if real_install_path.startswith(home_dir):
            return "user"

    # 4. System: Check Virtual Environment (Treat as system/standard for this env)
    if hasattr(sys, "real_prefix") or (
        hasattr(sys, "base_prefix") and sys.base_prefix != sys.prefix
    ):
        if real_install_path.startswith(os.path.realpath(sys.prefix)):
            return "system"

    # 5. System: Check site.getsitepackages()
    try:
        for path in site.getsitepackages():
            if real_install_path.startswith(os.path.realpath(path)):
                return "system"
    except (AttributeError, TypeError):
        pass

    # 6. System: Check sys.path fallback for 'site-packages'
    for path in sys.path:
        if path and ("site-packages" in path or "dist-packages" in path):
            if real_install_path.startswith(os.path.realpath(path)):
                return "system"

    return "unknown"


def get_latest_version_from_pypi(package_name: str) -> str:
    """
    Fetches the latest published version of a package from the PyPI JSON API.

    Args:
        package_name (str): The name of the package as it appears on PyPI.

    Returns:
        str: The latest version number as a string, or an error message if the lookup fails.
    """
    # Return an error immediately if the `requests` library is not available.
    if isinstance(requests, DummyRequests):
        return "Error: requests library not found for network lookup"

    try:
        url = PYPI_JSON_URL.format(package_name=package_name)
        response = requests.get(url, timeout=5)

        if response.status_code == 200:
            data = response.json()
            return data["info"]["version"]
        if response.status_code == 404:
            return "Package not found on PyPI"

        return f"Error: HTTP {response.status_code}"

    except requests.exceptions.RequestException:
        return "Error: Network failure"
    except Exception:  # pylint: disable=broad-exception-caught
        return "Error: Metadata parsing failure"


def get_module_type(dist: importlib.metadata.Distribution) -> str:
    """
    Determines if a package is 'purelib' (pure Python) or 'platlib' (contains compiled binaries).

    This function inspects the file list of an installed package for common compiled file extensions
    (e.g., .so, .pyd) to differentiate between pure Python and platform-specific distributions.

    Args:
        dist (importlib.metadata.Distribution): The distribution object for the package.

    Returns:
        str: A string indicating the module type, e.g., "purelib" or "platlib".
    """
    compiled_extensions = (".so", ".pyd", ".dll", ".dylib")

    if dist.files is None:
        return "Type Unknown (No File Listing)"

    for file in dist.files:
        if Path(str(file)).suffix.lower() in compiled_extensions:
            return "platlib (Binary/Compiled C/C++)"

    return "purelib (Pure Python code)"


def resolve_package_metadata(package_name: str) -> dict:  # pylint: disable=too-many-locals,too-many-branches,too-many-statements
    """
    Resolves a comprehensive set of metadata for a given installed package.

    This is the core function of the utility module. It orchestrates multiple steps to gather
    detailed information about a package, including its version, path, type, and dependencies.
    The path resolution logic is particularly robust, using a multi-layered approach to
    reliably find the package's location on disk.

    Args:
        package_name (str): The name of the package to resolve.

    Returns:
        dict: A dictionary containing detailed metadata, or an error dictionary if the package
              is not found.
    """
    global DEBUG_MODE  # pylint: disable=global-variable-not-assigned

    if DEBUG_MODE:
        print("\n--- DEBUG: Path Resolution Start ---")

    if sys.version_info < MIN_PYTHON_VERSION_TUPLE:
        return {
            "error": (
                f"Python {MIN_PYTHON_VERSION_TUPLE[0]}.{MIN_PYTHON_VERSION_TUPLE[1]} "
                "or newer required for metadata handling."
            )
        }

    # --- 1. Get Distribution Metadata ---
    try:
        dist = importlib.metadata.distribution(package_name)
        current_version = dist.version
        metadata_dict = dist.metadata

    except importlib.metadata.PackageNotFoundError:
        return {"error": f"Package '{package_name}' not found."}

    # --- 2. Determine Top-Level Module (TML) ---
    top_level_text = dist.read_text("top_level.txt")

    if top_level_text:
        # Use the first line as the primary TML.
        raw_tml = top_level_text.splitlines()[0].strip()
    else:
        raw_tml = package_name.lower().replace("-", "_")

    # --- 2a. TML Heuristic Refinement ---
    package_name_normalized = package_name.lower().replace("-", "_")
    top_level_module = raw_tml

    if not top_level_module:
        top_level_module = package_name_normalized
    elif (
        top_level_module.startswith("_") and top_level_module != package_name_normalized
    ):
        top_level_module = package_name_normalized
    elif package_name_normalized.startswith(top_level_module) and len(
        package_name_normalized
    ) > len(top_level_module):
        pass
    else:
        if not top_level_module or not importlib.util.find_spec(top_level_module):
            top_level_module = package_name_normalized

    # --- 3. Determine Installation Root (dist_root) ---
    dist_root = "Could not determine root."

    try:
        if dist.files:
            dist_info_folder_name = [
                str(f).split(os.sep, maxsplit=1)[0]
                for f in dist.files
                if str(f).endswith(".dist-info") or str(f).endswith(".egg-info")
            ][0]
            dist_root = str(
                Path(
                    os.path.abspath(str(dist.locate_file(Path(dist_info_folder_name))))
                ).parent
            )
    except Exception:  # pylint: disable=broad-exception-caught
        dist_root = "Could not determine root via files."

    if DEBUG_MODE:
        print(f"DEBUG 1: Top-Level Module (TML): {top_level_module}")
        print(f"DEBUG 1: Distribution Root (Calculated): {dist_root}")

    # --- 4. Locate the installation folder (FINAL PATH LOGIC) ---
    resolved_path = "Could not resolve path."

    if dist_root != "Could not determine root." and Path(dist_root).is_dir():
        potential_path = Path(dist_root) / top_level_module
        if DEBUG_MODE:
            print(f"DEBUG 2: Constructed Module Path: {potential_path}")
            print(f"DEBUG 2: Constructed Path Exists?: {potential_path.is_dir()}")

        if potential_path.is_dir():
            resolved_path = str(potential_path)
        else:
            resolved_path = "Falling through to find_spec."

    if resolved_path in ("Could not resolve path.", "Falling through to find_spec."):
        try:
            spec = importlib.util.find_spec(top_level_module)

            if spec and spec.submodule_search_locations:
                resolved_path = spec.submodule_search_locations[0]
            elif spec and spec.origin:
                resolved_path = os.path.dirname(spec.origin)
            else:
                resolved_path = dist_root
        except ImportError:
            resolved_path = dist_root

    # --- 4a. Path Resolution Final Fallback ---
    if resolved_path == "Could not determine root via files.":
        try:
            potential_root_path = str(
                Path(
                    os.path.abspath(str(dist.locate_file(Path(top_level_module))))
                ).parent
            )
            if Path(potential_root_path).is_dir():
                resolved_path = potential_root_path
        except Exception as e:  # pylint: disable=broad-exception-caught
            resolved_path = f"Could not determine root via locate_file: {str(e)}"

    if DEBUG_MODE:
        print(f"DEBUG FINAL: Resolved Path Before Return: {resolved_path}")
        print("--- DEBUG: Path Resolution End ---\n")

    # --- 5. Gather Remaining Metadata ---
    latest_version = get_latest_version_from_pypi(package_name)
    module_type = get_module_type(dist)
    location_category = get_package_location_category(resolved_path)

    requires_dist = metadata_dict.get("Requires-Dist")

    # Process License: Truncate at first newline or 65 chars
    raw_license = metadata_dict.get("License", metadata_dict.get("Classifier", "N/A"))
    if raw_license and raw_license != "N/A":
        first_line = str(raw_license).split("\n", maxsplit=1)[0]
        if len(first_line) > 65:
            license_text = first_line[:65] + "..."
        else:
            license_text = first_line
    else:
        license_text = "N/A"

    return {
        "package_name": package_name,
        "import_name": top_level_module,
        "exact_path": resolved_path,
        "current_version": current_version,
        "latest_version": latest_version,
        "module_type": module_type,
        "location_category": location_category,
        # Verbose/Additional Fields
        "metadata_summary": metadata_dict.get("Summary", "N/A"),
        "required_python_version": metadata_dict.get("Requires-Python", "N/A"),
        "license": license_text,
        "author": metadata_dict.get("Author", "N/A"),
        "homepage": metadata_dict.get("Home-page", "N/A"),
        "required_dependencies": (
            requires_dist
            if isinstance(requires_dist, list)
            else ([requires_dist] if requires_dist else [])
        ),
    }
