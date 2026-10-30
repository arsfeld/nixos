# plab live search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A search box on plab that queries the tracker live across all time and shows the results as plab's usual cards, with lazily loaded thumbnails and a working **Add to Vault**.

**Architecture:** `GET /search?q=` runs one tracker search, records the rows in a short-lived `search.json` (separate from `cache.json`), and renders the existing card grid in a "results" mode. Cards with unknown images load `thumb/<id>`, which fetches the topic page on first use (at most two at a time) and 302s to the existing `img/<sha1>` proxy. `add_topic` and `image_for` accept ids and URLs from either store, so the image proxy still serves only URLs plab parsed itself.

**Tech Stack:** stdlib Python 3 (`http.server`, `urllib`, `unittest`), Alpine.js + daisyUI on the page, NixOS module in `default.nix`.

**Spec:** `docs/superpowers/specs/2026-10-30-plab-live-search-design.md`

## Global Constraints

- All code lives in `hosts/galactica/services/plab/`. Plain stdlib Python, no pip dependencies.
- Run tests with `python3 -m unittest -q` from `hosts/galactica/services/plab/`. All 196 existing tests must keep passing after every task.
- Searches run with **no `tm` parameter** (all time), first results page only: `SEARCH_LIMIT = 50`.
- `search.json` entries older than **24 h** (`SEARCH_TTL = 86400`) are dropped on the next search save.
- At most **2** concurrent topic-page fetches from `/thumb` and `/images` (`threading.BoundedSemaphore(2)`).
- No production classification for search results; `cache.json` is never written by a search.
- Commit messages: `feat(galactica): plab …` conventional commits, straight to master, never mention Claude.
- Match the surrounding code's comment density and idiom: short docstrings saying *why*, `# noqa: BLE001 -- reason` on broad excepts.

---

### Task 1: `Lab.search` can search all time

**Files:**
- Modify: `hosts/galactica/services/plab/lab.py` (`Lab.search`)
- Test: `hosts/galactica/services/plab/test_lab.py`

**Interfaces:**
- Produces: `Lab.search(query, forums, days=32, limit=20, predicate=None)`; `days=None` sends no `tm` parameter.

- [ ] **Step 1: Write the failing test**

Add to `LabTest` in `test_lab.py`, after `test_search_encodes_params_and_filters`:

```python
    def test_search_all_time_sends_no_window(self):
        lab, opener = self.lab(fixture("tracker.html"))
        lab.search("Alpha", [1875], days=None, limit=1)
        call_url = opener.calls[0].full_url
        self.assertIn("nm=Alpha", call_url)
        self.assertNotIn("tm=", call_url)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 -m unittest -q test_lab.LabTest.test_search_all_time_sends_no_window`
Expected: FAIL, `'tm=' unexpectedly found in …tm=None…`

- [ ] **Step 3: Implement**

In `lab.py`, replace the params block of `search`:

```python
    def search(self, query, forums, days=32, limit=20, predicate=None):
        """Search releases matching `query` within `forums` uploaded in the last `days` days
        (all time when `days` is None)."""
        params = [("f[]", f) for f in forums] + [("nm", query), ("o", 10), ("s", 2)]
        if days is not None:
            params.append(("tm", days))
        url = "tracker.php?" + urllib.parse.urlencode(params)
```

Leave the rest of the method unchanged.

- [ ] **Step 4: Run all tests**

