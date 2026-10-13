# plab Curated Filters & Targeted Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement automated tracker discovery for indie and couples releases (such as Lustery, Joybear, Erika Lust, X-Art) across a 30-day window, merge and tag them in plab's atomic cache, and add an "Indie & Couples" filter toggle with visual badges to the UI.

**Architecture:** Python 3 standard library only. Configurable search terms loaded from disk/env/defaults; `Lab.search()` queries `tracker.php` with `nm` and `tm=30` parameters; `refresh()` runs baseline + targeted searches, deduplicating and tagging curated releases; `page.py` renders the "Indie & Couples" filter toggle and badges; `assets.py` filters cards and syncs state via URL hash.

**Tech Stack:** Python 3 (stdlib: `urllib`, `html`, `re`, `json`, `unittest`), DaisyUI, Tailwind CSS, NixOS.

**Spec:** [docs/superpowers/specs/2026-10-12-plab-curated-filters-design.md](file:///home/arosenfeld/Code/nixos/docs/superpowers/specs/2026-10-12-plab-curated-filters-design.md)

## Global Constraints

- Plain-stdlib Python run with `pkgs.python3`; no pip dependencies.
- Politeness: 1.0 second delay (`DELAY`) between tracker requests.
- Fail-fast authentication errors (`LoginError`) abort refresh without corrupting cache. Non-auth search query errors log warnings and proceed.
- Exact styling with existing DaisyUI classes and Tailwind runtime.

---

### Task 1: Search Queries Loader & Default Terms

**Files:**
- Modify: `hosts/galactica/services/plab/main.py:59-88`
- Test: `hosts/galactica/services/plab/test_main.py`

**Interfaces:**
- Produces: `DEFAULT_SEARCHES: list[str]`, `load_searches(path=None, state_dir=None) -> list[str]`

- [ ] **Step 1: Write the failing tests in `test_main.py`**

Add `SearchesTest` class to `hosts/galactica/services/plab/test_main.py`:

```python
class SearchesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def test_load_searches_fallback_to_defaults(self):
        terms = main.load_searches("/nonexistent/file", state_dir=self.dir.name)
        self.assertIn("Lustery", terms)
        self.assertIn("Joybear", terms)
        self.assertIn("X-Art", terms)
        self.assertIn("real couple", terms)

    def test_load_searches_from_file_strips_comments_and_whitespace(self):
        path = os.path.join(self.dir.name, "searches.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("# comment\n\n  Lustery  \n# another comment\n\"real couple\"\n")
        terms = main.load_searches(path)
        self.assertEqual(terms, ["Lustery", "\"real couple\""])

    def test_load_searches_from_state_dir(self):
        path = os.path.join(self.dir.name, "searches.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("FrolicMe\n")
        terms = main.load_searches(state_dir=self.dir.name)
        self.assertEqual(terms, ["FrolicMe"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_main.SearchesTest -v`
Expected: FAIL with `AttributeError: module 'main' has no attribute 'load_searches'`

- [ ] **Step 3: Implement `DEFAULT_SEARCHES` and `load_searches` in `main.py`**

In `hosts/galactica/services/plab/main.py`:

```python
DEFAULT_SEARCHES = [
    "Lustery",
    "Joybear",
    "Erika Lust",
    "XConfessions",
    "Lust Cinema",
    "FrolicMe",
    "Sssh",
    "X-Art",
    "Colette",
    "Viv Thomas",
    "Bellesa",
    "MetArt",
    "real couple",
    "amateur couple",
    "romantic",
    "sensual",
]


def load_searches(path=None, state_dir=None):
    """Load search queries from file.

    Checks `path` (or PLAB_SEARCHES_FILE), falling back to `searches.txt` in `state_dir`.
    If neither exists, returns DEFAULT_SEARCHES.
    """
    if path is None:
        path = os.environ.get("PLAB_SEARCHES_FILE")
    if not path and state_dir:
        candidate = os.path.join(state_dir, "searches.txt")
        if os.path.isfile(candidate):
            path = candidate
    if not path or not os.path.isfile(path):
        return list(DEFAULT_SEARCHES)
    terms = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                terms.append(line)
    return terms if terms else list(DEFAULT_SEARCHES)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_main.SearchesTest -v`
Expected: PASS (all 3 tests pass)

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/main.py hosts/galactica/services/plab/test_main.py
git commit -m "feat(galactica): plab search queries loader and defaults"
```

---

### Task 2: Tracker Client Search Method (`lab.search`)

**Files:**
- Modify: `hosts/galactica/services/plab/lab.py:110-131`
- Test: `hosts/galactica/services/plab/test_lab.py`

**Interfaces:**
- Produces: `Lab.search(self, query: str, forums: tuple[int, ...], days: int = 30, limit: int = 20, predicate = None) -> list[dict]`

- [ ] **Step 1: Write the failing tests in `test_lab.py`**

In `hosts/galactica/services/plab/test_lab.py`, add `test_search_encodes_params_and_filters`:

```python
    def test_search_encodes_params_and_filters(self):
        lab, opener = self.lab(fixture("tracker.html"))
        pred = lambda r: r["id"] != 3314001
        rows = lab.search("Lustery", [1875, 1818], days=30, limit=10, predicate=pred)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], 3313754)
        call_url = opener.calls[0].full_url
        self.assertIn("f%5B%5D=1875", call_url)
        self.assertIn("f%5B%5D=1818", call_url)
        self.assertIn("nm=Lustery", call_url)
        self.assertIn("tm=30", call_url)
        self.assertIn("o=10", call_url)
        self.assertIn("s=2", call_url)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_lab.LabTest.test_search_encodes_params_and_filters -v`
Expected: FAIL with `AttributeError: 'Lab' object has no attribute 'search'`

- [ ] **Step 3: Implement `Lab.search` in `lab.py`**

In `hosts/galactica/services/plab/lab.py`, add method to class `Lab`:

```python
    def search(self, query, forums, days=30, limit=20, predicate=None):
        """Search releases matching `query` within `forums` uploaded in the last `days` days."""
        params = [("f[]", f) for f in forums] + [
            ("nm", query),
            ("o", 10),
            ("s", 2),
            ("tm", days),
        ]
        url = "tracker.php?" + urllib.parse.urlencode(params)
        page = self.page(url)
        rows = parse.rows(page)
        if predicate:
            rows = [r for r in rows if predicate(r)]
        start = 50
        while len(rows) < limit:
            link = parse.page_link(page, start)
            if not link:
                break
            page = self.page(link)
            more = parse.rows(page)
            if predicate:
                more = [r for r in more if predicate(r)]
            rows += more
            start += 50
        return rows[:limit]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_lab.LabTest.test_search_encodes_params_and_filters -v`
Expected: PASS

- [ ] **Step 5: Run full `test_lab.py` suite**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_lab -v`
Expected: PASS (all tests pass)

