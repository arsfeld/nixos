"""Télé-Québec GraphQL client and data models."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

import requests

BASE_URL = "https://telequebec.tv"
GRAPHQL_URL = "https://api.pc-cms.tele.quebec/graphql"
BRIGHTCOVE_ACCOUNT_ID = "6150020952001"
DEFAULT_PLAYER_ID = "ja7RtbSne"

_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ),
    "Accept-Language": "fr-CA,fr;q=0.9,en;q=0.8",
}

_RE_WATCH = re.compile(r"/regarder/(?P<slug>[^/?#]+)/(?P<season>\d+)/(?P<episode>\d+)")
_RE_CONTENT = re.compile(r"/contenu/(?P<slug>[^/?#]+)(?:/saison/(?P<season>\d+))?")
_RE_SLUG = re.compile(r"^[a-z0-9-]+$")

_session = requests.Session()


class TeleQuebecError(RuntimeError):
    pass


@dataclass
class Season:
    number: int
    episode_count: int


@dataclass
class Series:
    slug: str
    title: str
    year: int
    seasons: list[Season] = field(default_factory=list)


@dataclass
class EpisodeMeta:
    slug: str
    season: int
    number: int
    title: str
    series: str
    year: int
    description: str
    media_id: str
    player_id: str

    @property
    def brightcove_url(self) -> str:
        return (
            f"http://players.brightcove.net/{BRIGHTCOVE_ACCOUNT_ID}/"
            f"{self.player_id}_default/index.html?videoId=ref:{self.media_id}"
        )


def _gql(query: str) -> dict:
    resp = _session.post(
        GRAPHQL_URL, json={"query": query}, headers=_HEADERS, timeout=60
    )
    resp.raise_for_status()
    data = resp.json()
    if "errors" in data:
        messages = "; ".join(e.get("message", "unknown error") for e in data["errors"])
        raise TeleQuebecError(f"GraphQL error: {messages}")
    return data["data"]


def parse_target(value: str) -> tuple[str, Optional[int], Optional[int]]:
    """Return (slug, season, episode) from a slug or telequebec URL."""
    value = value.strip().rstrip("/")
    m = _RE_WATCH.search(value)
    if m:
        return m.group("slug"), int(m.group("season")), int(m.group("episode"))
    m = _RE_CONTENT.search(value)
    if m:
        season = int(m.group("season")) if m.group("season") else None
        return m.group("slug"), season, None
    if not _RE_SLUG.match(value):
        raise TeleQuebecError(f"Invalid slug or URL: {value}")
    return value, None, None


def _series_query(slug: str) -> dict:
    return _gql(
        """
        query {
          productByRootProductSlug(rootProductSlug: "%s") {
            title
            productionYear
            seasons {
              seasonNumber
              episodeCount
              available
            }
          }
        }
        """
        % slug
    )


def fetch_series(slug: str) -> Series:
    data = _series_query(slug)
    product = data.get("productByRootProductSlug")
    if not product or not product.get("title"):
        raise TeleQuebecError(f"Series '{slug}' not found")

    seasons = [
        Season(number=int(s["seasonNumber"]), episode_count=int(s["episodeCount"]))
        for s in product.get("seasons") or []
        if s.get("available")
    ]
    seasons.sort(key=lambda s: s.number)
    year = product.get("productionYear") or 0
    return Series(slug=slug, title=product["title"], year=int(year), seasons=seasons)


def list_seasons(slug: str) -> list[int]:
    return [s.number for s in fetch_series(slug).seasons]


_EPISODE_QUERY = """
query {
  videoPlayerPage(rootProductSlug: "%s", seasonNumber: %d, episodeNumber: %d) {
    blocks {
      blockType
      ... on ArtisanBlocksVideoPlayer {
        blockConfiguration {
          playerId
          product {
            title
            externalKey
            episodeNumber
            seasonNumber
            summary
          }
        }
      }
    }
  }
}
"""


def fetch_episode(
    slug: str,
    season: int,
    number: int,
    series: Series,
) -> Optional[EpisodeMeta]:
    """Return episode metadata, or None if the episode does not exist."""
    data = _gql(_EPISODE_QUERY % (slug, season, number))
    page = data.get("videoPlayerPage")
    if not page:
        return None

    player_id = DEFAULT_PLAYER_ID
    product = None
    for block in page.get("blocks") or []:
        if block.get("blockType") != "VIDEO_PLAYER":
            continue
        config = block.get("blockConfiguration") or {}
        if config.get("playerId"):
            player_id = config["playerId"]
        product = config.get("product") or {}

    if not product:
        return None

    media_id = product.get("externalKey")
    if not media_id:
        return None

    return EpisodeMeta(
        slug=slug,
        season=int(product.get("seasonNumber") or season),
        number=int(product.get("episodeNumber") or number),
        title=product.get("title") or f"Épisode {number}",
        series=series.title,
        year=series.year,
        description=product.get("summary") or "",
        media_id=str(media_id),
        player_id=player_id,
    )
