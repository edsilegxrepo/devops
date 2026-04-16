#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# pathfix.py
# v1.0.0xg  2026/04/15  XDG / MIS Center
# -----------------------------------------------------------------------------
"""
# OBJECTIVE:
#   A high-integrity utility for updating Python interpreter paths in shebang
#   lines (#!). It is designed for large-scale DevOps environments where
#   data safety, atomic commitment, and performance are critical.
#
# CORE COMPONENTS:
#   1. Safe Transactional Engine: Implements a Write-Ahead-Log style safety
#      net using mandatory backups (.bak) and atomic swaps (os.replace).
#   2. Performance Walker: An optimized directory crawler with pruning for
#      high-speed scanning of massive repositories.
#   3. Flexible Targeting: Advanced glob-based filename and depth filtering.
#
# DATA FLOW:
#   [CLI Input] -> [Config Validation] -> [Target Discovery (os.walk)]
#       -> [Pruning (Excludes/Scope)] -> [Script Identification]
#           -> [Safe Transactional Swap]
#               -> Create .bak -> Write Temp -> Atomic Replace -> Rollback if Error
"""

import argparse
import fnmatch
import logging
import os
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Set

# Setup logging architecture
logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(__name__)

# --- CONFIGURATION & DEFAULTS ---

# Static list of directories that are historically "noise" in development environments.
# These are skipped at the walker level to significantly reduce I/O.
DEFAULT_EXCLUDE_DIRS = {
    "__pycache__",
    "node_modules",
    "venv",
    "build",
    "dist",
    "artifacts",
    "target",
    "out",
    "reports",
    "results",
    "logs",
    "tmp",
    "temp",
}


@dataclass
class Config:
    """
    Centralized configuration state.
    Eliminates global variables and ensures consistent propagation of flags.
    """

    new_interpreter: bytes
    preserve_timestamps: bool
    keep_backup: bool
    keep_flags: bool
    add_flags: bytes
    keep_space: bool
    file_pattern: Optional[str] = None
    max_depth: Optional[int] = None
    custom_excludes: Set[str] = field(default_factory=set)


# --- CORE UTILITIES ---


def parse_args() -> argparse.Namespace:
    """
    Orchestrates the Command Line Interface (CLI).
    Handles input validation and ensures mandatory paths are provided.
    """
    parser = argparse.ArgumentParser(
        description="Change the #! line (shebang) occurring in Python scripts."
    )
    # Action Flags
    parser.add_argument(
        "-i", "--interpreter", required=True, help="New interpreter (must start with /)"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Engineering-level output"
    )
    parser.add_argument(
        "-p", "--preserve", action="store_true", help="Preserve mtime/atime"
    )
    parser.add_argument(
        "-b",
        "--backup",
        action="store_true",
        help="Commit backup (.bak) to disk after success",
    )
    parser.add_argument(
        "-s",
        "--keep-space",
        action="store_true",
        help="Preserve original shebang spacing style",
    )
    parser.add_argument(
        "-k",
        "--keep-flags",
        action="store_true",
        help="Inherit flags from the original shebang",
    )
    parser.add_argument(
        "-a", "--add-flags", default="", help="Literal flag string to inject"
    )

    # Filter Controls
    parser.add_argument(
        "-t", "--file-pattern", help="Filename glob pattern (e.g. '*.py')"
    )
    parser.add_argument(
        "-o", "--scope", type=int, help="Recursion depth limit (0 = local)"
    )
    parser.add_argument(
        "-x", "--exclude", help="Comma-separated ignore list (patterns or names)"
    )

    parser.add_argument("paths", nargs="+", help="Target files or root directories")

    args = parser.parse_args()

    # Enable Debug logging if requested
    if args.verbose:
        logger.setLevel(logging.DEBUG)

    # Input validation
    if not args.interpreter.startswith("/"):
        parser.error("The interpreter path must be absolute (starting with '/')")
    if " " in args.add_flags:
        parser.error(
            "Injected flags (-a) cannot contains spaces (standard Linux shebang constraint)"
        )

    return args


