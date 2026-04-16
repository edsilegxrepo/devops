#!/usr/bin/env python3
# ----------------------------------------------
# python_pkg_upgrader.py
# v1.1.0xg  2025/12/09  XDG / MIS Center
# ----------------------------------------------
#
"""
Objective:
    This script is a system utility designed to manage Python packages. It allows
    administrators to inspect installed packages with detailed metadata and
    perform bulk upgrades of all outdated modules.

Core Functionality:
    1. Package Listing (--list):
       - Scans all installed packages.
       - Uses the shared `python_pkg_utils` to resolve the exact on-disk location,
         version, and module type (pure Python vs. compiled extension).
       - Classifies packages as 'system', 'user', or 'custom' based on path.

    2. Bulk Upgrade (--upgrade):
       - Identifies outdated packages using `pip list --outdated`.
       - Performs a bulk upgrade of all identified packages.
       - Supports a simulation mode (--simulate) to preview changes without acting.

    3. Shared Logic:
       - Relies on `python_pkg_utils.py` for robust path resolution and common
         helper functions, ensuring consistency with `python_pkg_info.py`.
"""

import argparse
import sys
import json
import subprocess
import importlib.metadata
import os
import shutil
from pathlib import Path
from python_pkg_utils import resolve_package_metadata


def list_all_packages(json_output=False):
    """
    Lists all installed packages with their metadata.

    Args:
        json_output (bool): If True, prints the output in JSON format.
    """
    # Retrieve all package distributions from the current environment.
    dists = importlib.metadata.distributions()
    package_list = []

    # Sort distributions by package name for consistent ordering.
    for dist in sorted(dists, key=lambda d: d.metadata["name"].lower()):
        package_name = dist.metadata["name"]
        # Use a shared utility function to get detailed metadata for each package.
        metadata = resolve_package_metadata(package_name)
        if "error" not in metadata:
            package_list.append(metadata)

    # Output the data in the specified format.
    if json_output:
        print(json.dumps(package_list, indent=4))
    else:
        # Print a formatted table for human-readable output.
        header = (
            f"{'Package':<30} {'Version':<15} {'Location':<10} {'Type':<18} {'Path'}"
        )
        print(header)
        print("=" * (len(header) + 5))
        for metadata in package_list:
            print(
                f"{metadata['package_name']:<30} {metadata['current_version']:<15} "
                f"{metadata['location_category']:<10} {metadata['module_type']:<18} "
                f"{metadata['exact_path']}"
            )


def get_outdated_packages():
    """
    Gets a list of outdated packages using 'pip list --outdated'.

    Returns:
        list: A list of dictionaries, where each dictionary represents an outdated package.
    """
    try:
        # Execute 'pip list' with the '--outdated' and '--format=json' flags
        # to get a machine-readable list of packages that need upgrading.
        result = subprocess.run(
            [sys.executable, "-m", "pip", "list", "--outdated", "--format=json"],
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout)
    except (
        subprocess.CalledProcessError,
        FileNotFoundError,
        json.JSONDecodeError,
    ) as e:
        # Handle potential errors, such as pip not being installed or JSON parsing issues.
        print(f"Error checking for outdated packages: {e}", file=sys.stderr)
        return []


def remove_old_package_from_target(package_name, target_path):
    """
    Removes the old version of a package from the target directory
    to prevent duplicate metadata directories (shadowing).

    Args:
        package_name (str): The name of the package to remove.
        target_path (str): The target directory where the package is installed.
    """
    abs_target = os.path.realpath(os.path.abspath(target_path))

    # 1. Resolve and remove the package source (module/package)
    metadata = resolve_package_metadata(package_name)
    if "error" not in metadata:
        install_path = metadata["exact_path"]
        # Check if the package is actually installed in the target directory
        if install_path and os.path.exists(install_path):
            parent_dir = os.path.dirname(install_path)

            # Normalize paths for comparison
            if os.path.realpath(parent_dir) == abs_target:
                try:
                    if os.path.isdir(install_path):
                        shutil.rmtree(install_path)
                    elif os.path.isfile(install_path):
                        os.remove(install_path)
                    # print(f"Removed old package source: {install_path}")
                except OSError as e:
                    print(
                        f"Warning: Failed to remove {install_path}: {e}",
                        file=sys.stderr,
                    )

    # 2. Remove dist-info/egg-info directory
    try:
        dist = importlib.metadata.distribution(package_name)
        files = dist.files
        if files:
            # Find the path to .dist-info
            dist_info_file = next(
                (f for f in files if ".dist-info" in str(f) or ".egg-info" in str(f)),
                None,
            )
            if dist_info_file:
                full_path = str(dist.locate_file(dist_info_file))
                # Walk up to the .dist-info directory
                path_obj = Path(full_path)
                while path_obj.name and not (
                    path_obj.name.endswith(".dist-info")
                    or path_obj.name.endswith(".egg-info")
                ):
                    path_obj = path_obj.parent

                if path_obj.name.endswith(".dist-info") or path_obj.name.endswith(
                    ".egg-info"
                ):
                    # Check if it is in target path
                    if os.path.realpath(path_obj.parent) == abs_target:
                        # print(f"Removed old metadata: {path_obj}")
                        shutil.rmtree(path_obj)
    except (importlib.metadata.PackageNotFoundError, OSError):
        pass


