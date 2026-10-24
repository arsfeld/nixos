# vault-grab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A timer on galactica searches Prowlarr for each followed studio every 3 h. It grabs one 1080p copy of every scene posted in the last 30 days that it hasn't grabbed yet, into Transmission at `Vault/<Studio>`.

**Architecture:** A stdlib-only Python script in `hosts/galactica/services/vault-grab/`, laid out like plab: `main.py` with pure functions plus thin I/O, and `test_main.py`. It reuses plab's `transmission.py` via `PYTHONPATH`, after Task 1 teaches it magnet links. A oneshot systemd service runs it as `media`, a timer fires it, and the studio list comes from a sops secret.

**Tech Stack:** Python 3 stdlib (`urllib`, `json`, `re`, `unittest`), NixOS (`writeShellApplication`, systemd timer, sops-nix), Prowlarr v1 API, Transmission RPC.

**Spec:** `docs/superpowers/specs/2026-10-24-vault-grab-design.md`

## Global Constraints

- No studio name in the repository: not in code, tests, comments or commit messages. Tests use placeholder studios (`Studio A`, `Studio B`). The real rules live only in the sops secret `vault-grab-rules`.
- Python: stdlib only. Run the tests from `hosts/galactica/services/vault-grab/` with `PYTHONPATH=../plab python3 -m unittest -v`.
- Window: 30 days. Resolution: `1080p` or `1088p`. The quota indexer is named `PornoLab`.
- Commit straight to `master`, as conventional commits with scope `galactica`. No branches or worktrees.
- Never mention Claude in commits.
- A new file is invisible to `nix build` until it is `git add`ed.
- Run `just fmt` (alejandra) before committing any `.nix` file.

## File Structure

| File | Responsibility |
|------|----------------|
| `hosts/galactica/services/plab/transmission.py` (modify) | `add()` also accepts a magnet link (`str`) |
| `hosts/galactica/services/plab/test_transmission.py` (modify) | Magnet test |
| `hosts/galactica/services/vault-grab/main.py` (create) | Rules, selection, keys, Prowlarr I/O, state, `run`, CLI |
| `hosts/galactica/services/vault-grab/test_main.py` (create) | All vault-grab unit tests |
| `hosts/galactica/services/vault-grab/default.nix` (create) | Wrapper, service, timer, sops secret |
| `hosts/galactica/services/default.nix` (modify) | Import `./vault-grab` |
| `secrets/sops/galactica.yaml` (modify) | New key `vault-grab-rules` |

---

### Task 1: plab's `transmission.add` accepts magnet links

**Files:**
- Modify: `hosts/galactica/services/plab/transmission.py`
- Test: `hosts/galactica/services/plab/test_transmission.py`

**Interfaces:**
- Produces: `transmission.add(url: str, torrent: bytes | str, download_dir: str) -> str`. `bytes` is sent as `metainfo` (base64), a `str` (a magnet link) as `filename`. Returns the torrent's name. A duplicate is not an error.

- [ ] **Step 1: Write the failing test**

Add to class `Add` in `hosts/galactica/services/plab/test_transmission.py`, after `test_duplicate_is_success`:

```python
    def test_magnet_is_sent_as_filename(self):
        Stub.reply = {"result": "success", "arguments": {"torrent-added": {"name": "Magnet Release"}}}
        magnet = "magnet:?xt=urn:btih:836EDDB16DC9A43927DAA5A83F2726513069B41A&dn=x"
        self.assertEqual(transmission.add(self.url, magnet, "/x"), "Magnet Release")
        args = Stub.requests[1][1]["arguments"]
        self.assertEqual(args["filename"], magnet)
        self.assertNotIn("metainfo", args)
        self.assertEqual(args["download-dir"], "/x")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd hosts/galactica/services/plab && python3 -m unittest -v test_transmission`
Expected: `test_magnet_is_sent_as_filename` ERRORs with `TypeError: a bytes-like object is required, not 'str'`

- [ ] **Step 3: Implement**

In `hosts/galactica/services/plab/transmission.py`, replace the docstring and `body =` statement of `add`:

