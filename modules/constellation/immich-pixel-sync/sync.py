#!/usr/bin/env python3
"""Stage recent Immich assets into a flat directory for Syncthing → Pixel → Google Photos.

The staging directory is the only state. Every staged filename is a pure function of
the asset row it came from, so a run reconciles by comparing the filenames the query
wants against the filenames already on disk — there is no manifest to drift out of
sync with reality.
"""

from __future__ import annotations

import argparse
import os
import re
import struct
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
    if not desired:
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


def stage_plain(asset: dict, dest: Path) -> None:
    """Hardlink the original into staging.

    No bytes copied, and unlinking the staged name later cannot touch Immich's
    original — the reap path only ever removes one of two names for one inode.
    """
    os.link(asset["originalPath"], dest)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Stage recent Immich assets for the Pixel.")
    parser.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    parser.add_argument("--force", action="store_true", help="proceed past the shrink guard")
    parser.parse_args(argv)
    log("not implemented yet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
