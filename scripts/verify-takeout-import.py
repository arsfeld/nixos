#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Verify a Google Takeout extraction, and its import into Immich.

Two checks, two different questions, deliberately kept in one tool because the
second is meaningless without the first:

    extraction  Does every JSON sidecar have its media file next to it?
                A Google Photos takeout ships one <media>.json per asset. A
                sidecar with no media is the signature of a truncated or
                interrupted extraction — the tree looks populated, and the
                missing half is invisible until you count.

    import      Is every extracted media file's *content* present in Immich?
                Compares SHA-1 of each file against `asset.checksum`, which is
                exactly what Immich deduplicates on. Filename comparison is not
                good enough: Immich's storage template renames files, and names
                like IMG_0012.HEIC repeat across years.

The import check is what earns the right to delete the archives. Anything short
of "zero absent" means something in the takeout exists nowhere else.

Usage:
    ./verify-takeout-import.py extraction /mnt/storage/files/Takeout/extracted
    ./verify-takeout-import.py import     /mnt/storage/files/Takeout/extracted
    ./verify-takeout-import.py import /path --workers 4 --out-dir /tmp/report

Run on the Immich host: the import check shells out to psql, and the default
`sudo -u postgres` prefix is how root reaches the immich database there (peer
auth refuses root->postgres directly).
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

# JSON files that describe an album or the account, not an individual asset.
# Counting these as orphaned sidecars would invent thousands of phantom losses.
NON_ASSET_JSON = {
    "metadata.json",
    "print-subscriptions.json",
    "shared_album_comments.json",
    "user-generated-memory-titles.json",
}

# Google has used both spellings for the per-asset sidecar.
SIDECAR_SUFFIXES = (".supplemental-metadata.json", ".json")

NON_MEDIA_SUFFIXES = {".json", ".html"}


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


def media_files(root: Path) -> list[Path]:
    """Every file in the tree that is not a sidecar or the archive browser."""
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if Path(name).suffix.lower() in NON_MEDIA_SUFFIXES:
                continue
            found.append(Path(dirpath) / name)
    return found


def sidecar_target(path: Path) -> Path | None:
    """The media file a sidecar refers to, or None if it is not a sidecar."""
    if path.name in NON_ASSET_JSON:
        return None
    name = path.name
    for suffix in SIDECAR_SUFFIXES:
        if name.endswith(suffix):
            return path.with_name(name[: -len(suffix)])
    return None


# ---------------------------------------------------------------------------
# extraction check
# ---------------------------------------------------------------------------


@dataclass
class ExtractionResult:
    sidecars: int = 0
    present: int = 0
    missing: int = 0
    missing_paths: list[str] = field(default_factory=list)


def check_extraction(root: Path) -> ExtractionResult:
    result = ExtractionResult()
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if not name.lower().endswith(".json"):
                continue
            target = sidecar_target(Path(dirpath) / name)
            if target is None:
                continue
            result.sidecars += 1
            if target.exists():
                result.present += 1
            else:
                result.missing += 1
                result.missing_paths.append(str(target))
    return result


# ---------------------------------------------------------------------------
# import check
# ---------------------------------------------------------------------------


def immich_checksums(psql_prefix: list[str], database: str) -> set[str]:
    """Every checksum Immich currently tracks, as lowercase hex.

    Immich stores checksum as a bytea sha1; encode() on the server side is far
    cheaper than shipping raw bytes through psql's text output.
    """
    argv = [*psql_prefix, "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-d", database]
    result = subprocess.run(
        argv,
        input="SELECT encode(checksum, 'hex') FROM asset;",
        check=True,
        capture_output=True,
        text=True,
    )
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def sha1(path: Path) -> tuple[Path, str | None]:
    digest = hashlib.sha1()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return path, None
    return path, digest.hexdigest()


def check_import(root: Path, psql_prefix: list[str], database: str, workers: int) -> dict:
    log("querying Immich checksums")
    known = immich_checksums(psql_prefix, database)
    log(f"{len(known)} checksums in Immich")

    files = media_files(root)
    log(f"{len(files)} media files to hash")

    absent: list[str] = []
    unreadable: list[str] = []
    seen: set[str] = set()
    matched_contents: set[str] = set()
    done = 0

    # Threads, not processes: this is disk-bound, and hashlib releases the GIL.
    # Keep the worker count low — a spinning array serving other services loses
    # more to seeking than it gains from parallel readers.
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for path, digest in pool.map(sha1, files):
            done += 1
            if done % 2000 == 0:
                log(f"hashed {done}/{len(files)}")
            if digest is None:
                unreadable.append(str(path))
                continue
            seen.add(digest)
            if digest in known:
                matched_contents.add(digest)
            else:
                absent.append(str(path))

    absent_bytes = 0
    absent_inodes = set()
    for name in absent:
        try:
            stat = os.stat(name)
        except OSError:
            continue
        if stat.st_ino in absent_inodes:
            continue
        absent_inodes.add(stat.st_ino)
        absent_bytes += stat.st_size

    return {
        "files_hashed": len(files),
        "unique_contents": len(seen),
        "contents_in_immich": len(matched_contents),
        "contents_absent": len(seen) - len(matched_contents),
        "absent_paths": len(absent),
        "absent_unique_files": len(absent_inodes),
        "absent_bytes": absent_bytes,
        "absent_gib": round(absent_bytes / 1024**3, 1),
        "unreadable": len(unreadable),
        "_absent_list": absent,
        "_unreadable_list": unreadable,
    }


# ---------------------------------------------------------------------------


def write_list(out_dir: Path | None, name: str, rows: list[str]) -> str | None:
    if out_dir is None or not rows:
        return None
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / name
    target.write_text("\n".join(rows) + "\n")
    return str(target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["extraction", "import"])
    parser.add_argument("root", type=Path, help="Root of the extracted takeout tree")
    parser.add_argument("--workers", type=int, default=4, help="Hashing threads (import mode)")
    parser.add_argument("--database", default="immich")
    parser.add_argument(
        "--psql",
        default="sudo -u postgres psql",
        help="Command used to reach the Immich database (default: %(default)s)",
    )
    parser.add_argument("--out-dir", type=Path, default=None, help="Write detail lists here")
    args = parser.parse_args()

    if not args.root.is_dir():
        sys.exit(f"not a directory: {args.root}")

    if args.mode == "extraction":
        result = check_extraction(args.root)
        summary = {
            "mode": "extraction",
            "root": str(args.root),
            "sidecars": result.sidecars,
            "media_present": result.present,
            "media_missing": result.missing,
        }
        summary["missing_list"] = write_list(args.out_dir, "missing-media.txt", result.missing_paths)
        print(json.dumps(summary, indent=2))
        # Exit non-zero on an incomplete extraction so a runbook can gate on it.
        return 0 if result.missing == 0 else 1

    result = check_import(args.root, args.psql.split(), args.database, args.workers)
    absent_list = result.pop("_absent_list")
    unreadable_list = result.pop("_unreadable_list")
    result["mode"] = "import"
    result["root"] = str(args.root)
    result["absent_list"] = write_list(args.out_dir, "absent-from-immich.txt", absent_list)
    result["unreadable_list"] = write_list(args.out_dir, "unreadable.txt", unreadable_list)
    print(json.dumps(result, indent=2))
    return 0 if result["contents_absent"] == 0 and result["unreadable"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
