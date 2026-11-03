# stash-identify Product Code Lookup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify coded files by their product code (StashDB, then the code database) instead of an LLM filename guess, and upgrade the scenes that already got a guess.

**Architecture:** A pure `match.product_code` spots a code in the filename. `main.code_prop` looks it up on StashDB and then via a new `codedb.CodeDb` REST client, accepts only exact-code hits, and returns the same `"scrape"` proposal shape the existing `apply` path writes. `run_pass` also selects `llm-identified` scenes with a code, and applies their matches with `overwrite=True`.

**Tech Stack:** Python 3 stdlib only (urllib, unittest), Stash GraphQL, the code database's REST API. NixOS module `hosts/galactica/services/stash-identify/default.nix` (unchanged, but it ships the whole directory).

**Spec:** `docs/superpowers/specs/2026-09-28-stash-identify-code-design.md`

## Global Constraints

- All code lives in `hosts/galactica/services/stash-identify/`. Run the tests from there with `python3 -m unittest -v`.
- No new sops secret. The code-database key comes from Stash's `configuration.general.stashBoxes` entry whose endpoint contains `codedb`.
- Code matches have **no duration gate**. Only an exact `code_key` match counts.
- A failed StashDB or code-database request raises `main.TransientError`, never downgrades to llm-only.
- An upgrade candidate (a scene tagged `llm-identified` with a product code) never calls the LLM. On a miss nothing is written and the state file is untouched.
- Match surrounding style: small functions, short docstrings that explain *why*, no type hints, pure logic in `match.py`, I/O in `stash.py`, `codedb.py` and `net.py`.
- New files must be `git add`ed before any `nix build` (flakes only see tracked files).
- Conventional commits, scope `galactica`. Commit straight to master (no branches).

---

### Task 1: Pure code helpers and overwrite in `match.py`

**Files:**
- Modify: `hosts/galactica/services/stash-identify/match.py`
- Test: `hosts/galactica/services/stash-identify/test_match.py`

**Interfaces:**
- Produces:
  - `match.product_code(path) -> str | None`, which returns the uppercased code, e.g. `"ABCD-910"`.
  - `match.code_key(s) -> tuple[str, int] | None`.
  - `match.single_scene(cands) -> dict | None`, where `cands` is a list of scraped-scene dicts.
  - `match.codedb_scene(hit) -> dict`, which returns the ScrapedScene-shaped dict.
  - `match.scrape_update(scene, primary, stash_ids, studio_id, performer_ids, tag_ids, drop_tag_ids, overwrite=False)`.

- [ ] **Step 1: Write the failing tests.** Append to `test_match.py` (before the `if __name__` block if there is one, otherwise at the end):

```python
class ProductCodeTest(unittest.TestCase):
    def test_real_codes(self):
        for path, code in [("ABCD-910.mp4", "ABCD-910"), ("EFGH-796.H265.mp4", "EFGH-796"),
                           ("sub/dir/ijkl-795.mp4", "IJKL-795"), ("MNOPQ-601-C.mp4", "MNOPQ-601"),
                           ("RST-843 uncensored.mkv", "RST-843")]:
            self.assertEqual(match.product_code(path), code, path)

    def test_non_code_names_from_the_library(self):
        for path in ["site958_sd.wmv", "name0720.mp4", "ABC026_s04_1080.mp4",
                     "StudioD - Performer C aka Performer D - Title (XY) OB643.mp4",
                     "3.TitleB.2026.1080p.EN.studioe.example.org.mp4",
                     "title-c-540p.mp4", "18Studio - Performer E - Title D.mp4",
                     "studiof.24.08.03.performer.f.and.performer.g.title.1080p.mp4"]:
            self.assertIsNone(match.product_code(path), path)


class CodeKeyTest(unittest.TestCase):
    def test_equivalent_spellings(self):
        self.assertEqual(match.code_key("wxyz00402"), ("WXYZ", 402))
        self.assertEqual(match.code_key("WXYZ-402"), match.code_key("wxyz-402"))

    def test_different_codes_and_non_codes(self):
        self.assertNotEqual(match.code_key("UVWX-732"), match.code_key("EFGH-732"))
        self.assertIsNone(match.code_key(None))
        self.assertIsNone(match.code_key("Winter Cabin"))


class SingleSceneTest(unittest.TestCase):
    def test_agreeing_hits_give_the_first(self):
        a, b = cand("IJKL-795", "Studio B"), cand("ijkl-795", "Studio B")
        self.assertIs(match.single_scene([a, b]), a)

    def test_disagreeing_or_empty_give_none(self):
        self.assertIsNone(match.single_scene([cand("One", "S"), cand("Two", "S")]))
        self.assertIsNone(match.single_scene([]))


# Trimmed from a real `GET https://api.codedb.example.org/codes?q=ABCD-910` response.
CODEDB_HIT = {
    "external_id": "abcd-910", "slug": "studio-a-abcd-910-title-a",
    "title": "ABCD-910 - Title A", "date": "2026-03-03",
    "description": "d", "duration": 7800, "url": "https://example.org/movies/abcd910/",
    "poster": "https://thumb/poster", "background": {"full": "https://cdn/bg"},
    "site": {"name": "Studio A"},
    "performers": [{"name": "Performer A", "image": "https://cdn/p1", "parent": {"name": "Performer A"}},
                   {"name": "Perf. B", "image": None, "parent": {"name": "Performer B"}},
                   {"name": "", "image": None, "parent": None}],
    "tags": [{"name": "Tag A"}],
}


