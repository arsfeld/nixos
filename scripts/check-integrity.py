#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "Pillow>=10.0",
#     "mutagen>=1.47",
#     "pikepdf>=8.0",
# ]
# ///
"""
File integrity checker for bcachefs corruption recovery.

Scans directories for corrupted files using format-specific validation
and null-byte heuristic detection. Designed for checking rsync'd files
where corrupted blocks became null bytes.

Usage:
    ./check-integrity.py /mnt/restore/homes
    ./check-integrity.py /mnt/restore/servarica-restored/home --workers 8
    ./check-integrity.py /path/to/dir 2>progress.log | tee results.jsonl
"""

import argparse
import csv
import json
import os
import sys
import tarfile
import time
import zipfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import asdict, dataclass

# Format-specific imports are done inside check functions to avoid
# issues with multiprocessing on some systems.

# ---------------------------------------------------------------------------
# File format extensions
# ---------------------------------------------------------------------------

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".tiff", ".tif", ".bmp"}
AUDIO_EXTS = {".mp3", ".flac", ".ogg"}
ZIP_EXTS = {".zip", ".epub"}
TAR_EXTS = {".tar"}
TGZ_EXTS = {".tar.gz", ".tgz"}
PDF_EXTS = {".pdf"}
VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".webm"}
RAR_EXTS = {".rar"}

ALL_CHECKED_EXTS = (
    IMAGE_EXTS | AUDIO_EXTS | ZIP_EXTS | TAR_EXTS | TGZ_EXTS
    | PDF_EXTS | VIDEO_EXTS | RAR_EXTS
)


# ---------------------------------------------------------------------------
# Result dataclass
# ---------------------------------------------------------------------------

@dataclass
class CheckResult:
    path: str
    status: str          # ok, corrupt, error
    format: str
    detail: str = ""
    null_blocks: int = 0
    size: int = 0


# ---------------------------------------------------------------------------
# Null-byte heuristic
# ---------------------------------------------------------------------------

def count_null_runs(filepath: str, threshold: int = 4096) -> int:
    """Count runs of consecutive null bytes >= threshold.

    Skips the first 4KB of the file to avoid false positives on headers
    that legitimately contain null padding.
    """
    SKIP_HEADER = 4096
    BUFSIZE = 1024 * 1024  # 1MB read buffer
    count = 0
    run_length = 0

    try:
        file_size = os.path.getsize(filepath)
        if file_size <= SKIP_HEADER:
            return 0

        with open(filepath, "rb") as f:
            f.seek(SKIP_HEADER)
            while True:
                buf = f.read(BUFSIZE)
                if not buf:
                    break
                for byte in buf:
                    if byte == 0:
                        run_length += 1
                    else:
                        if run_length >= threshold:
                            count += 1
                        run_length = 0
            # Handle run at end of file
            if run_length >= threshold:
                count += 1
    except OSError:
        pass

    return count


# ---------------------------------------------------------------------------
# Format-specific checkers
# ---------------------------------------------------------------------------

def check_image(filepath: str) -> tuple[str, str]:
    """Validate image using Pillow verify() + full decode."""
    from PIL import Image

    # First pass: verify() checks structural integrity
    with Image.open(filepath) as img:
        img.verify()

    # Second pass: load() does full pixel decode (verify() invalidates the image)
    with Image.open(filepath) as img:
        img.load()

    return "ok", ""


def check_mp3(filepath: str) -> tuple[str, str]:
    """Validate MP3 using mutagen."""
    from mutagen.mp3 import MP3, HeaderNotFoundError

    try:
        audio = MP3(filepath)
    except HeaderNotFoundError:
        return "corrupt", "No valid MP3 header found"

    if audio.info.sketchy:
        return "corrupt", "MP3 parsed but flagged as sketchy (incomplete/damaged frames)"

    return "ok", ""


def check_flac(filepath: str) -> tuple[str, str]:
    """Validate FLAC using mutagen."""
    from mutagen.flac import FLAC, FLACNoHeaderError

    try:
        FLAC(filepath)
    except FLACNoHeaderError:
        return "corrupt", "No valid FLAC header found"

    return "ok", ""


