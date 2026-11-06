# plab assistant: searching the tracker and Prowlarr

## Goal

The assistant can only search what plab already holds: `search_lists` filters the
releases on the Video and Indexers lists, `find_stash_scenes` searches the Stash library.
Asked for something that is on neither, it has nothing to offer. The UI search box
already queries the tracker live (`plab::run_search`); the assistant should be able to do
the same, and also search the other indexers through Prowlarr, and pick what it finds
the way it picks anything else: a card with Stream and Download buttons.

Success: in a chat, "find me X" returns cards for releases that were on no list, from the
tracker and from other indexers, and those cards stay in the conversation forever.

## Decisions

| Question | Answer |
|---|---|
| Sources | Tracker and Prowlarr, in one tool |
| Where a search-hit card's data lives | In the stored tool result. No new table |
| How long a card is shown | Forever, like the rest of the transcript |
| How long its buttons work | While its search hit is fresh (`SEARCH_TTL`, 24 h); after that the card says the result expired |
| Classifier for Prowlarr hits | Not run. The assistant is the judge; the exclude list and hide rule still apply |

## The tool: `search_releases(q)`

Added to `assistant/tools.rs` beside the existing three. Description for the model:
"Search the tracker and other indexers for releases not on plab's lists. Returns refs
usable as stream or download picks." Arguments are the same `{"q": string}` as the other
search tools, through the existing `query` helper.

Result, as the JSON string every tool returns:

```json
{"results": [{"ref": "t:123", "title": "…", "source": "tracker", "size": 1234,
              "seeders": 10, "leechers": 2, "published": 1762300000}],
 "errors": ["Prowlarr: …"]}
```

`source` is `"tracker"` or the Prowlarr indexer's name. `errors` is omitted when empty. At
most 20 results (`LIMIT`): tracker hits first, in the tracker's order, then Prowlarr hits
by seeders. One half failing never fails the other; both failing is
`{"results": [], "errors": [...]}`, which the model reads like any tool error.

**Tracker half.** `plab::run_search` as the search box calls it: one results page, the
exclude list applied by the tracker search, rows saved with `save_search` (topic row plus
`search_hit`). The hide rule (`filters`) is applied to the titles before they are
returned, as `find_stash_scenes` does for scenes.

**Prowlarr half.** The curated job's steps, without classification and without the
`WINDOW_DAYS` age cutoff (a search is asking for anything, not what is new):

1. Enabled torrent indexers except `sources.primary_indexer`; none left is an error for
   this half only.
2. `prowlarr.search_in(q, &sources.categories, &ids)`; no categories is an error for this
   half only.
3. `candidate` (torrent protocol only), the exclude list, `collapse` by `sources.noise`.
4. Drop anything `is_duplicate` against this search's tracker titles.
5. Each survivor: `upsert_external` (kind `Torrent`) for its id, then a topic row
   (forum 0, the candidate's title/size/seeders/leechers/published) and a `search_hit`,
   so `db.find` resolves it exactly as it resolves a tracker search hit. `add_topic` and
   the streamer already route external ids through `external_torrent`.

Prowlarr not configured: the tracker half alone, with no error entry; that is a
configuration, not a failure.

`candidate` is private to `curated.rs` today; it becomes `pub(crate)`. The step list is
small enough to write in the tool's module rather than factor out of the curated job,
whose loop interleaves classification and Stash scene matching the tool does not want.

**What never goes in the result:** Prowlarr's `download_url`. It embeds Prowlarr's API
key, and the tool result is sent to OpenRouter and stored in the transcript. It stays in
`external_release.link`, where `external_torrent` already reads it.

## Wiring

Turns run on detached `'static` tasks (`web/assistant_routes.rs`, and the daily
generation in `Assistant::ensure_daily`), so the tool cannot borrow `Ctx`. The
`Assistant` instead owns a search handle, built in `app.rs` where the tracker, Prowlarr,
`Db`, sources, exclude and filter paths are all owned:

```rust
pub trait ReleaseSearch: Send + Sync {
    fn search<'a>(&'a self, q: &'a str, now: i64)
        -> Pin<Box<dyn Future<Output = Value> + Send + 'a>>;
}
```

`Assistant::with_search(Arc<dyn ReleaseSearch>)`, in the style of `with_hide`. Without
one (tests that do not need it), `search_releases` is left out of `definitions()`, so the
model is never offered a tool that cannot run. `tools::run` gains an
`Option<&dyn ReleaseSearch>` parameter.

## Cards from the tool result

`conversation_dto` (`web/assistant_routes.rs`) resolves `t:` picks through
`resolve_topics`, which only finds releases on an advisable list, and drops the rest. It
gains a fallback: a picked `t:` ref that did not resolve is looked up in the
conversation's own `search_releases` tool results, the most recent one holding that ref
winning. The transcript already holds those messages (`role = 'tool'`); the tool-call
message names the function, the tool message carries the result by `tool_call_id`.

A card built this way is a snapshot: title, source, size, seeders and leechers as of the
search. Its `PickedTopic` holds a `TopicDto` built from that snapshot (or, while the hit is
fresh, from `api::topic` over the stored topic row), `section: "video"`, and
whether its buttons work:

- `db.find(id, now)` resolves it: buttons as for any release, with the usual
  added/queued/downloading status from `api::topic`.
- It does not (the `search_hit` expired, and the topic row was pruned with it): the card
  shows "Search result expired, search again" in place of its buttons.

The pick cards (`ui/src/components/Picks.svelte`) gain that one state; nothing else in the UI changes.

## Error handling

- Tracker search failure (login, captcha, network): an entry in `errors`, the Prowlarr
  half still returned.
- Prowlarr failure, per indexer list or search: an entry in `errors`.
- `upsert_external` or `save_search` failure: the tool's whole result is `{"error": …}`
  as today, because a hit that was not stored cannot be picked.
- A stored tool result that fails to parse: skipped by the fallback, and the pick is
  dropped as an unresolved pick is today (with its `debug` log).

## Not in scope

- Keeping an expired card actionable (re-registering the hit from the stored result).
  Possible for tracker hits; Prowlarr hits would need a re-search. Revisit if old chats
  turn out to matter.
- Images and thumbnails for search-hit cards.
- Stash scene matching for Prowlarr hits.

## Testing

- `assistant/tools.rs`: with a fake `ReleaseSearch`, `search_releases` is offered only
  when one is set, and its result is passed through unchanged.
- The real `ReleaseSearch` against a fake tracker and wiremocked Prowlarr: a tracker hit,
  a Prowlarr hit stored as external + topic + `search_hit` and resolvable by `db.find`,
  a Prowlarr hit dropped as a duplicate of a tracker hit, the exclude list and hide rule
  applied, one half failing with the other returned, no `download_url` in the output.
- `web_tests`: a conversation whose pick names a ref only a stored `search_releases`
  result holds renders that card; after `SEARCH_TTL` it still renders, marked expired.