- [ ] **Step 6: Commit**

```bash
git add hosts/galactica/services/plab/lab.py hosts/galactica/services/plab/test_lab.py
git commit -m "feat(galactica): plab search tracker query support"
```

---

### Task 3: Curated Recognition in `labels.py`

**Files:**
- Modify: `hosts/galactica/services/plab/labels.py`
- Test: `hosts/galactica/services/plab/test_labels.py`

**Interfaces:**
- Produces: `is_curated(title: str, studio: str | None = None, tags: list[str] | None = None) -> bool`

- [ ] **Step 1: Write the failing tests in `test_labels.py`**

In `hosts/galactica/services/plab/test_labels.py`, add `test_is_curated`:

```python
    def test_is_curated_by_studio(self):
        from labels import is_curated
        self.assertTrue(is_curated("[Lustery.com] Couple Fun [1080p]", studio="Lustery.com"))
        self.assertTrue(is_curated("[Joybear.com] Movie [1080p]", studio="Joybear.com"))
        self.assertTrue(is_curated("[X-Art.com] Romance [1080p]", studio="X-Art.com"))
        self.assertFalse(is_curated("[Brazzers.com] Scene [1080p]", studio="Brazzers.com"))

    def test_is_curated_by_tags(self):
        from labels import is_curated
        self.assertTrue(is_curated("Title", tags=["anal", "real couple"]))
        self.assertTrue(is_curated("Title", tags=["sensual", "brunette"]))
        self.assertFalse(is_curated("Title", tags=["anal", "blowjob"]))

    def test_is_curated_by_title_text(self):
        from labels import is_curated
        self.assertTrue(is_curated("Lustery: Alice & Bob at home"))
        self.assertTrue(is_curated("Erika Lust - The Cab Ride [1080p]"))
        self.assertFalse(is_curated("Random Big Release [1080p]"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_labels.Labels.test_is_curated_by_studio -v`
