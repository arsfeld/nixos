# stash-identify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A systemd service on galactica that watches the Stash library, runs Stash's
scan → generate → identify on new files, and fills title/studio/performers on scenes still bare,
using an LLM filename parse confirmed against StashDB/ThePornDB where possible.

**Architecture:** Four small standard-library Python modules in a host-local module directory:
`net.py` (HTTP JSON), `stash.py` (Stash GraphQL client), `llm.py` (OpenRouter chat + Jev),
`match.py` (pure matching and payload building), and `main.py` (per-scene identify/apply,
the pass, state, watcher, CLI). The package is a `writeShellApplication` wrapper that execs python3,
the same pattern as `hosts/galactica/services/immich-pixel-sync/`. A plain `systemd.services` unit
runs `stash-identify watch`.

**Tech Stack:** Python 3 stdlib only, `unittest`, `inotify-tools`, Stash v0.31 GraphQL,
OpenRouter (`~deepseek/deepseek-flash-latest`, `typesafe/jev-1.13`), NixOS module, sops-nix.

**Spec:** `docs/superpowers/specs/2026-09-27-stash-llm-identify-design.md`

## Global Constraints

- Python standard library only. No pip packages.
- Stash URL default `http://localhost:9999/graphql`, overridable with `STASH_URL`. Send `ApiKey` header only if `STASH_API_KEY` is set.
- OpenRouter key from `OPENROUTER_API_KEY`, else read from the file at `OPENROUTER_API_KEY_FILE`.
- Parse model default `~deepseek/deepseek-flash-latest` (`PARSE_MODEL`). Jev model default `typesafe/jev-1.13` (`JEV_MODEL`).
- stash-box endpoints, in preference order: `https://theporndb.net/graphql`, then `https://stashdb.org/graphql`.
- Library paths: host `/mnt/storage/media/Vault` ↔ container `/media/Vault`.
- Duration filter: a candidate qualifies only if its duration is known and within **10 s** of the file's.
- Only empty scene fields are filled; nothing already set is overwritten. **The one exception is the cover on a scrape match**, which always replaces the generated screenshot (the same thing Stash's Identify `setCoverImage` does).
- Performers are never taken from Stash's `stored_id`: it matches by alias, and "Vivian" (Lustery) resolved to Kattie Gold (#1019). Resolve by stash-box ID, then exact name. Allow alias matches only for names of two or more words.
- LLM-only guesses get the tag `llm-identified`, created if missing.
- A scrape-match apply removes Stash Identify's skip tag(s): the IDs in `defaults.identify.options.skipMultipleMatchTag` / `skipSingleNamePerformerTag`, `1398` "SKIP" today.
- State file default `/var/lib/stash-identify/attempted.json` (`STATE_FILE`).
- Settle window: 120 s with no events. Daily sweep: every 24 h, plus once at startup. Job timeout: 6 h.
- Commits: conventional, scope `galactica`. Never mention Claude. Commit straight to `master` (no branches or worktrees).
- New files must be `git add`ed before `nix build` can see them.

## File Structure

```
hosts/galactica/services/stash-identify/
  default.nix     package, sops secret, systemd unit
  net.py          post_json()
  stash.py        Stash class: GraphQL queries, jobs, lookups, creates
  llm.py          OpenRouter class: parse(), choose()
  match.py        pure: normalize, filter, rules, create/update payloads, Jev request
  main.py         identify_scene(), apply(), run_pass(), State, Debouncer, watch(), CLI
  test_match.py   unit tests for match.py
  test_main.py    unit tests for main.py with fake Stash / fake LLM
hosts/galactica/services/default.nix   + ./stash-identify
secrets/sops/galactica.yaml            + openrouter-api-key
CLAUDE.md                              + stash-identify in galactica's host-local list
```

Run the unit tests with:
`cd hosts/galactica/services/stash-identify && python3 -m unittest -v`

---

### Task 1: Pure matching logic (`match.py`)

**Files:**
- Create: `hosts/galactica/services/stash-identify/match.py`
- Test: `hosts/galactica/services/stash-identify/test_match.py`

**Interfaces:**
- Produces (all pure):
  - `norm(s: str|None) -> str`
  - `studio_name(c: dict) -> str|None`
  - `duration_ok(c: dict, file_duration: float) -> bool`
  - `dedupe(cands: list[tuple[str, dict]]) -> list[tuple[str, dict]]`
  - `deterministic_match(cands, parse: dict) -> tuple[str, dict]|None`
  - `twins(chosen: tuple[str, dict], all_cands, file_duration) -> list[tuple[str, dict]]`
  - `stash_ids_for(endpoint: str, remote_id: str|None) -> list[dict]`
  - `performer_create_input(p: dict, endpoint: str) -> dict`
  - `studio_create_input(s: dict, endpoint: str, parent_id: str|None = None) -> dict`
  - `alias_ok(name: str) -> bool`
  - `pick_by_name(records: list[dict], name: str, alias_field: str, allow_alias: bool) -> str|None`
  - `scrape_update(scene, primary, stash_ids, studio_id, performer_ids, tag_ids, drop_tag_ids) -> dict`
  - `llm_update(scene, parse, studio_id, performer_ids, llm_tag_id) -> dict`
  - `jev_request(path: str, duration: float, parse: dict, cands) -> tuple[dict, dict]` (state, questions)
  - `jev_pick(answer: dict, cands) -> tuple[str, dict]|None`
- Candidate shape: `(endpoint_url, scraped_scene_dict)`, where the dict follows Stash's `ScrapedScene` (`title`, `date`, `duration`, `studio{name,...}`, `performers[...]`, `remote_site_id`, `image`, ...).
- Scene shape (from `stash.SCENE_FIELDS`): `id, title, code, details, director, date, urls, studio{id}, performers[{id}], tags[{id}], stash_ids[{endpoint, stash_id}], files[{path, duration}]`.

- [ ] **Step 1: Write the failing tests**

`hosts/galactica/services/stash-identify/test_match.py`:

```python
"""Unit tests for stash-identify's pure matching logic."""
import unittest

import match

TPDB = "https://theporndb.net/graphql"
STASHDB = "https://stashdb.org/graphql"


def cand(title, studio, date=None, duration=None, **kw):
    return {"title": title, "studio": {"name": studio} if studio else None,
            "date": date, "duration": duration, **kw}


class NormTest(unittest.TestCase):
    def test_collapses_case_space_punctuation(self):
        self.assertEqual(match.norm("Trip For Fuck"), match.norm("TripForFuck"))
        self.assertEqual(match.norm("CAN'T WAIT"), "cantwait")
        self.assertEqual(match.norm(None), "")


class DurationTest(unittest.TestCase):
    def test_within_tolerance(self):
        self.assertTrue(match.duration_ok(cand("a", "s", duration=358), 348.0))
        self.assertFalse(match.duration_ok(cand("a", "s", duration=359), 348.0))

    def test_unknown_duration_never_qualifies(self):
        self.assertFalse(match.duration_ok(cand("a", "s"), 348.0))


class DedupeTest(unittest.TestCase):
    def test_first_endpoint_wins_per_scene(self):
        out = match.dedupe([(TPDB, cand("Snowed In", "Frolic Me")),
                            (STASHDB, cand("SNOWED IN", "FrolicMe")),
                            (STASHDB, cand("Other", "Frolic Me"))])
        self.assertEqual([ep for ep, _ in out], [TPDB, STASHDB])
        self.assertEqual(out[1][1]["title"], "Other")


class DeterministicTest(unittest.TestCase):
    parse = {"studio": "TripForFuck", "date": "2024-12-24"}

    def test_studio_and_date_fire(self):
        c = (TPDB, cand("She's A Breeding Cow", "Trip For Fuck", "2024-12-24", 1200))
        self.assertEqual(match.deterministic_match([c], self.parse), c)

    def test_twins_across_endpoints_still_fire(self):
        a = (TPDB, cand("She's A Breeding Cow", "Trip For Fuck", "2024-12-24"))
        b = (STASHDB, cand("She's a breeding cow", "TripForFuck", "2024-12-24"))
        self.assertEqual(match.deterministic_match([a, b], self.parse), a)

    def test_two_different_scenes_do_not_fire(self):
        a = (TPDB, cand("One", "Trip For Fuck", "2024-12-24"))
        b = (TPDB, cand("Two", "Trip For Fuck", "2024-12-24"))
        self.assertIsNone(match.deterministic_match([a, b], self.parse))

    def test_needs_both_studio_and_date(self):
        c = (TPDB, cand("x", "Trip For Fuck", "2024-12-24"))
        self.assertIsNone(match.deterministic_match([c], {"studio": "TripForFuck", "date": None}))
        self.assertIsNone(match.deterministic_match([c], {"studio": "Other", "date": "2024-12-24"}))


class TwinsTest(unittest.TestCase):
    def test_finds_same_scene_on_other_endpoint(self):
        a = (STASHDB, cand("SNOWED IN", "Frolic Me", duration=600))
        b = (TPDB, cand("Snowed In", "Frolic Me", duration=601))
        c = (TPDB, cand("Snowed In", "Frolic Me", duration=900))  # wrong duration
        self.assertEqual(match.twins(a, [b, a, c], 600.0), [b, a])


class CreateInputTest(unittest.TestCase):
    def test_performer_conversions(self):
        p = {"name": "Vivian", "gender": "female", "height": "170", "weight": "55",
             "penis_length": None, "circumcised": "nonsense", "aliases": "Viv, V. ",
             "images": ["https://img/1.jpg", "https://img/2.jpg"], "remote_site_id": "abc",
             "country": "", "urls": []}
        got = match.performer_create_input(p, TPDB)
        self.assertEqual(got, {
            "name": "Vivian", "gender": "FEMALE", "height_cm": 170, "weight": 55,
            "alias_list": ["Viv", "V."], "image": "https://img/1.jpg",
            "stash_ids": [{"endpoint": TPDB, "stash_id": "abc"}]})

    def test_studio_with_parent(self):
        s = {"name": "Lustery", "image": "https://logo", "aliases": None, "remote_site_id": "r1"}
        self.assertEqual(match.studio_create_input(s, STASHDB, parent_id="7"), {
            "name": "Lustery", "image": "https://logo", "parent_id": "7",
            "stash_ids": [{"endpoint": STASHDB, "stash_id": "r1"}]})


class PickByNameTest(unittest.TestCase):
    records = [{"id": "1019", "name": "Kattie Gold", "alias_list": ["Vivian", "Katie Gold"]},
               {"id": "842", "name": "Vivian Grace", "alias_list": []}]

    def test_exact_name(self):
        self.assertEqual(match.pick_by_name(self.records, "vivian grace", "alias_list", True), "842")

    def test_single_name_alias_is_refused(self):
        self.assertFalse(match.alias_ok("Vivian"))
        self.assertIsNone(match.pick_by_name(self.records, "Vivian", "alias_list",
                                             match.alias_ok("Vivian")))

    def test_multi_word_alias_is_allowed(self):
        self.assertEqual(match.pick_by_name(self.records, "Katie Gold", "alias_list",
                                            match.alias_ok("Katie Gold")), "1019")


class UpdateTest(unittest.TestCase):
    scene = {"id": "5", "title": "", "code": "", "details": "", "director": "",
             "date": None, "urls": [], "studio": None, "performers": [],
             "tags": [{"id": "1398"}, {"id": "9"}],
             "stash_ids": [{"endpoint": STASHDB, "stash_id": "old"}]}

    def test_scrape_update_fills_empty_and_sets_cover(self):
        primary = {"title": "T", "code": "C", "date": "2026-07-23", "urls": ["u"],
                   "image": "data:image/jpeg;base64,xx", "details": None}
        up = match.scrape_update(
            self.scene, primary,
            stash_ids=[{"endpoint": TPDB, "stash_id": "new"}, {"endpoint": STASHDB, "stash_id": "old"}],
            studio_id="161", performer_ids=["1", "2"], tag_ids=["9", "20"], drop_tag_ids={"1398"})
        self.assertEqual(up, {
            "id": "5", "title": "T", "code": "C", "date": "2026-07-23", "urls": ["u"],
            "cover_image": "data:image/jpeg;base64,xx", "studio_id": "161",
            "performer_ids": ["1", "2"], "tag_ids": ["9", "20"],
            "stash_ids": [{"endpoint": STASHDB, "stash_id": "old"}, {"endpoint": TPDB, "stash_id": "new"}]})

    def test_scrape_update_never_overwrites(self):
        scene = {**self.scene, "title": "Mine", "studio": {"id": "3"}}
        up = match.scrape_update(scene, {"title": "T"}, [], "161", [], [], set())
        self.assertNotIn("title", up)
        self.assertNotIn("studio_id", up)

    def test_llm_update_tags_guess(self):
        up = match.llm_update(self.scene, {"title": "Guess"}, "3", ["4"], "77")
        self.assertEqual(up, {"id": "5", "title": "Guess", "studio_id": "3",
                              "performer_ids": ["4"], "tag_ids": ["1398", "9", "77"]})


class JevTest(unittest.TestCase):
    def test_request_and_pick(self):
        cands = [(TPDB, cand("A", "S", duration=100)), (STASHDB, cand("B", "S", duration=101))]
        state, q = match.jev_request("dir/file.mp4", 100.4, {"studio": "S"}, cands)
        self.assertEqual(state["file_duration_seconds"], 100)
        self.assertEqual(sorted(q["match"]["criteria"]), ["c0", "c1", "none"])
        self.assertEqual(match.jev_pick({"choice": "c1"}, cands), cands[1])
        self.assertIsNone(match.jev_pick({"choice": "none"}, cands))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_match -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'match'`

- [ ] **Step 3: Write the implementation**

`hosts/galactica/services/stash-identify/match.py`:

```python
"""Pure matching and payload-building logic for stash-identify. No I/O here."""
import re

# A candidate must be within this many seconds of the file. It is the gate that makes
# the looser checks (Jev, studio+date) safe: in testing every real match was within ~1 s.
DURATION_TOLERANCE = 10

GENDERS = {"MALE", "FEMALE", "TRANSGENDER_MALE", "TRANSGENDER_FEMALE", "INTERSEX", "NON_BINARY"}
CIRCUMCISED = {"CUT", "UNCUT"}

JEV_INSTRUCTIONS = (
    "All candidates already have a duration matching the file. Which one is the exact same "
    "scene as this file? The title or studio in the file path should correspond to the candidate. "
    "Performer names in file paths are often aliases, first names only, or folder names, so a "
    "performer mismatch alone does not rule a candidate out. Pick none if the title and studio "
    "don't correspond.")


def norm(s):
    """Lowercase alphanumerics only, so "TripForFuck" == "Trip For Fuck"."""
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def studio_name(c):
    return (c.get("studio") or {}).get("name")


def scene_key(c):
    return norm(c.get("title")), norm(studio_name(c))


def duration_ok(c, file_duration):
    d = c.get("duration")
    return bool(d) and abs(d - file_duration) <= DURATION_TOLERANCE


def dedupe(cands):
    """cands: [(endpoint, scraped)] in endpoint preference order; first per scene wins."""
    seen, out = set(), []
    for ep, c in cands:
        if scene_key(c) not in seen:
            seen.add(scene_key(c))
            out.append((ep, c))
    return out


def deterministic_match(cands, parse):
    """Studio and date agree with the filename parse. cands must be duration-filtered.

    Release-style names (TripForFuck.24.12.24.Peachy.Alice) carry a date but no title,
    which Jev reads as a mismatch; this rule catches them. Several hits must all be the
    same scene, else nothing fires."""
    studio, date = norm(parse.get("studio")), parse.get("date")
    if not studio or not date:
        return None
    hits = [(ep, c) for ep, c in cands
            if norm(studio_name(c)) == studio and c.get("date") == date]
    if hits and len({norm(c.get("title")) for _, c in hits}) == 1:
        return hits[0]
    return None


def twins(chosen, all_cands, file_duration):
    """All candidates, from any endpoint and including chosen, that are the same scene."""
    key = scene_key(chosen[1])
    return [(ep, c) for ep, c in all_cands
            if scene_key(c) == key and duration_ok(c, file_duration)]


def describe(c):
    d = c.get("duration")
    return (f"title={c.get('title')!r}; studio={studio_name(c)!r}; "
            f"performers={[p['name'] for p in c.get('performers') or []]}; "
            f"date={c.get('date')}; code={c.get('code')}; "
            f"duration={f'{d}s' if d else 'unknown'}")


def _compact(d):
    return {k: v for k, v in d.items() if v not in (None, "", [])}


def _int(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def _float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _enum(v, allowed):
    v = (v or "").upper().replace(" ", "_").replace("-", "_")
    return v if v in allowed else None


def _aliases(v):
    return [a.strip() for a in (v or "").split(",") if a.strip()]


def stash_ids_for(endpoint, remote_id):
    return [{"endpoint": endpoint, "stash_id": remote_id}] if remote_id else []


def performer_create_input(p, endpoint):
    """ScrapedPerformer -> PerformerCreateInput, keeping every field stash-box returned."""
    images = p.get("images") or []
    return _compact({
        "name": p["name"], "disambiguation": p.get("disambiguation"),
        "gender": _enum(p.get("gender"), GENDERS), "urls": p.get("urls"),
        "birthdate": p.get("birthdate"), "death_date": p.get("death_date"),
        "ethnicity": p.get("ethnicity"), "country": p.get("country"),
        "eye_color": p.get("eye_color"), "hair_color": p.get("hair_color"),
        "height_cm": _int(p.get("height")), "weight": _int(p.get("weight")),
        "measurements": p.get("measurements"), "fake_tits": p.get("fake_tits"),
        "penis_length": _float(p.get("penis_length")),
        "circumcised": _enum(p.get("circumcised"), CIRCUMCISED),
        "career_start": p.get("career_start"), "career_end": p.get("career_end"),
        "tattoos": p.get("tattoos"), "piercings": p.get("piercings"),
        "alias_list": _aliases(p.get("aliases")), "details": p.get("details"),
        "image": images[0] if images else None,
        "stash_ids": stash_ids_for(endpoint, p.get("remote_site_id")),
    })


def studio_create_input(s, endpoint, parent_id=None):
    """ScrapedStudio -> StudioCreateInput."""
    return _compact({
        "name": s["name"], "urls": s.get("urls"), "image": s.get("image"),
        "details": s.get("details"), "aliases": _aliases(s.get("aliases")),
        "parent_id": parent_id,
        "stash_ids": stash_ids_for(endpoint, s.get("remote_site_id")),
    })


def alias_ok(name):
    """Single-word aliases are too ambiguous: "Vivian" is one of Kattie Gold's 34."""
    return len(name.split()) >= 2


def pick_by_name(records, name, alias_field, allow_alias):
    """records come from a q= search. Exact normalized name first; alias only if allowed."""
    n = norm(name)
    for r in records:
        if norm(r["name"]) == n:
            return r["id"]
    if allow_alias:
        for r in records:
            if any(norm(a) == n for a in r.get(alias_field) or []):
                return r["id"]
    return None


def _ids(objs):
    return [o["id"] for o in objs or []]


def _merge(existing, new):
    out = list(existing)
    for i in new:
        if i not in out:
            out.append(i)
    return out


def scrape_update(scene, primary, stash_ids, studio_id, performer_ids, tag_ids, drop_tag_ids):
    """SceneUpdateInput for a confirmed stash-box match. Fills empty fields only,
    except the cover, which replaces the generated screenshot."""
    up = {"id": scene["id"]}
    for k in ("title", "code", "details", "director", "date"):
        if primary.get(k) and not scene.get(k):
            up[k] = primary[k]
    if primary.get("urls") and not scene.get("urls"):
        up["urls"] = primary["urls"]
    if primary.get("image"):
        up["cover_image"] = primary["image"]
    if studio_id and not scene.get("studio"):
        up["studio_id"] = studio_id
    up["performer_ids"] = _merge(_ids(scene.get("performers")), performer_ids)
    up["tag_ids"] = [t for t in _merge(_ids(scene.get("tags")), tag_ids) if t not in drop_tag_ids]
    have = scene.get("stash_ids") or []
    seen = {(s["endpoint"], s["stash_id"]) for s in have}
    up["stash_ids"] = have + [s for s in stash_ids if (s["endpoint"], s["stash_id"]) not in seen]
    return up


def llm_update(scene, parse, studio_id, performer_ids, llm_tag_id):
    """SceneUpdateInput for an unconfirmed filename guess, tagged for later review."""
    up = {"id": scene["id"]}
    if parse.get("title") and not scene.get("title"):
        up["title"] = parse["title"]
    if studio_id and not scene.get("studio"):
        up["studio_id"] = studio_id
    up["performer_ids"] = _merge(_ids(scene.get("performers")), performer_ids)
    up["tag_ids"] = _merge(_ids(scene.get("tags")), [llm_tag_id])
    return up


def jev_request(path, duration, parse, cands):
    """(state, questions) for a Jev choice over duration-filtered candidates."""
    criteria = {f"c{i}": describe(c) for i, (_, c) in enumerate(cands)}
    criteria["none"] = "None of the candidates is this exact scene."
    state = {"file_path": path, "file_duration_seconds": round(duration), "filename_parse": parse}
    return state, {"match": {"type": "choice", "instructions": JEV_INSTRUCTIONS,
                             "criteria": criteria}}


def jev_pick(answer, cands):
    choice = answer["choice"]
    return None if choice == "none" else cands[int(choice[1:])]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_match -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/stash-identify/match.py hosts/galactica/services/stash-identify/test_match.py
git commit -m "feat(galactica): stash-identify matching logic"
```

---

### Task 2: Stash and OpenRouter clients (`net.py`, `stash.py`, `llm.py`)

I/O wrappers, verified by read-only smoke calls against the live services rather than by unit
tests. `main.py`'s tests (Task 3) use fakes with the same method names.

**Files:**
- Create: `hosts/galactica/services/stash-identify/net.py`
- Create: `hosts/galactica/services/stash-identify/stash.py`
- Create: `hosts/galactica/services/stash-identify/llm.py`

**Interfaces:**
- Consumes: `match.jev_request(path, duration, parse, cands)`
- Produces:
  - `net.post_json(url: str, body: dict, headers: dict|None = None, timeout: int = 120) -> dict`
  - `stash.Stash(url: str, api_key: str|None = None)` with methods:
    - `defaults() -> dict` with keys `scan`, `generate`, `identify` (nulls stripped, shaped as job inputs)
    - `video_extensions() -> list[str]`
    - `max_scene_id() -> int`
    - `scene_ids_after(scene_id: int) -> list[str]`
    - `scan(paths: list[str]|None, options: dict)`, `generate(scene_ids: list[str]|None, options: dict)`, `identify(scene_ids: list[str], options: dict)`: each starts the job and blocks until it ends; raises `stash.JobFailed`
    - `scenes(ids: list[str]) -> list[dict]` (SCENE_FIELDS)
    - `bare_scenes() -> list[dict]` (no title, no studio, no performers)
    - `search(endpoint: str, query: str) -> list[dict]` (SCRAPED_FIELDS)
    - `performer_by_stash_id(endpoint, stash_id) -> str|None`, `studio_by_stash_id(endpoint, stash_id) -> str|None`
    - `performers_like(name) -> list[{id,name,alias_list}]`, `studios_like(name) -> list[{id,name,aliases}]`
    - `tag_id(name: str, create: bool = False) -> str|None`
    - `create_performer(inp: dict) -> str`, `create_studio(inp: dict) -> str`, `update_scene(inp: dict) -> None`
  - `llm.OpenRouter(api_key: str, parse_model: str, jev_model: str)` with:
    - `parse(path: str) -> dict` (keys `studio, title, performers, date, query`; raises `ValueError` after one re-ask)
    - `choose(path, duration, parse, cands) -> dict` (Jev answer: `choice`, `confidence`, `probabilities`)

- [ ] **Step 1: Write `net.py`**

```python
"""JSON-over-HTTP POST, shared by the Stash and OpenRouter clients."""
import json
import urllib.request


def post_json(url, body, headers=None, timeout=120):
    req = urllib.request.Request(
        url, json.dumps(body).encode(),
        {"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)
```

- [ ] **Step 2: Write `stash.py`**

```python
"""Thin Stash GraphQL client for stash-identify."""
import time

from net import post_json

SCENE_FIELDS = """id title code details director date urls studio { id } performers { id }
  tags { id } stash_ids { endpoint stash_id } files { path duration }"""

SCRAPED_FIELDS = """title code details director urls date image duration remote_site_id
  studio { name urls image details aliases remote_site_id parent { name remote_site_id } }
  performers { name disambiguation gender urls birthdate death_date ethnicity country
    eye_color hair_color height weight measurements fake_tits penis_length circumcised
    career_start career_end tattoos piercings aliases details images remote_site_id }
  tags { name stored_id }"""

_IDENTIFY_OPTIONS = """fieldOptions { field strategy createMissing } setCoverImage setOrganized
  includeMalePerformers performerGenders skipMultipleMatches skipMultipleMatchTag
  skipSingleNamePerformers skipSingleNamePerformerTag"""

# Saved task defaults from the Stash UI. The output shapes match the job input types
# field for field, so they pass straight through once nulls are stripped.
DEFAULTS_QUERY = """{ configuration { defaults {
  scan { rescan scanGenerateCovers scanGeneratePreviews scanGenerateImagePreviews
    scanGenerateSprites scanGeneratePhashes scanGenerateImagePhashes scanGenerateThumbnails
    scanGenerateClipPreviews }
  generate { covers sprites previews imagePreviews markers markerImagePreviews
    markerScreenshots transcodes phashes interactiveHeatmapsSpeeds imageThumbnails clipPreviews
    previewOptions { previewSegments previewSegmentDuration previewExcludeStart
      previewExcludeEnd previewPreset } }
  identify { sources { source { scraper_id stash_box_index stash_box_endpoint }
      options { %s } }
    options { %s } } } } }""" % (_IDENTIFY_OPTIONS, _IDENTIFY_OPTIONS)

JOB_INPUT_TYPES = {"metadataScan": "ScanMetadataInput",
                   "metadataGenerate": "GenerateMetadataInput",
                   "metadataIdentify": "IdentifyMetadataInput"}
JOB_TIMEOUT = 6 * 3600
JOB_POLL = 5


class JobFailed(RuntimeError):
    pass


def strip_nulls(v):
    if isinstance(v, dict):
        return {k: strip_nulls(x) for k, x in v.items() if x is not None}
    if isinstance(v, list):
        return [strip_nulls(x) for x in v]
    return v


class Stash:
    def __init__(self, url, api_key=None):
        self.url = url
        self.headers = {"ApiKey": api_key} if api_key else {}

    def gql(self, query, **variables):
        d = post_json(self.url, {"query": query, "variables": variables}, self.headers)
        if d.get("errors"):
            raise RuntimeError(d["errors"])
        return d["data"]

    # --- configuration -------------------------------------------------------

    def defaults(self):
        return strip_nulls(self.gql(DEFAULTS_QUERY)["configuration"]["defaults"])

    def video_extensions(self):
        q = "{ configuration { general { videoExtensions } } }"
        return self.gql(q)["configuration"]["general"]["videoExtensions"]

    # --- jobs ----------------------------------------------------------------

    def _run_job(self, mutation, inp):
        job = self.gql(f"mutation($i: {JOB_INPUT_TYPES[mutation]}!) {{ {mutation}(input: $i) }}",
                       i=inp)[mutation]
        deadline = time.monotonic() + JOB_TIMEOUT
        while time.monotonic() < deadline:
            j = self.gql("query($id: ID!) { findJob(input: {id: $id}) { status error } }",
                         id=job)["findJob"]
            # Finished jobs are pruned from the queue after a grace period.
            if j is None or j["status"] == "FINISHED":
                return
            if j["status"] in ("FAILED", "CANCELLED"):
                raise JobFailed(f"{mutation} job {job}: {j['status']} {j.get('error') or ''}")
            time.sleep(JOB_POLL)
        raise JobFailed(f"{mutation} job {job}: timed out after {JOB_TIMEOUT}s")

    def scan(self, paths, options):
        self._run_job("metadataScan", {**options, **({"paths": paths} if paths else {})})

    def generate(self, scene_ids, options):
        inp = {**options, "overwrite": False}
        if scene_ids is not None:
            inp["sceneIDs"] = scene_ids
        self._run_job("metadataGenerate", inp)

    def identify(self, scene_ids, options):
        self._run_job("metadataIdentify", {**options, "sceneIDs": scene_ids})

    # --- scenes --------------------------------------------------------------

    def max_scene_id(self):
        d = self.gql('{ findScenes(filter: {sort: "id", direction: DESC, per_page: 1}) '
                     '{ scenes { id } } }')["findScenes"]["scenes"]
        return int(d[0]["id"]) if d else 0

    def scene_ids_after(self, scene_id):
        d = self.gql("""query($v: Int!) { findScenes(
              scene_filter: {id: {value: $v, modifier: GREATER_THAN}}, filter: {per_page: -1})
              { scenes { id } } }""", v=scene_id)
        return [s["id"] for s in d["findScenes"]["scenes"]]

    def scenes(self, ids):
        d = self.gql(f"query($ids: [ID!]) {{ findScenes(ids: $ids, filter: {{per_page: -1}}) "
                     f"{{ scenes {{ {SCENE_FIELDS} }} }} }}", ids=ids)
        return d["findScenes"]["scenes"]

    def bare_scenes(self):
        d = self.gql(f'{{ findScenes(scene_filter: {{is_missing: "title"}}, filter: {{per_page: -1}}) '
                     f'{{ scenes {{ {SCENE_FIELDS} }} }} }}')
        return [s for s in d["findScenes"]["scenes"] if not s["studio"] and not s["performers"]]

    def search(self, endpoint, query):
        d = self.gql(f"""query($s: ScraperSourceInput!, $i: ScrapeSingleSceneInput!) {{
              scrapeSingleScene(source: $s, input: $i) {{ {SCRAPED_FIELDS} }} }}""",
                     s={"stash_box_endpoint": endpoint}, i={"query": query})
        return d["scrapeSingleScene"]

    # --- lookups and creates ---------------------------------------------------

    def _by_stash_id(self, kind, endpoint, stash_id):
        d = self.gql(f"""query($e: String!, $s: String!) {{ find{kind}s(
              {kind.lower()}_filter: {{stash_id_endpoint: {{endpoint: $e, stash_id: $s, modifier: EQUALS}}}})
              {{ {kind.lower()}s {{ id }} }} }}""", e=endpoint, s=stash_id)
        hits = d[f"find{kind}s"][f"{kind.lower()}s"]
        return hits[0]["id"] if hits else None

    def performer_by_stash_id(self, endpoint, stash_id):
        return self._by_stash_id("Performer", endpoint, stash_id)

    def studio_by_stash_id(self, endpoint, stash_id):
        return self._by_stash_id("Studio", endpoint, stash_id)

    def performers_like(self, name):
        d = self.gql("""query($q: String!) { findPerformers(filter: {q: $q, per_page: 50})
              { performers { id name alias_list } } }""", q=name)
        return d["findPerformers"]["performers"]

    def studios_like(self, name):
        d = self.gql("""query($q: String!) { findStudios(filter: {q: $q, per_page: 50})
              { studios { id name aliases } } }""", q=name)
        return d["findStudios"]["studios"]

    def tag_id(self, name, create=False):
        d = self.gql("""query($q: String!) { findTags(filter: {q: $q, per_page: 50})
              { tags { id name } } }""", q=name)
        for t in d["findTags"]["tags"]:
            if t["name"] == name:
                return t["id"]
        if not create:
            return None
        return self.gql("mutation($i: TagCreateInput!) { tagCreate(input: $i) { id } }",
                        i={"name": name})["tagCreate"]["id"]

    def create_performer(self, inp):
        return self.gql("mutation($i: PerformerCreateInput!) { performerCreate(input: $i) { id } }",
                        i=inp)["performerCreate"]["id"]

    def create_studio(self, inp):
        return self.gql("mutation($i: StudioCreateInput!) { studioCreate(input: $i) { id } }",
                        i=inp)["studioCreate"]["id"]

    def update_scene(self, inp):
        self.gql("mutation($i: SceneUpdateInput!) { sceneUpdate(input: $i) { id } }", i=inp)
```

- [ ] **Step 3: Write `llm.py`**

```python
"""OpenRouter calls: filename parse (chat, JSON mode) and Jev candidate choice."""
import json

from match import jev_request
from net import post_json

CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"
DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"

PARSE_PROMPT = """You identify adult video scenes from their file path. Return JSON:
{"studio": str|null, "title": str|null, "performers": [str], "date": "YYYY-MM-DD"|null,
 "query": str}
"studio" is the production studio/site (e.g. "Lustery", "TripForFuck"), or the creator's
handle for OnlyFans/amateur content. Use folder names as context. Expand dotted/abbreviated
release names into proper words. "query" is the best short search string for a scene database
(studio + performers + title keywords). Use null / [] rather than guessing."""


class OpenRouter:
    def __init__(self, api_key, parse_model, jev_model):
        self.headers = {"Authorization": f"Bearer {api_key}"}
        self.parse_model = parse_model
        self.jev_model = jev_model

    def parse(self, path):
        body = {"model": self.parse_model, "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": PARSE_PROMPT},
                             {"role": "user", "content": path}]}
        for _ in range(2):  # one re-ask on a malformed reply
            d = post_json(CHAT_URL, body, self.headers)
            try:
                out = json.loads(d["choices"][0]["message"]["content"])
            except (json.JSONDecodeError, KeyError, IndexError, TypeError):
                continue
            if isinstance(out, dict):
                return out
        raise ValueError(f"malformed parse reply for {path!r}")

    def choose(self, path, duration, parse, cands):
        state, questions = jev_request(path, duration, parse, cands)
        d = post_json(DECISIONS_URL, {"model": self.jev_model, "state": state,
                                      "questions": questions}, self.headers)
        return d["answers"]["match"]
```

- [ ] **Step 4: Smoke-test read-only against live galactica from raider**

Run (from `hosts/galactica/services/stash-identify`):

```bash
STASH_URL=http://galactica.bat-boa.ts.net:9999/graphql python3 - <<'EOF'
import json, os
from stash import Stash
from llm import OpenRouter
s = Stash(os.environ["STASH_URL"])
d = s.defaults()
print(sorted(d), d["generate"]["phashes"], d["identify"]["options"]["skipSingleNamePerformerTag"])
print(len(s.bare_scenes()), s.max_scene_id(), s.video_extensions()[:3])
print([x["title"] for x in s.search("https://theporndb.net/graphql", "Lustery Clark Vivian Big Boobs")][:2])
print(s.performer_by_stash_id("https://stashdb.org/graphql", "none"), s.tag_id("SKIP"))
o = OpenRouter(os.environ["OPENROUTER_API_KEY"], "~deepseek/deepseek-flash-latest", "typesafe/jev-1.13")
print(o.parse("TripForFuck.24.12.24.Peachy.Alice.XXX.720p.HEVC.x265.mp4"))
EOF
```

Expected:
- `['generate', 'identify', 'scan'] True 1398`
- a bare count ≤ 134, a max id ≥ 13030, and `['m4v', 'mp4', 'mov']`
- a list containing `'Big Boobs Are Made For Fucking'`
- `None 1398`
- a dict with `studio` ≈ TripForFuck and `date` `2024-12-24`

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/stash-identify/{net,stash,llm}.py
git commit -m "feat(galactica): stash-identify Stash and OpenRouter clients"
```

---

### Task 3: Per-scene identify and apply (`main.py`, first half)

**Files:**
- Create: `hosts/galactica/services/stash-identify/main.py`
- Test: `hosts/galactica/services/stash-identify/test_main.py`

**Interfaces:**
- Consumes: everything `match.py` produces, plus the `Stash` and `OpenRouter` method names from Task 2.
- Produces:
  - `BOXES: list[str]` (TPDB first)
  - `LLM_TAG = "llm-identified"`
  - `rel_path(container_path: str) -> str`
  - `identify_scene(stash, llm, scene: dict) -> dict`, a proposal with keys:
    `kind` (`"scrape" | "llm" | "none"`), `rule` (`"date" | "jev" | None`), `parse`, `primary` (scraped dict | None), `primary_endpoint`, `stash_ids` (list), `confidence` (float | None), `delta` (seconds | None)
  - `apply(stash, scene: dict, proposal: dict, skip_tag_ids: set[str]) -> None`
  - `format_line(scene: dict, proposal: dict) -> str`

- [ ] **Step 1: Write the failing tests**

`hosts/galactica/services/stash-identify/test_main.py`:

```python
"""Unit tests for stash-identify's per-scene flow, with fake Stash and LLM."""
import unittest

import main

TPDB, STASHDB = main.BOXES


def scene(id="5", path="/media/Vault/dir/file.mp4", duration=600.0, **kw):
    base = {"id": id, "title": "", "code": "", "details": "", "director": "", "date": None,
            "urls": [], "studio": None, "performers": [], "tags": [], "stash_ids": [],
            "files": [{"path": path, "duration": duration}]}
    return {**base, **kw}


class FakeStash:
    def __init__(self, results=None, performers=(), studios=(), tags=None):
        self.results = results or {}      # endpoint -> list of scraped scenes
        self.performers = list(performers)
        self.studios = list(studios)
        self.tags = dict(tags or {})      # name -> id
        self.updates, self.created = [], []

    def search(self, endpoint, query):
        return self.results.get(endpoint, [])

    def performer_by_stash_id(self, endpoint, sid):
        return next((p["id"] for p in self.performers if sid in p.get("sids", [])), None)

    def studio_by_stash_id(self, endpoint, sid):
        return next((s["id"] for s in self.studios if sid in s.get("sids", [])), None)

    def performers_like(self, name):
        return self.performers

    def studios_like(self, name):
        return self.studios

    def tag_id(self, name, create=False):
        if name not in self.tags and create:
            self.tags[name] = f"t-{name}"
        return self.tags.get(name)

    def create_performer(self, inp):
        self.created.append(("performer", inp))
        return f"p-{inp['name']}"

    def create_studio(self, inp):
        self.created.append(("studio", inp))
        return f"s-{inp['name']}"

    def update_scene(self, inp):
        self.updates.append(inp)


class FakeLLM:
    def __init__(self, parse, choice="none"):
        self._parse, self._choice = parse, choice

    def parse(self, path):
        if isinstance(self._parse, Exception):
            raise self._parse
        return self._parse

    def choose(self, path, duration, parse, cands):
        return {"choice": self._choice, "confidence": 0.4}


def scraped(title, studio, date=None, duration=600, rid="r", **kw):
    return {"title": title, "date": date, "duration": duration, "remote_site_id": rid,
            "studio": {"name": studio, "remote_site_id": f"st-{studio}"}, "performers": [],
            "tags": [], "image": "data:img", **kw}


class RelPathTest(unittest.TestCase):
    def test_strips_library_root(self):
        self.assertEqual(main.rel_path("/media/Vault/a/b.mp4"), "a/b.mp4")


class IdentifyTest(unittest.TestCase):
    def test_date_rule_beats_jev(self):
        st = FakeStash({TPDB: [scraped("Cow", "Trip For Fuck", "2024-12-24", rid="t1")],
                        STASHDB: [scraped("cow", "TripForFuck", "2024-12-24", 601, rid="s1")]})
        llm = FakeLLM({"studio": "TripForFuck", "date": "2024-12-24", "query": "q"}, choice="none")
        p = main.identify_scene(st, llm, scene())
        self.assertEqual((p["kind"], p["rule"], p["primary_endpoint"]), ("scrape", "date", TPDB))
        self.assertEqual(p["stash_ids"], [{"endpoint": TPDB, "stash_id": "t1"},
                                          {"endpoint": STASHDB, "stash_id": "s1"}])

    def test_jev_pick_and_tpdb_twin_becomes_primary(self):
        st = FakeStash({TPDB: [scraped("Snowed In", "Frolic Me", rid="t1")],
                        STASHDB: [scraped("SNOWED IN", "Frolic Me", rid="s1")]})
        # After dedupe only the TPDB copy is offered to Jev, as c0.
        p = main.identify_scene(st, FakeLLM({"query": "q"}, choice="c0"), scene())
        self.assertEqual((p["kind"], p["rule"], p["primary_endpoint"]), ("scrape", "jev", TPDB))
        self.assertEqual(len(p["stash_ids"]), 2)

    def test_duration_filter_blocks_lookalikes(self):
        st = FakeStash({STASHDB: [scraped("Similar", "Other", duration=900)]})
        p = main.identify_scene(st, FakeLLM({"title": "T", "query": "q"}, choice="c0"), scene())
        self.assertEqual(p["kind"], "llm")

    def test_empty_parse_is_none(self):
        p = main.identify_scene(FakeStash(), FakeLLM({"query": ""}), scene())
        self.assertEqual(p["kind"], "none")

    def test_parse_failure_propagates(self):
        with self.assertRaises(ValueError):
            main.identify_scene(FakeStash(), FakeLLM(ValueError("bad")), scene())


class ApplyTest(unittest.TestCase):
    def test_scrape_resolves_by_stash_id_then_creates(self):
        known = {"id": "1019", "name": "Kattie Gold", "alias_list": ["Vivian"], "sids": []}
        st = FakeStash(performers=[known], studios=[{"id": "161", "name": "Lustery", "aliases": []}])
        primary = scraped("Big Boobs", "Lustery", performers=[
            {"name": "Vivian", "remote_site_id": "v1", "images": ["https://i"]}],
            tags=[{"name": "Blowjob", "stored_id": "20"}, {"name": "Unknown", "stored_id": None}])
        prop = {"kind": "scrape", "primary": primary, "primary_endpoint": TPDB,
                "stash_ids": [{"endpoint": TPDB, "stash_id": "r"}]}
        main.apply(st, scene(tags=[{"id": "1398"}]), prop, skip_tag_ids={"1398"})
        # "Vivian" must NOT resolve to Kattie Gold through her alias.
        self.assertEqual(st.created, [("performer", {
            "name": "Vivian", "image": "https://i",
            "stash_ids": [{"endpoint": TPDB, "stash_id": "v1"}]})])
        up = st.updates[0]
        self.assertEqual(up["studio_id"], "161")
        self.assertEqual(up["performer_ids"], ["p-Vivian"])
        self.assertEqual(up["tag_ids"], ["20"])
        self.assertEqual(up["cover_image"], "data:img")

    def test_llm_guess_creates_by_name_and_tags(self):
        st = FakeStash()
        prop = {"kind": "llm", "parse": {"title": "Guess", "studio": "yoursofia",
                                         "performers": ["Sofia Young"]}}
        main.apply(st, scene(), prop, skip_tag_ids=set())
        self.assertEqual(st.created, [("studio", {"name": "yoursofia"}),
                                      ("performer", {"name": "Sofia Young"})])
        self.assertEqual(st.updates[0], {"id": "5", "title": "Guess", "studio_id": "s-yoursofia",
                                         "performer_ids": ["p-Sofia Young"],
                                         "tag_ids": ["t-llm-identified"]})

    def test_none_writes_nothing(self):
        st = FakeStash()
        main.apply(st, scene(), {"kind": "none"}, skip_tag_ids=set())
        self.assertEqual((st.updates, st.created), ([], []))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_main -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'main'`

- [ ] **Step 3: Write the implementation**

`hosts/galactica/services/stash-identify/main.py`:

```python
"""stash-identify: scan, generate and identify new Stash files, then fill bare scenes
from an LLM filename parse, confirmed against stash-box where possible.

Design: docs/superpowers/specs/2026-09-27-stash-llm-identify-design.md
"""
import sys

import match

BOXES = ["https://theporndb.net/graphql", "https://stashdb.org/graphql"]  # preference order
PER_BOX = 6
LLM_TAG = "llm-identified"
LIBRARY_HOST = "/mnt/storage/media/Vault"
LIBRARY_CONTAINER = "/media/Vault"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def rel_path(container_path):
    return container_path.removeprefix(LIBRARY_CONTAINER + "/")


def identify_scene(stash, llm, scene):
    """Propose metadata for one bare scene. Raises if the parse itself fails."""
    f = scene["files"][0]
    path, duration = rel_path(f["path"]), f["duration"]
    parse = llm.parse(path)
    prop = {"kind": "none", "rule": None, "parse": parse, "primary": None,
            "primary_endpoint": None, "stash_ids": [], "confidence": None, "delta": None}
    if parse.get("title") or parse.get("studio") or parse.get("performers"):
        prop["kind"] = "llm"

    everything = []
    if parse.get("query"):
        for ep in BOXES:
            try:
                everything += [(ep, c) for c in stash.search(ep, parse["query"])[:PER_BOX]]
            except Exception as e:
                log(f"  [{scene['id']}] search {ep}: {e}")
    cands = [c for c in match.dedupe(everything) if match.duration_ok(c[1], duration)]
    if not cands:
        return prop

    chosen, rule = match.deterministic_match(cands, parse), "date"
    if chosen is None:
        rule = "jev"
        try:
            answer = llm.choose(path, duration, parse, cands)
            chosen, prop["confidence"] = match.jev_pick(answer, cands), answer.get("confidence")
        except Exception as e:
            log(f"  [{scene['id']}] jev: {e}")
    if chosen is None:
        return prop

    group = match.twins(chosen, everything, duration)
    primary_ep, primary = min(group, key=lambda t: BOXES.index(t[0]))
    ids, seen = [], set()
    for ep, c in sorted(group, key=lambda t: BOXES.index(t[0])):
        if ep not in seen and c.get("remote_site_id"):
            seen.add(ep)
            ids += match.stash_ids_for(ep, c["remote_site_id"])
    prop.update(kind="scrape", rule=rule, primary=primary, primary_endpoint=primary_ep,
                stash_ids=ids, delta=round(primary["duration"] - duration))
    return prop


def resolve_studio(stash, name, create_input=None, endpoint=None, remote_id=None, create=True):
    if endpoint and remote_id:
        hit = stash.studio_by_stash_id(endpoint, remote_id)
        if hit:
            return hit
    hit = match.pick_by_name(stash.studios_like(name), name, "aliases", allow_alias=True)
    if hit or not create:
        return hit
    return stash.create_studio(create_input or {"name": name})


def resolve_performer(stash, name, create_input=None, endpoint=None, remote_id=None):
    if endpoint and remote_id:
        hit = stash.performer_by_stash_id(endpoint, remote_id)
        if hit:
            return hit
    hit = match.pick_by_name(stash.performers_like(name), name, "alias_list",
                             allow_alias=match.alias_ok(name))
    return hit or stash.create_performer(create_input or {"name": name})


def apply(stash, scene, prop, skip_tag_ids):
    if prop["kind"] == "scrape":
        p, ep = prop["primary"], prop["primary_endpoint"]
        studio_id = None
        if p.get("studio"):
            s = p["studio"]
            parent = s.get("parent")
            parent_id = parent and resolve_studio(stash, parent["name"], endpoint=ep,
                                                  remote_id=parent.get("remote_site_id"),
                                                  create=False)
            studio_id = resolve_studio(stash, s["name"], match.studio_create_input(s, ep, parent_id),
                                       ep, s.get("remote_site_id"))
        performer_ids = [resolve_performer(stash, x["name"], match.performer_create_input(x, ep),
                                           ep, x.get("remote_site_id"))
                         for x in p.get("performers") or [] if x.get("name")]
        tag_ids = [t["stored_id"] for t in p.get("tags") or [] if t.get("stored_id")]
        stash.update_scene(match.scrape_update(scene, p, prop["stash_ids"], studio_id,
                                               performer_ids, tag_ids, skip_tag_ids))
    elif prop["kind"] == "llm":
        parse = prop["parse"]
        studio_id = parse.get("studio") and resolve_studio(stash, parse["studio"])
        performer_ids = [resolve_performer(stash, n) for n in parse.get("performers") or [] if n]
        stash.update_scene(match.llm_update(scene, parse, studio_id, performer_ids,
                                            stash.tag_id(LLM_TAG, create=True)))


def format_line(scene, prop):
    head = f"[{scene['id']}] {rel_path(scene['files'][0]['path'])}"
    if prop["kind"] == "scrape":
        p = prop["primary"]
        src = "+".join(sorted({s["endpoint"].split("/")[2].split(".")[-2] for s in prop["stash_ids"]}))
        conf = f" conf={prop['confidence']:.2f}" if prop["confidence"] is not None else ""
        perf = ", ".join(x["name"] for x in p.get("performers") or [])
        body = (f"{src} ({prop['rule']}{conf}) | {p.get('title')!r} | {match.studio_name(p)} | "
                f"{perf or '-'} | Δ{prop['delta']:+d}s")
    elif prop["kind"] == "llm":
        q = prop["parse"]
        body = (f"llm-only | {q.get('title')!r} | {q.get('studio') or '-'} | "
                f"{', '.join(q.get('performers') or []) or '-'}")
    else:
        body = "nothing found"
    return f"{head}\n    {body}"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest -v`
Expected: all tests in `test_match` and `test_main` PASS.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/stash-identify/main.py hosts/galactica/services/stash-identify/test_main.py
git commit -m "feat(galactica): stash-identify per-scene identify and apply"
```

---

### Task 4: The pass, state file and `run` CLI (`main.py`, second half)

**Files:**
- Modify: `hosts/galactica/services/stash-identify/main.py` (append)
- Modify: `hosts/galactica/services/stash-identify/test_main.py` (append tests)

**Interfaces:**
- Consumes: `identify_scene`, `apply`, `format_line` (Task 3); `Stash`, `JobFailed`, `OpenRouter` (Task 2)
- Produces:
  - `to_container(host_path: str) -> str`
  - `State(path: str)` with `__contains__(scene_id)`, `add(scene_id)` (saves atomically)
  - `skip_tags(defaults: dict) -> set[str]`
  - `run_pass(stash, llm, state, defaults, paths: list[str]|None, *, jobs=True, dry_run=False, limit=None, scene_ids=None) -> None`: `jobs=False` skips steps 1–3 (manual runs); `scene_ids` given means process exactly those scenes, ignoring the state file
  - `main(argv: list[str]) -> int` with subcommands `run` (Task 4) and `watch` (Task 5)

- [ ] **Step 1: Write the failing tests**

Append to `test_main.py`, above the `if __name__ == "__main__":` line:

```python
import json
import os
import tempfile


class PathTest(unittest.TestCase):
    def test_host_to_container(self):
        self.assertEqual(main.to_container("/mnt/storage/media/Vault/a b/c"), "/media/Vault/a b/c")


class StateTest(unittest.TestCase):
    def test_persists_ids(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "sub", "attempted.json")
            s = main.State(path)
            self.assertNotIn("5", s)
            s.add("5")
            self.assertIn("5", main.State(path))
            self.assertEqual(json.load(open(path)), ["5"])


class SkipTagsTest(unittest.TestCase):
    def test_collects_identify_skip_tags(self):
        d = {"identify": {"options": {"skipMultipleMatchTag": "1398",
                                      "skipSingleNamePerformerTag": "1398"}}}
        self.assertEqual(main.skip_tags(d), {"1398"})
        self.assertEqual(main.skip_tags({"identify": {}}), set())


class PassTest(unittest.TestCase):
    class PassStash(FakeStash):
        def __init__(self, bare):
            super().__init__()
            self.bare, self.jobs = bare, []

        def max_scene_id(self):
            return 10

        def scan(self, paths, options):
            self.jobs.append(("scan", paths))

        def scene_ids_after(self, sid):
            return ["11"]

        def generate(self, ids, options):
            self.jobs.append(("generate", ids))

        def identify(self, ids, options):
            self.jobs.append(("identify", ids))

        def bare_scenes(self):
            return self.bare

    defaults = {"scan": {}, "generate": {}, "identify": {}}

    def state(self, d):
        return main.State(os.path.join(d, "s.json"))

    def test_steps_in_order_and_state_recorded(self):
        st = self.PassStash([scene("11"), scene("12")])
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            state.add("12")
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                          ["/mnt/storage/media/Vault/new"])
            self.assertEqual(st.jobs, [("scan", ["/media/Vault/new"]),
                                       ("generate", ["11"]), ("identify", ["11"])])
            self.assertEqual([u["id"] for u in st.updates], ["11"])  # 12 was already attempted
            self.assertIn("11", state)

    def test_dry_run_skips_jobs_writes_and_state(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                          None, dry_run=True)
            self.assertEqual((st.jobs, st.updates), ([], []))
            self.assertNotIn("11", state)

    def test_manual_run_skips_jobs_but_applies(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), self.state(d), self.defaults,
                          None, jobs=False)
            self.assertEqual(st.jobs, [])
            self.assertEqual([u["id"] for u in st.updates], ["11"])

    def test_parse_failure_is_not_recorded(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            main.run_pass(st, FakeLLM(ValueError("bad")), state, self.defaults, None)
            self.assertNotIn("11", state)

    def test_job_failure_still_reaches_llm_step(self):
        st = self.PassStash([scene("11")])

        def boom(paths, options):
            raise main.JobFailed("scan failed")
        st.scan = boom
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), self.state(d), self.defaults, None)
            self.assertEqual([u["id"] for u in st.updates], ["11"])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_main -v`
Expected: FAIL with `AttributeError: module 'main' has no attribute 'to_container'` (plus the others).

- [ ] **Step 3: Write the implementation**

In `main.py`, extend the imports at the top to:

```python
import argparse
import json
import os
import sys
import tempfile

import match
from llm import OpenRouter
from stash import JobFailed, Stash
```

Append to `main.py`:

```python
def to_container(host_path):
    return LIBRARY_CONTAINER + host_path.removeprefix(LIBRARY_HOST)


class State:
    """Scene IDs the LLM step has finished with, so hopeless files aren't re-billed."""

    def __init__(self, path):
        self.path = path
        try:
            with open(path) as f:
                self.ids = set(json.load(f))
        except FileNotFoundError:
            self.ids = set()

    def __contains__(self, scene_id):
        return scene_id in self.ids

    def add(self, scene_id):
        self.ids.add(scene_id)
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path))
        with os.fdopen(fd, "w") as f:
            json.dump(sorted(self.ids, key=int), f)
        os.replace(tmp, self.path)


def skip_tags(defaults):
    opts = defaults.get("identify", {}).get("options", {})
    return {t for t in (opts.get("skipMultipleMatchTag"), opts.get("skipSingleNamePerformerTag")) if t}


def run_pass(stash, llm, state, defaults, paths, *, jobs=True, dry_run=False, limit=None,
             scene_ids=None):
    """One pass. paths=None means the whole library (the sweep). jobs=False skips Stash's
    scan/generate/identify; scene_ids processes exactly those scenes, ignoring state."""
    if jobs and not dry_run:
        try:
            before = stash.max_scene_id()
            log(f"scan {paths or 'library'}")
            stash.scan([to_container(p) for p in paths] if paths else None, defaults["scan"])
            new = stash.scene_ids_after(before)
            log(f"{len(new)} new scene(s)")
            if new or paths is None:
                # The sweep generates library-wide (overwrite is always off, so only
                # missing files are made); a watched pass only touches its new scenes.
                stash.generate(new if paths else None, defaults["generate"])
            if new:
                stash.identify(new, defaults["identify"])
        except Exception as e:
            log(f"stash jobs failed, continuing to the LLM step: {e}")

    todo = stash.scenes(scene_ids) if scene_ids else \
        [s for s in stash.bare_scenes() if s["id"] not in state]
    if limit:
        todo = todo[:limit]
    log(f"llm step: {len(todo)} scene(s)")
    drop = skip_tags(defaults)
    for scene in todo:
        try:
            prop = identify_scene(stash, llm, scene)
            print(format_line(scene, prop), flush=True)
            if dry_run:
                continue
            apply(stash, scene, prop, drop)
            state.add(scene["id"])
        except Exception as e:
            log(f"  [{scene['id']}] failed, will retry next pass: {e}")


def openrouter_key():
    if os.environ.get("OPENROUTER_API_KEY"):
        return os.environ["OPENROUTER_API_KEY"]
    with open(os.environ["OPENROUTER_API_KEY_FILE"]) as f:
        return f.read().strip()


def clients():
    stash = Stash(os.environ.get("STASH_URL", "http://localhost:9999/graphql"),
                  os.environ.get("STASH_API_KEY"))
    llm = OpenRouter(openrouter_key(),
                     os.environ.get("PARSE_MODEL", "~deepseek/deepseek-flash-latest"),
                     os.environ.get("JEV_MODEL", "typesafe/jev-1.13"))
    state = State(os.environ.get("STATE_FILE", "/var/lib/stash-identify/attempted.json"))
    return stash, llm, state


def main(argv):
    ap = argparse.ArgumentParser(prog="stash-identify")
    sub = ap.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run", help="one pass, by hand")
    run.add_argument("--dry-run", action="store_true", help="print proposals; write nothing")
    run.add_argument("--limit", type=int)
    run.add_argument("--scene", action="append", dest="scenes",
                     help="only this scene ID (repeatable); ignores the state file")
    args = ap.parse_args(argv)
    stash, llm, state = clients()
    if args.cmd == "run":
        # A manual run never scans; it only does the LLM step.
        run_pass(stash, llm, state, stash.defaults(), None, jobs=False, dry_run=args.dry_run,
                 limit=args.limit, scene_ids=args.scenes)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest -v`
Expected: all tests PASS.

- [ ] **Step 5: Live dry run from raider (read-only)**

Run (from `hosts/galactica/services/stash-identify`):

```bash
STASH_URL=http://galactica.bat-boa.ts.net:9999/graphql \
STATE_FILE=/tmp/claude-1000/stash-identify-dryrun.json \
python3 main.py run --dry-run --limit 10
```

Expected: 10 two-line entries in the `format_line` format, a mix of `tpdb…(date)`/`(jev …)` and
`llm-only`, and no errors. Nothing changes in Stash, and the state file is not created.

- [ ] **Step 6: Commit**

```bash
git add hosts/galactica/services/stash-identify/main.py hosts/galactica/services/stash-identify/test_main.py
git commit -m "feat(galactica): stash-identify pass, state file and run command"
```

---

### Task 5: Watcher and daily sweep (`watch` subcommand)

**Files:**
- Modify: `hosts/galactica/services/stash-identify/main.py`
- Modify: `hosts/galactica/services/stash-identify/test_main.py`

**Interfaces:**
- Consumes: `run_pass`, `clients`, `State` (Task 4); `Stash.video_extensions`, `Stash.defaults`
- Produces:
  - `Debouncer(quiet: float)` with `add(path: str, now: float)` and `ready(now: float) -> set[str]|None`
  - `changed_dir(line: str, video_exts: set[str]) -> str|None`, which parses one `inotifywait --format '%e|%w%f'` line
  - `watch(stash, llm, state) -> None` (never returns normally; raises if inotifywait exits)
  - constants `SETTLE = 120`, `SWEEP_EVERY = 24 * 3600`

- [ ] **Step 1: Write the failing tests**

Append to `test_main.py`, above the `if __name__ == "__main__":` line:

```python
class DebouncerTest(unittest.TestCase):
    def test_fires_once_after_quiet(self):
        d = main.Debouncer(quiet=120)
        self.assertIsNone(d.ready(0))
        d.add("/v/a", 0)
        d.add("/v/b", 100)
        self.assertIsNone(d.ready(219))           # 119 s since the last event
        self.assertEqual(d.ready(220), {"/v/a", "/v/b"})
        self.assertIsNone(d.ready(1000))          # drained


class ChangedDirTest(unittest.TestCase):
    exts = {"mp4", "mkv"}

    def test_video_file_gives_its_folder(self):
        self.assertEqual(main.changed_dir("CLOSE_WRITE,CLOSE|/v/a b/x.MP4", self.exts), "/v/a b")

    def test_moved_in_folder_gives_itself(self):
        self.assertEqual(main.changed_dir("MOVED_TO,ISDIR|/v/New Folder", self.exts), "/v/New Folder")

    def test_other_files_ignored(self):
        self.assertIsNone(main.changed_dir("CLOSE_WRITE,CLOSE|/v/x.nfo", self.exts))
        self.assertIsNone(main.changed_dir("garbage", self.exts))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_main -v`
Expected: FAIL with `AttributeError: module 'main' has no attribute 'Debouncer'`

- [ ] **Step 3: Write the implementation**

Add `import queue`, `import subprocess`, `import threading` and `import time` to the imports in
`main.py`. Then insert this block after `run_pass` and before `openrouter_key`:

```python
SETTLE = 120            # seconds without events before a pass runs
SWEEP_EVERY = 24 * 3600


class Debouncer:
    def __init__(self, quiet):
        self.quiet, self.pending, self.last = quiet, set(), 0.0

    def add(self, path, now):
        self.pending.add(path)
        self.last = now

    def ready(self, now):
        if self.pending and now - self.last >= self.quiet:
            out, self.pending = self.pending, set()
            return out
        return None


def changed_dir(line, video_exts):
    """One `inotifywait --format '%e|%w%f'` line -> the folder Stash should scan."""
    events, sep, path = line.rstrip("\n").partition("|")
    if not sep:
        return None
    if "ISDIR" in events.split(","):
        return path
    if path.rsplit(".", 1)[-1].lower() in video_exts:
        return os.path.dirname(path)
    return None


def watch(stash, llm, state):
    exts = {e.lower() for e in stash.video_extensions()}
    proc = subprocess.Popen(
        ["inotifywait", "-m", "-r", "-q", "-e", "close_write,moved_to",
         "--format", "%e|%w%f", LIBRARY_HOST],
        stdout=subprocess.PIPE, text=True)
    events = queue.Queue()

    def reader():
        for line in proc.stdout:
            d = changed_dir(line, exts)
            if d:
                events.put(d)
    threading.Thread(target=reader, daemon=True).start()

    debouncer, last_sweep = Debouncer(SETTLE), 0.0   # 0 => sweep at startup (backfill)
    while True:
        if proc.poll() is not None:
            raise RuntimeError(f"inotifywait exited with {proc.returncode}")
        try:
            debouncer.add(events.get(timeout=10), time.monotonic())
            continue
        except queue.Empty:
            pass
        now = time.monotonic()
        dirs = debouncer.ready(now)
        if dirs:
            log(f"changed: {sorted(dirs)}")
            run_pass(stash, llm, state, stash.defaults(), sorted(dirs))
        elif now - last_sweep >= SWEEP_EVERY or last_sweep == 0.0:
            log("sweep")
            run_pass(stash, llm, state, stash.defaults(), None)
            last_sweep = time.monotonic()
```

In `main()`, register the subcommand next to `run`:

```python
    sub.add_parser("watch", help="the service: watch the library, sweep daily")
```

and dispatch it after the `run` branch:

```python
    if args.cmd == "watch":
        watch(stash, llm, state)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/stash-identify/main.py hosts/galactica/services/stash-identify/test_main.py
git commit -m "feat(galactica): stash-identify watcher and daily sweep"
```

---

### Task 6: NixOS module, secret, deploy and verify

**Files:**
- Create: `hosts/galactica/services/stash-identify/default.nix`
- Modify: `hosts/galactica/services/default.nix` (add `./stash-identify` to `imports`, alphabetically after `./qbittorrent-vpn.nix`)
- Modify: `secrets/sops/galactica.yaml` (add `openrouter-api-key`)
- Modify: `CLAUDE.md` (add `stash-identify/` to galactica's host-local module list)

**Interfaces:**
- Consumes: `main.py watch` / `main.py run` (Tasks 4–5)
- Produces: the `stash-identify` command on galactica's PATH, and `systemd.services.stash-identify`

- [ ] **Step 1: Add the OpenRouter key to galactica's secrets (non-interactive)**

```bash
nix develop -c sops set secrets/sops/galactica.yaml '["openrouter-api-key"]' \
  "$(python3 -c 'import json,os; print(json.dumps(os.environ["OPENROUTER_API_KEY"]))')"
nix develop -c sops --decrypt --extract '["openrouter-api-key"]' secrets/sops/galactica.yaml | cut -c1-8
```

Expected: the second command prints `sk-or-v1`.

- [ ] **Step 2: Write `default.nix`**

```nix
# stash-identify: watches the Stash library and, for every new file, runs Stash's own
# scan -> generate -> identify with the defaults saved in the Stash UI, then fills title,
# studio and performers on any scene still bare, using an LLM filename parse confirmed
# against StashDB/ThePornDB where it can. Guesses are tagged `llm-identified`.
#
# Design: docs/superpowers/specs/2026-09-27-stash-llm-identify-design.md
# Unit tests: `python3 -m unittest -v` in this directory.
{
  config,
  pkgs,
  ...
}: let
  keyFile = config.sops.secrets.openrouter-api-key.path;

  stashIdentify = pkgs.writeShellApplication {
    name = "stash-identify";
    runtimeInputs = [pkgs.inotify-tools];
    text = ''
      export OPENROUTER_API_KEY_FILE="''${OPENROUTER_API_KEY_FILE:-${keyFile}}"
      exec ${pkgs.python3}/bin/python3 ${./.}/main.py "$@"
    '';
  };
in {
  sops.secrets.openrouter-api-key.owner = "media";

  environment.systemPackages = [stashIdentify];

  systemd.services.stash-identify = {
    description = "Scan, generate and identify new Stash files";
    wantedBy = ["multi-user.target"];
    after = ["${config.virtualisation.oci-containers.backend}-stash.service" "mnt-storage.mount"];
    wants = ["${config.virtualisation.oci-containers.backend}-stash.service"];
    requires = ["mnt-storage.mount"];
    serviceConfig = {
      ExecStart = "${stashIdentify}/bin/stash-identify watch";
      User = "media";
      Group = "media";
      StateDirectory = "stash-identify";
      Restart = "always";
      RestartSec = "30s";
    };
  };
}
```

- [ ] **Step 3: Import it, update CLAUDE.md, and build**

In `hosts/galactica/services/default.nix`, add `./stash-identify` after `./qbittorrent-vpn.nix`.

In `CLAUDE.md`, section "Constellation Modules", find the sentence listing galactica's host-local
modules (`… tablet-sync`, `vpn-exit-nodes`, `immich-pixel-sync/`, …) and add `stash-identify/`
after `immich-pixel-sync/`.

```bash
git add hosts/galactica/services/stash-identify/default.nix
just fmt
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
```

Expected: the build succeeds. (If it fails with `No such file or directory` for the new
directory, a file wasn't `git add`ed.)

- [ ] **Step 4: Commit**

```bash
git add hosts/galactica/services/stash-identify/default.nix hosts/galactica/services/default.nix \
  secrets/sops/galactica.yaml CLAUDE.md
git commit -m "feat(galactica): run stash-identify as a file-watching service"
```

- [ ] **Step 5: Apply to two known scenes from raider before deploying**

This is the first step that writes to Stash. Use the Lustery scene (a scrape match with a
single-name performer) and one yoursofia scene (LLM-only):

```bash
cd hosts/galactica/services/stash-identify
STASH_URL=http://galactica.bat-boa.ts.net:9999/graphql \
STATE_FILE=/tmp/claude-1000/stash-identify-manual.json \
python3 main.py run --scene 12904 --scene 11782
```

Then check in Stash (`https://stash.arsfeld.one`, or query GraphQL):
- **12904**: title "Big Boobs Are Made For Fucking", studio Lustery (#161), performers Vivian
  and Clark **not linked to Kattie Gold (#1019)**, a cover, stash_ids for TPDB (and StashDB if
  its twin matched), tag SKIP removed.
- **11782**: title "Two demons seduce a guy", tag `llm-identified`.

- [ ] **Step 6: Deploy and watch the backfill**

```bash
just deploy galactica
ssh root@galactica.bat-boa.ts.net journalctl -u stash-identify -f
```

Expected: `sweep`, the scan/generate log lines, then `llm step: ~132 scene(s)` and one entry per
scene. About 17 scrape matches, the rest llm-only, and about 4 `nothing found`. Afterwards,
`/var/lib/stash-identify/attempted.json` lists the IDs.

- [ ] **Step 7: Verify the new-file path**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media cp "/mnt/storage/media/Vault/Movie on 2012-01-04 at 21.09.mov" /mnt/storage/media/Vault/stash-identify-test.mov'
```

Expected in the journal, about 2 minutes later: `changed: ['/mnt/storage/media/Vault']`, a scan
reporting `1 new scene(s)`, generate and identify for it, then an LLM-step entry. Clean up with
`rm /mnt/storage/media/Vault/stash-identify-test.mov`, then run Stash's Clean task from the UI.
