#!/usr/bin/env python3
# ----------------------------------------------
# python_pkg_parser.py
# v1.0.2xg  2025/12/08  XDG / MIS Center
# ----------------------------------------------
"""
Requirements: Python 3.10 or newer.

OVERVIEW:
This script analyzes a given directory of Python source code to identify and report
all external (third-party) dependencies. It recursively scans for .py files,
parses them using Abstract Syntax Trees (AST) to find import statements, and
distinguishes external modules from Python's standard library modules.
The script then attempts to determine the version of each external module.

The final output provides two summaries:
1. A unique list of all external modules and their versions.
2. A file-by-file breakdown of external dependencies.
"""

import os
import sys
import ast
from collections import defaultdict
import importlib.util
from importlib.metadata import version, PackageNotFoundError
# For Python 3.8+ onwards, but we require 3.10+


# --- Function to get standard library modules ---
def get_stdlib_modules():
    """
    Returns a set of top-level standard library module names.
    This function strictly requires Python 3.10 or newer due to its reliance on
    sys.stdlib_module_names.
    """
    # This check acts as a final safeguard, though main() performs the primary version check.
    if not hasattr(sys, "stdlib_module_names"):
        # This error should technically not be reached if the sys.version_info check in main()
        # passes.
        raise RuntimeError(
            "sys.stdlib_module_names is not available. "
            "This script's 'get_stdlib_modules' function requires Python 3.10 "
            "or newer."
        )
    return set(sys.stdlib_module_names)


# --- Function to get module version ---
def get_module_version(module_name):
    """
    Attempts to get the version string for a given module.
    Prioritizes importlib.metadata, falls back to __version__ attribute by importing.
    Returns "N/A" if the version cannot be determined.
    """
    # Attempt 1: Use importlib.metadata (preferred as it doesn't import the module)
    # This is the safest and most reliable method as it reads package metadata directly.
    try:
        return version(module_name)
    except PackageNotFoundError:
        pass  # Not found by distribution name, proceed to next attempt

    # Attempt 2: Import the module and check for __version__ attribute
    # NOTE: Importing a module can have side effects. Use with caution.
    try:
        # Check if the module is already loaded to avoid re-importing unnecessarily
        if module_name in sys.modules:
            module = sys.modules[module_name]
        else:
            # Only import if not already loaded
            module = importlib.import_module(module_name)

        if hasattr(module, "__version__"):
            return module.__version__
    except ImportError:
        # Module cannot be imported at all in the current environment
        pass
    except Exception as e:  # pylint: disable=broad-exception-caught
        # Catch any other unexpected errors during import or attribute access
        print(
            f"Warning: Could not get version for '{module_name}' via __version__ due to: {e}",
            file=sys.stderr,
        )

    return "N/A"  # Version Not Available


# --- Function to find Python files recursively ---
def find_python_files(root_dir):
    """Recursively finds all Python files in a directory."""
    python_files = []
    for dirpath, _, filenames in os.walk(
        root_dir
    ):  # os.walk ensures recursive traversal
        for f in filenames:
            if f.endswith(".py"):
                python_files.append(os.path.join(dirpath, f))
    return python_files


