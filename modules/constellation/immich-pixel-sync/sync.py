#!/usr/bin/env python3
"""Stage recent Immich assets into a flat directory for Syncthing → Pixel → Google Photos.

The staging directory is the only state. Every staged filename is a pure function of
the asset row it came from, so a run reconciles by comparing the filenames the query
wants against the filenames already on disk — there is no manifest to drift out of
sync with reality.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import struct
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


# Google Photos only recognises a Motion Photo when the filename matches
#   ^([^\s\/\\][^\/\\]*MP)\.(JPG|jpg|JPEG|jpeg|HEIC|heic|AVIF|avif)$
# so a pair whose primary is any other format ships as a plain still.
MOTION_PRIMARY_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".heic": "image/heic",
    ".avif": "image/avif",
}

# The spec permits video/quicktime with HEVC, so no transcode is needed.
MOTION_VIDEO_MIME = {
    ".mov": "video/quicktime",
    ".mp4": "video/mp4",
}

# Characters Android's storage layer rejects in a filename.
_UNSAFE = re.compile(r'[\\/:*?"<>|\x00-\x1f]')

# Immich stores originals 0600, and Syncthing runs as its own user that is only a
# member of the media group, so staged files have to be group-readable or every
# scan fails with "permission denied".
STAGED_MODE = 0o640


# The only source of truth for what should be staged.
#
# The final NOT EXISTS clause drops MOV halves of Live Photo pairs: they ship
# embedded inside their still, never standalone. It is NOT EXISTS rather than
# NOT IN because NOT IN against a nullable column silently returns nothing.
#
# visibility = 'timeline' is redundant today — every non-timeline asset in the
# library is a Live Photo MOV half, which NOT EXISTS already drops — but Immich's
# 'locked' visibility is its PIN-protected folder. Without this clause, the day
# something is locked or archived is the day it silently ships to Google Photos.
#
# :'notbefore' is the cutover floor. Google Photos deduplicates on file content,
# and muxing a Live Photo changes its bytes, so any photo it already holds from an
# earlier sync path comes back as a second copy rather than being recognised. The
# floor keeps the window from ever reaching back into already-uploaded history.
#
# A pair is selected on its *image* asset's date and the video half is pulled via
# livePhotoVideoId regardless of its own timestamp, which keeps pairs atomic at
# the window boundary.
SQL = """
SELECT coalesce(json_agg(t), '[]'::json) FROM (
  SELECT a.id,
         a."originalPath",
         a."originalFileName",
         to_char(a."fileCreatedAt" AT TIME ZONE 'UTC', 'YYYYMMDD_HH24MISS') AS ts,
         v."originalPath" AS live_video
  FROM asset a
  LEFT JOIN asset v ON v.id = a."livePhotoVideoId"
  WHERE a."ownerId" = :'owner'::uuid
    AND a."deletedAt" IS NULL
    AND a.status = 'active'
    AND NOT a."isOffline"
    AND a.visibility = 'timeline'
    AND a."fileCreatedAt" > now() - make_interval(days => :days)
    AND a."fileCreatedAt" >= :'notbefore'::timestamptz
    AND NOT EXISTS (SELECT 1 FROM asset p WHERE p."livePhotoVideoId" = a.id)
  ORDER BY a."fileCreatedAt"
) t;
"""


class Abort(Exception):
    """Stop the run before anything in the staging directory is touched."""


@dataclass(frozen=True)
class Config:
    staging: Path
    tmp: Path
    lock: Path
    owner_id: str
    window_days: int
    shrink_guard_percent: int
    not_before: str
    db_name: str
    db_user: str
    db_socket: str

    @classmethod
    def from_env(cls) -> "Config":
        def need(name: str) -> str:
            value = os.environ.get(name)
            if not value:
                sys.exit(f"{name} is not set")
            return value

        return cls(
            staging=Path(need("IPS_STAGING_DIR")),
            tmp=Path(need("IPS_TMP_DIR")),
            lock=Path(need("IPS_LOCK_FILE")),
            owner_id=need("IPS_OWNER_ID"),
            window_days=int(need("IPS_WINDOW_DAYS")),
            shrink_guard_percent=int(need("IPS_SHRINK_GUARD_PERCENT")),
            not_before=need("IPS_NOT_BEFORE"),
            db_name=need("IPS_DB_NAME"),
            db_user=need("IPS_DB_USER"),
            db_socket=need("IPS_DB_SOCKET"),
        )


def log(message: str) -> None:
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {message}", flush=True)


def sanitize(stem: str) -> str:
    """Make a filename stem safe for Android's storage layer."""
    cleaned = _UNSAFE.sub("_", stem)
    cleaned = re.sub(r"\s+", "_", cleaned).strip("._")
    return cleaned or "photo"