def check_ogg(filepath: str) -> tuple[str, str]:
    """Validate OGG using mutagen."""
    from mutagen.oggvorbis import OggVorbis, OggVorbisHeaderError

    try:
        OggVorbis(filepath)
    except OggVorbisHeaderError as e:
        return "corrupt", f"OGG Vorbis header error: {e}"

    return "ok", ""


def check_zip(filepath: str) -> tuple[str, str]:
    """Validate ZIP/EPUB using CRC-32 checks."""
    with zipfile.ZipFile(filepath, "r") as zf:
        # Skip encrypted zips - we can't verify without a password
        if any(zi.flag_bits & 0x1 for zi in zf.infolist()):
            return "ok", ""
        bad = zf.testzip()
        if bad is not None:
            return "corrupt", f"CRC mismatch in archive member: {bad}"

    return "ok", ""


def check_tar(filepath: str, compressed: bool = False) -> tuple[str, str]:
    """Validate tar/tgz by iterating all members."""
    mode = "r:gz" if compressed else "r:"
    with tarfile.open(filepath, mode) as tf:
        for member in tf:
            if member.isfile():
                f = tf.extractfile(member)
                if f is not None:
                    # Read through entire member to detect corruption
                    while f.read(1024 * 1024):
                        pass
                    f.close()

    return "ok", ""


def check_pdf(filepath: str) -> tuple[str, str]:
    """Validate PDF using pikepdf (QPDF backend). Falls back to header check."""
    try:
        import pikepdf
    except (ImportError, OSError):
        # pikepdf C extension unavailable (e.g. NixOS) - check header only
        with open(filepath, "rb") as f:
            header = f.read(5)
        if header != b"%PDF-":
            return "corrupt", "Missing PDF header"
        return "ok", ""

    with pikepdf.open(filepath) as pdf:
        pdf.check()

    return "ok", ""


# ---------------------------------------------------------------------------
# Main check dispatcher
# ---------------------------------------------------------------------------

def get_format(filepath: str) -> str | None:
    """Determine file format from extension."""
    lower = filepath.lower()

    # Check multi-part extensions first
    if lower.endswith(".tar.gz"):
        return "tar.gz"

    ext = os.path.splitext(lower)[1]

    if ext in IMAGE_EXTS:
        return ext.lstrip(".")
    if ext == ".mp3":
        return "mp3"
    if ext == ".flac":
        return "flac"
    if ext == ".ogg":
        return "ogg"
    if ext == ".zip":
        return "zip"
    if ext == ".epub":
        return "epub"
    if ext == ".tar":
        return "tar"
    if ext == ".tgz":
        return "tar.gz"
    if ext in PDF_EXTS:
        return "pdf"
    if ext in VIDEO_EXTS:
        return ext.lstrip(".")
    if ext in RAR_EXTS:
        return "rar"

    return None