```python
def add(url, torrent, download_dir):
    """Add a torrent, as .torrent bytes or a magnet link (str); return its name. A duplicate
    is not an error."""
    source = ({"filename": torrent} if isinstance(torrent, str)
              else {"metainfo": base64.b64encode(torrent).decode()})
    body = json.dumps({
        "method": "torrent-add",
        "arguments": {**source, "download-dir": download_dir},
    }).encode()
```

Also update the module docstring's first line to `"""Transmission RPC, just `torrent-add` (bytes or magnet), including its CSRF session-id handshake."""`.

- [ ] **Step 4: Run all plab tests**

Run: `cd hosts/galactica/services/plab && python3 -m unittest -v`
Expected: all pass, including the new test.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/transmission.py hosts/galactica/services/plab/test_transmission.py
git commit -m "feat(galactica): plab transmission client accepts magnet links"
```

---

### Task 2: vault-grab selection: rules, filter, scene keys, choice

The pure half of `main.py`, with no I/O.

**Files:**
- Create: `hosts/galactica/services/vault-grab/main.py`
- Create: `hosts/galactica/services/vault-grab/test_main.py`

**Interfaces:**
- Produces:
  - `Rule = namedtuple("Rule", "name query match")`, where `match` is a compiled case-insensitive regex.
  - `load_rules(path: str) -> list[Rule]`, which raises `ValueError` on a bad file.
  - `skip_reason(rule: Rule, result: dict, now: datetime) -> str | None`. `None` means the result is a candidate. `result` is one Prowlarr `/api/v1/search` item, with keys `title`, `publishDate` (ISO, `Z`), `indexer`, `seeders`, `downloadUrl` and `protocol`.
  - `scene_keys(rule: Rule, title: str) -> set[str]`, holding `ep:<n>` and/or `name:<squashed>`. Only call it on a title that `rule.match` matches.
  - `choose(candidates: list[tuple[dict, set[str]]]) -> list[tuple[dict, set[str]]]`.
  - `log(message: str)` (stderr).

- [ ] **Step 1: Write the failing tests**

Create `hosts/galactica/services/vault-grab/test_main.py`:

```python
import datetime
import os
import tempfile
import unittest

import main

NOW = datetime.datetime(2026, 10, 24, 12, tzinfo=datetime.timezone.utc)
A = main.Rule("Studio A", "studioa", main.re.compile(r"^(\[studioa\.com\]|studioa e\d+\b)", main.re.I))
B = main.Rule("Studio B", "studiob", main.re.compile(r"^(\[studiob\.com\]|studio b\s)", main.re.I))


def result(title, indexer="1337x", seeders=10, published="2026-10-17T20:00:00Z", url="http://p/1/download"):
    return {"title": title, "indexer": indexer, "seeders": seeders, "publishDate": published,
            "downloadUrl": url, "protocol": "torrent"}


def rules_file(text):
    f = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8")
    f.write(text)
    f.close()
    return f.name


class LoadRules(unittest.TestCase):
    def test_blocks_and_comments(self):
        path = rules_file("# c\n\n[Studio A]\nquery = studioa\nmatch = ^studioa e\\d+\n\n[Studio B]\n"
                          "query = studiob\nmatch = ^\\[studiob\\.com\\]\n")
        rules = main.load_rules(path)
        os.unlink(path)
        self.assertEqual([r.name for r in rules], ["Studio A", "Studio B"])
        self.assertEqual(rules[0].query, "studioa")
        self.assertTrue(rules[1].match.match("[StudioB.com] X - Y"))  # case-insensitive

    def test_missing_key(self):
        path = rules_file("[Studio A]\nquery = studioa\n")
        with self.assertRaisesRegex(ValueError, "missing match"):
            main.load_rules(path)
        os.unlink(path)

    def test_unknown_key_and_line_before_block(self):
        for text in ("[Studio A]\nquery = a\nmatch = a\nsave = x\n", "query = a\n"):
            path = rules_file(text)
            with self.assertRaisesRegex(ValueError, "unexpected line"):
                main.load_rules(path)
            os.unlink(path)

    def test_bad_regex(self):
        path = rules_file("[Studio A]\nquery = a\nmatch = ^(a\n")
        with self.assertRaisesRegex(ValueError, r"\[Studio A\] match"):
            main.load_rules(path)
        os.unlink(path)


