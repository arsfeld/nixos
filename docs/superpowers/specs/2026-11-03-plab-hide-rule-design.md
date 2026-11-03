# plab: a hide rule for releases and Stash scenes

Date: 2026-11-03. Host: galactica. Package: `packages/plab`.

## Goal

Some kinds of scene should not appear anywhere in plab: not in the listings, which the
exclude list already filters, and not in what the Assistant suggests. A scene is hidden
only when that is **certain**. If there is any sign that a scene falls outside the
unwanted kind, it stays visible.

The terms that describe the kind live only in the `plab-exclude` sops secret. Code,
tests, this spec and commit messages refer to them only as *hide terms* and *keep
terms*. The tests use placeholder words, the way the existing filter tests do.

## What the data showed

These measurements were taken on 2026-11-03 against a copy of `/var/lib/plab/state.db`
(865 releases) and the full Stash library (1072 scenes). They are why the rule has the
shape it does:

- **Performer gender in Stash cannot prove a scene's kind.** Male performers are
  often missing from a cast. A cast with no man listed therefore proves nothing, while
  a cast with a man listed does prove one is present. The rule uses the cast in that
  one direction only.
- **Tags are the signal.** In video releases, the bracketed tag list was right for the
  hide terms in 22 of 23 releases. The one exception was ambiguous, and the keep rule
  leaves it visible.
- **The game forums use compound tags** such as `X/Y` alongside tags that clearly
  rule the kind out. Matching on whole tags means a compound tag never equals a bare
  hide term, so no game was hidden.
- **One broad tag is not reliable on its own.** It also appears on scenes it should
  not hide, so it is not a hide term.
- **Keep terms are needed.** A multi-scene pack carried a hide term among tags that
  rule the kind out. In Stash, 7 scenes with a hide tag list a man in the cast. The
  other 10 carried only keep tags. The keep tags and the cast together keep all of them.
- **Untagged titles.** 510 of the 865 releases come from other indexers and have
  plain-text titles. Every one of them that carried a hide word was correctly a hide.

## The rule

`HideRule { hide: Vec<String>, keep: Vec<String> }` holds lowercase terms.

```
hides(rule, terms) = any hide term ∈ terms  &&  no keep term ∈ terms
```

An empty `hide` list never hides anything, so a missing section or a missing file
leaves today's behaviour unchanged.

Terms are compared case-insensitively. What counts as a scene's terms depends on where
it comes from:

| Source | Terms |
|---|---|
| A release title whose tag list `labels::labels` finds | each tag in that list, whole and trimmed |
| A release title with no tag list | each whole word of the title. A multi-word term matches as a run of whole words (`candidates::has_word` semantics) |
| A Stash scene | each tag name, whole. A listed performer whose `gender` is `MALE` adds an implicit keep |

### Always terms (added 2026-11-03)

A third list, `always`, hides whatever else a scene carries: no keep term and no listed
cast member saves it. It is for a format rather than a kind of content, one where the
other tags say nothing about whether it is wanted. Its terms are matched like hide terms
(whole tags, or whole words of an untagged title).

```
hides(rule, terms) = any always term ∈ terms
                  || (any hide term ∈ terms && no keep term ∈ terms)
```

Its first use is VR releases. On the tracker, the VR forum is also dropped from
`plab-site`'s video groups, so plab stops fetching it; the `always` terms catch VR
releases that come from other indexers and VR scenes in Stash. Measured on the same
copy: the VR forum held 8 releases, all of which the terms alone hide; no other release
and no game matched. A bare format word was left out because three game releases use
it as a tag. Stash held 5 scenes with the VR tag.

A titled release with a tag list is **not** also matched on its free-text words. The
title text of a tagged release can contain a hide word without being that kind, and
the tag list is the more precise of the two.

## The file

`plab-exclude` keeps its format. Every line before the first section header is still
a case-insensitive regex, as today. The file gains two optional sections:

```
<regex>
<regex>

[hide]
<term>
<term>

[keep]
<term>
...
```

A line is a section header only if, once trimmed, it is exactly `[hide]`, `[keep]` or
`[always]`.
Any other line starting with `[` is still a regex (a character class), so existing
patterns cannot be misread. Blank lines and `#` comments are ignored in every section.
Regex lines after a section header belong to that section, as terms, not patterns.