Expected: FAIL with `ImportError: cannot import name 'is_curated' from 'labels'`

- [ ] **Step 3: Implement `is_curated` in `labels.py`**

In `hosts/galactica/services/plab/labels.py`:

```python
CURATED_STUDIO_PREFIXES = (
    "lustery",
    "joybear",
    "erika lust",
    "erikalust",
    "xconfessions",
    "lust cinema",
    "lustcinema",
    "frolicme",
    "sssh",
    "x-art",
    "xart",
    "colette",
    "viv thomas",
    "vivthomas",
    "bellesa",
    "metart",
)

CURATED_KEYWORDS = (
    "real couple",
    "amateur couple",
    "romantic",
    "sensual",
    "homemade couple",
)


def is_curated(title, studio=None, tags=None):
    """True if release matches indie/romantic couples studios, tags or title keywords."""
    if studio:
        s = studio.lower()
        if any(prefix in s for prefix in CURATED_STUDIO_PREFIXES):
            return True
    if tags:
        for t in tags:
            tl = t.lower()
            if any(k in tl for k in CURATED_KEYWORDS):
                return True
    tl = title.lower()
    if any(prefix in tl for prefix in CURATED_STUDIO_PREFIXES):
        return True
    if any(k in tl for k in CURATED_KEYWORDS):
        return True
    return False
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_labels -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/labels.py hosts/galactica/services/plab/test_labels.py
git commit -m "feat(galactica): plab curated studio and tag recognition"
```

---

### Task 4: Refresh Pipeline Integration (Targeted Searches & Cache Tagging)

**Files:**
- Modify: `hosts/galactica/services/plab/main.py:89-160, 270-310`
- Test: `hosts/galactica/services/plab/test_main.py`

**Interfaces:**
- Consumes: `load_searches` (from Task 1), `Lab.search` (from Task 2), `is_curated` (from Task 3)
- Produces: `refresh(..., searches_file=None)` populating `curated` on topics in `cache.json`

- [ ] **Step 1: Write failing test in `test_main.py`**

Add `test_refresh_merges_and_tags_curated_searches` in `hosts/galactica/services/plab/test_main.py`:

```python
    def test_refresh_merges_and_tags_curated_searches(self):
        searches_path = os.path.join(self.dir.name, "searches.txt")
        with open(searches_path, "w", encoding="utf-8") as f:
            f.write("Lustery\n")

        lab = FakeLab([row(1, "Mainstream Top 100")])
        lab.searched_rows = {"Lustery": [row(2, "Lustery Release"), row(1, "Mainstream Top 100")]}

        main.refresh(lab, self.store, searches_file=searches_path, sleep=lambda _: None)
        cached = self.store.cache()["topics"]
        self.assertEqual([t["id"] for t in cached], [1, 2])
        t1 = next(t for t in cached if t["id"] == 1)
        t2 = next(t for t in cached if t["id"] == 2)
        self.assertTrue(t1.get("curated"))  # present in targeted search
        self.assertTrue(t2.get("curated"))
```

Also update `FakeLab` in `test_main.py` to add `search`:

```python
    def search(self, query, forums, days=30, limit=20, predicate=None):
        rows = getattr(self, "searched_rows", {}).get(query, [])
        if predicate:
            rows = [r for r in rows if predicate(r)]
        return rows
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_main.ExcludeTest.test_refresh_merges_and_tags_curated_searches -v`
Expected: FAIL with `TypeError: refresh() got an unexpected keyword argument 'searches_file'`