def upgrade_modules(simulate=False, json_output=False, target_path=None):  # pylint: disable=too-many-branches
    """
    Upgrades all installed Python modules.

    Args:
        simulate (bool): If True, lists the packages to be upgraded without performing the upgrade.
        json_output (bool): If True and in simulation mode, prints the output in JSON format.
        target_path (str): Optional. Specifies the target directory for installation.
    """
    outdated_packages = get_outdated_packages()

    if not outdated_packages:
        # If there are no outdated packages, inform the user and exit.
        if json_output and simulate:
            print(json.dumps([]))
        else:
            print("All packages are up to date.")
        return

    # If in simulation mode, just print the list of outdated packages.
    if simulate:
        if json_output:
            print(json.dumps(outdated_packages, indent=4))
        else:
            print(f"{'Module':<30} {'Old Version':<15} {'New Version':<15}")
            print("=" * 60)
            for package in outdated_packages:
                print(
                    f"{package['name']:<30} {package['version']:<15} "
                    f"{package['latest_version']:<15}"
                )
    else:
        # If not in simulation mode, proceed with the upgrade.
        package_names = [pkg["name"] for pkg in outdated_packages]
        print(f"Upgrading {len(package_names)} packages...")

        # Construct the 'pip install --upgrade' command.
        command = [sys.executable, "-m", "pip", "install", "--upgrade"]

        if target_path:
            command.extend(["--target", target_path])
            # Pre-cleanup: Remove old versions from target path to avoid duplicates
            for pkg_name in package_names:
                remove_old_package_from_target(pkg_name, target_path)

        command.extend(package_names)

        try:
            # Use Popen to stream the output of the upgrade process in real-time.
            with subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            ) as proc:
                if proc.stdout:
                    for line in proc.stdout:
                        print(line, end="")
                proc.wait()  # Wait for the subprocess to complete.

                # Check for errors after the process has finished.
                if proc.returncode != 0 and proc.stderr:
                    stderr_output = "".join(proc.stderr.readlines())
                    raise subprocess.CalledProcessError(
                        proc.returncode, command, stderr=stderr_output
                    )

            print("\nSuccessfully upgraded all packages.")
        except subprocess.CalledProcessError as e:
            print(f"\nFailed to upgrade packages. Error:\n{e.stderr}", file=sys.stderr)
        except FileNotFoundError:
            print(f"Error: The command '{command[0]}' was not found.", file=sys.stderr)


def main():
    """
    Main function to parse arguments and execute the appropriate action.
    """
    # Set up the command-line argument parser.
    parser = argparse.ArgumentParser(
        description="A tool to list and upgrade Python modules."
    )

    # Create a mutually exclusive group for --list and --upgrade, as they cannot be used together.
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--list", action="store_true", help="List all installed packages."
    )
    group.add_argument(
        "--upgrade", action="store_true", help="Upgrade all installed packages."
    )

    # Add optional arguments that can be used with the main commands.
    parser.add_argument(
        "--simulate",
        action="store_true",
        help="Simulate the upgrade process (only works with --upgrade).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output the results in JSON format (works with --list or --upgrade --simulate).",
    )
    parser.add_argument(
        "--target",
        help="Specify a target directory for the upgrade installation (works with --upgrade).",
    )

    # If the script is run without arguments, print the help message.
    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)

    args = parser.parse_args()

    # Call the appropriate function based on the parsed arguments.
    if args.list:
        list_all_packages(json_output=args.json)
    elif args.upgrade:
        upgrade_modules(
            simulate=args.simulate, json_output=args.json, target_path=args.target
        )


if __name__ == "__main__":
    # This block ensures the main function is called only when the script is executed directly.
    main()