def is_motion(asset: dict) -> bool:
    """True when both halves of a Live Photo pair are formats the spec allows."""
    if not asset.get("live_video"):
        return False
    image_ext = os.path.splitext(asset["originalFileName"])[1].lower()
    video_ext = os.path.splitext(asset["live_video"])[1].lower()
    return image_ext in MOTION_PRIMARY_MIME and video_ext in MOTION_VIDEO_MIME


def staged_name(asset: dict) -> str:
    """Flat, collision-safe staging filename.

        20260724_143022_a1b2c3d4_IMG_2145.MP.heic   live pair, muxed
        20260724_143022_a1b2c3d4_IMG_2146.heic      everything else

    2,506 basenames repeat across the library, so the asset UUID prefix is what
    keeps a flat directory honest. Google Photos takes its date from EXIF, so the
    timestamp is only there for sort order and legibility.
    """
    stem, extension = os.path.splitext(asset["originalFileName"])
    suffix = ".MP" if is_motion(asset) else ""
    return f"{asset['ts']}_{asset['id'][:8]}_{sanitize(stem)}{suffix}{extension.lower()}"


def plan_actions(
    desired: dict,
    current: set,
    shrink_guard_percent: int,
    force: bool = False,
) -> tuple[dict, list]:
    """Decide what to stage and what to reap.

    `desired` maps staging filename → asset row; `current` is the set of filenames
    already staged. Reaping falls out of the window rather than being separate
    logic, so there is one code path to get right instead of two.

    Raises Abort rather than proceeding when the result looks like a failure
    dressed up as an answer — a bug here deletes photos off a phone.
    """
    # An empty result with files already staged is the signature of a broken query,
    # not of a real answer, so it must never be read as "delete everything".
    # Wanting nothing while nothing is staged is just a quiet period — right after
    # a cutover date, or a genuine gap in photos — and must not fail the unit
    # hourly. --force means the emptiness is deliberate: purge.
    if not desired and current and not force:
        raise Abort("query returned no assets; refusing to empty the staging directory")

    if current and not force:
        shrink = (len(current) - len(desired)) * 100 / len(current)
        if shrink > shrink_guard_percent:
            raise Abort(
                f"desired set is {shrink:.0f}% smaller than what is staged "
                f"({len(desired)} vs {len(current)}); refusing without --force"
            )

    to_add = {name: asset for name, asset in desired.items() if name not in current}
    to_delete = sorted(current - set(desired))
    return to_add, to_delete


def mpvd_box(video: bytes) -> bytes:
    """Wrap the video in the ISO-BMFF box Google's parser looks for at the tail."""
    return struct.pack(">I", 8 + len(video)) + b"mpvd" + video


def stage_plain(asset: dict, dest: Path, tmp_dir: Path) -> None:
    """Reflink the original into staging.

    Deliberately not a hardlink. Immich stores originals mode 0600, and Syncthing
    runs as a different user, so the staged copy must be group-readable. A hardlink
    shares its inode with Immich's original, which means chmod-ing the staged name
    would change the permissions of the original — a write into Immich's library,
    which this module must never do. A reflink is a separate inode over shared
    extents: free on btrfs, and its mode is its own.
    """
    scratch = tmp_dir / (dest.name + ".part")
    scratch.unlink(missing_ok=True)
    reflink_copy(Path(asset["originalPath"]), scratch)
    os.chmod(scratch, STAGED_MODE)
    os.replace(scratch, dest)


def fetch_assets(cfg: Config) -> list:
    """Run the selector query.

    psql connects over the unix socket as the Immich role; galactica's ident map
    (`immich-users media immich`) lets the media user do that without a password.
    Raises CalledProcessError if the query fails, which the caller turns into an
    abort — an unreachable database must never read as "delete everything".

    The query goes in on stdin, not `-c`. psql only interpolates `:'owner'` and
    `:days` while lexing stdin or a `-f` file; `-c` ships the string to the server
    untouched, which fails with `syntax error at or near ":"`.
    """
    result = subprocess.run(
        [
            "psql", "-X", "-A", "-t", "-q",
            "-v", "ON_ERROR_STOP=1",
            "-h", cfg.db_socket,
            "-U", cfg.db_user,
            "-d", cfg.db_name,
            "-v", f"owner={cfg.owner_id}",
            "-v", f"days={cfg.window_days}",
            "-v", f"notbefore={cfg.not_before}",
        ],
        input=SQL,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout.strip() or "[]")


def reflink_copy(src: Path, dst: Path) -> None:
    """Copy-on-write copy of the primary image.

    On btrfs this costs no space, and unlike a hardlink it guarantees the mux
    cannot write through into Immich's original.
    """
    subprocess.run(
        ["cp", "--reflink=auto", "--preserve=timestamps", "--", str(src), str(dst)],
        check=True,
        capture_output=True,
        text=True,
    )


