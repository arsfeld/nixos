"""Downloading via yt-dlp."""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path


class DownloadError(RuntimeError):
    pass


def sanitize(name: str) -> str:
    name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "", name).strip()
    name = re.sub(r"\s+", " ", name)
    return name.rstrip(" .")


def episode_path(
    output_dir: str, series: str, year: int, season: int, number: int, title: str
) -> Path:
    show = sanitize(series)
    ep_title = sanitize(title) or f"Episode {number}"
    show_dir = (
        Path(output_dir) / f"{show} ({year})" if year else Path(output_dir) / show
    )
    season_dir = show_dir / f"Season {season:02d}"
    return season_dir / f"{show} ({year}) - S{season:02d}E{number:02d} - {ep_title}.mkv"


def is_downloaded(path: Path) -> bool:
    return any(path.parent.glob(f"{path.stem}.*")) or path.exists()


def find_ytdlp() -> str:
    ytdlp = shutil.which("yt-dlp")
    if not ytdlp:
        raise RuntimeError("yt-dlp not found on PATH")
    return ytdlp


def download(
    brightcove_url: str,
    dest: Path,
    *,
    quality: int,
    subtitles: bool,
    thumbnail: bool,
) -> bool:
    """Download an episode. Returns True on success, False if already present.

    Raises DownloadError if yt-dlp fails.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    if is_downloaded(dest):
        return False

    ytdlp = find_ytdlp()
    cmd = [
        ytdlp,
        "--no-warnings",
        "--no-overwrites",
        "--newline",
        "--continue",
        "-f",
        f"b[height<={quality}]/bv*[height<={quality}]+ba/b[height<={quality}]",
        "--merge-output-format",
        "mkv",
        "-o",
        str(dest),
    ]
    if subtitles:
        cmd += ["--write-subs", "--sub-langs", "fr-CA", "--embed-subs"]
    if thumbnail:
        cmd += ["--embed-metadata", "--embed-thumbnail"]
    cmd += [brightcove_url]

    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        raise DownloadError(f"yt-dlp exited with code {proc.returncode}")
    return True