The current secret has two lines and neither starts with `[`, so the change is
backward compatible.

## Components

### `filters.rs`

- `pub struct Excludes { patterns: Vec<fancy_regex::Regex>, rule: HideRule }`
  replaces `Vec<fancy_regex::Regex>` as what `load_excludes` returns.
- `parse_excludes(text) -> Excludes` is pure, and `load_excludes` keeps its signature
  apart from the return type.
- `Excludes::excluded(&self, title) -> bool` is true if a pattern matches **or**
  `hides(rule, title_terms(title))`. It replaces the free function `excluded`.
- `Excludes::pattern_excluded(&self, title)` applies only the patterns. Album names
  use it (see below).
- `pub fn title_terms(title) -> Terms` gives the tag list if `labels` finds one, and
  otherwise the title's words, as above. `labels` takes a forum argument, but the tag
  parse does not depend on it, so pass `0`. `Terms` is an enum (`Tags(Vec<String>)` /
  `Words(String)`) so that `hides` can apply whole-tag or whole-word matching.
- `pub fn hides(rule, terms: &Terms) -> bool`.

### Call sites

These change mechanically from `&[Regex]` to `&Excludes`, with the same behaviour plus
the rule:

- `tracker/mod.rs`: `top`, `search` and `rows`. This covers the tracker lists and the
  live search (`plab.rs::run_search`).
- `curated.rs`: the external indexer pass (`!excluded(excludes, &c.title)`).
- `curated.rs` album pass: switches to `pattern_excluded`. Album names are image-set
  names, not scenes, and the rule was not measured against them.
- The `TrackerApi` fakes in the tests.

### Assistant

- `stash/library.rs`: `FIELDS` asks for `performers { id name gender }`, and the
  performer type gains an `Option<String>` gender.
- `assistant/context.rs`: `gather` loads `Excludes` once (`load_excludes` with the
  configured path, which the assistant's state needs to carry) and drops any
  unwatched scene for which `scene_hidden(&excludes.rule, &LibScene)` is true. That
  happens before `candidates::candidates`.
- `assistant/tools.rs`: `find_stash_scenes` drops hidden scenes the same way before
  it builds its JSON. `search_lists` reads the listings, which the refresh has
  already filtered.
- `scene_hidden` lives in `filters.rs` next to `hides`, so both rules sit together and
  `candidates.rs` stays pure and unaware of the rule.

The taste profile is not filtered. It describes what was actually watched, and hiding
a scene from suggestions does not change that history.

## Behaviour notes

- Listings re-read the exclude file on every page load (web.rs list), so listings pick up a secret change at once, and the Assistant picks it up because the secret's `restartUnits` restarts plab; the refresh also stops listing hidden releases.
- A bad term cannot fail: terms are plain strings, not regexes.
- The rule applies wherever the exclude list applies today, which includes the Games
  section. The whole-tag match is what keeps games visible, as measured above. Nothing
  in the rule is specific to a forum.

## Testing

Unit tests in `filters.rs` use placeholder words:

- Section parsing: regex lines before `[hide]` stay patterns; `[a-z]foo` stays a
  pattern; a file with no sections gives an empty rule.
- `hides` in tag mode: a hide tag hides; a hide tag plus a keep tag does not; a
  compound tag `hide/other` does not; matching is case-insensitive.
- `hides` in word mode: a whole word hides; a substring inside a word does not; a
  multi-word term matches.
- `title_terms` chooses tags when a tag list exists and words otherwise.
- `scene_hidden`: a hide tag hides; a keep tag keeps; a listed `MALE` performer keeps
  even with no keep tag; an empty cast does not keep.
- The existing `load_excludes_*` tests keep passing with `Excludes::excluded`.

There is also an existing context or tool test with a mocked Stash response. It
should be extended so that a scene with a hide tag is absent from the candidates and
from the `find_stash_scenes` output.

**Verification before deploy:** run the rule, with the real secret's terms, over a
copy of `state.db` and the Stash scene dump from galactica. The release and scene
counts should match the measurements above: the 22 tagged hides plus the solos are
hidden, the pack and the ambiguous release are kept, and no game and no Stash scene
listing a man is hidden. Once deployed, the `[hide]`/`[keep]` sections are added to
the secret.