def check_file(filepath: str, null_threshold: int = 4096) -> CheckResult | None:
    """Check a single file for integrity. Returns None if format not supported."""
    fmt = get_format(filepath)
    if fmt is None:
        return None

    try:
        size = os.path.getsize(filepath)
    except OSError as e:
        return CheckResult(
            path=filepath, status="error", format=fmt or "unknown",
            detail=f"Cannot stat file: {e}", size=0,
        )

    # Skip empty files
    if size == 0:
        return CheckResult(
            path=filepath, status="corrupt", format=fmt,
            detail="Empty file (0 bytes)", size=0,
        )

    status = "ok"
    detail = ""
    null_blocks = 0

    # Format-specific check
    try:
        if fmt in ("jpg", "jpeg", "png", "gif", "webp", "tiff", "tif", "bmp"):
            status, detail = check_image(filepath)
        elif fmt == "mp3":
            status, detail = check_mp3(filepath)
        elif fmt == "flac":
            status, detail = check_flac(filepath)
        elif fmt == "ogg":
            status, detail = check_ogg(filepath)
        elif fmt in ("zip", "epub"):
            status, detail = check_zip(filepath)
        elif fmt == "tar":
            status, detail = check_tar(filepath, compressed=False)
        elif fmt == "tar.gz":
            status, detail = check_tar(filepath, compressed=True)
        elif fmt == "pdf":
            status, detail = check_pdf(filepath)
        # Video and RAR: null-byte heuristic only (no format check)
    except Exception as e:
        status = "corrupt"
        detail = f"{type(e).__name__}: {e}"

    # Null-byte heuristic (supplemental check for all formats)
    try:
        null_blocks = count_null_runs(filepath, null_threshold)
        if null_blocks > 0 and status == "ok":
            status = "corrupt"
            detail = f"Found {null_blocks} run(s) of {null_threshold}+ consecutive null bytes"
        elif null_blocks > 0 and status == "corrupt":
            detail += f"; also found {null_blocks} null-byte run(s)"
    except Exception:
        pass

    return CheckResult(
        path=filepath, status=status, format=fmt,
        detail=detail, null_blocks=null_blocks, size=size,
    )


# ---------------------------------------------------------------------------
# Directory walker (streaming)
# ---------------------------------------------------------------------------

def walk_supported_files(root: str):
    """Yield supported files as they're discovered (no upfront collection)."""
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            if get_format(full) is not None:
                yield full


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def result_to_dict(r: CheckResult) -> dict:
    d = asdict(r)
    # Remove null_blocks if zero for cleaner output
    if d["null_blocks"] == 0:
        del d["null_blocks"]
    return d


def print_jsonl(result: CheckResult, file=sys.stdout):
    json.dump(result_to_dict(result), file, ensure_ascii=False)
    file.write("\n")
    file.flush()


