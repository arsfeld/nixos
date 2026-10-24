"""vault-grab: one 1080p copy of every new scene from the followed studios, into Vault.

  run [--dry-run]   search Prowlarr for each studio and grab what is new (timer);
                    --dry-run prints what it would grab and why the rest was skipped

Design: docs/superpowers/specs/2026-10-24-vault-grab-design.md
Unit tests: `PYTHONPATH=../plab python3 -m unittest -v` in this directory.
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import namedtuple

import transmission  # plab's, via PYTHONPATH

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
    return (result.get("indexer") == QUOTA_INDEXER, -(result.get("seeders") or 0))


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


def api_key(config_xml):
    """Prowlarr's API key, from its own config.xml: no second copy to drift."""
    with open(config_xml, encoding="utf-8") as f:
        m = re.search(r"<ApiKey>([^<]+)</ApiKey>", f.read())
    if not m:
        raise ValueError(f"no <ApiKey> in {config_xml}")
    return m.group(1)


def search(base, key, query, urlopen=urllib.request.urlopen):
    """Prowlarr's results for `query` across every enabled indexer."""
    url = f"{base}/api/v1/search?" + urllib.parse.urlencode({"query": query, "type": "search", "limit": 100})
    with urlopen(urllib.request.Request(url, headers={"X-Api-Key": key}), timeout=300) as response:
        return json.load(response)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a 3xx surfaces as HTTPError, so a magnet: Location can be read


def fetch(url, open_=urllib.request.build_opener(_NoRedirect).open):
    """A result's torrent: .torrent bytes, or the magnet link Prowlarr redirects to."""
    try:
        with open_(url, timeout=120) as response:
            data = response.read()
    except urllib.error.HTTPError as e:
        location = e.headers.get("Location", "") if e.headers else ""
        e.close()
        if 300 <= e.code < 400 and location.startswith("magnet:"):
            return location
        raise
    if not data.startswith(b"d"):
        raise ValueError(f"not a .torrent ({data[:40]!r})")
    return data


class State:
    """Scene keys already grabbed, per studio. Saved after every grab, atomically."""

    def __init__(self, path):
        self.path = path
        try:
            with open(path, encoding="utf-8") as f:
                self.data = json.load(f)
        except FileNotFoundError:
            self.data = {"studios": {}}

    def grabbed(self, studio, keys):
        return bool(self.data["studios"].get(studio, {}).keys() & keys)

    def record(self, studio, keys, title, at):
        seen = self.data["studios"].setdefault(studio, {})
        for k in keys:
            seen[k] = {"title": title, "at": at}
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.data, f, indent=1, sort_keys=True)
        os.replace(tmp, self.path)


def run(rules, search, fetch, add, state, download_root, now, dry_run=False):
    """One pass over every studio. Returns the exit code: 1 if any studio's search failed.
    A failed grab is logged and not recorded, so the next run retries it."""
    status = 0
    for rule in rules:
        try:
            results = search(rule.query)
        except Exception as e:  # noqa: BLE001 -- the other studios still run
            log(f"[{rule.name}] search failed: {e}")
            status = 1
            continue
        candidates = []
        for result in results:
            try:
                reason = skip_reason(rule, result, now)
                keys = scene_keys(rule, result["title"]) if reason is None else set()
                if reason is None and not keys:
                    reason = "no scene key"
            except Exception as e:  # noqa: BLE001 -- one malformed result must not end the run
                log(f"[{rule.name}] skip (bad result: {e}): {result.get('title', '?')}")
                continue
            if reason:
                if dry_run:
                    log(f"[{rule.name}] skip ({reason}): {result.get('title', '?')}")
                continue
            candidates.append((result, keys))
        scenes = choose(candidates)
        new = [(r, k) for r, k in scenes if not state.grabbed(rule.name, k)]
        log(f"[{rule.name}] {len(results)} results, {len(scenes)} scenes, {len(new)} new")
        for result, keys in new:
            label = f"[{rule.name}] {result.get('title', '?')} ({result.get('indexer', '?')})"
            if dry_run:
                log(f"would grab {label}")
                continue
            try:
                name = add(fetch(result["downloadUrl"]), os.path.join(download_root, rule.name))
                state.record(rule.name, keys, result["title"], now.isoformat())
            except Exception as e:  # noqa: BLE001 -- a failure here must not end the run
                # A failed record after a successful add leaves the copy in Transmission but
                # unrecorded, so the next run may grab it again; the alternative is aborting.
                log(f"grab failed {label}: {e}")
                continue
            log(f"grabbed {label} as {name!r}")
    return status


def main(argv=None):
    parser = argparse.ArgumentParser(prog="vault-grab", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("run").add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    env = os.environ
    rules = load_rules(env["VAULT_GRAB_RULES_FILE"])
    base = env["VAULT_GRAB_PROWLARR_URL"]
    key = api_key(env["VAULT_GRAB_PROWLARR_CONFIG"])
    rpc = env["VAULT_GRAB_TRANSMISSION_URL"]
    state = State(os.path.join(env["VAULT_GRAB_STATE_DIR"], "state.json"))
    return run(rules, lambda q: search(base, key, q), fetch,
               lambda torrent, d: transmission.add(rpc, torrent, d),
               state, env["VAULT_GRAB_DOWNLOAD_DIR"], datetime.datetime.now(datetime.timezone.utc),
               args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
