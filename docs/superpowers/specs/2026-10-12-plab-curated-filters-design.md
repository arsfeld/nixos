# plab — targeted discovery and filtering for indie & couples content

**Host:** galactica · **URL:** `https://plab.arsfeld.one` · **Code:** `hosts/galactica/services/plab/`

## Goal

Provide automated discovery and intuitive filtering for authentic amateur, romantic, and indie couples releases (studios like Lustery, Joybear, Erika Lust, X-Art, etc.) within plab. Because this content is uploaded less frequently and rarely competes with mainstream releases in the global top 100 most-seeded list of the last 7 days, plab will run targeted tracker queries across a 30-day window, merge and tag these releases into its atomic cache, and provide an "Indie & Couples" filter toggle with visual badges in the web interface.

## User Configuration (`PLAB_SEARCHES_FILE`)

Targeted queries are configurable from a file, mirroring `PLAB_EXCLUDE_FILE`:
1. Checked via `PLAB_SEARCHES_FILE` environment variable.
2. Falls back to `/var/lib/plab/searches.txt` in the state directory if present.
3. If neither exists, falls back to a built-in default list.

File format: plain text, UTF-8. Blank lines and lines starting with `#` are ignored. Each non-empty line specifies a tracker search term or phrase.

### Built-in Default Search Terms
```text
# Indie & couples studios
Lustery
Joybear
Erika Lust
XConfessions
Lust Cinema
FrolicMe
Sssh

# Glamour & romantic studios
X-Art
Colette
Viv Thomas
Bellesa
MetArt

# Genre keywords
"real couple"
"amateur couple"
"romantic"
"sensual"
"threesome"
```

## Tracker Client Changes (`lab.py`)

Add a dedicated search method to `Lab`:
```python
def search(self, query, forums, days=30, limit=20, predicate=None):
    """Search tracker releases matching `query` within `forums` uploaded in the last `days` days."""
```
- Parameters passed to `tracker.php`:
  - `f[]`: allowlisted video forums (from `forums.FORUMS`).
  - `nm`: search string.
  - `o=10`, `s=2`: sort by seeders descending.
  - `tm`: time window (default 30 days).
- Fetches and parses rows via `parse.rows(page)`.
- Filters rows using `predicate` to honor exclusion rules from `PLAB_EXCLUDE_FILE`.
- Returns up to `limit` releases.

## Refresh Pipeline Changes (`main.py`)

The `refresh()` pipeline in `main.py` is extended:

1. **General Top 100**:
   - Queries `lab.top(forums, days=7, limit=100, predicate=pred)` as before.
2. **Targeted Searches**:
   - Loads search queries using `load_searches(path, state_dir)`.
   - Iterates through each search term, invoking `lab.search(term, forums, days=30, limit=20, predicate=pred)`.
   - Pauses for `DELAY` (1.0s) between queries to maintain tracker politeness.
   - Non-fatal resilience: if an individual search query fails or times out, logs a warning and proceeds with other queries rather than failing the whole refresh. Authentication errors (`LoginError`) remain fatal and fail-fast to prevent account lockouts or unhandled captchas.
   - Discovered search rows are flagged with `"curated": True`.
3. **Deduplication and Merge**:
   - Merges baseline top 100 rows and targeted search rows by unique `id`.
   - If a release appears in both the baseline scrape and a targeted search, it is retained and marked `"curated": True`.
   - Topics from the top 100 matching the curated studio/tag patterns (see `labels.py`) are also flagged `"curated": True`.
4. **Thumbnail Fetching & Atomic Cache Write**:
   - Downloads thumbnails for all newly discovered releases.
   - Writes the combined list to `cache.json` atomically via `Store`.

## Labels & Detection (`labels.py`)

Add `is_curated(title, studio, tags)` in `labels.py`:
- Checks whether `studio` belongs to the known indie/couples studio allowlist, or if `tags` contain relevant keywords (`"real couple"`, `"amateur couple"`, `"romantic"`, `"sensual"`, `"homemade"`).
- Used during cache generation and rendering to ensure releases matching curated criteria are consistently tagged regardless of which query fetched them.

## Web UI & Filter Bar (`page.py`, `assets.py`)

### 1. Card DOM & Visual Badges (`page.py`)
- Cards gain `data-curated="1"` on the top-level `.card` element when `t.get("curated")` or `is_curated(...)` is true.
- When `data-curated="1"`, renders an attractive badge in the card thumbnail container:
  ```html
  <span class="badge badge-secondary font-bold absolute bottom-2 left-2 z-[1]">Couples</span>
  ```
- Header subtitle reflects both general and curated releases:
  ```html
  <span class="text-sm text-base-content/60">{total} releases · last 7 days + curated · updated ...</span>
  ```

### 2. Filter Bar & JavaScript (`assets.py`)
- New toggle button in `_filter_bar`:
  ```html
  <button type="button" class="btn btn-sm" data-toggle="couples">Indie & Couples</button>
  ```
- `FILTER_JS`:
  - `TOGGLES = ['h24', 'new', 'hide', 'couples']`.
  - Filter logic check:
    ```javascript
    && (!st.couples || d.curated === '1')
    ```
  - State serialized into URL hash (`#couples=1`) and `localStorage` so active filters persist across page reloads.

## NixOS Configuration (`hosts/galactica/services/plab/default.nix`)

- Exposes `PLAB_SEARCHES_FILE` in the `plab` wrapper script:
  ```nix
  export PLAB_SEARCHES_FILE="''${PLAB_SEARCHES_FILE:-${secrets.plab-searches.path}}"
  ```
  (falling back gracefully if no sops secret is present).

## Testing Plan

1. **Unit Tests**:
   - `test_lab.py`:
     - Test `search()` URL parameter encoding (`nm`, `f[]`, `tm=30`, `o=10`, `s=2`).
     - Test `search()` pagination and predicate exclusion.
   - `test_main.py`:
     - Test `load_searches()` file loading, comment stripping, and fallback defaults.
     - Test `refresh()` runs both `top()` and `search()`, deduplicates topics by `id`, and sets `"curated": True`.
     - Test resilient error handling when an individual search returns 0 results or throws a query error.
   - `test_labels.py`:
     - Test `is_curated()` recognition against studio names and title tags.
   - `test_page.py`:
     - Test `_card()` rendering of `data-curated="1"` and the `"Couples"` badge.
     - Test `_filter_bar()` rendering of the `"Indie & Couples"` toggle button.
2. **Integration & Regression**:
   - Run `python3 -m unittest -v` across all test suites in `hosts/galactica/services/plab/`.
   - Run `nix eval .#nixosConfigurations.galactica.config.systemd.services.plab.serviceConfig.ExecStart` to confirm clean Nix evaluation.
