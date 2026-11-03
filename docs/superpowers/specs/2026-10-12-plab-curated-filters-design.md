# plab — curated filters and targeted discovery

**Host:** galactica · **URL:** `https://plab.arsfeld.one` · **Code:** `hosts/galactica/services/plab/`

## Goal

Some content is uploaded rarely and never competes with mainstream releases in the
7-day top 100, so plab runs targeted tracker searches for it over a longer window,
merges the results into its cache, and offers one filter toggle per curated group.

**No group name or search term lives in this repository.** All of them come from one
file, the `plab-filter` sops secret, so changing what plab looks for is a secret edit,
not a commit. Tests use placeholder terms (`Alpha`, `Group A`).

## The filter file (`PLAB_FILTER_FILE`)

1. `PLAB_FILTER_FILE` (set by `default.nix` to the `plab-filter` secret).
2. Otherwise `filter.txt` in the state directory (`/var/lib/plab`).
3. Otherwise no curated filters, no searches.

Plain UTF-8 text. Blank lines and `#` comments are ignored. A `[Name]` line starts a
filter. Each line under it is a tracker search term. Terms before any header belong to a
filter named `Curated`, and a repeated header adds to the earlier one.

```text
[Group A]
Alpha Studio
"two words"

[Group B]
"beta"
```

Edit it with `sops set secrets/sops/galactica.yaml '["plab-filter"]' '"…"'`. The next
refresh (every 3 h) picks it up and needs no deploy.

## Refresh (`main.py`)

1. `lab.top(forums, days=7, limit=100)`, as before.
2. For every term of every filter, run `lab.search(term, forums, days=32, limit=20)`,
   waiting `DELAY` between searches. A failed search is logged and skipped. A
   `LoginError` stays fatal.
3. Merge the rows by `id`. A release belongs to a filter if one of that filter's searches
   found it, or if its title contains one of the filter's terms (`labels.match_term`,
   which ignores case, spaces and punctuation, so `Alpha Studio` matches
   `[AlphaStudio.com]`).
4. Each topic gets `filters` (the names of the filters it belongs to, in file order) and
   `curated_reason` (the badge text: the matching term of its first filter, without
   quotes). The cache also stores the `filters` list itself, so the page can show a
   toggle for a filter that matched nothing.

## Page (`page.py`, `assets.py`)

- One button per filter (`data-filter="<name>"`), after the fixed toggles. At most one
  filter is active at a time: clicking the active one clears it. The state key is `f`,
  kept in the URL hash and in `localStorage` like the selects. A saved name that is no
  longer in the file is dropped on load, so it cannot hide every card.
- A card in any filter gets `data-curated="1"` and a `badge-secondary` badge showing
  `curated_reason`. The header counts those cards (`· N curated`).
