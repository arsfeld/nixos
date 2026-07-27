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
import bisect
import hashlib
import json
import os
import re
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


def sidecar_stem(path: Path) -> str | None:
    """The media filename a sidecar refers to, or None if it is not a sidecar."""
    if path.name in NON_ASSET_JSON:
        return None
    name = path.name
    for suffix in SIDECAR_SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return None


# Google writes a duplicate's sidecar as `foo.jpg(1).json` while naming the media
# `foo(1).jpg` — the counter moves from after the extension to before it.
_DUPLICATE = re.compile(r"^(?P<stem>.+)\.(?P<ext>[A-Za-z0-9]+)\((?P<n>\d+)\)$")


def media_candidates(stem: str) -> list[str]:
    """Filenames that could satisfy a sidecar, most literal first.

    Three quirks, each of which makes a present file look missing:

      foo.jpg(1).json  ->  foo(1).jpg   the duplicate counter moves across the
                                        extension
      foo.jpg(1).json  ->  foo.jpg      or there is no second media file at all
                                        and Google simply emitted a second
                                        sidecar for the same one
      <51 chars>.json  ->  truncated    long names are cut, sometimes mid-
                                        extension ("..._COVER.jp")

    The truncation case cannot be resolved from the name alone; the caller
    handles it with a prefix match.
    """
    candidates = [stem]
    match = _DUPLICATE.match(stem)
    if match:
        candidates.append(f"{match['stem']}({match['n']}).{match['ext']}")
        candidates.append(f"{match['stem']}.{match['ext']}")
    return candidates


_TRUNCATED_DUPLICATE = re.compile(r"^(?P<base>.+?)\((?P<n>\d+)\)$")


def prefix_match(sorted_media: list[str], stem: str) -> bool:
    """Does some media file look like a truncated form of this sidecar's name?

    Google truncates long filenames, and truncates the sidecar and the media to
    *different* lengths, then appends any duplicate counter afterwards:

        sidecar  blob_https___genevievebeauprephotographe.pic-t(10).json
        media    blob_https___genevievebeauprephotographe.pic-ti(10).jpg

    So the counter lands at a different offset in each and a whole-stem prefix
    test fails. Where a counter is present, match on the part before it and
    require the candidate to carry the same counter — without that second
    condition, (10) would happily match (11).
    """
    def scan(prefix: str, needle: str | None) -> bool:
        index = bisect.bisect_left(sorted_media, prefix)
        while index < len(sorted_media) and sorted_media[index].startswith(prefix):
            if needle is None or needle in sorted_media[index]:
                return True
            index += 1
        return False

    if scan(stem, None):
        return True

    match = _TRUNCATED_DUPLICATE.match(stem)
    if not match:
        return False
    if scan(match["base"], f"({match['n']})"):
        return True

    # No counter in any candidate. Google also emits a second sidecar for a file
    # that has no second copy — two sidecars, one media, or two media truncated
    # to a single shared stem (a .gif and .mp4 of the same clip). Accept the
    # prefix alone here; the alternative is reporting present files as missing.
    return scan(match["base"], None)


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
    """Does every sidecar have its media file somewhere in the tree?

    Tree-wide, not per-directory, and that distinction is the whole game. A photo
    that belongs to an album is frequently stored only in the album folder while
    its "Photos from YYYY" folder carries just the sidecar. Checking directory by
    directory reports thousands of those as missing when nothing is missing at
    all.
    """
    result = ExtractionResult()

    sidecars: list[tuple[str, str]] = []  # (directory, media stem)
    all_media: set[str] = set()

    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if Path(name).suffix.lower() not in NON_MEDIA_SUFFIXES:
                all_media.add(name)
                continue
            if not name.lower().endswith(".json"):
                continue
            stem = sidecar_stem(Path(dirpath) / name)
            if stem is not None:
                sidecars.append((dirpath, stem))

    # Sorted once so the truncation case can bisect for a prefix instead of
    # scanning 75,000 names per sidecar.
    sorted_media = sorted(all_media)

    for dirpath, stem in sidecars:
        result.sidecars += 1

        if any(candidate in all_media for candidate in media_candidates(stem)):
            result.present += 1
            continue

        if prefix_match(sorted_media, stem):
            result.present += 1
            continue

        result.missing += 1
        result.missing_paths.append(str(Path(dirpath) / stem))

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