class SkipReason(unittest.TestCase):
    def reason(self, title, rule=A, **kw):
        return main.skip_reason(rule, result(title, **kw), NOW)

    def test_candidates(self):
        self.assertIsNone(self.reason("StudioA E2283 Iris And Jase How We Deepthroat XXX 1080p MP4 FETiSH [XC]"))
        self.assertIsNone(self.reason("[StudioA.com] Johanna & Lars - Park & Ohhh (E2274) "
                                      "[2026-09-29, All sex, Outdoor, 1080p, SiteRip]"))
        self.assertIsNone(self.reason("[StudioB.com] Kitty Wild - Waking to Find You "
                                      "[2026, Blowjob, All Sex, 1088p, SiteRip]", rule=B))
        self.assertIsNone(self.reason("Studio B   Hailey White   An Evening of Romance (10.06.2026) 1080p",
                                      rule=B))

    def test_480p_twin(self):
        self.assertEqual(self.reason("StudioA E2283 Iris And Jase How We Deepthroat XXX 480p MP4 XXX [XC]"),
                         "not 1080p")

    def test_studio_must_lead_the_title(self):
        self.assertEqual(self.reason("Guess the Straight Girl (Other) [2026 г., BDRip, 1080p] "
                                     "(Jane(StudioA - Emanuel & Jane))"), "not this studio")

    def test_window(self):
        self.assertEqual(self.reason("StudioA E2100 Some Couple Some Title XXX 1080p", published="2026-09-20T00:00:00Z"),
                         "older than the window")

    def test_pack_and_imageset(self):
        self.assertEqual(self.reason("[StudioA.com] Mike & Vika (3 ролика) Pack [2025-2026, 1080p]"),
                         "pack or image set")
        self.assertEqual(self.reason("Studio B   Ashby Winter IMAGESET (30.04.2026) 1080p", rule=B),
                         "pack or image set")

    def test_old_scene_reuploaded(self):
        self.assertEqual(self.reason("[StudioA.com] Katya And Paul - Cabin Kink (E769) [2022 г., HDRip, 1080p]"),
                         "old scene re-uploaded")
        self.assertIsNone(self.reason("[StudioA.com] Ariel & Kirk - Pull Out Couch [2025-10-13, 1080p, SiteRip]"))

    def test_not_a_torrent(self):
        r = result("StudioA E1 Some Couple Some Title XXX 1080p")
        r["protocol"] = "usenet"
        self.assertEqual(main.skip_reason(A, r, NOW), "not a torrent")


class SceneKeys(unittest.TestCase):
    def test_both_namings_share_keys(self):
        lab = main.scene_keys(A, "[StudioA.com] Johanna & Lars - Park & Ohhh (E2274) [2026-09-29, 1080p, SiteRip]")
        x = main.scene_keys(A, "StudioA E2274 Johanna And Lars Park And Ohhh XXX 1080p MP4 FETiSH [XC]")
        self.assertEqual(lab, {"ep:2274", "name:johannaandlarsparkandohhh"})
        self.assertEqual(x, lab)

    def test_name_only(self):
        self.assertEqual(main.scene_keys(B, "[StudioB.com] Sofia Smith - Beauty In The Bath [2026-10-16, 1080p]"),
                         {"name:sofiasmithbeautyinthebath"})

    def test_short_name_is_not_a_key(self):
        self.assertEqual(main.scene_keys(A, "StudioA E0042 Ab XXX 1080p"), {"ep:42"})
        self.assertEqual(main.scene_keys(B, "[StudioB.com] Ab [2026, 1080p]"), set())


