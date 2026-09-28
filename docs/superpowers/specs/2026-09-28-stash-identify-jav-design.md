# stash-identify: JAV code lookup

Extends `hosts/galactica/services/stash-identify` (design:
`2026-09-27-stash-llm-identify-design.md`) with a dedicated path for JAV files, whose
filename is a product code (`CAWD-910.mp4`) that identifies the release exactly.

## Problem

Measured on 2026-09-28: the Vault holds seven code-named JAV files. Two (IPZZ-795,
MIDA-796) matched StashDB through the existing flow. Five (CAWD-910, MIDA-732,
START-601, MUDR-402, JUR-843) ended up `llm-identified` with an invented title and
studio (`Kawaii* – CAWD-910`) and no performers, because:

- StashDB and TPDB's stash-box endpoint don't carry those codes; a search returns
  neighbours with the same number (PPPD-910, HAVD-910).
- TPDB's separate JAV database (`https://api.theporndb.net/jav?q=<code>`) has all five as
  the exact-code first hit, with title, studio and performers. The TPDB key Stash
  already stores for its stash-box works there.
- TPDB JAV durations are rounded to the minute (7800 s listed vs 7519 s on disk), so the
  ±10 s `DURATION_TOLERANCE` gate would reject every hit anyway.
- Every installed web JAV scraper is unusable: R18.dev, JavLibrary and JavDatabase answer
  403, javdb fails TLS, DMM panics Stash with a nil dereference, and `ThePornDBJAV` has
  no API key (401). Fixing that YAML by hand was rejected: Stash's scraper manager
  overwrites it on update, and it would hold a secret in a mutable file.

`gachi958_sd.wmv` (Gachinco amateur content) has no product code and is out of scope.

## Design

### Detection (`match.py`, pure)

- `jav_code(path)`: the basename of `path` without its extension must start with 2–6
  letters, a hyphen, and 3–5 digits, followed by nothing or by a `-`, `_`, `.` or space
  and anything after it. It returns the code uppercased (`CAWD-910`), or `None`. The
  hyphen is required so that `gachi958_sd`, `kaly0720` and tokens inside Western
  filenames (`... OB643.mp4`) don't match. A false positive costs one lookup, then the
  scene falls back to the LLM flow.
- `code_key(s)`: returns `(LETTERS, int(digits))` for a code-like string, or `None`.
  Codes are compared only through this, so `crvr00402`, `CRVR-402` and `crvr-402` are
  equal.

### Lookup (`main.identify_scene`)

When `jav_code` returns a code, the LLM parse is skipped and the scene goes through
these steps:

1. **StashDB:** run `stash.search("https://stashdb.org/graphql", code)` and keep the hits
   whose `code_key(c["code"])` equals the file's. If every kept hit is the same scene
   (per `scene_key`), use it as the primary, with twins and stash_ids as today, and
   `rule = "code"`. Hits that disagree count as no match.
2. **TPDB JAV:** otherwise call `tpdb.jav_search(code)` (a new small client in
   `tpdb.py`, using a new `net.get_json` beside `post_json`; the request needs a
   `User-Agent` header, `Accept: application/json` and `Authorization: Bearer <key>`). Keep the hits whose
   `code_key(external_id)` matches, with the same uniqueness rule (distinct normalised
   titles). Map the chosen hit with `match.tpdb_jav_scene(hit)` into the ScrapedScene
   shape `apply` already consumes:
   - `title` ← `title`, `code` ← `external_id` uppercased, `date`, `details` ←
     `description`, `image` ← `background.full` (falling back to `poster`), and
     `urls` ← `["https://theporndb.net/jav/<slug>"]`.
   - `studio` ← `{"name": site.name}`.
   - `performers` ← `[{"name": p.parent.name or p.name}]`.
   - There is no `remote_site_id`, so `stash_ids` is empty. TPDB JAV is not a stash-box
     endpoint, so studios and performers resolve by name as the llm path does.
3. **No duration gate** on either JAV match, because the code is the identity check.
   Multi-part files (CD1/CD2) share a code and would fail one anyway. `delta` is still
   computed and logged.
4. **Both miss:** a new scene continues into the existing LLM flow unchanged.
5. **Errors:** a failure in either request raises `TransientError`, so the scene is
   retried next pass and never downgraded to llm-only.

The proposal `kind` stays `"scrape"`. `format_line` shows the source as `stashdb` or
`tpdb-jav`, and the rule as `code`.

The TPDB API key is read at startup from Stash's `configuration.general.stashBoxes`
entry whose endpoint contains `theporndb`. There is no new sops secret. If there is no
such entry, JAV lookup falls back to StashDB only and logs that once.

### Upgrading `llm-identified` scenes

- **Selection:** `run_pass` (unless `scene_ids` is given) adds scenes tagged
  `llm-identified` whose file has a JAV code, regardless of the state file. It needs a
  new `stash.scenes_with_tag(tag_id)` query.
- **Lookup only:** these upgrade candidates run just the JAV lookup. On a miss nothing is
  written, nothing is billed, and the state file is untouched. They are re-queried every
  pass, which costs at most two HTTP calls per scene.
- **Re-check before writing:** the "edited meanwhile" check treats an upgrade candidate
  as untouched while it still carries the `llm-identified` tag. Removing the tag in the
  UI therefore opts a scene out.
- **Writing:** `apply(..., overwrite=True)` calls `scrape_update(..., overwrite=True)`,
  which sets title, code, date, details, urls and studio even when present, replaces
  (rather than merges) the performer list, and drops the `llm-identified` tag id from
  `tag_ids`. The cover is replaced, as it is today.
- **Orphaned studios:** studios the LLM created (`Kawaii*`, `Muku`, …) are left in
  place. Deleting studios is out of scope.

## Testing

- `test_match.py`: `jav_code` cases taken from the real library, both positive (`CAWD-910.mp4`,
  `MIDA-796.H265.mp4`) and negative (`gachi958_sd.wmv`, `kaly0720.mp4`,
  `PBB026_s04_1080.mp4`, the LegalPorno `... OB643.mp4` name, `3.Deseos.2026....mp4`).
  Also `code_key` equivalences, `tpdb_jav_scene` on a recorded TPDB response, and
  `scrape_update` with `overwrite=True`.
- `test_main.py` with fake Stash and TPDB clients: a StashDB exact-code hit, a TPDB-only
  hit, both missing (falls to the LLM for a new scene and is a no-op for an upgrade
  candidate), a TPDB error (`TransientError`), ambiguous exact hits, and selection of
  upgrade candidates.
- Live: `stash-identify run --dry-run --scene 10068 --scene 12227 --scene 12877 --scene
  12938 --scene 12941` on galactica prints `tpdb-jav (code)` proposals for all five.
  After deploy, the first sweep upgrades them.