def get_shebang_style(line: bytes, config: Config) -> bytes:
    """
    Determines the visual style of the shebang prefix.
    Default: 'Compact' (#!/).
    -s Flag: Respects the original file's spacing if present.
    """
    if config.keep_space:
        return b"#! " if line.startswith(b"#! ") else b"#!"
    return b"#!"


def get_flags(line: bytes, config: Config) -> bytes:
    """
    Extracts existing flags and merges them with user-defined additions.
    Handles the common Linux shell limitation where the entire argument string
    is passed as a single block to the interpreter.
    """
    old_flags = b""
    if config.keep_flags:
        shebang = line.rstrip(b"\n\r")
        start = shebang.find(b" -")
        if start != -1:
            old_flags = shebang[start + 2 :]

    if not (old_flags or config.add_flags):
        return b""

    # Construction: Join added flags and old flags behind a single '-'
    return b" -" + config.add_flags + old_flags


def fix_line(line: bytes, config: Config) -> bytes:
    """
    Core shebang transformation logic.
    Only proceeds if the line is a valid Python shebang.
    """
    if not line.startswith(b"#!") or b"python" not in line.lower():
        return line

    style = get_shebang_style(line, config)
    flags = get_flags(line, config)
    return style + config.new_interpreter + flags + b"\n"


def is_python_candidate(path_obj: Path, config: Config) -> bool:
    """
    Determines if a file is a valid candidate for shebang fixing.
    Uses a multi-stage check:
    1. Exclusion filter (manual/named/patterns).
    2. Optional filename pattern (-t).
    3. Extension check (.py).
    4. Heuristic header check (Binary read of extensionless files).
    """
    name = path_obj.name

    # 1. Custom Exclusion Audit
    for pattern in config.custom_excludes:
        if fnmatch.fnmatch(name, pattern):
            return False

    # 2. File Pattern filtering
    if config.file_pattern:
        return fnmatch.fnmatch(name, config.file_pattern)

    # 3. Standard Python extensions
    if path_obj.suffix == ".py":
        return True

    # 4. Identification of scripts without extensions (e.g. 'my_tool')
    if not path_obj.suffix:
        try:
            # Low-I/O header inspection
            with open(path_obj, "rb") as f:
                header = f.read(32)
                return header.startswith(b"#!") and b"python" in header.lower()
        except (IOError, PermissionError):
            pass
    return False


# --- TRANSACTIONAL LOGIC ---


def process_file(file_path: Path, config: Config) -> bool:
    """
    Safe Transactional Implementation.
    Protects original data using a bit-perfect backup and atomic replacement.

    Data Flow in this function:
      1. Stat original metadata.
      2. Write bit-perfect .bak file (Mandatory safety net).
      3. Process shebang transformation in memory.
      4. Write result to hidden temporary file (@+name).
      5. Atomic swap (os.replace).
      6. Metadata restoration (copymode/utime).
      7. Cleanup backup unless -b is set.
    """
    backup_path = file_path.with_name(file_path.name + ".bak")
    temp_path = file_path.with_name("@" + file_path.name)

    try:
        # Phase 1: Security Setup
        original_stat = file_path.stat()
        shutil.copy2(file_path, backup_path)
        logger.debug(f"{file_path}: Established safety net (.bak)")

        # Phase 2: Processing (Closed loop)
        with open(file_path, "rb") as f:
            first_line = f.readline()
            new_first_line = fix_line(first_line, config)

            # Optimization: Skip if no change is actualy required
            if first_line == new_first_line:
                backup_path.unlink()
                return False

            try:
                with open(temp_path, "wb") as g:
                    logger.info(f"{file_path}: Updating shebang...")
                    g.write(new_first_line)
                    shutil.copyfileobj(f, g)  # Stream remainder of file efficiently
            except Exception as e:
                if temp_path.exists():
                    temp_path.unlink()
                raise e

        # Phase 3: Committal
        # On modern systems, os.replace is atomic (File is never missing or empty).
        shutil.copymode(file_path, temp_path)  # Transfer permission bits
        os.replace(temp_path, file_path)

        # Restore timestamps if requested
        if config.preserve_timestamps:
            os.utime(file_path, (original_stat.st_atime, original_stat.st_mtime))

        # Final cleanup of the transactional safety net
        if not config.keep_backup:
            backup_path.unlink()

        return False

    except Exception as e:
        logger.error(f"ENGINE FAILURE: {file_path}: {e}")

        # ROLLBACK ARCHITECTURE
        # If the transaction fails, we attempt to restore the original file state.
        if backup_path.exists():
            logger.warning(
                f"ROLLBACK: Attempting to restore {file_path} from safety backup..."
            )
            try:
                os.replace(backup_path, file_path)
                logger.info("ROLLBACK SUCCESSFUL: File restored to original state.")
            except OSError as roll_err:
                logger.critical(
                    f"FATAL ROLLBACK ERROR: Manual intervention required! Copy at {backup_path}: {roll_err}"
                )

        if temp_path.exists():
            temp_path.unlink()

        return True


