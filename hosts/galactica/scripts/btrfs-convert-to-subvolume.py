#!/usr/bin/env python3
"""
Convert plain btrfs directories to subvolumes in-place.

Each directory is converted by:
  1. Creating a new subvolume alongside it (.subvol-new)
  2. Copying contents with cp --reflink=always (instant on btrfs)
  3. Renaming original to .subvol-old, new subvolume into place
  4. Old directory can be cleaned up later with the 'cleanup' command

Usage:
  btrfs-convert-to-subvolume status /mnt/storage
  btrfs-convert-to-subvolume convert /mnt/storage/watch --dry-run
  btrfs-convert-to-subvolume convert-all /mnt/storage --dry-run
  btrfs-convert-to-subvolume cleanup /mnt/storage
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

# ANSI colors
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
BOLD = "\033[1m"
RESET = "\033[0m"


def color(text: str, c: str) -> str:
    if not sys.stdout.isatty():
        return text
    return f"{c}{text}{RESET}"


def run(cmd: list[str], check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    """Run a command with list args (no shell injection)."""
    result = subprocess.run(cmd, check=check, capture_output=capture, text=True)
    return result


def is_btrfs_mount(path: Path) -> bool:
    """Check if path is on a btrfs filesystem."""
    try:
        result = run(["stat", "-f", "-c", "%T", str(path)], capture=True)
        return result.stdout.strip() == "btrfs"
    except subprocess.CalledProcessError:
        return False


def is_subvolume(path: Path) -> bool:
    """Check if path is already a btrfs subvolume."""
    try:
        result = run(["btrfs", "subvolume", "show", str(path)], capture=True, check=False)
        return result.returncode == 0
    except FileNotFoundError:
        return False


def get_directories(mount: Path) -> list[Path]:
    """Get immediate subdirectories of mount point, excluding hidden/special dirs."""
    dirs = []
    for entry in sorted(mount.iterdir()):
        if entry.is_dir() and not entry.name.startswith("."):
            dirs.append(entry)
    return dirs


def convert_directory(target: Path, dry_run: bool = False) -> bool:
    """Convert a single directory to a btrfs subvolume.

    Returns True on success, False on failure.
    """
    target = target.resolve()
    parent = target.parent
    name = target.name

    new_path = parent / f".{name}.subvol-new"
    old_path = parent / f".{name}.subvol-old"

    # Validations
    if not target.is_dir():
        print(color(f"  ERROR: {target} is not a directory", RED))
        return False

    if not is_btrfs_mount(target):
        print(color(f"  ERROR: {target} is not on a btrfs filesystem", RED))
        return False

    if is_subvolume(target):
        print(color(f"  SKIP: {target} is already a subvolume", YELLOW))
        return True

    if new_path.exists():
        print(color(f"  ERROR: {new_path} already exists (stale state from previous run?)", RED))
        print(f"  Remove it manually if the previous conversion was interrupted:")
        print(f"    btrfs subvolume delete {new_path}")
        return False

    if old_path.exists():
        print(color(f"  ERROR: {old_path} already exists (needs cleanup?)", RED))
        print(f"  Run 'cleanup' command or remove it manually:")
        print(f"    rm -rf {old_path}")
        return False

    if dry_run:
        print(color(f"  DRY RUN: Would convert {target}", BLUE))
        print(f"    1. btrfs subvolume create {new_path}")
        print(f"    2. cp -a --reflink=always {target}/. {new_path}/")
        print(f"    3. mv {target} {old_path}")
        print(f"    4. mv {new_path} {target}")
        return True

    print(f"  Creating subvolume {new_path} ...")
    try:
        run(["btrfs", "subvolume", "create", str(new_path)])
    except subprocess.CalledProcessError as e:
        print(color(f"  ERROR: Failed to create subvolume: {e}", RED))
        return False

    print(f"  Copying contents with reflink ...")
    try:
        run(["cp", "-a", "--reflink=always", f"{target}/.", f"{new_path}/"])
    except subprocess.CalledProcessError as e:
        print(color(f"  ERROR: Copy failed: {e}", RED))
        print(f"  Cleaning up partial subvolume ...")
        try:
            run(["btrfs", "subvolume", "delete", str(new_path)])
        except subprocess.CalledProcessError:
            print(color(f"  WARNING: Failed to clean up {new_path}, remove manually", RED))
        return False

    print(f"  Swapping directories ...")
    try:
        run(["mv", str(target), str(old_path)])
        run(["mv", str(new_path), str(target)])
    except subprocess.CalledProcessError as e:
        print(color(f"  ERROR: Rename failed: {e}", RED))
        print(color(f"  WARNING: Filesystem may be in inconsistent state!", RED))
        print(f"  Check: {old_path} and {new_path}")
        return False

    print(color(f"  OK: {target} is now a subvolume", GREEN))
    print(f"  Old data at {old_path} (remove with 'cleanup' command)")
    return True


def cmd_status(args: argparse.Namespace) -> int:
    """Show subvolume status for directories under a mount point."""
    mount = Path(args.mount).resolve()

    if not mount.is_dir():
        print(color(f"ERROR: {mount} is not a directory", RED), file=sys.stderr)
        return 1

    if not is_btrfs_mount(mount):
        print(color(f"ERROR: {mount} is not a btrfs filesystem", RED), file=sys.stderr)
        return 1

    print(f"Status of directories under {color(str(mount), BOLD)}:\n")

    dirs = get_directories(mount)
    if not dirs:
        print("  No directories found.")
        return 0

    subvols = 0
    regular = 0
    stale = 0

    for d in dirs:
        if is_subvolume(d):
            print(f"  {color('[subvolume]', GREEN)}  {d.name}")
            subvols += 1
        else:
            print(f"  {color('[directory]', YELLOW)}  {d.name}")
            regular += 1

    # Check for stale conversion artifacts
    for entry in sorted(mount.iterdir()):
        if entry.name.startswith(".") and entry.name.endswith(".subvol-old"):
            print(f"  {color('[stale-old]', RED)}  {entry.name}")
            stale += 1
        elif entry.name.startswith(".") and entry.name.endswith(".subvol-new"):
            print(f"  {color('[stale-new]', RED)}  {entry.name}")
            stale += 1

    print(f"\nSummary: {subvols} subvolumes, {regular} directories", end="")
    if stale:
        print(f", {color(f'{stale} stale artifacts', RED)}", end="")
    print()

    return 0


def cmd_convert(args: argparse.Namespace) -> int:
    """Convert a single directory to a subvolume."""
    target = Path(args.path).resolve()
    print(f"Converting {color(str(target), BOLD)} ...")
    success = convert_directory(target, dry_run=args.dry_run)
    return 0 if success else 1


def cmd_convert_all(args: argparse.Namespace) -> int:
    """Convert all directories under a mount point."""
    mount = Path(args.mount).resolve()

    if not mount.is_dir():
        print(color(f"ERROR: {mount} is not a directory", RED), file=sys.stderr)
        return 1

    if not is_btrfs_mount(mount):
        print(color(f"ERROR: {mount} is not a btrfs filesystem", RED), file=sys.stderr)
        return 1

    dirs = get_directories(mount)
    if not dirs:
        print("No directories found to convert.")
        return 0

    # Filter to only non-subvolume directories
    to_convert = [d for d in dirs if not is_subvolume(d)]
    if not to_convert:
        print("All directories are already subvolumes.")
        return 0

    print(f"Converting {len(to_convert)} directories under {color(str(mount), BOLD)}:\n")

    failures = 0
    for d in to_convert:
        print(f"Converting {color(d.name, BOLD)} ...")
        if not convert_directory(d, dry_run=args.dry_run):
            failures += 1
        print()

    if failures:
        print(color(f"\n{failures} conversion(s) failed.", RED))
        return 1

    if args.dry_run:
        print(color("\nDry run complete. No changes made.", BLUE))
    else:
        print(color(f"\nAll {len(to_convert)} directories converted successfully.", GREEN))
    return 0


def cmd_cleanup(args: argparse.Namespace) -> int:
    """Remove .subvol-old directories after verifying conversions."""
    mount = Path(args.mount).resolve()

    if not mount.is_dir():
        print(color(f"ERROR: {mount} is not a directory", RED), file=sys.stderr)
        return 1

    old_dirs = sorted(
        entry for entry in mount.iterdir()
        if entry.name.startswith(".") and entry.name.endswith(".subvol-old") and entry.is_dir()
    )

    if not old_dirs:
        print("No .subvol-old directories found.")
        return 0

    print(f"Found {len(old_dirs)} old directories to clean up:\n")

    failures = 0
    for old_dir in old_dirs:
        # Derive the expected subvolume name
        # .foo.subvol-old -> foo
        original_name = old_dir.name[1:].removesuffix(".subvol-old")
        expected = mount / original_name

        if not expected.exists():
            print(color(f"  WARNING: {expected} does not exist, skipping {old_dir.name}", YELLOW))
            failures += 1
            continue

        if not is_subvolume(expected):
            print(color(f"  WARNING: {expected} is not a subvolume, skipping {old_dir.name}", YELLOW))
            failures += 1
            continue

        if args.dry_run:
            print(f"  {color('DRY RUN', BLUE)}: Would remove {old_dir.name}")
            continue

        print(f"  Removing {old_dir.name} ...")
        try:
            run(["rm", "-rf", str(old_dir)])
            print(color(f"  OK: {old_dir.name} removed", GREEN))
        except subprocess.CalledProcessError as e:
            print(color(f"  ERROR: Failed to remove {old_dir.name}: {e}", RED))
            failures += 1

    if args.dry_run:
        print(color("\nDry run complete. No changes made.", BLUE))
    elif failures:
        print(color(f"\n{failures} cleanup(s) failed.", RED))
        return 1
    else:
        print(color(f"\nAll {len(old_dirs)} old directories cleaned up.", GREEN))

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert btrfs directories to subvolumes in-place.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # status
    p_status = subparsers.add_parser("status", help="Show subvolume status of directories")
    p_status.add_argument("mount", help="Mount point to inspect (e.g. /mnt/storage)")

    # convert
    p_convert = subparsers.add_parser("convert", help="Convert a single directory to a subvolume")
    p_convert.add_argument("path", help="Directory to convert")
    p_convert.add_argument("--dry-run", action="store_true", help="Show what would be done")

    # convert-all
    p_convert_all = subparsers.add_parser("convert-all", help="Convert all directories under a mount point")
    p_convert_all.add_argument("mount", help="Mount point (e.g. /mnt/storage)")
    p_convert_all.add_argument("--dry-run", action="store_true", help="Show what would be done")

    # cleanup
    p_cleanup = subparsers.add_parser("cleanup", help="Remove .subvol-old directories after conversion")
    p_cleanup.add_argument("mount", help="Mount point (e.g. /mnt/storage)")
    p_cleanup.add_argument("--dry-run", action="store_true", help="Show what would be done")

    args = parser.parse_args()

    commands = {
        "status": cmd_status,
        "convert": cmd_convert,
        "convert-all": cmd_convert_all,
        "cleanup": cmd_cleanup,
    }

    return commands[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
