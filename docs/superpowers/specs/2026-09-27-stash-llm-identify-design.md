# Stash LLM identify: design

A quick, disposable script that fills title, studio and performers on Stash scenes that
have none, by reading their file paths with an LLM and confirming against StashDB and
ThePornDB where possible.

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

One file, `scripts/stash-llm-identify.py`, standard library only, run from raider:

```
python3 scripts/stash-llm-identify.py                 # dry run, writes proposals JSON
python3 scripts/stash-llm-identify.py --limit 10      # dry run on 10 scenes
python3 scripts/stash-llm-identify.py --apply         # apply the saved proposals
```

- Stash: GraphQL at `http://galactica.bat-boa.ts.net:9999/graphql`, which is reachable
  from the tailnet. It sends Stash's `api_key` if `STASH_API_KEY` is set.
- OpenRouter: `OPENROUTER_API_KEY` from the environment (already set on raider).
- Models: `~deepseek/deepseek-flash-latest` for parsing and `typesafe/jev-1.13` for
  picking a candidate, both overridable with flags.

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

## What gets written (`--apply`)

**Scrape match: everything stash-box returned.**

- Scene: title, code, details, director, date, urls, cover image (`image`, a base64 data
  URL, passed to `sceneUpdate.cover_image`), and `stash_ids`
  (`{endpoint, stash_id: remote_site_id}`) for each endpoint that matched.
- Studio: use `stored_id` if Stash already matched it. Otherwise create it with
  name, urls, image, aliases and the endpoint stash_id. The parent studio is linked if it
  already exists (not created).
- Performers: use `stored_id` where present. Otherwise create them with every field
  returned (disambiguation, gender, birthdate, country, ethnicity, measurements, height,
  aliases, urls, details, …), the first entry of `images` as the image, and the endpoint
  stash_id.
- Tags: link those with a `stored_id`. Tags Stash doesn't know are skipped, not created,
  so the tag list doesn't balloon.

**LLM-only:** title; the studio and performers matched by name, then by alias,
case-insensitive (`findStudios`/`findPerformers`); anything unmatched is created by
name only. No cover, no date.

**Always:** only empty fields are filled. Nothing already set on a scene is overwritten.
Existing performers and studios are linked, never edited.

## Dry run and review

The default mode prints one line per scene:

```
[11751] SinDeluxe - Angels…Scene 2 1080p.mp4
    llm-only | "Angels Will Be Sinners - Scene 2" | SinDeluxe (NEW) | –
[12904] lustery.e2206.clark.and.vivian…mp4
    tpdb+stashdb (date) | "Big Boobs Are Made For Fucking" | Lustery (#161) | Vivian (#1019), Clark (#2130) | Δ0s
```

It writes every proposal, including the full scraped payload with its cover, to
`stash-identify-proposals.json` in the working directory. `--apply` reads that file and
writes exactly what was reviewed, with no new LLM or search calls. Delete a scene's entry
from the file to skip it. `--only-scraped` applies only scrape matches.

## Errors

A failed LLM, search or Jev call, or a malformed reply, is logged against its scene, and
that scene falls back to the next stage (search failure means LLM-only, parse failure
means skipped). One re-ask on malformed JSON, and no other retries. During `--apply`, a
failed create or update is logged and the script moves on. A re-run skips scenes that are
already filled, because selection happens again.

## When to run it

By hand, from raider. There is no timer: the LLM-only proposals are guesses and deserve
a look before they are written.

- Once now, to backfill the 134 scenes.
- After new downloads: run Stash's Identify task first (the fingerprint match catches the easy
  ones), then this script for whatever is still bare.

## Testing

Dry run with `--limit 10`, and read the table. `--apply` on those 10, then check them in
the Stash UI: cover, studio logo, performer images, stash-box links. Then run the rest.
Expected on today's data: about 17 scraped, about 113 LLM-only, 4 empty.

## Out of scope

Web search for scene URLs; per-site URL scrapers; creating unknown tags; a scheduled
mode; packaging as a Stash plugin or a nix module.