class Choose(unittest.TestCase):
    def test_non_quota_indexer_wins_then_seeders(self):
        lab = result("lab", indexer="PornoLab", seeders=99)
        weak = result("weak", seeders=5)
        strong = result("strong", seeders=40)
        scenes = main.choose([(lab, {"ep:1", "name:x"}), (weak, {"ep:1"}), (strong, {"name:x"})])
        self.assertEqual(len(scenes), 1)
        self.assertIs(scenes[0][0], strong)
        self.assertEqual(scenes[0][1], {"ep:1", "name:x"})

    def test_distinct_scenes_stay_apart(self):
        scenes = main.choose([(result("a"), {"ep:1"}), (result("b"), {"ep:2"})])
        self.assertEqual(len(scenes), 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd hosts/galactica/services/vault-grab && PYTHONPATH=../plab python3 -m unittest -v`
Expected: ERROR, `ModuleNotFoundError: No module named 'main'`. Python puts the current directory first on `sys.path`, so this is vault-grab's own (absent) `main.py`, never plab's.

- [ ] **Step 3: Implement**

Create `hosts/galactica/services/vault-grab/main.py`:

```python
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/vault-grab && PYTHONPATH=../plab python3 -m unittest -v`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/vault-grab/main.py hosts/galactica/services/vault-grab/test_main.py
git commit -m "feat(galactica): vault-grab rules, release filter and scene dedup"
```

---

### Task 3: vault-grab I/O: Prowlarr, state, `run`, CLI

**Files:**
- Modify: `hosts/galactica/services/vault-grab/main.py`
- Modify: `hosts/galactica/services/vault-grab/test_main.py`

**Interfaces:**
- Consumes (Task 2): `Rule`, `load_rules`, `skip_reason`, `scene_keys`, `choose`, `log`. Consumes (Task 1): `transmission.add(url, torrent: bytes | str, download_dir) -> str`.
- Produces:
  - `api_key(config_xml: str) -> str`.
  - `search(base: str, key: str, query: str, urlopen=urllib.request.urlopen) -> list[dict]`.
  - `fetch(url: str, open_=...) -> bytes | str`: `.torrent` bytes, or a magnet link from a 3xx.
  - `State(path)`, with `.grabbed(studio, keys) -> bool` and `.record(studio, keys, title, at)`. `record` saves atomically.
  - `run(rules, search, fetch, add, state, download_root, now, dry_run=False) -> int`. Here `search(query) -> list[dict]`, `fetch(url) -> bytes | str` and `add(torrent, download_dir) -> str`.
  - `main(argv=None) -> int`, which reads env `VAULT_GRAB_RULES_FILE`, `VAULT_GRAB_STATE_DIR`, `VAULT_GRAB_PROWLARR_URL`, `VAULT_GRAB_PROWLARR_CONFIG`, `VAULT_GRAB_TRANSMISSION_URL` and `VAULT_GRAB_DOWNLOAD_DIR`.

- [ ] **Step 1: Write the failing tests**

Append to `hosts/galactica/services/vault-grab/test_main.py`, before the `if __name__ == "__main__":` line. Also add these imports at the top: `import json`, `import threading`, `from http.server import BaseHTTPRequestHandler, HTTPServer`.

```python
class ApiKey(unittest.TestCase):
    def test_reads_config_xml(self):
        path = rules_file("<Config>\n  <Port>9696</Port>\n  <ApiKey>abc123</ApiKey>\n</Config>\n")
        self.assertEqual(main.api_key(path), "abc123")
        os.unlink(path)

    def test_missing(self):
        path = rules_file("<Config></Config>")
        with self.assertRaisesRegex(ValueError, "no <ApiKey>"):
            main.api_key(path)
        os.unlink(path)


class Download(BaseHTTPRequestHandler):
    """Prowlarr's /download: a 301 to a magnet for one indexer, .torrent bytes for another."""
    def do_GET(self):
        if self.path == "/magnet":
            self.send_response(301)
            self.send_header("Location", "magnet:?xt=urn:btih:ABC&dn=x")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/torrent":
            self.send_response(200)
            self.send_header("Content-Type", "application/x-bittorrent")
            self.send_header("Content-Length", "8")
            self.end_headers()
            self.wfile.write(b"d4:infoe")
        elif self.path == "/html":
            self.send_response(200)
            self.send_header("Content-Length", "6")
            self.end_headers()
            self.wfile.write(b"<html>")
        elif self.path.startswith("/api/v1/search"):
            body = json.dumps([{"title": self.path, "key": self.headers.get("X-Api-Key")}]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, *args):
        pass


class Http(unittest.TestCase):
    def setUp(self):
        self.server = HTTPServer(("127.0.0.1", 0), Download)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_magnet_redirect_is_not_followed(self):
        self.assertEqual(main.fetch(self.base + "/magnet"), "magnet:?xt=urn:btih:ABC&dn=x")

    def test_torrent_bytes(self):
        self.assertEqual(main.fetch(self.base + "/torrent"), b"d4:infoe")

    def test_not_a_torrent(self):
        with self.assertRaisesRegex(ValueError, "not a .torrent"):
            main.fetch(self.base + "/html")

    def test_server_error(self):
        with self.assertRaises(main.urllib.error.HTTPError):
            main.fetch(self.base + "/boom")

    def test_search_sends_key_and_query(self):
        [item] = main.search(self.base, "k3y", "studio a")
        self.assertEqual(item["key"], "k3y")
        self.assertIn("query=studio+a", item["title"])
        self.assertIn("type=search", item["title"])


class StateFile(unittest.TestCase):
    def test_record_persists_and_matches_any_key(self):
        path = os.path.join(tempfile.mkdtemp(), "state.json")
        s = main.State(path)
        self.assertFalse(s.grabbed("Studio A", {"ep:1"}))
        s.record("Studio A", {"ep:1", "name:abcdefgh"}, "t", "2026-10-24T00:00:00+00:00")
        again = main.State(path)
        self.assertTrue(again.grabbed("Studio A", {"name:abcdefgh"}))
        self.assertFalse(again.grabbed("Studio B", {"ep:1"}))
        self.assertFalse(os.path.exists(path + ".tmp"))


class Run(unittest.TestCase):
    def setUp(self):
        self.state = main.State(os.path.join(tempfile.mkdtemp(), "state.json"))
        self.added = []
        self.fail_urls = set()

    def fetch(self, url):
        if url in self.fail_urls:
            raise main.urllib.error.HTTPError(url, 429, "daily limit", {}, None)
        return "magnet:" + url

    def add(self, torrent, download_dir):
        self.added.append((torrent, download_dir))
        return "name"

    def go(self, results, dry_run=False, search=None):
        return main.run([A], search or (lambda q: results), self.fetch, self.add, self.state,
                        "/vault", NOW, dry_run)

    def test_grabs_one_copy_per_scene_into_studio_dir(self):
        results = [
            result("StudioA E2283 Iris And Jase How We Deepthroat XXX 480p MP4 XXX [XC]", url="u480"),
            result("StudioA E2283 Iris And Jase How We Deepthroat XXX 1080p MP4 FETiSH [XC]", url="u1080"),
            result("[StudioA.com] Iris & Jase - How We Deepthroat (E2283) [2026-10-15, 1080p, SiteRip]",
                   indexer="PornoLab", seeders=90, url="ulab"),
            result("Unrelated Release 1080p", url="other"),
        ]
        self.assertEqual(self.go(results), 0)
        self.assertEqual(self.added, [("magnet:u1080", "/vault/Studio A")])
        self.assertTrue(self.state.grabbed("Studio A", {"name:irisandjasehowwedeepthroat"}))

    def test_already_grabbed_is_skipped(self):
        self.state.record("Studio A", {"ep:2283"}, "t", "x")
        self.go([result("StudioA E2283 Iris And Jase How We Deepthroat XXX 1080p MP4 [XC]")])
        self.assertEqual(self.added, [])

    def test_failed_grab_is_not_recorded_and_others_continue(self):
        self.fail_urls = {"bad"}
        status = self.go([result("StudioA E1001 Some Couple Some Title XXX 1080p", url="bad"),
                          result("StudioA E1002 Other Couple Other Title XXX 1080p", url="good")])
        self.assertEqual(status, 0)
        self.assertEqual(self.added, [("magnet:good", "/vault/Studio A")])
        self.assertFalse(self.state.grabbed("Studio A", {"ep:1001"}))
        self.assertTrue(self.state.grabbed("Studio A", {"ep:1002"}))

    def test_failed_search_exits_1(self):
        def broken(query):
            raise OSError("connection refused")
        self.assertEqual(self.go([], search=broken), 1)

    def test_dry_run_writes_nothing(self):
        self.go([result("StudioA E1001 Some Couple Some Title XXX 1080p")], dry_run=True)
        self.assertEqual(self.added, [])
        self.assertFalse(os.path.exists(self.state.path))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd hosts/galactica/services/vault-grab && PYTHONPATH=../plab python3 -m unittest -v`
Expected: the new classes ERROR with `AttributeError: module 'main' has no attribute 'api_key'` (and `fetch`, `search`, `State`, `run`). Task 2's tests still pass.

- [ ] **Step 3: Implement**

In `hosts/galactica/services/vault-grab/main.py`, replace the import block with:

```python
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
```

Then append to the end of the file:

```python
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
            reason = skip_reason(rule, result, now)
            keys = scene_keys(rule, result["title"]) if reason is None else set()
            if reason is None and not keys:
                reason = "no scene key"
            if reason:
                if dry_run:
                    log(f"[{rule.name}] skip ({reason}): {result['title']}")
                continue
            candidates.append((result, keys))
        scenes = choose(candidates)
        new = [(r, k) for r, k in scenes if not state.grabbed(rule.name, k)]
        log(f"[{rule.name}] {len(results)} results, {len(scenes)} scenes, {len(new)} new")
        for result, keys in new:
            label = f"[{rule.name}] {result['title']} ({result['indexer']})"
            if dry_run:
                log(f"would grab {label}")
                continue
            try:
                name = add(fetch(result["downloadUrl"]), os.path.join(download_root, rule.name))
            except Exception as e:  # noqa: BLE001 -- not recorded: retried next run
                log(f"grab failed {label}: {e}")
                continue
            state.record(rule.name, keys, result["title"], now.isoformat())
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/vault-grab && PYTHONPATH=../plab python3 -m unittest -v`
Expected: all pass. Then run `cd ../plab && python3 -m unittest -v`: all pass.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/vault-grab/main.py hosts/galactica/services/vault-grab/test_main.py
git commit -m "feat(galactica): vault-grab Prowlarr search, grab, state and CLI"
```

---

### Task 4: NixOS module and rules secret

**Files:**
- Create: `hosts/galactica/services/vault-grab/default.nix`
- Modify: `hosts/galactica/services/default.nix` (add `./vault-grab` after `./vault.nix`)
- Modify: `secrets/sops/galactica.yaml` (new key `vault-grab-rules`)

**Interfaces:**
- Consumes (Task 3): `main.py run [--dry-run]` and the six `VAULT_GRAB_*` environment variables.
- Produces: a `vault-grab` command on PATH, `vault-grab.service` and `vault-grab.timer`.

- [ ] **Step 1: Add the rules secret**

The rules content is kept out of the repository. It is in
`/tmp/claude-1000/-home-arosenfeld-Code-nixos/934e1759-6873-4838-bdcd-4581e2c9eea6/scratchpad/vault-grab-rules.txt`:
two `[Name]` blocks, each with `query =` and `match =`, in the format of the spec's
"The rules file" section. Do not copy its studio names anywhere in the repo.

```bash
R=/tmp/claude-1000/-home-arosenfeld-Code-nixos/934e1759-6873-4838-bdcd-4581e2c9eea6/scratchpad/vault-grab-rules.txt
nix develop -c sops set secrets/sops/galactica.yaml '["vault-grab-rules"]' "$(jq -Rs . < $R)"
nix develop -c sops -d --extract '["vault-grab-rules"]' secrets/sops/galactica.yaml | diff - $R && echo same
```
Expected: `same`.

- [ ] **Step 2: Write the module**

Create `hosts/galactica/services/vault-grab/default.nix`:

```nix
# vault-grab: one 1080p copy of every new scene from the studios in the
# `vault-grab-rules` secret, found through Prowlarr and added to Transmission
# under Vault/<Studio>. No page, no port: the journal is the record.
#
# Design: docs/superpowers/specs/2026-10-24-vault-grab-design.md
# Unit tests: `PYTHONPATH=../plab python3 -m unittest -v` in this directory.
# What would a run grab: `sudo -u media vault-grab run --dry-run`.
{
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;

  vault-grab = pkgs.writeShellApplication {
    name = "vault-grab";
    text = ''
      export VAULT_GRAB_RULES_FILE="''${VAULT_GRAB_RULES_FILE:-${config.sops.secrets.vault-grab-rules.path}}"
      export VAULT_GRAB_STATE_DIR="''${VAULT_GRAB_STATE_DIR:-/var/lib/vault-grab}"
      export VAULT_GRAB_PROWLARR_URL="http://127.0.0.1:9696"
      # Read at run time: Prowlarr owns the key, so there is no second copy to drift.
      export VAULT_GRAB_PROWLARR_CONFIG="${vars.configDir}/prowlarr/config.xml"
      # Straight into the PIA namespace, never through the Authelia-gated
      # transmission vhost (see transmission-vpn.nix).
      export VAULT_GRAB_TRANSMISSION_URL="http://${config.constellation.pia.namespaceAddress}:9091/transmission/rpc"
      # plab's tree too; Transmission creates each <Studio> directory.
      export VAULT_GRAB_DOWNLOAD_DIR="${vars.storageDir}/media/Downloads/Vault"
      # plab's Transmission client, shared rather than copied.
      export PYTHONPATH="${../plab}"
      exec ${pkgs.python3}/bin/python3 ${./.}/main.py "$@"
    '';
  };
in {
  sops.secrets.vault-grab-rules.owner = vars.user;

  environment.systemPackages = [vault-grab];

  systemd.services.vault-grab = {
    description = "Grab new scenes of the followed studios into Vault";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = vars.user;
      Group = vars.group;
      StateDirectory = "vault-grab";
      ExecStart = "${vault-grab}/bin/vault-grab run";
    };
  };

  systemd.timers.vault-grab = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 01/3:30:00"; # between plab-refresh runs (00/3:00)
      OnBootSec = "5min";
      Persistent = true;
    };
  };
}
```

Add `./vault-grab` to `hosts/galactica/services/default.nix` on the line after `./vault.nix`.

- [ ] **Step 3: Format, stage and build**

```bash
just fmt
git add hosts/galactica/services/vault-grab/default.nix hosts/galactica/services/default.nix secrets/sops/galactica.yaml
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
```
Expected: the build succeeds. sops-nix validates at build time that `vault-grab-rules` exists in `galactica.yaml`, so a missing key fails here.

Also confirm that every galactica unit already gets the `email@` OnFailure:
`nix eval .#nixosConfigurations.galactica.config.systemd.services.vault-grab.onFailure`
Expected: `[ "email@%n.service" ]`, set fleet-wide by `modules/systemd-email-notify.nix`. If it
is empty, add `onFailure = ["email@%n.service"];` to the service, rebuild, and check again.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(galactica): vault-grab service, timer and rules secret"
```

---

### Task 5: Deploy and verify on galactica

**Files:** none. This task is operational.

- [ ] **Step 1: Deploy**

From raider: `just deploy galactica`
Expected: phase 1 builds and pushes, and phase 2 activates galactica without errors.

- [ ] **Step 2: Dry run**

```bash
ssh galactica.bat-boa.ts.net 'sudo -u media vault-grab run --dry-run' 2>&1
```
Expected:
- Each studio prints `N results, M scenes, K new`, with K > 0 for both studios. The backfill covers the last 30 days.
- Every `would grab` line is a 1080p or 1088p title that leads with the studio tag.
- There is no 480p twin, no pack or imageset, no old-year re-upload, and no scene twice.

If a real title is misclassified, add that title's shape (with a placeholder studio) as a test in Task 2's or Task 3's test classes, fix it, re-run the unit tests, commit, and redeploy.

- [ ] **Step 3: Real run**

```bash
ssh galactica.bat-boa.ts.net 'sudo systemctl start vault-grab.service; systemctl is-failed vault-grab.service; journalctl -u vault-grab.service -n 60 --no-pager'
```
Expected: `inactive` (not `failed`), `grabbed …` lines, and at most a few `grab failed` lines (a PornoLab daily limit is acceptable).

- [ ] **Step 4: Confirm in Transmission and on disk**

```bash
ssh galactica.bat-boa.ts.net 'nix shell nixpkgs#transmission_4 -c transmission-remote <namespaceAddress>:9091 -l | tail -n 30; sudo -u media ls /mnt/storage/media/Downloads/Vault/'
```
Get `<namespaceAddress>` with `nix eval --raw .#nixosConfigurations.galactica.config.constellation.pia.namespaceAddress`.
Expected: the grabbed torrents are listed and downloading, and each studio's directory exists under `Vault/`.

- [ ] **Step 5: Idempotence**

Run Step 3 again.
Expected: every studio reports `0 new`, apart from the retries of earlier `grab failed` releases. No duplicate torrents.

- [ ] **Step 6: Timer**

```bash
ssh galactica.bat-boa.ts.net 'systemctl list-timers vault-grab.timer --no-pager'
```
Expected: the next run is scheduled at `HH:30` on an hour of the form 3k+1.
