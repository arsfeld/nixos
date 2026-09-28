# Stash LLM identify: design

A service on galactica that watches the Stash library for new files and runs Stash's
own scan, generate and identify steps on them. For any scene still bare after that, it fills
title, studio and performers by reading the file path with an LLM, confirming against
StashDB and ThePornDB where it can.

## Why

Stash on galactica has 934 scenes, and 134 of them have no title, no studio and no performers.
They all have phashes and none has a stash-box ID, so the fingerprint-based Identify task
already tried them and failed. Their paths still carry most of the answer, e.g.
`TripForFuck.24.12.24.Peachy.Alice.XXX.1080p…`, `[onlyfans.com] allisonrose07, …`, or a
folder named after the performer.

## What the test runs showed

Read-only runs over all 134 scenes (2026-09-27, about $0.20 on OpenRouter):

- A text search on stash-box (`scrapeSingleScene` with a `query`) followed by a Jev check
  confirmed 15 scenes, and every one matched the file's duration within about 1s. Rewording
  the question recovered 2–3 more, so about 17 (13%) can be scraped for real.
- Jev picks up look-alike candidates too, with shared performers and a similar title. The
  duration filter throws those out, but duration alone does not: an unrelated scene once
  landed at Δ0s.
- Jev is sensitive to wording. One prompt rejected every TripForFuck match, because those
  filenames carry a date instead of a title. That is the reason for the deterministic rule
  below.
- Web search (`:online`) found performer pages, not scene pages: 0 hits in 10 tries at
  about $0.007 each. **Dropped.**
- About 113 scenes are OnlyFans/amateur, old DVD compilations, JAV or FC2, which the stash-box
  text search does not find. For those, the LLM filename parse is the only source.
- 4 scenes have no usable name at all (`Movie on 2012-01-01 at 02.01.mov`, a hash) and
  stay empty.

## Shape

A host-local module, `hosts/galactica/services/stash-identify.nix`, which
`hosts/galactica/services/default.nix` imports. The Python script sits next to it in
`hosts/galactica/services/stash-identify/` and is packaged with `inotify-tools` on its
PATH. It uses the standard library only.

- **Unit:** `systemd.services.stash-identify`, a plain unit rather than `media.services`,
  because it has no port and no web UI. Runs as the `media` user, `Restart=always`,
  `StateDirectory=stash-identify`.
- **Stash:** GraphQL at `http://localhost:9999/graphql` (the container uses host
  networking). It sends `ApiKey` if `STASH_API_KEY` is set.
- **OpenRouter:** a new `openrouter-api-key` secret in `secrets/sops/galactica.yaml`, set
  non-interactively from raider's `OPENROUTER_API_KEY` and passed in through `EnvironmentFile`.
- **Models:** `~deepseek/deepseek-flash-latest` for parsing and `typesafe/jev-1.13` for
  picking a candidate, both overridable with flags.

```
stash-identify watch                   # the service: watcher + daily sweep
stash-identify run [--dry-run] [--limit N] [--scene ID]   # one pass, by hand
```

## Trigger

- `inotifywait -m -r` on `/mnt/storage/media/Vault` (plain btrfs, so inotify is
  reliable; the limit of 524k watches is plenty), listening for `close_write` and `moved_to` on
  files with Stash's video extensions.
- **Settle:** changed folders accumulate until 2 minutes pass with no new events, then one
  pass runs. A download still being written, or a folder being copied, is handled once
  it finishes.
- **Daily sweep:** once a day the same pass runs over the whole library. That catches events
  missed while the service was down.

## A pass

Every job-starting mutation below is followed by polling `findJob` until the job finishes.
All options are read at run time from Stash's saved defaults
(`configuration { defaults { scan generate identify } }`), so changing them in the Stash
UI changes the service too, with nothing hardcoded.

1. **Scan:** `metadataScan` over the changed folders (the whole library for the sweep),
   using the saved **scan** options. Host paths are translated to container paths:
   `/mnt/storage/media/Vault/…` → `/media/Vault/…`.
2. **Generate:** `metadataGenerate` for the scenes the scan created (their `created_at`
   is after the pass started) using the saved **generate** options. Today those are covers,
   phashes, previews and sprites, with `overwrite: false`. The sweep runs it library-wide,
   which fills in only the supporting files that are missing.
3. **Identify:** `metadataIdentify` on those scenes, using the saved **identify** options:
   StashDB then TPDB by fingerprint, create missing, set cover, mark organized, skip
   multiple matches, and skip single-name performers. That last option is why Lustery-style
   scenes reach step 4.
4. **LLM pipeline** (below) on every scene that is still completely bare and not listed in
   the state file.

**Backfill:** the first pass finds the existing 134 bare scenes in step 4 and handles them
like new ones. Turning the service on is the backfill.

**State file:** `/var/lib/stash-identify/attempted.json` holds the IDs of scenes step 4 has
finished with, whether it applied a match, a guess or nothing. Unidentifiable files
like `Movie on 2012-01-01.mov` are therefore not retried, and billed, on every pass.
Removing an ID makes that scene eligible again.

## Pipeline, per scene

Scenes selected: `findScenes(scene_filter: {is_missing: "title"})`, keeping only those
that also have no studio and no performers. Today those are the same 134.