class CodeDbSceneTest(unittest.TestCase):
    def test_maps_to_scraped_scene_shape(self):
        s = match.codedb_scene(CODEDB_HIT)
        self.assertEqual(s["title"], "ABCD-910 - Title A")
        self.assertEqual(s["code"], "ABCD-910")
        self.assertEqual((s["date"], s["details"], s["duration"]), ("2026-03-03", "d", 7800))
        self.assertEqual(s["image"], "https://cdn/bg")
        self.assertEqual(s["urls"], ["https://codedb.example.org/codes/studio-a-abcd-910-title-a",
                                     "https://example.org/movies/abcd910/"])
        self.assertEqual(s["studio"], {"name": "Studio A"})
        # parent (the canonical performer) wins over the site-local name; nameless dropped
        self.assertEqual(s["performers"], [{"name": "Performer A", "images": ["https://cdn/p1"]},
                                           {"name": "Performer B", "images": []}])
        self.assertEqual(s["tags"], [])
        self.assertIsNone(s.get("remote_site_id"))

    def test_poster_fallback_and_missing_site(self):
        s = match.codedb_scene({**CODEDB_HIT, "background": {"full": None}, "site": None})
        self.assertEqual(s["image"], "https://thumb/poster")
        self.assertIsNone(s["studio"])


class ScrapeUpdateOverwriteTest(unittest.TestCase):
    guessed = {"id": "20", "title": "Studio A* – ABCD-910", "code": "", "details": "",
               "director": "", "date": "2026-01-01", "urls": [], "studio": {"id": "s9"},
               "performers": [{"id": "p9"}], "tags": [{"id": "t-llm"}, {"id": "t2"}],
               "stash_ids": []}

    def test_overwrite_replaces_guess_and_drops_llm_tag(self):
        primary = match.codedb_scene(CODEDB_HIT)
        up = match.scrape_update(self.guessed, primary, [], "s2", ["p1"], [], {"t-llm"},
                                 overwrite=True)
        self.assertEqual(up["title"], "ABCD-910 - Title A")
        self.assertEqual((up["code"], up["date"]), ("ABCD-910", "2026-03-03"))
        self.assertEqual(up["studio_id"], "s2")
        self.assertEqual(up["performer_ids"], ["p1"])
        self.assertEqual(up["tag_ids"], ["t2"])
        self.assertEqual(up["cover_image"], "https://cdn/bg")

    def test_without_overwrite_existing_fields_stay(self):
        primary = match.codedb_scene(CODEDB_HIT)
        up = match.scrape_update(self.guessed, primary, [], "s2", ["p1"], [], set())
        self.assertNotIn("title", up)
        self.assertNotIn("studio_id", up)
        self.assertEqual(up["performer_ids"], ["p9", "p1"])
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_match -v`
Expected: the new tests fail with `AttributeError: module 'match' has no attribute 'product_code'` (plus `code_key`, `single_scene`, `codedb_scene`), and `ScrapeUpdateOverwriteTest` fails with `TypeError: ... unexpected keyword argument 'overwrite'`.

- [ ] **Step 3: Implement it in `match.py`.** Add `import os` beside `import re`. After `twins(...)`, add:

```python
# A product code leading a filename: 2-6 letters, a hyphen, 3-5 digits, then nothing
# or a separator and anything (EFGH-796.H265, MNOPQ-601-C). The hyphen is required so
# site958_sd, name0720 and tokens inside Western names don't match; a false positive
# only costs a lookup before the LLM flow takes over.
PRODUCT_CODE = re.compile(r"([A-Za-z]{2,6})-(\d{3,5})(?:[-_. ].*)?")


def product_code(path):
    stem = os.path.splitext(os.path.basename(path))[0]
    m = PRODUCT_CODE.fullmatch(stem)
    return f"{m[1].upper()}-{m[2]}" if m else None


def code_key(s):
    """("WXYZ", 402) for wxyz00402, WXYZ-402 and wxyz-402 alike; None for non-codes."""
    m = re.fullmatch(r"\s*([A-Za-z]{2,6})[-_ ]?(\d{2,6})\s*", s or "")
    return (m[1].upper(), int(m[2])) if m else None


def single_scene(cands):
    """cands already share the file's code. The one scene they all are, or None when
    there are none or they disagree on the title."""
    if cands and len({norm(c.get("title")) for c in cands}) == 1:
        return cands[0]
    return None


