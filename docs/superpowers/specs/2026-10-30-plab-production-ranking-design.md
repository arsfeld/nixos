# plab: rank by production style, not just seeders

## Problem

plab lists releases in the tracker's order: most seeded over the last 7 days, with the
curated filters' 32-day search results appended after. On 2026-10-30, 40 of the top 50
of 221 cards mentioned anal, and the top was dominated by LegalPorno/AnalVids, Tushy,
Woodman, TeamSkeet and the family-taboo sites.

The 18 adds still in the cache show what is actually wanted. They are amateur and couples
releases (OnlyFans couples, a homemade archive clip, Privacy.com.br) and intimate/artistic
studios (Erika Lust, X-Art, SexArt, Bellesa). Several are anal, but none come from a
gonzo factory. So the axis to push down is **industrial gonzo**, not "any studio" and not
"anal".

## Decision

Classify every release once with OpenRouter's Jev decisions API, the one
stash-identify already uses. Store the class in `cache.json` and re-rank the page by
seeders weighted by class. Industrial releases sink but stay on the page; nothing is
hidden.

Rejected: a hand-kept studio list in sops. It cannot judge bracketless titles (17 of 221)
or new studios. Deferred: a sops override list on top of Jev. Add it only if Jev gets a
class of studio consistently wrong.

## Components

### `classify.py` (new)

A small OpenRouter client modelled on `stash-identify/llm.py`, with its own copy of the
six-line `post_json`, because the two services are separate Python programs:

- `Classifier(api_key, model)`, with `classify(title, category) -> {"class": str, "confidence": ...}`.
- It POSTs to `https://openrouter.ai/api/alpha/decisions` with
  `state = {"title": title, "category": category}` and one question:
  `{"production": {"type": "choice", "instructions": ..., "criteria": {...}}}`.
- The criteria, with the examples written into their text:
  - `industrial`: mass-produced gonzo, anal, taboo/family-roleplay or casting studios
    (LegalPorno/AnalVids/PornBox, Tushy, Woodman, TeamSkeet, family sites, Backroom
    Casting Couch).
  - `pro_artistic`: professional but intimate, romantic or artistic productions (Erika
    Lust, X-Art, SexArt/MetArt, Bellesa, Frolicme, Viv Thomas).
  - `amateur`: homemade, real couples, OnlyFans or creator-run content.
- A choice outside those three raises `ValueError`.

### `refresh()` in `main.py`

`refresh` takes an optional `classify` callable (`(title, category) -> dict`), and `None`
means no classification. When it builds each topic:

- If the previous entry has `production`, that value is copied over.
- Otherwise, if `classify` is set, it is called and the result is stored as
  `topic["production"]`.
- Any exception except `LoginError`, which classification never raises, is logged and the
  topic is saved without `production`. The next refresh retries it. A classifier failure
  never fails the refresh.

Calls are sequential, one per unclassified topic. After the first run, a refresh only
classifies topics that are new since the previous refresh.

`main()` builds the classifier when `PLAB_OPENROUTER_KEY_FILE` names a readable file,
with the model from `PLAB_JEV_MODEL` (default `typesafe/jev-1.13`). Without a key file,
`classify` is `None` and plab behaves as before.

### `page.py`

`render` sorts topics by `score = seeders × WEIGHT[class]` before building the cards,
with ties keeping cache order:

| class | weight |
|---|---|
| `amateur` | 1.5 |
| `pro_artistic` | 1.0 |
| unclassified | 1.0 |
| `industrial` | 0.25 |

`WEIGHT` is a module constant. Confidence is stored but does not affect the score.
Because the curated 32-day rows now interleave with the top list by score instead of
trailing it, the page becomes one ranked list.

Each card's meta line gains a muted label: `amateur`, `artistic` or `industrial`. It shows
nothing when the topic is unclassified. The label is for spotting misclassifications.
There are no new filter controls.

### `default.nix`

- It exports `PLAB_OPENROUTER_KEY_FILE` as `${secrets.openrouter-api-key.path}`. The
  secret already exists and is owned by `media`; stash-identify declares it.
- `PLAB_JEV_MODEL` is not exported. It defaults to `classify.MODEL`
  (`typesafe/jev-1.13`), which is the only place the model is named.

## Testing

- `test_classify.py`:
  - The request carries the right `state`, the `production` choice and the three criteria.
  - An answer is parsed into `{class, confidence}`.
  - An unknown choice raises.
  - Calls go through a stubbed `post`, so the tests make no network calls.
- `test_main.py`:
  - Only topics without a stored `production` are classified, and stored values are reused.
  - A classifier exception leaves the topic unclassified and the cache is still saved.
  - `classify=None` changes nothing.
- `test_page.py`:
  - Cards are ordered by weighted score.
  - An unclassified topic gets weight 1.0.
  - The label renders for each class and is absent when the topic is unclassified.

## Rollout

1. Deploy galactica, then run `sudo -u media plab refresh` by hand. The first run
   classifies the ~221 cached topics.
2. Audit the result from `cache.json`:
   - LegalPorno, Tushy and Woodman should be `industrial`.
   - X-Art, Erika Lust and Bellesa should be `pro_artistic`.
   - The OnlyFans couples should be `amateur`.
3. If a studio is consistently wrong, add the deferred override list rather than reworking
   the criteria indefinitely.
