# plab live search — the tracker's whole catalogue through plab's cards

**Host:** galactica · **Code:** `hosts/galactica/services/plab/` · **Builds on:**
`2026-10-09-plab-design.md`, `2026-10-30-plab-production-ranking-design.md`

## Goal

A search box on plab that queries the tracker live, across all time, and shows the
results as the same cards the weekly list uses: thumbnail, gallery, labels, filters and
**Add to Vault**. It is for releases the weekly top-100 and the curated searches never
pick up, chiefly older popular ones.

The weekly list is untouched. Nothing a search does is written to `cache.json`.

## Shape

- A search input in the toolbar submits `GET /search?q=…`, a separate results view.
  `/` stays the weekly list.
- One tracker request per search: `tracker.php` with `nm=<q>`, the video-forum
  allowlist, sorted by seeders descending, **no `tm`** (all time), first results page
  only (up to 50 rows). The exclude patterns apply as they do on refresh.
- The results page renders at once, with placeholder thumbnails. Each card loads its
  thumbnail lazily from `GET /thumb/<id>`, which fetches the topic page on first use.
  This keeps a search to about a second, where fetching all 50 topic pages up front
  would take 30 to 60 s at refresh's pacing.

## Server

### `lab.py`

`search(query, forums, days=32, limit=20, predicate=None)` accepts `days=None`, which
omits the `tm` parameter. The refresh's curated searches keep passing `days=32`.

### `store.py`: `search.json`

A second, short-lived topic store, kept apart from `cache.json` so that a search can
never disturb the weekly list.

- Shape: `{"<topic id>": {...tracker row, "images": [...] | null, "at": <unix time>}}`.
  `images` is `null` until the topic page has been fetched.
- `search_topics()`: the dict without entries more than 24 h old (checked on read, not
  written back), empty when the file is missing or corrupt (same `_read_json` fallback as
  the other files).
- `save_search(rows, now)`: merges the rows in, keeping the `images` of topics already
  known and setting `at` to `now` on every row in this search, then drops entries whose
  `at` is more than 24 h old. Atomic write, like every other file here.
- `set_search_images(topic_id, urls)`: records a topic's images.
- Writers are the server's threads only (`refresh` never writes it), and they serialize
  on a lock the `Store` holds, because each write is a read-modify-write.

`refresh`'s `store.prune_images(...)` keeps the URLs referenced by `search.json` as
well as `cache.json`'s, so a refresh never deletes thumbnails an open results page
still shows. Search images age out with their entries: the next refresh after an entry
is dropped prunes its files.

### `main.py`

- `run_search(lab, store, query, exclude_file=None, filter_file=None, now=None)`: runs the
  tracker search with the exclude predicate, fetching one results page (`pages=1`, a single
  tracker request), calls `save_search`, and returns the rows in tracker order.
- `topic_images(lab, store, topic_id)`: the image URLs of a listed or searched topic.
  - A topic in `cache.json` returns its cached images.
  - A topic in `search.json` with images already known returns those.
  - Otherwise plab fetches the topic page under a semaphore of **2**, parses the images,
    records them with `set_search_images` and returns them. The semaphore caps
    concurrent tracker fetches from one results page.
  - Any other id raises `ValueError`, so the route can only fetch topics plab has itself
    listed.
- `add_topic` and `image_for` accept ids and image URLs from `cache.json` **or**
  `search.json`. The image proxy still serves only URLs that plab parsed from a tracker
  page, so it is still not an open proxy.

Routes:

| Route | Behaviour |
|---|---|
| `GET /search?q=…` | A blank `q` is a 302 to `./`. Otherwise `run_search` and the results page. A `LoginError` or tracker failure renders the results page with the error text in place of the grid (200, not 502), so the search box stays usable. |
| `GET /thumb/<id>` | `topic_images`, caches the first image with `store.ensure_image`, then a 302 to `img/<sha1>`. 404 when the topic has no images or is unknown; 502 on a fetch failure. |
| `GET /images/<id>` | `topic_images` as `{"images": [<sha1>, …]}` for the gallery; same error codes. |