Run: `python3 -m unittest -q`
Expected: OK (197 tests)

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/lab.py hosts/galactica/services/plab/test_lab.py
git commit -m "feat(galactica): plab tracker search over all time"
```

---

### Task 2: `search.json` in the store

**Files:**
- Modify: `hosts/galactica/services/plab/store.py`
- Test: `hosts/galactica/services/plab/test_store.py`

**Interfaces:**
- Produces:
  - `store.SEARCH_TTL = 86400`
  - `Store.search_topics() -> dict[str, dict]`: keys are topic ids **as strings** (JSON object keys), values are tracker rows plus `"images": list | None` and `"at": float`.
  - `Store.save_search(rows: list[dict], now: float) -> None`
  - `Store.set_search_images(topic_id: int, urls: list[str]) -> None` (no-op for an unknown id)

- [ ] **Step 1: Write the failing tests**

Add to `StoreTest` in `test_store.py`:

```python
    def test_search_empty_default(self):
        self.assertEqual(self.store.search_topics(), {})

    def test_save_search_records_rows_without_images(self):
        self.store.save_search([{"id": 5, "title": "a"}], now=1000)
        self.assertEqual(Store(self.dir.name).search_topics(),
                         {"5": {"id": 5, "title": "a", "images": None, "at": 1000}})

    def test_save_search_keeps_known_images_and_refreshes_at(self):
        self.store.save_search([{"id": 5, "title": "a"}], now=1000)
        self.store.set_search_images(5, ["https://x/1.jpg"])
        self.store.save_search([{"id": 5, "title": "a2"}], now=2000)
        self.assertEqual(self.store.search_topics()["5"],
                         {"id": 5, "title": "a2", "images": ["https://x/1.jpg"], "at": 2000})

    def test_save_search_drops_entries_older_than_a_day(self):
        self.store.save_search([{"id": 5}], now=1000)
        self.store.save_search([{"id": 6}], now=1000 + SEARCH_TTL)
        self.assertEqual(set(self.store.search_topics()), {"5", "6"})  # exactly a day: kept
        self.store.save_search([{"id": 7}], now=1001 + SEARCH_TTL)
        self.assertEqual(set(self.store.search_topics()), {"6", "7"})

    def test_set_search_images_unknown_topic_is_a_no_op(self):
        self.store.set_search_images(9, ["https://x/1.jpg"])
        self.assertEqual(self.store.search_topics(), {})