- [ ] **Step 3: Update `refresh()` and CLI wiring in `main.py`**

In `hosts/galactica/services/plab/main.py`:

1. Update `refresh`:
```python
def refresh(lab, store, forums=FORUMS, days=DAYS, limit=LIMIT, sleep=time.sleep,
            exclude_file=None, searches_file=None):
    """Rebuild cache.json. Raises, leaving the old cache in place, if the list fails."""
    patterns = load_excludes(exclude_file, state_dir=store.root)
    pred = exclude_predicate(patterns)
    rows = lab.top(forums, days, limit, predicate=pred)
    if not rows:
        raise RuntimeError("tracker returned no rows")

    # Run targeted curated searches
    search_terms = load_searches(searches_file, state_dir=store.root)
    curated_ids = set()
    extra_rows = []
    for term in search_terms:
        sleep(DELAY)
        try:
            results = lab.search(term, forums, days=30, limit=20, predicate=pred)
            for r in results:
                curated_ids.add(r["id"])
                extra_rows.append(r)
        except LoginError:
            raise
        except Exception as err:
            log(f"search failed for {term!r}: {err}")

    # Combine & deduplicate rows by id
    seen = set()
    combined = []
    for r in rows + extra_rows:
        if r["id"] not in seen:
            seen.add(r["id"])
            combined.append(r)

    previous = {t["id"]: t for t in store.cache()["topics"]}
    fetch = _image_fetcher(lab)
    topics = []
    from labels import is_curated, labels
    for row in combined:
        images = previous.get(row["id"], {}).get("images") or []
        if not images:
            try:
                images = parse.images(lab.topic(row["id"]))
            except LoginError:
                raise
            except Exception as err:
                log(f"topic {row['id']} failed: {err}")
            sleep(DELAY)
        for img in images[:1]:
            try:
                store.save_image(img, fetch)
            except Exception as err:
                log(f"image {img} failed: {err}")
        lab_info = labels(row["title"], row["forum"])
        is_cur = row["id"] in curated_ids or is_curated(row["title"], lab_info["studio"], lab_info["tags"])
        topics.append(dict(row, images=images, curated=is_cur))

    store.save_cache(topics)
    log(f"refreshed: {len(topics)} topics ({len([t for t in topics if t.get('curated')])} curated)")
```

2. Update `run_refresh` and `main` entrypoint:
```python
def run_refresh(lab, store, transmission_url, download_dir, exclude_file=None, searches_file=None):
    drain(lab, store, transmission_url, download_dir)
    refresh(lab, store, exclude_file=exclude_file, searches_file=searches_file)
```
Pass `os.environ.get("PLAB_SEARCHES_FILE")` in `args.cmd == "refresh"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_main -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/main.py hosts/galactica/services/plab/test_main.py
git commit -m "feat(galactica): plab refresh executes targeted searches and marks curated topics"
```

---

### Task 5: Web UI Card Badge, Header Count & Filter Bar Toggle

**Files:**
- Modify: `hosts/galactica/services/plab/page.py`
- Modify: `hosts/galactica/services/plab/assets.py`
- Test: `hosts/galactica/services/plab/test_page.py`

**Interfaces:**
- Produces: `_card` with `data-curated="1"` and `Couples` badge; `_filter_bar` with `data-toggle="couples"`; `FILTER_JS` filtering `!st.couples || d.curated === '1'`

- [ ] **Step 1: Write failing tests in `test_page.py`**

In `hosts/galactica/services/plab/test_page.py`:

```python
    def test_card_renders_curated_attribute_and_badge(self):
        t = {"id": 1, "title": "Test Title", "forum": 1875, "size": 100, "seeders": 1,
             "leechers": 0, "completed": 0, "added": 0, "images": [], "curated": True}
        lab = {"tags": [], "quality": None, "studio": None, "category": "Clips"}
        html = page._card(t, lab, set(), set(), 1000)
        self.assertIn('data-curated="1"', html)
        self.assertIn('>Couples</span>', html)

    def test_filter_bar_has_couples_toggle(self):
        labs = [{"tags": [], "quality": None, "studio": None, "category": "Clips"}]
        html = page._filter_bar(labs)
        self.assertIn('data-toggle="couples">Indie & Couples</button>', html)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_page.Card.test_card_renders_curated_attribute_and_badge test_page.Card.test_filter_bar_has_couples_toggle -v`