def codedb_scene(hit):
    """A code-database /code record -> the ScrapedScene shape apply() consumes. There is no
    remote_site_id: the code database isn't a stash-box, so studio and performers resolve by name.
    The code database's tags carry no Stash id, so none are passed on."""
    site = hit.get("site") or {}
    performers = []
    for p in hit.get("performers") or []:
        name = (p.get("parent") or {}).get("name") or p.get("name")
        if name:
            performers.append({"name": name, "images": [p["image"]] if p.get("image") else []})
    urls = [f"https://codedb.example.org/codes/{hit['slug']}" if hit.get("slug") else None, hit.get("url")]
    return {"title": hit.get("title"), "code": (hit.get("external_id") or "").upper() or None,
            "date": hit.get("date"), "details": hit.get("description"),
            "duration": hit.get("duration"),
            "image": (hit.get("background") or {}).get("full") or hit.get("poster"),
            "urls": [u for u in urls if u],
            "studio": {"name": site["name"]} if site.get("name") else None,
            "performers": performers, "tags": []}
```

Then replace `scrape_update` with:

```python
def scrape_update(scene, primary, stash_ids, studio_id, performer_ids, tag_ids, drop_tag_ids,
                  overwrite=False):
    """SceneUpdateInput for a confirmed stash-box match. Fills empty fields only,
    except the cover, which replaces the generated screenshot. overwrite (upgrading an
    llm-identified guess) replaces the guessed fields and performers outright."""
    up = {"id": scene["id"]}
    for k in ("title", "code", "details", "director", "date"):
        if primary.get(k) and (overwrite or not scene.get(k)):
            up[k] = primary[k]
    if primary.get("urls") and (overwrite or not scene.get("urls")):
        up["urls"] = primary["urls"]
    if primary.get("image"):
        up["cover_image"] = primary["image"]
    if studio_id and (overwrite or not scene.get("studio")):
        up["studio_id"] = studio_id
    up["performer_ids"] = (list(performer_ids) if overwrite
                           else _merge(_ids(scene.get("performers")), performer_ids))
    up["tag_ids"] = [t for t in _merge(_ids(scene.get("tags")), tag_ids) if t not in drop_tag_ids]
    have = scene.get("stash_ids") or []
    seen = {(s["endpoint"], s["stash_id"]) for s in have}
    up["stash_ids"] = have + [s for s in stash_ids if (s["endpoint"], s["stash_id"]) not in seen]
    return up
```

- [ ] **Step 4: Run all the tests to verify they pass.**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest -v`
Expected: every test passes, old and new.

- [ ] **Step 5: Commit.**

```bash
git add hosts/galactica/services/stash-identify/match.py hosts/galactica/services/stash-identify/test_match.py
git commit -m "feat(galactica): stash-identify pure product code helpers and overwrite update"
```

---

### Task 2: I/O clients: `net.get_json`, `codedb.CodeDb`, and the new Stash queries

**Files:**
- Modify: `hosts/galactica/services/stash-identify/net.py`
- Create: `hosts/galactica/services/stash-identify/codedb.py`
- Modify: `hosts/galactica/services/stash-identify/stash.py`
- Test: `hosts/galactica/services/stash-identify/test_main.py`