```

Change the import line at the top to:

```python
from store import SEARCH_TTL, Store, key
```

- [ ] **Step 2: Run them to verify they fail**

Run: `python3 -m unittest -q test_store`
Expected: ERROR, `ImportError: cannot import name 'SEARCH_TTL'`

- [ ] **Step 3: Implement**

In `store.py`, update the module docstring's first line to mention the new file:

```python
"""plab's files under the state dir: cache.json, added.json, queued.json, search.json and
img/<sha1 of url>.
```

Add after `def key(url): …`:

```python
# How long a live search's results stay addable and their images servable.
SEARCH_TTL = 86400
```

In `Store.__init__`, add a lock:

```python
        os.makedirs(self.img, exist_ok=True)
        # search.json is read-modify-write from the server's threads.
        self._search_lock = threading.Lock()
```

Add these methods after `dequeue`:

```python
    def search_topics(self):
        """Live search results by topic id (a string: JSON keys), each a tracker row plus
        "images" (None until the topic page is fetched) and "at" (when last searched)."""
        return self._read_json("search.json", {})

    def _save_search(self, topics):
        _write(os.path.join(self.root, "search.json"), json.dumps(topics).encode())

    def save_search(self, rows, now):
        with self._search_lock:
            topics = self.search_topics()
            for row in rows:
                images = topics.get(str(row["id"]), {}).get("images")
                topics[str(row["id"])] = {**row, "images": images, "at": now}
            self._save_search({k: t for k, t in topics.items() if now - t["at"] <= SEARCH_TTL})

    def set_search_images(self, topic_id, urls):
        with self._search_lock:
            topics = self.search_topics()
            if str(topic_id) in topics:
                topics[str(topic_id)]["images"] = list(urls)
                self._save_search(topics)
```

- [ ] **Step 4: Run all tests**

Run: `python3 -m unittest -q`
Expected: OK

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/store.py hosts/galactica/services/plab/test_store.py
git commit -m "feat(galactica): plab search.json store for live search results"
```

---

### Task 3: search, topic images and the search-aware add/image paths in `main.py`

**Files:**
- Modify: `hosts/galactica/services/plab/main.py`
- Test: `hosts/galactica/services/plab/test_main.py`

**Interfaces:**
- Consumes: `Lab.search(..., days=None, ...)` (Task 1); `Store.search_topics`, `Store.save_search`, `Store.set_search_images` (Task 2).
- Produces:
  - `main.SEARCH_LIMIT = 50`
  - `main.match_filters(filters, title, found=None) -> (list[str], str | None)`: the names of the curated filters `title` belongs to (file order) and the badge of the first. `found` is `{filter name: badge}` already known from searches.
  - `main.run_search(lab, store, query, exclude_file=None, filter_file=None, now=None) -> list[dict]`: the search-store entries for the results in tracker order, each with `"filters"` and `"curated_reason"` added.
  - `main.topic_images(lab, store, topic_id, slots=FETCH_SLOTS) -> list[str]`: image URLs; raises `ValueError` for a topic neither listed nor searched.
  - `add_topic` and `image_for` accept search-only topics/URLs.

- [ ] **Step 1: Write the failing tests**

In `test_main.py`, make `FakeLab` record searches and allow a search failure. Replace its `search` method and add two attributes in `__init__`:

```python
        self.torrents = []
        self.searches = []
        self.search_error = None
```

```python
    def search(self, query, forums, days=32, limit=20, predicate=None):
        self.searches.append((query, days, limit))
        if self.search_error:
            raise self.search_error
        rows = getattr(self, "searched_rows", {}).get(query, [])
        if predicate:
            rows = [r for r in rows if predicate(r)]
        return rows
```

Add a test class after `Routes`:

```python
class Search(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.save_cache([dict(row(1), images=[COVER])])
        self.lab = FakeLab([])
        self.lab.searched_rows = {"alpha": [row(5, "Alpha One"), row(6, "Ripe Cherry")]}

    def tearDown(self):
        self.dir.cleanup()

    def write(self, name, text):
        path = os.path.join(self.dir.name, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def test_run_search_all_time_excludes_and_records(self):
        exclude = self.write("ex.txt", "cherry\n")
        topics = main.run_search(self.lab, self.store, "alpha", exclude_file=exclude, now=1000)
        self.assertEqual([t["id"] for t in topics], [5])
        self.assertEqual(self.lab.searches, [("alpha", None, main.SEARCH_LIMIT)])
        self.assertIsNone(topics[0]["images"])
        self.assertEqual(set(self.store.search_topics()), {"5"})
        self.assertEqual(self.store.cache()["topics"][0]["id"], 1)  # the weekly list is untouched

    def test_run_search_marks_curated_by_title(self):
        filters = self.write("f.txt", "[Fav]\nalpha\n[Other]\nzulu\n")
        topics = main.run_search(self.lab, self.store, "alpha", filter_file=filters, now=1000)
        self.assertEqual(topics[0]["filters"], ["Fav"])
        self.assertEqual(topics[0]["curated_reason"], "Alpha")
        self.assertEqual(topics[1]["filters"], [])

    def test_match_filters_prefers_found_badges(self):
        filters = [("A", ["alpha"]), ("B", ["one"])]
        self.assertEqual(main.match_filters(filters, "Alpha One", {"B": "Searched"}), (["A", "B"], "Alpha"))
        self.assertEqual(main.match_filters(filters, "nothing"), ([], None))

    def test_topic_images_fetches_a_searched_topic_once(self):
        main.run_search(self.lab, self.store, "alpha", now=1000)
        self.assertEqual(main.topic_images(self.lab, self.store, 5)[0], COVER)
        self.assertEqual(main.topic_images(self.lab, self.store, 5)[0], COVER)
        self.assertEqual(self.lab.topics_fetched, [5])
        self.assertEqual(self.store.search_topics()["5"]["images"][0], COVER)

    def test_topic_images_of_a_listed_topic_needs_no_fetch(self):
        self.assertEqual(main.topic_images(self.lab, self.store, 1), [COVER])
        self.assertEqual(self.lab.topics_fetched, [])

    def test_topic_images_unknown_topic_rejected(self):
        with self.assertRaises(ValueError):
            main.topic_images(self.lab, self.store, 99)
        self.assertEqual(self.lab.topics_fetched, [])

    def test_add_accepts_a_searched_topic(self):
        main.run_search(self.lab, self.store, "alpha", now=1000)
        result = main.add_topic(self.lab, self.store, 5, "http://rpc", "/vault", add=lambda *a: "Release")
        self.assertEqual(result, {"name": "Release"})
        self.assertEqual(self.store.added(), {5})

    def test_image_for_accepts_a_searched_topics_image(self):
        main.run_search(self.lab, self.store, "alpha", now=1000)
        self.store.set_search_images(5, ["https://s/only.jpg"])
        data, ctype = main.image_for(self.lab, self.store, key("https://s/only.jpg"))
        self.assertEqual((data, ctype), (JPEG, "image/jpeg"))

    def test_refresh_keeps_images_of_searched_topics(self):
        main.run_search(self.lab, self.store, "alpha", now=1000)
        self.store.set_search_images(5, ["https://s/only.jpg"])
        path = self.store.ensure_image("https://s/only.jpg", lambda url: JPEG)
        main.refresh(FakeLab([row(1)]), self.store, sleep=lambda s: None)
        self.assertTrue(os.path.exists(path))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `python3 -m unittest -q test_main.Search`
Expected: ERROR, `AttributeError: module 'main' has no attribute 'run_search'` (and `match_filters`, `topic_images`, `SEARCH_LIMIT`)

- [ ] **Step 3: Implement**

In `main.py`, add the constants after `CLASSIFY_FAILURE_LIMIT`:

```python
# One results page per live search: a single tracker request.
SEARCH_LIMIT = 50
# Topic pages fetched at once for search thumbnails; one results page must not burst the tracker.
FETCH_SLOTS = threading.BoundedSemaphore(2)
```

Add `match_filters` just above `refresh`:

```python
def match_filters(filters, title, found=None):
    """The curated filters a release belongs to, in file order, and the badge of the first.

    `found` holds {filter name: badge} for filters whose search returned it; any other
    filter claims it when the title names one of its terms."""
    matched = dict(found or {})
    for name, terms in filters:
        term = name not in matched and next((t for t in terms if match_term(t, title)), None)
        if term:
            matched[name] = term_label(term)
    names = [name for name, _ in filters if name in matched]
    return names, matched[names[0]] if names else None
```

In `refresh`, replace the block from `# A top-list release whose title names a term belongs to that filter too.` through the `topic = {...}` line with:

```python
        # A top-list release whose title names a term belongs to that filter too.
        names, reason = match_filters(filters, row["title"], found.get(row["id"]))
        topic = {**row, "images": images, "filters": names, "curated_reason": reason}
```

Add a helper above `add_topic`:

```python
def _listed(store, topic_id):
    """A topic of the weekly list or of a recent live search, or None."""
    for t in store.cache()["topics"]:
        if t["id"] == topic_id:
            return t
    return store.search_topics().get(str(topic_id))


def _image_urls(store):
    """Every image URL plab may serve: the weekly list's and the recent searches'."""
    topics = store.cache()["topics"] + list(store.search_topics().values())
    return (u for t in topics for u in t.get("images") or [])
```

In `refresh`, replace `store.prune_images(u for t in topics for u in t["images"])` with:

```python
    store.prune_images(_image_urls(store))  # after save_cache: the new list, plus searches
```

In `add_topic`, replace the list check:

```python
    if _listed(store, topic_id) is None:
        raise ValueError(f"topic {topic_id} is not on the list")
```

In `image_for`, replace the `urls = …` line:

```python
    urls = {key(u): u for u in _image_urls(store)}
```

and update its docstring's second line to: `Only URLs of listed or searched topics resolve, so this is not an open proxy.`

Add after `image_for`:

```python
def run_search(lab, store, query, exclude_file=None, filter_file=None, now=None):
    """A live tracker search over all time, recorded in search.json; the entries in tracker
    order, with their curated filters. Never touches cache.json."""
    pred = exclude_predicate(load_excludes(exclude_file, state_dir=store.root))
    rows = lab.search(query, FORUMS, days=None, limit=SEARCH_LIMIT, predicate=pred)
    store.save_search(rows, time.time() if now is None else now)
    known = store.search_topics()
    filters = load_filters(filter_file, state_dir=store.root)
    topics = []
    for r in rows:
        names, reason = match_filters(filters, r["title"])
        topics.append({**known[str(r["id"])], "filters": names, "curated_reason": reason})
    return topics


def topic_images(lab, store, topic_id, slots=FETCH_SLOTS):
    """The image URLs of a listed or searched topic, fetching a searched one's on first use."""
    topic = _listed(store, topic_id)
    if topic is None:
        raise ValueError(f"topic {topic_id} is not on the list")
    if topic.get("images") is not None:
        return topic["images"]
    with slots:
        # Another request may have fetched them while this one waited.
        images = (_listed(store, topic_id) or {}).get("images")
        if images is None:
            images = parse.images(lab.topic(topic_id))
            store.set_search_images(topic_id, images)
    return images