Expected: FAIL

- [ ] **Step 3: Update `page.py` and `assets.py`**

1. In `hosts/galactica/services/plab/page.py`:
- In `_card(t, lab, added, queued, now)`:
```python
    from labels import is_curated
    curated = bool(t.get("curated") or is_curated(t["title"], lab["studio"], lab["tags"]))
    curated_badge = '<span class="badge badge-secondary font-bold absolute bottom-2 left-2 z-[1]">Couples</span>' if curated else ''
```
Place `{curated_badge}` inside `<figure>`:
```python
    f'<figure class="relative aspect-[16/10] bg-black">{badge}{curated_badge}{thumb}</figure>'
```
Add to `data`:
```python
    "curated": "1" if curated else "",
```
- In `_filter_bar`:
Add `("couples", "Indie & Couples")` to `toggles`:
```python
    toggles = "".join(f'<button type="button" class="btn btn-sm" data-toggle="{k}">{name}</button>'
                      for k, name in (("h24", "Last 24h"), ("new", "New only"),
                                      ("couples", "Indie & Couples"), ("hide", "Hide added/queued")))
```
- In `render`:
Update header subtitle:
```python
    curated_n = sum(1 for t, lab in zip(topics, labs) if t.get("curated") or is_curated(t["title"], lab["studio"], lab["tags"]))
    curated_sub = f" · {curated_n} curated" if curated_n else ""
```
Include `{curated_sub}` in subtitle.

2. In `hosts/galactica/services/plab/assets.py`:
- In `FILTER_JS`:
```javascript
  const TOGGLES = ['h24', 'new', 'hide', 'couples'];
```
- In card match condition:
```javascript
      const ok = (!st.h24 || d.fresh === '1')
        && (!st.new || c.classList.contains('is-new'))
        && (!st.hide || !d.state)
        && (!st.couples || d.curated === '1')
        && (!st.cat || d.category === st.cat)
        && (!st.q || d.quality === st.q)
        && (!st.studio || d.studio === st.studio)
        && st.tags.every(t => tags.includes(t));
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd hosts/galactica/services/plab && python3 -m unittest test_page -v`
Expected: PASS

- [ ] **Step 5: Run all unit tests**

Run: `cd hosts/galactica/services/plab && python3 -m unittest -v`
Expected: PASS (all tests pass)

- [ ] **Step 6: Commit**

```bash
git add hosts/galactica/services/plab/page.py hosts/galactica/services/plab/assets.py hosts/galactica/services/plab/test_page.py
git commit -m "feat(galactica): plab Indie & Couples filter toggle and badges"
```

---

### Task 6: NixOS Integration & System Verification

**Files:**
- Modify: `hosts/galactica/services/plab/default.nix:60-63`

**Interfaces:**
- Produces: `PLAB_SEARCHES_FILE` exported in wrapper script

- [ ] **Step 1: Update `default.nix`**

In `hosts/galactica/services/plab/default.nix`, add after line 60:
```nix
      export PLAB_SEARCHES_FILE="''${PLAB_SEARCHES_FILE:-${if secrets ? plab-searches then secrets.plab-searches.path else ""}}"
```

- [ ] **Step 2: Verify NixOS evaluation**

Run: `nix eval .#nixosConfigurations.galactica.config.systemd.services.plab.serviceConfig.ExecStart`
Expected: Evaluation succeeds without errors.

- [ ] **Step 3: Run complete plab test suite**

Run: `cd hosts/galactica/services/plab && python3 -m unittest -v`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add hosts/galactica/services/plab/default.nix
git commit -m "feat(galactica): plab configure searches file in systemd service"
```
