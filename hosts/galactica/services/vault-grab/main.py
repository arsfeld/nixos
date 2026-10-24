"""vault-grab: one 1080p copy of every new scene from the followed studios, into Vault.

  run [--dry-run]   search Prowlarr for each studio and grab what is new (timer);
                    --dry-run prints what it would grab and why the rest was skipped

Design: docs/superpowers/specs/2026-10-24-vault-grab-design.md
Unit tests: `PYTHONPATH=../plab python3 -m unittest -v` in this directory.
"""
import datetime
import re
import sys
from collections import namedtuple

WINDOW = datetime.timedelta(days=30)
HD = re.compile(r"\b108[08]p\b", re.I)
JUNK = re.compile(r"\bpack\b|imageset|\d+\s*ролик", re.I)
YEAR = re.compile(r"(?<!\d)(19\d\d|20\d\d)(?!\d)")
EPISODE = re.compile(r"\bE(\d{3,5})\b", re.I)
MIN_NAME = 8  # a shorter squashed name is too likely to collide to dedup on
QUOTA_INDEXER = "PornoLab"  # has a daily download limit, shared with plab

Rule = namedtuple("Rule", "name query match")


def log(message):
    print(message, file=sys.stderr, flush=True)


def load_rules(path):
    """The studios in the rules file: `[Name]` blocks of `query =` and `match =`."""
    blocks = []
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                blocks.append({"name": line[1:-1].strip()})
                continue
            k, sep, v = line.partition("=")
            if not sep or not blocks or k.strip() not in ("query", "match"):
                raise ValueError(f"{path}:{n}: unexpected line {line!r}")
            blocks[-1][k.strip()] = v.strip()
    rules = []
    for b in blocks:
        missing = {"query", "match"} - b.keys()
        if missing:
            raise ValueError(f"[{b['name']}] is missing {', '.join(sorted(missing))}")
        try:
            match = re.compile(b["match"], re.I)
        except re.error as e:
            raise ValueError(f"[{b['name']}] match: {e}") from e
        rules.append(Rule(b["name"], b["query"], match))
    return rules


def skip_reason(rule, result, now):
    """Why a Prowlarr result is not a candidate for `rule`, or None if it is one."""
    title = result["title"]
    if result.get("protocol") != "torrent":
        return "not a torrent"
    if not rule.match.match(title):
        return "not this studio"  # anchored: a compilation crediting the studio is not its release
    published = datetime.datetime.fromisoformat(result["publishDate"].replace("Z", "+00:00"))
    if now - published > WINDOW:
        return "older than the window"
    if not HD.search(title):
        return "not 1080p"
    if JUNK.search(title):
        return "pack or image set"
    if any(int(y) < now.year - 1 for y in YEAR.findall(title)):
        return "old scene re-uploaded"
    return None


def scene_keys(rule, title):
    """The keys one scene is known by, whichever source named it: its episode number and
    its squashed "performers - title" part."""
    keys = {f"ep:{int(n)}" for n in EPISODE.findall(title)}
    rest = title[rule.match.match(title).end():]
    rest = re.sub(r"\(?\bE\d{3,5}\b\)?", " ", rest, flags=re.I)
    rest = re.split(r"\sXXX\b|\[|\(", rest, maxsplit=1)[0]
    name = re.sub(r"[^a-z0-9]", "", rest.replace("&", "and").lower())
    if len(name) >= MIN_NAME:
        keys.add(f"name:{name}")
    return keys


def _rank(candidate):
    result = candidate[0]
    return (result["indexer"] == QUOTA_INDEXER, -(result.get("seeders") or 0))


def choose(candidates):
    """One copy per scene from [(result, keys)]. Copies linked by shared keys, even only
    through a third copy, are one scene. Prefers an indexer without a daily quota, then
    more seeders. Each scene carries the union of its copies' keys, so a copy named the
    other way is recognised later too."""
    groups = []  # [[(result, keys), ...], union of their keys]
    for result, keys in candidates:
        members, union = [(result, keys)], set(keys)
        for group in [g for g in groups if g[1] & keys]:
            groups.remove(group)
            members += group[0]
            union |= group[1]
        groups.append([members, union])
    return [(min(members, key=_rank)[0], union) for members, union in groups]
