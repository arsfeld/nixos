"""Command-line interface for telequebec-archiver."""

from __future__ import annotations

import argparse
import sys
from typing import Optional

from . import __version__
from .download import DownloadError, download, episode_path
from .site import (
    EpisodeMeta,
    Season,
    TeleQuebecError,
    fetch_episode,
    fetch_series,
    parse_target,
)

DEFAULT_OUTPUT = "/mnt/storage/media/Series"


def _parse_range(value: Optional[str]) -> Optional[list[int]]:
    if value is None:
        return None
    result: list[int] = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, _, hi = part.partition("-")
            result.extend(range(int(lo), int(hi) + 1))
        else:
            result.append(int(part))
    return sorted(set(result))


def _select_seasons(series_seasons: list[Season], arg: Optional[str]) -> list[Season]:
    if arg is None:
        return series_seasons
    selected = _parse_range(arg) or []
    available = {s.number for s in series_seasons}
    unknown = [n for n in selected if n not in available]
    if unknown:
        raise TeleQuebecError(
            f"Season(s) {unknown} not available (available: {sorted(available)})"
        )
    return [s for s in series_seasons if s.number in selected]


def _download(meta: EpisodeMeta, output: str, args: argparse.Namespace) -> str:
    dest = episode_path(
        output, meta.series, meta.year, meta.season, meta.number, meta.title
    )
    try:
        if args.no_skip_existing or download(
            meta.brightcove_url,
            dest,
            quality=args.quality,
            subtitles=args.subtitles,
            thumbnail=not args.no_thumbnail,
        ):
            print(f"ok     {dest}")
            return "ok"
        print(f"skip   {dest}")
        return "skip"
    except DownloadError as exc:
        print(f"fail   {dest}: {exc}", file=sys.stderr)
        return "fail"


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="telequebec-archiver",
        description="Archive Télé-Québec series for Plex.",
    )
    parser.add_argument("target", help="show slug or telequebec.tv URL")
    parser.add_argument(
        "-o",
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"output root (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument("--seasons", help="comma/range list, e.g. '1,2' or '1-4'")
    parser.add_argument(
        "--episodes", help="comma/range list within a single season, e.g. '3-5'"
    )
    parser.add_argument(
        "--quality", type=int, default=720, help="max height (default: 720)"
    )
    parser.add_argument(
        "--subtitles", action="store_true", help="download and embed fr-CA subtitles"
    )
    parser.add_argument(
        "--no-thumbnail", action="store_true", help="skip embedded metadata/thumbnail"
    )
    parser.add_argument(
        "--no-skip-existing", action="store_true", help="re-download existing files"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="list episodes without downloading"
    )
    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )
    args = parser.parse_args(argv)

    if args.episodes and args.seasons is None:
        print(
            "error: --episodes requires --seasons with a single season", file=sys.stderr
        )
        return 1

    try:
        slug, season_no, episode_no = parse_target(args.target)
        series = fetch_series(slug)
    except TeleQuebecError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    try:
        if season_no is not None and episode_no is not None:
            meta = fetch_episode(slug, season_no, episode_no, series)
            if meta is None:
                print(
                    f"error: episode S{season_no:02d}E{episode_no:02d} not found",
                    file=sys.stderr,
                )
                return 1
            if args.dry_run:
                print(
                    f"{meta.series} - S{meta.season:02d}E{meta.number:02d} - {meta.title}"
                )
            else:
                _download(meta, args.output, args)
            return 0

        seasons = _select_seasons(series.seasons, args.seasons)
        if args.episodes and len(seasons) != 1:
            print(
                "error: --episodes requires --seasons to select exactly one season",
                file=sys.stderr,
            )
            return 1
        selected_episodes = _parse_range(args.episodes)

        counts = {"ok": 0, "skip": 0, "fail": 0}
        for season in seasons:
            for number in range(1, season.episode_count + 1):
                if selected_episodes is not None and number not in selected_episodes:
                    continue
                try:
                    meta = fetch_episode(slug, season.number, number, series)
                except TeleQuebecError as exc:
                    print(
                        f"fail   S{season.number:02d}E{number:02d}: {exc}",
                        file=sys.stderr,
                    )
                    counts["fail"] += 1
                    continue
                if meta is None:
                    continue
                if args.dry_run:
                    print(
                        f"{series.title} - S{meta.season:02d}E{meta.number:02d} - {meta.title}"
                    )
                    continue
                counts[_download(meta, args.output, args)] += 1

        if not args.dry_run:
            print(
                f"done   {counts['ok']} downloaded, {counts['skip']} skipped, {counts['fail']} failed",
            )
    except TeleQuebecError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