# --- Function to extract imports from a single file ---
def extract_imports(file_path, stdlib_modules):  # pylint: disable=too-many-nested-blocks
    """
    Extracts top-level absolute import statements from a Python file.
    Filters out standard library modules using the provided stdlib_modules set.
    """
    # pylint: disable=too-many-nested-blocks
    imports = set()
    # Use 'errors=ignore' for robustness against encoding issues in some files
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        try:
            # Parse the file into an Abstract Syntax Tree (AST)
            # This is a safe way to analyze code without executing it.
            tree = ast.parse(f.read(), filename=file_path)
            for node in ast.walk(tree):
                # pylint: disable=too-many-nested-blocks
                # Handle 'import module_name' or 'import package.submodule'
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        # Get 'module_name' from 'module_name.submodule'
                        top_level_module = alias.name.split(".")[0]
                        if top_level_module not in stdlib_modules:
                            imports.add(top_level_module)
                # Handle 'from module_name import something' or
                # 'from package.subpackage import something'
                elif isinstance(node, ast.ImportFrom):
                    # node.level == 0 indicates an absolute import
                    # (not a relative one like 'from . import ...')
                    if node.level == 0:
                        # Ensure module name exists (e.g., 'from . import x' might have
                        # node.module is None)
                        if node.module:
                            top_level_module = node.module.split(".")[0]
                            if top_level_module not in stdlib_modules:
                                imports.add(top_level_module)
                    # Relative imports (node.level > 0) are typically internal to the project
                    # and are not usually considered "external/third-party dependencies" in
                    # this context.
                    # We are intentionally skipping them here.

        except SyntaxError as e:
            # Log a warning if a file cannot be parsed due to a syntax error
            print(
                f"Warning: Could not parse '{file_path}' due to SyntaxError: {e}",
                file=sys.stderr,
            )
        except Exception as e:  # pylint: disable=broad-exception-caught
            # Catch any other unexpected errors during parsing
            print(
                f"Warning: An unexpected error occurred while parsing '{file_path}': {e}",
                file=sys.stderr,
            )
    return imports


# --- Main execution function ---
def main():  # pylint: disable=too-many-branches
    """
    Main function to execute the script. It handles command-line arguments,
    orchestrates the file scanning and parsing, and prints the final reports.
    """
    # --- Strict Runtime Version Check ---
    # Ensure the script is run with Python 3.10 or newer.
    if sys.version_info < (3, 10):
        print(
            f"Error: This script requires Python 3.10 or newer to run correctly. "
            f"You are currently running Python {sys.version.split(' ', maxsplit=1)[0]}.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Initialize the standard library modules set AFTER the version check
    # This relies on sys.stdlib_module_names, which is guaranteed in 3.10+
    standard_lib_modules = get_stdlib_modules()

    # Check for command-line arguments
    if len(sys.argv) < 2:
        print("Usage: python_pkg_parser.py <directory_to_scan>", file=sys.stderr)
        sys.exit(1)

    root_directory = sys.argv[1]
    # Validate the provided directory
    if not os.path.isdir(root_directory):
        print(
            f"Error: '{root_directory}' is not a valid directory or does not exist.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Data structures to hold the results
    all_external_modules = set()  # A set of all unique external modules found
    # A dictionary mapping files to their external modules
    file_external_dependencies = defaultdict(set)

    # Find all Python files recursively
    python_files = find_python_files(root_directory)
    print(f"Scanning {len(python_files)} Python files in '{root_directory}'...")

    # Process each Python file
    for py_file in python_files:
        # Extract external imports from the current file
        modules_in_file = extract_imports(py_file, standard_lib_modules)
        all_external_modules.update(
            modules_in_file
        )  # Add to the master set of all external modules
        if modules_in_file:
            # Store file-specific external dependencies
            file_external_dependencies[py_file] = modules_in_file

    # --- Output Summary of All Unique External Modules with Versions ---
    print(
        "\n--- Summary of All Unique Top-Level External/Third-Party Modules (with versions) ---"
    )
    if not all_external_modules:
        print("No external/third-party modules found in the scanned directory.")
    else:
        # Get and print versions for each unique external module
        for module_name in sorted(list(all_external_modules)):
            version_str = get_module_version(module_name)
            print(f"{module_name}=={version_str}")

    # --- Output File-by-File External Dependencies with Versions ---
    print("\n--- File-by-File External/Third-Party Dependencies (with versions) ---")
    if not file_external_dependencies:
        print("No external/third-party dependencies found in any file.")
    else:
        # Print dependencies for each file
        for py_file in sorted(file_external_dependencies.keys()):
            print(f"\n{py_file}:")
            if not file_external_dependencies[py_file]:
                print("  - No external dependencies in this file.")
            else:
                for module_name in sorted(list(file_external_dependencies[py_file])):
                    version_str = get_module_version(module_name)
                    print(f"  - {module_name}=={version_str}")


if __name__ == "__main__":
    main()