def write_motion_xmp(path: Path, video_len: int, image_ext: str, video_ext: str) -> None:
    """Declare the Motion Photo container in XMP.

    exiftool 13.x ships the namespace as XMP-GContainer with the tag named
    ContainerDirectory, so no custom .ExifTool_config is needed. Padding=8 on the
    primary item accounts for the 8-byte `mpvd` header that separates the image
    bytes from the video.
    """
    directory = (
        "[{Item={Mime=" + MOTION_PRIMARY_MIME[image_ext]
        + ",Semantic=Primary,Length=0,Padding=8}},"
        "{Item={Mime=" + MOTION_VIDEO_MIME[video_ext]
        + ",Semantic=MotionPhoto,Length=" + str(video_len) + ",Padding=0}}]"
    )
    subprocess.run(
        [
            "exiftool", "-overwrite_original", "-q",
            "-XMP-GCamera:MotionPhoto=1",
            "-XMP-GCamera:MotionPhotoVersion=1",
            "-XMP-GCamera:MotionPhotoPresentationTimestampUs=-1",
            "-XMP-GContainer:ContainerDirectory=" + directory,
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def stage_motion(asset: dict, dest: Path, tmp_dir: Path) -> None:
    """Mux an Apple Live Photo pair into a Google Motion Photo.

    The XMP must be written *before* the video is appended: exiftool rewrites the
    ISO-BMFF box structure and would discard a trailing box it does not recognise.
    The HEIC passes through byte-identical, gain map and all, so HDR survives.
    """
    image = Path(asset["originalPath"])
    video = Path(asset["live_video"])
    scratch = tmp_dir / (dest.name + ".part")
    scratch.unlink(missing_ok=True)

    reflink_copy(image, scratch)
    video_bytes = video.read_bytes()
    write_motion_xmp(scratch, len(video_bytes), image.suffix.lower(), video.suffix.lower())
    with open(scratch, "ab") as handle:
        handle.write(mpvd_box(video_bytes))
    os.chmod(scratch, STAGED_MODE)
    os.replace(scratch, dest)


def scan_staged(staging: Path) -> set:
    """Filenames currently staged.

    Dotfiles are Syncthing's (.stfolder, .stignore, .stversions, in-flight temp
    files) and are none of this script's business.
    """
    return {
        entry.name
        for entry in staging.iterdir()
        if entry.is_file() and not entry.name.startswith(".")
    }


def clean_scratch(tmp: Path) -> None:
    """Drop half-written files left by a run that died mid-mux."""
    for leftover in tmp.glob("*.part"):
        leftover.unlink(missing_ok=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Stage recent Immich assets for the Pixel.")
    parser.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    parser.add_argument("--force", action="store_true", help="proceed past the shrink guard")
    args = parser.parse_args(argv)

    cfg = Config.from_env()
    cfg.staging.mkdir(parents=True, exist_ok=True)
    cfg.tmp.mkdir(parents=True, exist_ok=True)
    cfg.lock.parent.mkdir(parents=True, exist_ok=True)

    lock_fd = open(cfg.lock, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another run holds the lock; exiting")
        return 0

    try:
        try:
            assets = fetch_assets(cfg)
        except subprocess.CalledProcessError as exc:
            log(f"ABORT: selector query failed: {(exc.stderr or '').strip()}")
            return 1

        desired = {staged_name(asset): asset for asset in assets}
        current = scan_staged(cfg.staging)

        try:
            to_add, to_delete = plan_actions(
                desired, current, cfg.shrink_guard_percent, args.force
            )
        except Abort as exc:
            log(f"ABORT: {exc}")
            return 1

        log(f"{len(desired)} desired, {len(current)} staged, +{len(to_add)} -{len(to_delete)}")

        if args.dry_run:
            for name in sorted(to_add):
                log(f"  + {name}")
            for name in to_delete:
                log(f"  - {name}")
            return 0

        clean_scratch(cfg.tmp)

        added = 0
        failed = 0
        for name, asset in sorted(to_add.items()):
            dest = cfg.staging / name
            try:
                if is_motion(asset):
                    stage_motion(asset, dest, cfg.tmp)
                else:
                    stage_plain(asset, dest, cfg.tmp)
                added += 1
            except Exception as exc:  # one bad asset must not take down the run
                log(f"  failed to stage {name}: {exc}")
                if is_motion(asset):
                    # Ship the still under the same name. One photo loses its
                    # motion, the run survives, and the name stays stable so the
                    # next run does not churn the phone by deleting and re-adding
                    # it. To retry the mux, delete the staged file.
                    try:
                        stage_plain(asset, dest, cfg.tmp)
                        log(f"  staged {name} without motion")
                        added += 1
                        continue
                    except Exception as fallback_exc:
                        log(f"  fallback also failed for {name}: {fallback_exc}")
                failed += 1

        for name in to_delete:
            (cfg.staging / name).unlink(missing_ok=True)

        log(f"done: +{added} -{len(to_delete)} failed={failed}")
        return 0
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()


if __name__ == "__main__":
    sys.exit(main())