```

- [ ] **Step 4: Run all tests**

Run: `python3 -m unittest -q`
Expected: OK (the existing `Refresh` curated-filter tests prove the `match_filters` refactor kept behaviour)

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/main.py hosts/galactica/services/plab/test_main.py
git commit -m "feat(galactica): plab live search and lazy topic images behind add and the image proxy"
```

---

### Task 4: the results page

**Files:**
- Modify: `hosts/galactica/services/plab/page.py`
- Modify: `hosts/galactica/services/plab/assets.py`
- Test: `hosts/galactica/services/plab/test_page.py`

**Interfaces:**
- Consumes: topics whose `"images"` may be `None` (search entries from Task 3).
- Produces: `page.render(cache, added, queued, now, search=None)`; `search` is `None` or `{"query": str, "error": str | None}`. The body carries `data-search="1"` on a results page. `plabApp.openTopicGallery(id)` and `plabCard.thumbFailed` exist in the JS.

- [ ] **Step 1: Write the failing tests**

Add to `Render` in `test_page.py`:

```python
    def search(self, topics, query="alpha", error=None):
        return page.render({"updated": 0, "topics": topics}, set(), set(), 1791117232 + 7200,
                           search={"query": query, "error": error})

    def test_list_has_an_empty_search_form(self):
        out = self.render([TOPIC])
        self.assertIn('<form method="get" action="search"', out)
        self.assertIn('name="q" value=""', out)
        self.assertNotIn('data-search="1"', out)

    def test_results_page(self):
        out = self.search([dict(TOPIC, images=None)], query='a"b')
        self.assertIn('name="q" value="a&quot;b"', out)
        self.assertIn('data-search="1"', out)
        self.assertIn("1 result for “a&quot;b” · all time", out)
        self.assertIn('href="./"', out)  # back to the weekly list
        self.assertIn('src="thumb/3313754"', out)
        self.assertIn("openTopicGallery(3313754)", out)
        self.assertIn('@error="thumbFailed = true"', out)
        self.assertIn("Add to Vault", out)

    def test_results_page_plural_and_known_images(self):
        out = self.search([TOPIC, dict(TOPIC, id=1)])
        self.assertIn("2 results for", out)
        self.assertIn('src="img/%s"' % key("https://x/cover.jpg"), out)

    def test_results_page_has_no_production_select_or_new_toggle(self):
        out = self.search([TOPIC])
        self.assertNotIn('data-key="prod"', out)
        self.assertNotIn('data-toggle="new"', out)

    def test_results_page_error(self):
        out = self.search([], error="login needs captcha")
        self.assertIn("login needs captcha", out)
        self.assertNotIn("results for", out)

    def test_search_script_hooks(self):
        script = self.render([TOPIC]).split("<script>")[1]
        self.assertIn("openTopicGallery", script)
        self.assertIn("dataset.search", script)
        self.assertIn("thumbFailed", script)
```