def print_csv_row(result: CheckResult, writer):
    d = result_to_dict(result)
    writer.writerow(d)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Check file integrity in a directory tree. "
                    "Reports corrupt files detected via format-specific validation "
                    "and null-byte heuristic.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  %(prog)s /mnt/restore/homes
  %(prog)s /mnt/restore/homes --workers 8
  %(prog)s /mnt/restore/homes 2>progress.log | tee results.jsonl
  %(prog)s /mnt/restore/homes --csv > results.csv
  %(prog)s /mnt/restore/homes --summary-only""",
    )
    parser.add_argument("directory", help="Directory to scan recursively")
    parser.add_argument(
        "--workers", type=int, default=4,
        help="Number of parallel workers (default: 4)",
    )
    parser.add_argument(
        "--null-threshold", type=int, default=4096,
        help="Minimum consecutive null bytes to flag (default: 4096)",
    )
    output_group = parser.add_mutually_exclusive_group()
    output_group.add_argument(
        "--json", dest="output_format", action="store_const", const="json",
        default="json", help="Output JSON lines (default)",
    )
    output_group.add_argument(
        "--csv", dest="output_format", action="store_const", const="csv",
        help="Output CSV instead of JSON lines",
    )
    parser.add_argument(
        "--summary-only", action="store_true",
        help="Only print summary statistics, no per-file output",
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Output all files including OK ones (default: only corrupt/error)",
    )

    args = parser.parse_args()

    root = os.path.abspath(args.directory)
    if not os.path.isdir(root):
        print(f"Error: {root} is not a directory", file=sys.stderr)
        sys.exit(1)

    # Setup CSV writer if needed
    csv_writer = None
    if args.output_format == "csv" and not args.summary_only:
        csv_writer = csv.DictWriter(
            sys.stdout,
            fieldnames=["path", "status", "format", "detail", "null_blocks", "size"],
        )
        csv_writer.writeheader()

    # Stats
    stats = {"ok": 0, "corrupt": 0, "error": 0}
    format_stats: dict[str, dict[str, int]] = {}
    checked = 0
    submitted = 0
    start_time = time.monotonic()

    print(f"Checking {root} ...", file=sys.stderr)

    def process_result(result: CheckResult):
        nonlocal checked
        checked += 1
        stats[result.status] += 1

        # Per-format stats
        if result.format not in format_stats:
            format_stats[result.format] = {"ok": 0, "corrupt": 0, "error": 0, "total": 0}
        format_stats[result.format][result.status] += 1
        format_stats[result.format]["total"] += 1

        # Progress
        elapsed = time.monotonic() - start_time
        rate = checked / elapsed if elapsed > 0 else 0
        if result.status != "ok":
            # Print corrupt/error filename immediately on its own line
            print(
                f"\r  {result.status.upper()}: {result.path}",
                file=sys.stderr,
            )
        print(
            f"\r[{checked}] {stats['corrupt']} corrupt, "
            f"{stats['error']} errors ({rate:.0f} files/s)",
            end="", file=sys.stderr,
        )

        # Output
        if not args.summary_only:
            if args.all or result.status != "ok":
                if args.output_format == "csv":
                    print_csv_row(result, csv_writer)
                else:
                    print_jsonl(result)

    # Stream files to workers as they're discovered
    MAX_PENDING = args.workers * 4  # backpressure limit

    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        pending: dict = {}  # future -> filepath

        for filepath in walk_supported_files(root):
            # Submit work
            fut = executor.submit(check_file, filepath, args.null_threshold)
            pending[fut] = filepath
            submitted += 1

            # Drain completed futures when we hit backpressure limit
            if len(pending) >= MAX_PENDING:
                done_futures = [f for f in pending if f.done()]
                if not done_futures:
                    # Nothing ready yet, wait for at least one
                    done_iter = as_completed(list(pending.keys()))
                    done_futures = [next(done_iter)]
                for fut in done_futures:
                    fp = pending.pop(fut)
                    try:
                        result = fut.result()
                        if result is not None:
                            process_result(result)
                    except Exception as e:
                        result = CheckResult(
                            path=fp, status="error",
                            format=get_format(fp) or "unknown",
                            detail=f"Worker exception: {type(e).__name__}: {e}",
                        )
                        process_result(result)

        # Drain remaining futures
        for future in as_completed(list(pending.keys())):
            fp = pending[future]
            try:
                result = future.result()
                if result is not None:
                    process_result(result)
            except Exception as e:
                result = CheckResult(
                    path=fp, status="error",
                    format=get_format(fp) or "unknown",
                    detail=f"Worker exception: {type(e).__name__}: {e}",
                )
                process_result(result)

    # Final summary
    elapsed = time.monotonic() - start_time
    print(file=sys.stderr)  # newline after progress
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Integrity Check Summary", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)
    print(f"Directory:  {root}", file=sys.stderr)
    print(f"Total files checked: {checked}", file=sys.stderr)
    print(f"  OK:      {stats['ok']}", file=sys.stderr)
    print(f"  Corrupt: {stats['corrupt']}", file=sys.stderr)
    print(f"  Error:   {stats['error']}", file=sys.stderr)
    print(f"Time: {elapsed:.1f}s ({checked/elapsed:.0f} files/s)" if elapsed > 0 else "", file=sys.stderr)

    if format_stats:
        print(f"\nPer-format breakdown:", file=sys.stderr)
        print(f"  {'Format':<10} {'Total':>7} {'OK':>7} {'Corrupt':>7} {'Error':>7} {'Corrupt%':>8}", file=sys.stderr)
        print(f"  {'-'*10} {'-'*7} {'-'*7} {'-'*7} {'-'*7} {'-'*8}", file=sys.stderr)
        for fmt in sorted(format_stats.keys()):
            s = format_stats[fmt]
            pct = (s["corrupt"] / s["total"] * 100) if s["total"] > 0 else 0
            print(
                f"  {fmt:<10} {s['total']:>7} {s['ok']:>7} {s['corrupt']:>7} {s['error']:>7} {pct:>7.1f}%",
                file=sys.stderr,
            )

    print(f"{'='*60}", file=sys.stderr)

    # Exit code: 1 if any corrupt files found
    if stats["corrupt"] > 0 or stats["error"] > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