**Interfaces:**
- Produces:
  - `net.get_json(url, headers=None, timeout=120) -> dict`.
  - `codedb.CODE_URL = "https://api.codedb.example.org/codes"`.
  - `codedb.CodeDb(api_key)` with `.code_search(code) -> list[dict]`, the raw code-database records (the response's `data`).
  - `Stash.codedb_api_key() -> str | None`.
  - `Stash.scenes_with_tag(tag_id) -> list[dict]`, the scenes with `SCENE_FIELDS`.

- [ ] **Step 1: Write the failing tests.** In `test_main.py`, add `import codedb` after `import stash as stash_mod`, then add this class after `StashLookupTest`:

```python
class ClientTest(unittest.TestCase):
    def test_codedb_search_sends_key_and_returns_data(self):
        seen = {}

        def fake_get_json(url, headers=None, timeout=120):
            seen.update(url=url, headers=headers)
            return {"data": [{"external_id": "abcd-910"}]}
        orig = codedb.get_json
        codedb.get_json = fake_get_json
        try:
            hits = codedb.CodeDb("k").code_search("ABCD-910")
        finally:
            codedb.get_json = orig
        self.assertEqual(hits, [{"external_id": "abcd-910"}])
        self.assertEqual(seen["url"], "https://api.codedb.example.org/codes?q=ABCD-910&per_page=10")
        self.assertEqual(seen["headers"]["Authorization"], "Bearer k")
        self.assertIn("User-Agent", seen["headers"])

    def test_codedb_api_key_from_stash_box_config(self):
        s = stash_mod.Stash("http://x/graphql")
        s.gql = lambda q, **v: {"configuration": {"general": {"stashBoxes": [
            {"endpoint": "https://stashdb.org/graphql", "api_key": "sdb"},
            {"endpoint": "https://codedb.example.org/graphql", "api_key": "tp"}]}}}
        self.assertEqual(s.codedb_api_key(), "tp")
        s.gql = lambda q, **v: {"configuration": {"general": {"stashBoxes": []}}}
        self.assertIsNone(s.codedb_api_key())

    def test_scenes_with_tag_filters_by_tag(self):
        s = stash_mod.Stash("http://x/graphql")
        calls = []

        def fake_gql(query, **variables):
            calls.append((query, variables))
            return {"findScenes": {"scenes": [{"id": "20"}]}}
        s.gql = fake_gql
        self.assertEqual(s.scenes_with_tag("77"), [{"id": "20"}])
        query, variables = calls[0]
        self.assertIn("tags:", query)
        self.assertIn("INCLUDES", query)
        self.assertEqual(variables, {"t": ["77"]})
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_main -v`
Expected: an import error, `ModuleNotFoundError: No module named 'codedb'`.

- [ ] **Step 3: Implement it.** First replace `net.py` wholesale:

```python
"""JSON over HTTP, shared by the Stash, OpenRouter and code-database clients."""
import json
import urllib.request


def post_json(url, body, headers=None, timeout=120):
    req = urllib.request.Request(
        url, json.dumps(body).encode(),
        {"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def get_json(url, headers=None, timeout=120):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)
```

Then create `codedb.py`:

```python
"""The code database. Its stash-box endpoint doesn't expose these records, and Stash's
community scraper for it would need a key hand-edited into a file the scraper
manager overwrites, so stash-identify calls the REST API itself."""
import urllib.parse

from net import get_json

CODE_URL = "https://api.codedb.example.org/codes"


class CodeDb:
    def __init__(self, api_key):
        # Without a User-Agent, urllib's default is refused at the edge.
        self.headers = {"Authorization": f"Bearer {api_key}", "Accept": "application/json",
                        "User-Agent": "stash-identify"}

    def code_search(self, code):
        return get_json(f"{CODE_URL}?q={urllib.parse.quote(code)}&per_page=10",
                        self.headers)["data"]
```

Finally, in `stash.py`, add to the `# --- configuration` section after `video_extensions`:

```python
    def codedb_api_key(self):
        """The key Stash holds for the code database's stash-box, reused for its code API."""
        q = "{ configuration { general { stashBoxes { endpoint api_key } } } }"
        boxes = self.gql(q)["configuration"]["general"]["stashBoxes"]
        return next((b["api_key"] for b in boxes
                     if "codedb" in b["endpoint"] and b.get("api_key")), None)
```

and add to the `# --- scenes` section after `bare_scenes`:

```python
    def scenes_with_tag(self, tag_id):
        d = self.gql(f"""query($t: [ID!]) {{ findScenes(
              scene_filter: {{tags: {{value: $t, modifier: INCLUDES}}}}, filter: {{per_page: -1}})
              {{ scenes {{ {SCENE_FIELDS} }} }} }}""", t=[tag_id])
        return d["findScenes"]["scenes"]
```

- [ ] **Step 4: Run all the tests to verify they pass.**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest -v`
Expected: all pass.

- [ ] **Step 5: Commit.** `codedb.py` is new, so it has to be added before the Nix build can see it.

```bash
git add hosts/galactica/services/stash-identify/{net.py,codedb.py,stash.py,test_main.py}
git commit -m "feat(galactica): stash-identify code-database client and tag/key queries"
```

---

### Task 3: Code lookup in `identify_scene`, plus log formatting and wiring

**Files:**
- Modify: `hosts/galactica/services/stash-identify/main.py`
- Modify: `hosts/galactica/services/stash-identify/default.nix` (header comment only)
- Test: `hosts/galactica/services/stash-identify/test_main.py`

**Interfaces:**
- Consumes: `match.product_code`, `match.code_key`, `match.single_scene`, `match.codedb_scene`, `match.stash_ids_for`, `codedb.CODE_URL`, `codedb.CodeDb`, and `Stash.codedb_api_key`.
- Produces:
  - `main.STASHDB` and `main.CODEDB`, the endpoint labels.
  - `main.code_prop(stash, codedb, scene) -> dict | None`. The proposal has `kind="scrape"`, `rule="code"`, `source` set to `"stashdb"` or `"codedb"`, and `delta` as an int or None.
  - `main.identify_scene(stash, llm, scene, codedb=None)`.
  - `main.clients() -> (stash, llm, state, codedb)`.
  - `main.watch(stash, llm, state, codedb)`.

- [ ] **Step 1: Write the failing tests.** In `test_main.py`, after the `scraped(...)` helper, add:

```python
class FakeCodeDb:
    def __init__(self, hits):
        self.hits, self.calls = hits, []

    def code_search(self, code):
        self.calls.append(code)
        if isinstance(self.hits, Exception):
            raise self.hits
        return self.hits


def code_hit(code, title=None, site="Studio A", duration=7800, performers=("Performer A",)):
    return {"external_id": code.lower(), "slug": f"x-{code.lower()}",
            "title": title or f"{code} - Some Title", "date": "2026-03-03", "description": "d",
            "duration": duration, "url": "https://example.org/x", "background": {"full": "https://img"},
            "site": {"name": site},
            "performers": [{"name": n, "image": None, "parent": {"name": n}} for n in performers]}


NO_LLM = FakeLLM(AssertionError("LLM must not be called for a product code hit"))
```

Then add this class after `IdentifyTest`:

```python
class CodeIdentifyTest(unittest.TestCase):
    path = "/media/Vault/ABCD-910.mp4"

    def test_stashdb_exact_code_wins_without_llm(self):
        st = FakeStash({STASHDB: [scraped("IJKL-795", "Studio B", duration=9499, rid="s1",
                                          code="IJKL-795"),
                                  scraped("EFGHI-795", "Studio D", rid="s2", code="EFGHI-795")]})
        tp = FakeCodeDb([])
        p = main.identify_scene(st, NO_LLM, scene(path="/media/Vault/IJKL-795.mp4", duration=9500), tp)
        self.assertEqual((p["kind"], p["rule"], p["source"]), ("scrape", "code", "stashdb"))
        self.assertEqual(p["primary_endpoint"], STASHDB)
        self.assertEqual(p["stash_ids"], [{"endpoint": STASHDB, "stash_id": "s1"}])
        self.assertEqual(p["delta"], -1)
        self.assertEqual(tp.calls, [])  # StashDB hit: the code database never asked

    def test_codedb_hit_ignores_duration(self):
        # StashDB only has same-number neighbours; the code database's nominal 7800 s is 281 s off.
        st = FakeStash({STASHDB: [scraped("AAAA-910", "Studio C", code="AAAA-910")]})
        p = main.identify_scene(st, NO_LLM, scene(path=self.path, duration=7519.0),
                                FakeCodeDb([code_hit("ABCD-910")]))
        self.assertEqual((p["kind"], p["rule"], p["source"]), ("scrape", "code", "codedb"))
        self.assertEqual(p["primary_endpoint"], main.CODEDB)
        self.assertEqual(p["primary"]["code"], "ABCD-910")
        self.assertEqual((p["stash_ids"], p["delta"]), ([], 281))

    def test_both_miss_falls_back_to_llm(self):
        p = main.identify_scene(FakeStash(), FakeLLM({"title": "T", "query": ""}),
                                scene(path=self.path), FakeCodeDb([code_hit("ABCD-190")]))
        self.assertEqual(p["kind"], "llm")

    def test_no_codedb_client_uses_stashdb_only(self):
        p = main.identify_scene(FakeStash(), FakeLLM({"title": "T", "query": ""}),
                                scene(path=self.path), None)
        self.assertEqual(p["kind"], "llm")

    def test_ambiguous_exact_hits_fall_back(self):
        tp = FakeCodeDb([code_hit("ABCD-910", title="One"), code_hit("ABCD-910", title="Two")])
        p = main.identify_scene(FakeStash(), FakeLLM({"title": "T", "query": ""}),
                                scene(path=self.path), tp)
        self.assertEqual(p["kind"], "llm")

    def test_codedb_failure_is_transient(self):
        with self.assertRaises(main.TransientError):
            main.identify_scene(FakeStash(), NO_LLM, scene(path=self.path),
                                FakeCodeDb(urllib.error.URLError("down")))

    def test_stashdb_failure_is_transient(self):
        with self.assertRaises(main.TransientError):
            main.identify_scene(FakeStash({STASHDB: RuntimeError("down")}), NO_LLM,
                                scene(path=self.path), FakeCodeDb([]))

    def test_codedb_apply_resolves_by_name(self):
        st = FakeStash()
        p = main.identify_scene(st, NO_LLM, scene(path=self.path, duration=7519.0),
                                FakeCodeDb([code_hit("ABCD-910")]))
        main.apply(st, scene(path=self.path), p, skip_tag_ids=set())
        self.assertEqual(st.created, [("studio", {"name": "Studio A"}),
                                      ("performer", {"name": "Performer A"})])
        up = st.updates[0]
        self.assertEqual((up["title"], up["code"]), ("ABCD-910 - Some Title", "ABCD-910"))
        self.assertEqual((up["studio_id"], up["performer_ids"]), ("s-Studio A", ["p-Performer A"]))
        self.assertEqual(up["stash_ids"], [])
```

Add these to `FormatLineTest`:

```python
    def test_codedb_line_shows_source_and_delta(self):
        prop = main.identify_scene(FakeStash(), NO_LLM,
                                   scene(path="/media/Vault/ABCD-910.mp4", duration=7519.0),
                                   FakeCodeDb([code_hit("ABCD-910")]))
        line = main.format_line(scene(path="/media/Vault/ABCD-910.mp4"), prop)
        self.assertIn("codedb (code)", line)
        self.assertIn("Δ+281s", line)

    def test_unknown_delta_does_not_crash(self):
        prop = main.identify_scene(FakeStash({STASHDB: [scraped("IJKL-795", "Studio B",
                                                                duration=None, code="IJKL-795")]}),
                                   NO_LLM, scene(path="/media/Vault/IJKL-795.mp4"), None)
        self.assertIn("Δ?", main.format_line(scene(), prop))
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_main -v`
Expected: the new tests fail with `TypeError: identify_scene() takes 3 positional arguments but 4 were given`.

- [ ] **Step 3: Implement it in `main.py`.**

Update the module docstring to:

```python
"""stash-identify: scan, generate and identify new Stash files, then fill bare scenes
from an LLM filename parse, confirmed against stash-box where possible. Coded files are
looked up by product code first, and replace earlier LLM guesses.

Design: docs/superpowers/specs/2026-09-27-stash-llm-identify-design.md
codes:  docs/superpowers/specs/2026-09-28-stash-identify-code-design.md
"""
```

Change the imports and constants:

```python
import match
from llm import OpenRouter
from stash import JobFailed, Stash
from codedb import CODE_URL as CODEDB, CodeDb

STASHDB = "https://stashdb.org/graphql"
BOXES = ["https://codedb.example.org/graphql", STASHDB]  # preference order
```

Add `code_prop` directly above `identify_scene`:

```python
def code_prop(stash, codedb, scene):
    """A "scrape" proposal for a file named by a product code, or None (no code, or no exact
    hit). StashDB first, for its stash_ids and tags; then the code database. The
    code is the identity check, so there's no duration gate: the code database lists code durations in
    whole minutes, and multi-part files share one code. A failed lookup raises
    TransientError rather than letting the scene fall through to a guess."""
    f = scene["files"][0]
    code = match.product_code(rel_path(f["path"]))
    if not code:
        return None
    key = match.code_key(code)
    try:
        hits = stash.search(STASHDB, code)
    except Exception as e:
        raise TransientError(f"scene {scene['id']}: search {STASHDB} failed: {e}") from e
    chosen = match.single_scene([c for c in hits if match.code_key(c.get("code")) == key])
    ep, source = STASHDB, "stashdb"
    if chosen is None and codedb:
        try:
            hits = codedb.code_search(code)
        except Exception as e:
            raise TransientError(f"scene {scene['id']}: the code database search failed: {e}") from e
        chosen = match.single_scene([match.codedb_scene(h) for h in hits
                                     if match.code_key(h.get("external_id")) == key])
        ep, source = CODEDB, "codedb"
    if chosen is None:
        return None
    d = chosen.get("duration")
    return {"kind": "scrape", "rule": "code", "source": source, "parse": None,
            "primary": chosen, "primary_endpoint": ep, "confidence": None,
            "stash_ids": match.stash_ids_for(ep, chosen.get("remote_site_id")),
            "delta": round(d - f["duration"]) if d else None}
```

Change `identify_scene`'s signature and docstring opening, and put the code lookup first:

```python
def identify_scene(stash, llm, scene, codedb=None):
    """Propose metadata for one bare scene. A coded file is looked up by its code
    first (code_prop), and only reaches the LLM if that finds nothing. Raises if the
    parse, a stash-box search, or ...
```

Keep the rest of the existing docstring. The body starts:

```python
    prop = code_prop(stash, codedb, scene)
    if prop:
        return prop
    f = scene["files"][0]
    ...  # existing body unchanged
```

In `format_line`, replace the `src = ...` line and the `body = (...)` for scrape with:

```python
        src = prop.get("source") or "+".join(
            sorted({s["endpoint"].split("/")[2].split(".")[-2] for s in prop["stash_ids"]}))
        conf = f" conf={prop['confidence']:.2f}" if prop["confidence"] is not None else ""
        perf = ", ".join(x["name"] for x in p.get("performers") or [])
        delta = f"Δ{prop['delta']:+d}s" if prop["delta"] is not None else "Δ?"
        body = (f"{src} ({prop['rule']}{conf}) | {p.get('title')!r} | {match.studio_name(p)} | "
                f"{perf or '-'} | {delta}")
```

Wire the client. Replace `clients()` with:

```python
def clients():
    stash = Stash(os.environ.get("STASH_URL", "http://localhost:9999/graphql"),
                  os.environ.get("STASH_API_KEY"))
    llm = OpenRouter(openrouter_key(),
                     os.environ.get("PARSE_MODEL", "~deepseek/deepseek-flash-latest"),
                     os.environ.get("JEV_MODEL", "typesafe/jev-1.13"))
    state = State(os.environ.get("STATE_FILE", "/var/lib/stash-identify/attempted.json"))
    key = stash.codedb_api_key()
    if not key:
        log("no code-database key in Stash's stash-box config; code lookup uses StashDB only")
    return stash, llm, state, CodeDb(key) if key else None
```

Change `watch(stash, llm, state)` to `watch(stash, llm, state, codedb)`, and its `safe_pass` call to `run_pass(stash, llm, state, stash.defaults(), paths, codedb=codedb)`. In `main()`, unpack `stash, llm, state, codedb = clients()`, pass `codedb=codedb` to the manual `run_pass(...)` call, and call `watch(stash, llm, state, codedb)`.

Give `run_pass` a `codedb=None` keyword parameter (after `scene_ids=None`) and pass it through: `prop = identify_scene(stash, llm, scene, codedb)`. (Task 4 reworks this loop further.)

In `default.nix`, extend the header comment's first paragraph with: `Coded files are looked up by product code first (StashDB, then the code database's product-code API).` Under the `# Design:` line, add `# Codes: docs/superpowers/specs/2026-09-28-stash-identify-code-design.md`.

- [ ] **Step 4: Run all the tests to verify they pass.**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest -v`
Expected: all pass, including every pre-existing `IdentifyTest` and `PassTest`.

- [ ] **Step 5: Commit.**

```bash
git add hosts/galactica/services/stash-identify/{main.py,default.nix,test_main.py}
git commit -m "feat(galactica): stash-identify looks up coded files by product code"
```

---

### Task 4: Upgrade `llm-identified` coded scenes in `run_pass`

**Files:**
- Modify: `hosts/galactica/services/stash-identify/main.py`
- Test: `hosts/galactica/services/stash-identify/test_main.py`

**Interfaces:**
- Consumes: `main.code_prop`, `Stash.scenes_with_tag`, `Stash.tag_id(name, create=False)`, and `match.scrape_update(..., overwrite=)`.
- Produces:
  - `main.is_upgrade(scene, llm_tag_id) -> bool`.
  - `main.apply(stash, scene, prop, skip_tag_ids, overwrite=False)`.

- [ ] **Step 1: Write the failing tests.** In `test_main.py`, add to `FakeStash.__init__` a line `self.tagged = []` (the scenes returned by `scenes_with_tag`) and add the method:

```python
    def scenes_with_tag(self, tag_id):
        return self.tagged
```

Add to `PassTest`:

```python
    def guessed(self, id="20", path="/media/Vault/ABCD-910.mp4", tags=("t-llm-identified",)):
        return scene(id, path=path, duration=7519.0, title="Studio A* – ABCD-910",
                     studio={"id": "s9"}, performers=[{"id": "p9"}],
                     tags=[{"id": t} for t in tags])

    def upgrade_stash(self, stale, fresh=None):
        st = self.PassStash([], scenes_dict={stale["id"]: fresh or stale})
        st.tags = {"llm-identified": "t-llm-identified"}
        st.tagged = [stale]
        return st

    def test_llm_guess_with_product_code_is_upgraded(self):
        st = self.upgrade_stash(self.guessed())
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            state.add("20")  # done long ago; upgrades ignore the state file
            main.run_pass(st, NO_LLM, state, self.defaults, None, jobs=False,
                          codedb=FakeCodeDb([code_hit("ABCD-910")]))
        up = st.updates[0]
        self.assertEqual(up["title"], "ABCD-910 - Some Title")
        self.assertEqual(up["studio_id"], "s-Studio A")
        self.assertEqual(up["performer_ids"], ["p-Performer A"])
        self.assertEqual(up["tag_ids"], [])  # llm-identified dropped

    def test_upgrade_miss_writes_nothing_and_leaves_state(self):
        st = self.upgrade_stash(self.guessed())
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.json")
            main.run_pass(st, NO_LLM, main.State(path), self.defaults, None, jobs=False,
                          codedb=FakeCodeDb([]))
            state = main.State(path)
            self.assertEqual((st.updates, st.created), ([], []))
            self.assertNotIn("20", state)
            self.assertEqual(state.failures, {})

    def test_llm_guess_without_code_is_not_revisited(self):
        tp = FakeCodeDb([code_hit("ABCD-910")])
        st = self.upgrade_stash(self.guessed(path="/media/Vault/Some Title.mp4"))
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, NO_LLM, self.state(d), self.defaults, None, jobs=False, codedb=tp)
        self.assertEqual((st.updates, tp.calls), ([], []))

    def test_upgrade_skipped_once_tag_removed_meanwhile(self):
        st = self.upgrade_stash(self.guessed(), fresh=self.guessed(tags=()))
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, NO_LLM, self.state(d), self.defaults, None, jobs=False,
                          codedb=FakeCodeDb([code_hit("ABCD-910")]))
        self.assertEqual(st.updates, [])

    def test_explicit_scene_run_upgrades_too(self):
        st = self.upgrade_stash(self.guessed())
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, NO_LLM, self.state(d), self.defaults, None, jobs=False,
                          scene_ids=["20"], codedb=FakeCodeDb([code_hit("ABCD-910")]))
        self.assertEqual(st.updates[0]["title"], "ABCD-910 - Some Title")
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest test_main.PassTest -v`
Expected: `test_llm_guess_with_product_code_is_upgraded` and `test_explicit_scene_run_upgrades_too` fail (no update, or the update keeps the guessed title). The others may pass by accident. That's fine, since they guard the implementation.

- [ ] **Step 3: Implement it in `main.py`.** Change `apply`'s signature and scrape branch:

```python
def apply(stash, scene, prop, skip_tag_ids, overwrite=False):
    if prop["kind"] == "scrape":
        ...  # unchanged down to the update call, which becomes:
        stash.update_scene(match.scrape_update(scene, p, prop["stash_ids"], studio_id,
                                               performer_ids, tag_ids, skip_tag_ids,
                                               overwrite=overwrite))
```

Add above `skip_tags`:

```python
def is_upgrade(scene, llm_tag_id):
    """An earlier LLM guess on a file named by a product code: re-checked every pass (lookup
    only, never the LLM) and overwritten once the code is found. Removing the tag in the
    UI opts a scene out."""
    tags = {t["id"] for t in scene.get("tags") or []}
    return bool(llm_tag_id) and llm_tag_id in tags and \
        match.product_code(rel_path(scene["files"][0]["path"])) is not None
```

In `run_pass`, replace the `todo = ...` statement with:

```python
    llm_tag = stash.tag_id(LLM_TAG)
    if scene_ids:
        todo = stash.scenes(scene_ids)
    else:
        todo = [s for s in stash.bare_scenes() if s["id"] not in state]
        if llm_tag:
            todo += [s for s in stash.scenes_with_tag(llm_tag) if is_upgrade(s, llm_tag)]
```

Then replace the body of the `for scene in todo:` loop's `try:` block with:

```python
        upgrade = is_upgrade(scene, llm_tag)
        try:
            if upgrade:
                prop = code_prop(stash, codedb, scene)
                if prop is None:
                    log(f"[{scene['id']}] llm guess, no code match yet")
                    continue
            else:
                prop = identify_scene(stash, llm, scene, codedb)
            print(format_line(scene, prop), flush=True)
            if dry_run:
                continue
            # Re-fetch: the LLM step can take minutes, so re-check against a fresh copy
            # right before writing, in case the scene was edited (or identified) by hand
            # -- or deleted outright -- in the meantime. An explicit --scene run means it
            # should apply regardless of an edit, but a deletion is never applicable. An
            # upgrade counts as untouched for as long as it keeps the llm-identified tag.
            fresh = stash.scenes([scene["id"]])
            if not fresh:
                log(f"[{scene['id']}] gone, skipped")
                state.clear_failures(scene["id"])
                continue
            fresh = fresh[0]
            edited = (not is_upgrade(fresh, llm_tag)) if upgrade else \
                (fresh.get("title") or fresh.get("studio") or fresh.get("performers"))
            if scene_ids is None and edited:
                log(f"[{scene['id']}] edited meanwhile, skipped")
                state.add(scene["id"])
                state.clear_failures(scene["id"])
                continue
            apply(stash, fresh, prop, drop | {llm_tag} if upgrade else drop, overwrite=upgrade)
            state.add(scene["id"])
            state.clear_failures(scene["id"])
```

Leave the `except Exception as e:` block exactly as it is. `drop | {llm_tag} if upgrade else drop` parses as `(drop | {llm_tag}) if upgrade else drop`, which is intended.

- [ ] **Step 4: Run all the tests to verify they pass.**

Run: `cd hosts/galactica/services/stash-identify && python3 -m unittest -v`
Expected: all pass, including the pre-existing `test_edited_meanwhile_not_applied`, `test_apply_uses_freshly_refetched_scene` and `test_explicit_scene_run_applies_even_if_edited_meanwhile`.

- [ ] **Step 5: Commit.**

```bash
git add hosts/galactica/services/stash-identify/{main.py,test_main.py}
git commit -m "feat(galactica): stash-identify upgrades llm-guessed coded scenes by code"
```

---

### Task 5: Live verification and deploy

**Files:** none changed.

- [ ] **Step 1: Build galactica.**

Run: `just build galactica`
Expected: the build succeeds. If it reports `No such file` for `codedb.py`, it wasn't `git add`ed.

- [ ] **Step 2: Dry-run the new code on galactica against the five guessed scenes, before deploying.**

```bash
rsync -a --exclude __pycache__ hosts/galactica/services/stash-identify/ galactica.bat-boa.ts.net:/tmp/si/
ssh galactica.bat-boa.ts.net 'cd /tmp/si && sudo -u media env OPENROUTER_API_KEY_FILE=/run/secrets/openrouter-api-key STATE_FILE=/tmp/si-state/attempted.json python3 main.py run --dry-run --scene 10068 --scene 12227 --scene 12877 --scene 12938 --scene 12941'
```

Expected: five lines of the form `codedb (code) | 'ABCD-910 - …' | Studio A | Performer A, Performer B | Δ+281s`, and no `llm-only` lines. Note that `--scene` goes through `is_upgrade`, since these scenes carry the tag.

- [ ] **Step 3: Deploy.** Run `just deploy galactica` (from raider). The service restarts, and its startup sweep runs the upgrade.

- [ ] **Step 4: Confirm the upgrade landed.**

```bash
ssh galactica.bat-boa.ts.net 'journalctl -u stash-identify --since "15 min ago" --no-pager | grep -E "codedb|stashdb \(code\)|no code match|failed"'
```

Expected: `codedb (code)` lines for scenes 10068, 12227, 12877, 12938 and 12941. Then query one scene:

```bash
ssh galactica.bat-boa.ts.net 'curl -s localhost:9999/graphql -H "Content-Type: application/json" -d "{\"query\":\"{ findScene(id: 10068) { title code studio { name } performers { name } tags { name } } }\"}"'
```

Expected: the title starts `ABCD-910 - `, the code is `ABCD-910`, the studio is `Studio A`, the performers are non-empty, and there's no `llm-identified` tag.

- [ ] **Step 5: Clean up** with `ssh galactica.bat-boa.ts.net 'rm -rf /tmp/si /tmp/si-state /tmp/probe*.py'`.