- [ ] **Step 2: Run them to verify they fail**

Run: `python3 -m unittest -q test_page`
Expected: FAIL/ERROR in the six new tests (`render() got an unexpected keyword argument 'search'`, missing form)

- [ ] **Step 3: Implement `page.py`**

In `_card`, replace the thumbnail block (`if t["images"]: … else: …`) with:

```python
    if t["images"] is None:
        # A live search result: plab fetches the topic page when the thumbnail scrolls into view.
        thumb = (f'<img class="thumb w-full h-full object-cover cursor-zoom-in" loading="lazy" '
                 f'src="thumb/{t["id"]}" x-show="!thumbFailed" @error="thumbFailed = true" '
                 f'@click="openTopicGallery({t["id"]})" alt="">'
                 '<div class="thumb none w-full h-full" x-show="thumbFailed" x-cloak></div>')
    elif t["images"]:
        keys = [key(u) for u in t["images"]]
        keys_json = e(json.dumps(keys))
        thumb = (f'<img class="thumb w-full h-full object-cover cursor-zoom-in" loading="lazy" '
                 f'src="img/{keys[0]}" data-images="{keys_json}" @click="openGallery({keys_json})" alt="">')
    else:
        thumb = '<div class="thumb none w-full h-full"></div>'
```

Add a helper after `_select`:

```python
def _search_form(query):
    """The live search box; a results page shows its query in it."""
    return ('<form method="get" action="search" class="join" role="search">'
            '<input class="input input-sm join-item w-48" type="search" name="q" '
            f'value="{html.escape(query)}" placeholder="Search the tracker" required>'
            '<button class="btn btn-sm join-item">Search</button></form>')
```

Change `_filter_bar(labs, filters)` to `_filter_bar(labs, filters, query="", search=False)` and inside it:

- the toggles tuple becomes
  ```python
  toggles = (("h24", "Last 24h"), ("hide", "Hide added")) if search else \
      (("h24", "Last 24h"), ("new", "New"), ("hide", "Hide added"))
  ```
  and the `"".join(...)` iterates `for k, name in toggles` (rename the HTML string variable to `toggle_bar`).
- the selects spec skips production on a results page (search results are not classified):
  ```python
  fields = (("prod", "production", "Production"), ("cat", "category", "Category"),
            ("studio", "studio", "Studio"), ("q", "quality", "Quality"))
  if search:
      fields = fields[1:]
  selects = [_select(k, name, _options(Counter(lab[field] for lab in labs if lab[field])))
             for k, field, name in fields]
  ```
- the returned bar starts with the form: `f'{_search_form(query)}{toggle_bar}{"".join(selects)}{tag_menu}{selected_tags}'`.

Note `selects.insert(1, …)` for the curated select stays; on a results page it lands after Category instead of Production, which is fine.

In `render`, change the signature to `def render(cache, added, queued, now, search=None):` and replace the header and body-opening parts. Build the summary before the return:

```python
    if search:
        n = len(topics)
        status = (f'<span class="text-error">{html.escape(search["error"])}</span>' if search.get("error")
                  else f'{n} result{"" if n == 1 else "s"} for “{html.escape(search["query"])}” · all time')
        summary = f'<a class="link link-hover" href="./">← weekly list</a> · {status}'
    else:
        summary = (f"{len(topics)} releases · last 7 days · updated {age(cache['updated'], now)}"
                   f"{curated_sub}{f' · {pending} queued' if pending else ''}"
                   "<span id=\"newcount\" x-show=\"newCount > 0\" x-text=\"' · ' + newCount + ' new'\"></span>")
```

and, next to it:

```python
    search_attr = ' data-search="1"' if search else ""
```

In the returned string:

```python
            "<body class=\"min-h-screen bg-base-100 text-base-content p-4 overflow-x-hidden\" x-data=\"plabApp\""
            f"{search_attr}>"
            "<header class=\"navbar min-h-0 p-0 mb-2 flex-wrap items-baseline gap-x-4 gap-y-1\">"
            "<h1 class=\"text-xl font-bold\">plab</h1>"
            f"<span class=\"text-sm text-base-content/60\">{summary}</span></header>"
            f"{_filter_bar(labs, cache.get('filters') or [], search['query'] if search else '', bool(search))}"
```

- [ ] **Step 4: Implement `assets.py`**

In `plabApp`, replace `init()`:

```js
      init() {
        // A live search's results are not the weekly list: they must not move the "new
        // since your last visit" mark or overwrite the list's saved filters.
        if (document.body.dataset.search) {
          this.newIds = null;
          return;
        }
        this.initSeen();
        this.initFilters();
        if (this.$watch) {
          this.$watch('st', () => this.saveFilters());
        }
      },
```

Add after `openGallery`:

```js
      async openTopicGallery(id) {
        try {
          const r = await fetch('images/' + id);
          if (!r.ok) return;
          const j = await r.json();
          if (j.images && j.images.length) this.openGallery(j.images);
        } catch (_) {}
      },
```