1. **Parse.** DeepSeek gets the path relative to the library root and returns JSON:
   `{studio, title, performers[], date, query}`. It returns null or `[]` rather than
   guessing. This runs once per scene.
2. **Search.** Run `scrapeSingleScene` with `query` against ThePornDB, then StashDB, and
   keep the top 6 from each, de-duplicated.
3. **Filter by duration.** Drop every candidate whose duration is unknown or more than 10s
   from the file's.
4. **Match.** Apply the first rule that fires:
   - **Deterministic:** the candidate's studio matches the parsed studio (normalized:
     lowercase, alphanumerics only, so "TripForFuck" = "Trip For Fuck"), **and** its date
     equals the parsed date. When several candidates qualify, they must all be the same
     scene (same title, normalized) or the rule doesn't fire.
   - **Jev:** a `choice` question over the remaining candidates plus `none`. The state is
     the path, the duration and the parse. Its instructions say that performer names in
     paths are often aliases or folder names, and that a title or studio match is what
     counts. Accept any pick other than `none`. There is no confidence threshold, because
     the duration filter is the gate: in testing, real matches came back at 0.30–0.48
     confidence and there were no false positives. The confidence is shown in the dry run.
   - Otherwise: no scrape match.
5. **Proposal.** A scrape match proposes the full scraped scene (below). Otherwise the
   proposal is the LLM parse only. A scene with an empty parse proposes nothing.

When both endpoints return the same scene, the TPDB one is preferred for the cover (it
comes back as base64) and the stash_ids of both are kept.

## What gets written

**Scrape match: everything stash-box returned.**

- Scene: title, code, details, director, date, urls, cover image (`image`, a base64 data
  URL, passed to `sceneUpdate.cover_image`), and `stash_ids`
  (`{endpoint, stash_id: remote_site_id}`) for each endpoint that matched.
- Studio: use `stored_id` if Stash already matched it. Otherwise create it with
  name, urls, image, aliases and the endpoint stash_id. The parent studio is linked if it
  already exists (not created).
- Performers: **never** use Stash's `stored_id`, because it matches by alias. The Lustery
  performer "Vivian" came back as #1019 Kattie Gold, one of whose 34 aliases is "Vivian".
  Resolve by the scraped performer's stash-box ID, then by exact name, and otherwise
  create them with every field returned (disambiguation, gender, birthdate, country, ethnicity, measurements, height,
  aliases, urls, details, …), the first entry of `images` as the image, and the endpoint
  stash_id.
- Tags: link those with a `stored_id`. Tags Stash doesn't know are skipped, not created,
  so the tag list doesn't balloon.

**LLM-only:** title; the studio and performers matched by name, then by alias
(for performers, alias matches only for names of two or more words),
case-insensitive (`findStudios`/`findPerformers`); anything unmatched is created by
name only. No cover, no date. The scene gets the tag **`llm-identified`** (created if
missing), so guesses can be filtered for in Stash and checked or fixed later.

**Always:** only empty fields are filled. Nothing already set on a scene is overwritten.
The exception is the cover on a scrape match, which replaces the screenshot generated
at scan time (the same thing Identify's `setCoverImage` does). A scrape match also removes
Identify's skip tag (`SKIP`, #1398), which it adds to scenes it matched but refused because
of single-name performers. 19 of the bare scenes carry it today.
Existing performers and studios are linked, never edited.

## Manual runs

`stash-identify run --dry-run` does a pass without writing anything: it skips steps 1–3
and does not record anything in the state file. It prints one line per scene, e.g.

```
[11751] SinDeluxe - Angels…Scene 2 1080p.mp4
    llm-only | "Angels Will Be Sinners - Scene 2" | SinDeluxe (NEW) | –
[12904] lustery.e2206.clark.and.vivian…mp4
    tpdb+stashdb (date) | "Big Boobs Are Made For Fucking" | Lustery (#161) | Vivian (#1019), Clark (#2130) | Δ0s
```

The service logs the same lines to the journal for what it actually applied.

## Errors

- A failed Stash job, or one that times out after 6 hours, is logged, and the pass skips
  to step 4 for scenes that already exist.
- A failed search or Jev call makes that scene LLM-only. A failed parse, or one malformed
  reply after a re-ask, skips the scene **without** recording it, so the next pass retries it.
- A failed create or update is logged and not recorded either.
- One bad scene never ends the pass, and a crash of the watcher is handled by `Restart=always`.

## Running it

It runs all the time as a service. There is nothing to do by hand after downloads.

## Testing

Before enabling the unit, run `stash-identify run --dry-run --limit 10` on galactica and
read the output. Then run `stash-identify run --scene <id>` against a couple of known
scenes and check them in the Stash UI: cover, studio logo, performer images, stash-box
links, and the `llm-identified` tag on guesses. Then deploy with the unit enabled and watch
the journal while it does the backfill. Expected on today's data: about 17 scraped, about
113 LLM-only, 4 empty. Last, drop a test file into Vault and check that it goes through all
four steps.

## Out of scope

Web search for scene URLs; per-site URL scrapers; creating unknown tags on scrape
matches; packaging as a Stash plugin; a review queue for guesses (the tag stands in for
one).