The `/search` route parses its query string with `urllib.parse`; every other route keeps
its exact-path match.

### What a search does not do

- No production classification. Results rank on seeders alone and carry no production
  badge. The Production select is not shown on the results page.
- No queue changes: an add past the daily limit queues as usual, and `drain_queue`
  needs nothing from `search.json`, since it works from ids alone.

## Page

`page.render(cache, added, queued, now, search=None)`. `search` is `None` for the weekly
list, or `{"query": q, "error": message-or-None}` for a results page, with
`cache["topics"]` holding the search rows.

- **Toolbar.** A `<form method="get" action="search">` with one text input (`name="q"`,
  prefilled with the current query on a results page) at the start of the existing
  toolbar, on both pages.
- **Header.** The weekly list keeps its header. A results page says
  `N results for "q" · all time` and links back to the list. On an error, the header
  gives the error and the grid is empty.
- **Cards.** The same `_card`, in the tracker's order (by seeders). A card whose topic
  has no known images renders `<img loading="lazy" src="thumb/<id>">`, so the browser
  fetches thumbnails as cards scroll into view. On a 404 or a failure (`@error`) the
  image is replaced by the existing `.thumb.none` placeholder. Clicking the thumbnail
  fetches `images/<id>` and opens the gallery with the keys it returns, through the
  existing `openGallery`. Cards with known images keep today's markup.
- **Curated badges.** The curated filter terms are matched against each result's title
  with `match_term`, the same rule refresh uses for top-list releases, so the Curated
  select works on results too. No extra tracker requests.
- **Client state.** On a results page the NEW pass is off: `plab.seen` is neither read
  nor written, because results are not the weekly list and would otherwise wipe out the
  "since your last visit" state. Filters still work but are not persisted: the page
  ignores and does not write `plab.filters` or the URL hash, so the query string stays
  the URL and the weekly list's saved filters stay as they were.

## Errors

- Tracker search failure or login needing a captcha: the results page shows the
  message (for example "login needs captcha"); nothing is written.
- A failed login is remembered for 5 minutes (`LOGIN_BACKOFF`): further logins re-raise it
  without posting the form, so lazy thumbnails cannot trigger a captcha. A newer cookie
  file (`plab set-cookie`) clears it. Concurrent logins are serialized.
- Topic fetch failure behind `/thumb` or `/images`: that card keeps its placeholder and
  the gallery stays closed. The next request retries, since `images` stays `null`.
- An add from a stale results page whose entry has aged out of `search.json` is refused
  with "topic N is not on the list", the same message a stale weekly list gets. A new
  search brings it back.

## Testing

Unit tests, `python3 -m unittest -v` in the directory, as today:

- `test_lab.py`: `search(days=None)` sends no `tm`; `days=32` still does.
- `test_store.py`: `save_search` merges, keeps known images and drops entries older
  than 24 h; `set_search_images`; `prune_images` keeps search-referenced images (via the
  refresh's call).
- `test_main.py`: `run_search` applies excludes and records rows; `topic_images` for
  cached, already-fetched, to-be-fetched and unknown ids (the last raises); `add_topic`
  and `image_for` accept search-only topics; the `/search` route redirects a blank `q`
  and renders the error page on `LoginError`; `/thumb` redirects to `img/<sha1>` and
  answers 404 for a topic with no images.
- `test_page.py`: a results page carries the search form prefilled, the results header
  and `thumb/<id>` sources for cards without images, and no Production select; the
  weekly list carries the empty search form.

Live check after deploy: search a term that the weekly list does not contain, watch the
thumbnails fill in, open a gallery, and add one release; confirm it lands in Transmission
under `Vault`.

## Out of scope

Paging past the first 50 results, other sort orders, a selectable time window, searching
outside the video forums, saving searches, and classifying search results.