In `plabCard`, add a field after `error: '',`:

```js
      thumbFailed: false,
```

`plabCard.init` already skips the NEW pass when `this.newIds` is falsy, so `null` leaves every result un-NEW.

- [ ] **Step 5: Run all tests**

Run: `python3 -m unittest -q`
Expected: OK. If an existing test asserts the exact toggles markup or header string, adjust only that test's expected string to the new markup, keeping its intent.

- [ ] **Step 6: Commit**

```bash
git add hosts/galactica/services/plab/page.py hosts/galactica/services/plab/assets.py hosts/galactica/services/plab/test_page.py
git commit -m "feat(galactica): plab search box and live search results page with lazy thumbnails"
```

---

### Task 5: `/search`, `/thumb` and `/images` routes, wiring and docs

**Files:**
- Modify: `hosts/galactica/services/plab/main.py` (`make_handler`, `serve`, `main`, module docstring)
- Modify: `hosts/galactica/services/plab/default.nix` (header comment only)
- Test: `hosts/galactica/services/plab/test_main.py`

**Interfaces:**
- Consumes: `run_search`, `topic_images`, `_image_fetcher` (Task 3); `page.render(..., search=…)` (Task 4).
- Produces: `make_handler(lab, store, rpc_url, download_dir, static_dir=None, exclude_file=None, filter_file=None)`; `serve(..., exclude_file=None, filter_file=None)`.

- [ ] **Step 1: Write the failing tests**

Add `import json` and `import urllib.error` to the import block at the top of `test_main.py`
(alphabetical, with the other stdlib imports), and after the imports:

```python
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None
```

Add a class after `Search`:

```python
class SearchRoutes(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.lab = FakeLab([])
        self.lab.searched_rows = {"alpha": [row(5, "Alpha One")]}
        handler = main.make_handler(self.lab, self.store, "http://rpc", "/vault")
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.opener = urllib.request.build_opener(NoRedirect)

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.dir.cleanup()

    def get(self, path):
        """(status, headers, body) without following redirects."""
        url = f"http://127.0.0.1:{self.httpd.server_address[1]}{path}"
        try:
            with self.opener.open(url) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    def test_blank_query_redirects_to_the_list(self):
        status, headers, _ = self.get("/search?q=+")
        self.assertEqual((status, headers["Location"]), (302, "./"))

    def test_results_page(self):
        status, _, body = self.get("/search?q=alpha")
        self.assertEqual(status, 200)
        self.assertIn(b"Alpha One", body)
        self.assertIn(b'src="thumb/5"', body)
        self.assertEqual(self.lab.searches, [("alpha", None, main.SEARCH_LIMIT)])

    def test_search_failure_is_shown_on_the_page(self):
        self.lab.search_error = LoginError("login needs captcha")
        status, _, body = self.get("/search?q=alpha")
        self.assertEqual(status, 200)
        self.assertIn(b"login needs captcha", body)

    def test_thumb_redirects_to_the_cached_image(self):
        self.get("/search?q=alpha")
        status, headers, _ = self.get("/thumb/5")
        self.assertEqual((status, headers["Location"]), (302, f"../img/{key(COVER)}"))
        self.assertTrue(os.path.exists(self.store.image_path(COVER)))

    def test_thumb_unknown_topic_is_404(self):
        self.assertEqual(self.get("/thumb/99")[0], 404)
        self.assertEqual(self.lab.topics_fetched, [])

    def test_thumb_topic_without_images_is_404(self):
        self.get("/search?q=alpha")
        self.store.set_search_images(5, [])
        self.assertEqual(self.get("/thumb/5")[0], 404)

    def test_thumb_fetch_failure_is_502(self):
        self.get("/search?q=alpha")
        self.lab.broken.add(5)
        self.assertEqual(self.get("/thumb/5")[0], 502)

    def test_images_lists_keys(self):
        self.get("/search?q=alpha")
        status, _, body = self.get("/images/5")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["images"][0], key(COVER))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `python3 -m unittest -q test_main.SearchRoutes`
Expected: FAIL, 404s where 200/302 are expected

- [ ] **Step 3: Implement**

In `main.py`, add `import urllib.parse` to the imports.

Change `make_handler`'s signature to add `filter_file=None` after `exclude_file=None`. Inside `Handler`, add after `_send`:

```python
        def _redirect(self, location):
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _search(self, query):
            if not query:
                return self._redirect("./")
            try:
                topics, error = run_search(lab, store, query, exclude_file, filter_file), None
            except Exception as e:  # noqa: BLE001 -- the reason goes on the page, next to the box
                topics, error = [], str(e)
                log(f"search {query!r} failed: {e}")
            cache = {**store.cache(), "topics": topics}
            body = page.render(cache, store.added(), set(store.queued()), time.time(),
                               search={"query": query, "error": error}).encode()
            self._send(200, body, "text/html; charset=utf-8")

        def _topic_images(self, kind, topic_id):
            try:
                images = topic_images(lab, store, topic_id)
                if kind == "images":
                    body = json.dumps({"images": [key(u) for u in images]}).encode()
                    return self._send(200, body, "application/json")
                if not images:
                    return self._send(404, b"no images", "text/plain")
                store.ensure_image(images[0], _image_fetcher(lab))
            except ValueError as e:  # not listed or searched, or not an image
                return self._send(404, str(e).encode(), "text/plain")
            except Exception as e:  # noqa: BLE001 -- the card keeps its placeholder
                log(f"{kind} {topic_id}: {e}")
                return self._send(502, b"images unavailable", "text/plain")
            self._redirect(f"../img/{key(images[0])}")
