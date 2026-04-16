#!/usr/bin/env python3
# ----------------------------------------------
# python_pkg_info.py
# v1.0.0xg  2025/12/08  XDG / MIS Center
# ----------------------------------------------
"""
Objective:
    This script provides a reliable and detailed inspection of an installed Python package.
    It is designed to find the exact on-disk installation location of a package and
    retrieve comprehensive metadata, including version, dependencies, and module type.

Core Functionality:
    1. Path Resolution: Implements a robust, multi-step process to determine the
       exact path of the package, prioritizing Python's own import machinery to
       ensure accuracy, especially for complex packages (e.g., namespace, editable).
    2. Metadata Retrieval: Uses the standard `importlib.metadata` library to fetch
       details like version, author, license, and dependencies.
    3. External Version Check: Optionally queries the PyPI API to find the latest
       available version of the package, helping identify outdated dependencies.
    4. Output Flexibility: Provides both human-readable text output (with multiple
       verbosity levels) and a machine-parseable JSON format for automation.
    5. Shared Logic:
       - Relies on `python_pkg_utils.py` for robust path resolution and common
         helper functions, ensuring consistency with `python_pkg_upgrader.py`.
"""

import argparse
import sys
import json
from python_pkg_utils import resolve_package_metadata, set_debug_mode

# --- Command-Line Entry Point (Handles Display) ---


def display_results(
    metadata: dict, json_output: bool, quiet_mode: bool, verbose_mode: bool
):
    """
    Prints the structured metadata dictionary either as formatted text or JSON.

    This function is responsible for the presentation layer. It takes the data
    dictionary from `resolve_package_metadata` and formats it for the user based
    on the specified command-line flags.

    Args:
        metadata: The dictionary of package information.
        json_output: If True, output in JSON format.
        quiet_mode: If True, suppress headers in text output.
        verbose_mode: If True, include extra details in text output.
    """
    # If the metadata dictionary contains an error, print it to stderr and exit.
    if "error" in metadata:
        sys.stderr.write(f"ERROR: {metadata['error']}\n")
        return

    # Handle JSON output.
    if json_output:
        if not verbose_mode:
            standard_keys = [
                "package_name",
                "import_name",
                "exact_path",
                "current_version",
                "latest_version",
                "module_type",
            ]
            output_data = {k: metadata[k] for k in standard_keys if k in metadata}
        else:
            output_data = metadata

        print(json.dumps(output_data, indent=4))
    else:
        # Handle human-readable text output.

        if not quiet_mode:
            print("\n--- Package Metadata ---")

        print(f"Found Package:   {metadata['package_name']}")
        print(f"Import Name:     {metadata['import_name']}")
        print(f"Exact Path:      {metadata['exact_path']}")

        if not quiet_mode:
            print("---")

        print(f"Current Version: {metadata['current_version']}")
        print(f"Latest Version:  {metadata['latest_version']}")
        print(f"Module Type:     {metadata['module_type']}")

        if verbose_mode:
            if not quiet_mode:
                print("\n--- Dependencies & Licensing ---")

            def format_list(items):
                items = [str(item) for item in items]
                return "\n" + "    " + "\n    ".join(items) if items else "None"

            print(f"Summary:         {metadata['metadata_summary']}")
            print(f"License:         {metadata['license']}")
            print(f"Author:          {metadata['author']}")
            print(f"Homepage URL:    {metadata['homepage']}")
            print(f"Python Requires: {metadata['required_python_version']}")
            print(f"Dependencies:    {format_list(metadata['required_dependencies'])}")


def main():
    """
    The main entry point of the script.

    This function is responsible for:
    1. Parsing command-line arguments.
    2. Calling the core logic to resolve package metadata.
    3. Passing the results to the display function for output.
    """

    # Set up the command-line argument parser.
    parser = argparse.ArgumentParser(
        description=(
            "Locate the exact installation folder and retrieve metadata "
            "for a Python package."
        )
    )

    # Define all the command-line arguments the script accepts.
    parser.add_argument(
        "--package",
        type=str,
        required=True,
        help="The name of the package as listed by 'pip list'.",
    )

    # Optional arguments for output control
    parser.add_argument(
        "--json", action="store_true", help="Output the results in JSON format."
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress introductory messages and separator lines in text output.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Display detailed dependency, licensing, and author information.",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Display detailed path resolution debugging information.",
    )

    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)

    args = parser.parse_args()

    # Set the global debug flag in the utility module
    set_debug_mode(args.debug)

    if not args.quiet and not args.json:
        print(f"Searching for: {args.package}")

    metadata = resolve_package_metadata(args.package)
    display_results(metadata, args.json, args.quiet, args.verbose)


if __name__ == "__main__":
    main()
