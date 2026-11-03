# plab: link downloads to their Stash scenes

Date: 2026-11-02. Builds on `2026-11-02-plab-provenance-identify-design.md`, which links
each Vault download to the Stash scenes its files became (`download_file.scene_id`) and
shows a status badge for it on the plab page.

## Goal

A download whose files are in Stash links to them. The status badge on its card, and
its row in Recent grabs, opens Stash in a new tab.

- **One scene:** the scene itself, `{stash}/scenes/{id}`.
- **Several scenes (a pack):** Stash's scene list searched by the pack's folder name,
  `{stash}/scenes?q="{folder}"`. Stash's scene search matches folder paths, so every scene
  of the pack is listed. The folder is quoted as a phrase because the search has its own
  grammar (words are ANDed, `-word` excludes, `OR` alternates), which would otherwise
  mangle names like `Jane - Title -Uncut`. A folder containing `"` cannot be quoted and
  gets no link. A different scene sharing that folder name would be listed too,
  which is acceptable for release folder names.

Stash's exact path filter (`/scenes?c=(…)`) is not used. Its URL encoding is internal
to Stash's UI, has changed between versions, and cannot be checked by plab's tests.

## Configuration

`PLAB_STASH_WEB_URL` is the address the browser reaches Stash at. The NixOS module sets
it to `https://stash.${vars.domain}`, which is behind the same Authelia gateway as plab.
When it is unset, no links are rendered. `PLAB_STASH_URL` (the GraphQL endpoint the
daemon uses, `localhost:9999`) is unchanged; it is not reachable from a browser.

## Data

`Status::InStash` and `Status::Identified` gain:

- `scenes: Vec<String>`: the linked scene ids, in `download_file.path` order, each once
  (two files on the same scene count as one scene).
- `folder: Option<String>`: the last component of the deepest directory shared by the
  linked files' library-relative paths. It is `None` when the linked files share no
  directory, for example two files at the library root. It is never empty.

Both come from the `download_file` rows `download_rows` already loads, so the page makes
no new queries.

## Link

`provenance::stash_link(base: &str, status: &Status) -> Option<String>`, which returns:

1. `None` unless the status is `InStash` or `Identified`, or when `base` is empty.
2. `{base}/scenes/{id}` for exactly one scene.
3. `{base}/scenes?q="{folder}"`, with the quoted folder percent-encoded as a query
   value, for several scenes that share a folder; `None` when the folder contains `"`.
4. `None` otherwise.

`base` has any trailing `/` trimmed.

## Page

`status_badge` takes the link. With one, the badge is an
`<a class="status badge …" href="…" target="_blank" rel="noreferrer" title="Open in Stash">`
with the same text and styling. Without one, it stays a `<span>`. Failed, queued,
downloading and added badges never link. The cards and the Recent grabs rows both use
it. The golden pages stay byte-identical: they render no statuses.

`WebState` gains `stash_web_url: Option<String>`, filled from the config.

## Testing

- `stash_link`:
  - one scene
  - a pack, including a folder name that needs encoding (spaces, `&`) or that holds
    search syntax (` - `, `-Uncut`), and one containing `"` (no link)
  - linked files with no shared folder
  - empty base, and a base with a trailing `/`
  - each unlinked status
- `status`: `scenes` and `folder` are filled from linked files only (an unlinked `.nfo`
  is ignored), and the shared folder of `Studio A/Rel/a.mp4` and `Studio A/Rel/b.mp4`
  is `Rel`.
- `status_badge`: an `<a>` with an escaped `href` when there is a link, a `<span>`
  without.
- Web: with `stash_web_url` set, a card whose download has one linked scene carries
  `href="https://stash.example/scenes/42"`; with it unset, no `href` to Stash appears.
- Config: `PLAB_STASH_WEB_URL` is read, and unset means `None`.