```

In `do_GET`, add at the top, before `if self.path == "/":`:

```python
            url = urllib.parse.urlsplit(self.path)
            if url.path == "/search":
                return self._search(urllib.parse.parse_qs(url.query).get("q", [""])[0].strip())
            m = re.fullmatch(r"/(thumb|images)/(\d+)", self.path)
            if m:
                return self._topic_images(m.group(1), int(m.group(2)))
```

Change `serve` to accept and pass `filter_file`:

```python
def serve(lab, store, bind, port, rpc_url, download_dir, static_dir=None, exclude_file=None, filter_file=None):
    handler = make_handler(lab, store, rpc_url, download_dir, static_dir, exclude_file, filter_file)
```

In `main()`, the `serve` call gains `os.environ.get("PLAB_FILTER_FILE")` as the last argument.

Update the module docstring's `serve` line:

```
  serve       the page, its vendored /static assets, the image proxy, POST /add/<topic> (queues past the daily limit)
              and POST /unqueue/<topic>; GET /search?q= searches the tracker live, all time
```

and add under the `Production ranking:` line:

```
Live search: docs/superpowers/specs/2026-10-30-plab-live-search-design.md
```

In `default.nix`, add the same spec pointer under the `# Production ranking:` comment line:

```nix
# Live search: docs/superpowers/specs/2026-10-30-plab-live-search-design.md
```

- [ ] **Step 4: Run all tests**

Run: `python3 -m unittest -q`
Expected: OK

- [ ] **Step 5: Build galactica**

Run from the repo root: `nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link`
Expected: builds without error.

- [ ] **Step 6: Commit**

```bash
git add hosts/galactica/services/plab/main.py hosts/galactica/services/plab/test_main.py hosts/galactica/services/plab/default.nix
git commit -m "feat(galactica): plab /search, /thumb and /images routes"
```

---

### Task 6: deploy and live check

**Files:** none

- [ ] **Step 1: Deploy**

From the repo root on raider: `just deploy galactica`
Expected: phase 1 builds and pushes, phase 2 activates galactica; `plab.service` restarts.

- [ ] **Step 2: Check the service**

Run: `ssh galactica.bat-boa.ts.net systemctl is-active plab` → `active`.

- [ ] **Step 3: Live check (with the user)**

Ask the user to open `https://plab.arsfeld.one`, search a term the weekly list does not contain, and confirm: results appear within a couple of seconds, thumbnails fill in as they scroll into view, a thumbnail click opens the gallery, and **Add to Vault** on one result adds it (or queues it past the daily limit). Then check the server log for errors:

Run: `ssh galactica.bat-boa.ts.net journalctl -u plab --since -15min --no-pager` and look for `search … failed`, `thumb …` or `images …` lines.