def walk_and_process(start_path: Path, config: Config) -> int:
    """
    High-performance directory walker with pruning.

    Exclusions:
      - All hidden directories (starting with '.') are skipped.
      - Known 'Noise' directories (node_modules, build, etc.) are skipped.
      - User-defined exclusions are checked via fnmatch.
    """
    errors = 0
    start_depth = len(start_path.parts)

    for root, dirs, files in os.walk(start_path):
        root_path = Path(root)
        current_depth = len(root_path.parts) - start_depth

        # 1. Pruning: Recursive Depth Control
        if config.max_depth is not None and current_depth >= config.max_depth:
            dirs[:] = []  # Instructs os.walk to not enter subdirectories

        # 2. Pruning: Directory Name Exclusion
        dirs[:] = [
            d
            for d in dirs
            if not d.startswith(".")
            and d not in DEFAULT_EXCLUDE_DIRS
            and not any(fnmatch.fnmatch(d, p) for p in config.custom_excludes)
        ]

        # 3. File Processing loop
        for name in files:
            file_path = root_path / name
            if is_python_candidate(file_path, config):
                if process_file(file_path, config):
                    errors += 1
    return errors


# --- INTERFACE ENTRY POINT ---


def main():
    """
    Primary Entry Point.
    Maps CLI arguments to the Config dataclass and initiates the walk.
    """
    args = parse_args()

    # Process comma-separated exclusion strings into a lookup set
    custom_ex = set()
    if args.exclude:
        custom_ex = {x.strip() for x in args.exclude.split(",")}

    config = Config(
        new_interpreter=args.interpreter.encode(),
        preserve_timestamps=args.preserve,
        keep_backup=args.backup,
        keep_flags=args.keep_flags,
        add_flags=args.add_flags.encode(),
        keep_space=args.keep_space,
        file_pattern=args.file_pattern,
        max_depth=args.scope,
        custom_excludes=custom_ex,
    )

    # Core processing sequence
    exit_code = 0
    for path_str in args.paths:
        path = Path(path_str)
        if not path.exists():
            logger.warning(f"SKIPPING: {path} (Not found)")
            exit_code = 1
            continue

        if path.is_file():
            # Handle explicit file paths passed on the CLI
            if is_python_candidate(path, config):
                if process_file(path, config):
                    exit_code = 1
        elif path.is_dir():
            # Handle recursive directory scanning
            exit_code += walk_and_process(path, config)
        else:
            logger.warning(f"SKIPPING: {path} (Invalid file type)")
            exit_code = 1

    # Exit with failure code if any file encountered an error
    sys.exit(1 if exit_code > 0 else 0)


if __name__ == "__main__":
    main()
