# plab Stash links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A download's status badge on the plab page (cards and Recent grabs) links to its
Stash scene, or, for a multi-scene pack, to Stash's scene search by the pack's folder.

**Architecture:** `provenance::status` records the linked scene ids and their shared
folder on the `InStash` and `Identified` statuses. A pure `provenance::stash_link` turns
a status plus the browser-facing Stash address into a URL. The page carries that address
in `Downloads` and renders a linked badge as an `<a>`.

**Tech Stack:** Rust (axum, serde_json, form_urlencoded), `packages/plab`. NixOS module
`modules/hosts/galactica/services/plab/default.nix`.

**Spec:** `docs/superpowers/specs/2026-11-02-plab-stash-links-design.md`

## Global Constraints

- Work on `master`, no branches or worktrees. Conventional commits with scope `galactica`.
  Never mention Claude. Never `git stash`; stage files by explicit path (another session
  may have uncommitted work in this checkout).
- From `packages/plab`: `cargo test` must pass (574 at the start). `cargo clippy
  --all-targets -- -D warnings` may show only the 3 pre-existing `collapsible_if` errors
  in `src/identify/matching.rs`.
- Single scene: `{base}/scenes/{id}`. Pack: `{base}/scenes?q={folder}`, with the folder
  encoded as a query value. `base` has trailing `/` trimmed. An empty base gives no link.
- Only `InStash` and `Identified` link. Failed, queued, downloading and added never do.
- The env var is `PLAB_STASH_WEB_URL`. The module sets it to `https://stash.${vars.domain}`.
  `PLAB_STASH_URL` (GraphQL) is unchanged.
- The golden pages (`tests/fixtures/golden_page*.html`) stay byte-identical. Never edit
  the fixtures.

---

## File Structure

| File | Change |
|---|---|
| `src/provenance.rs` | `Status::InStash { scenes, folder }`, `Identified` gains `scenes`, `folder`; `shared_folder`; `stash_link` |
| `src/provenance_tests.rs` | tests for the above; update existing `Status` literals |
| `src/page.rs` | `Downloads.stash`; `status_badge(s, link)`; linked badges in cards and grabs |
| `src/page_tests.rs` | badge tests; update `Status` literals |
| `src/config.rs` | `stash_web_url: Option<String>` from `PLAB_STASH_WEB_URL` |
| `src/web.rs`, `src/web_tests.rs`, `src/commands.rs` | `WebState.stash_web_url`, passed into `Downloads` |
| `modules/hosts/galactica/services/plab/default.nix` | export `PLAB_STASH_WEB_URL` |

---

### Task 1: Statuses carry their scenes, and `stash_link`

**Files:**
- Modify: `packages/plab/src/provenance.rs` (`Status` ~line 158, `status` ~175-232)
- Modify: `packages/plab/src/provenance_tests.rs` (`status_tests`, Identified literals ~300 and ~339, InStash ~361)
- Modify: `packages/plab/src/page.rs` and `packages/plab/src/page_tests.rs`, only so they compile with the new variant shapes (match arms `Status::InStash { .. }`, `Status::Identified { label, more, guess, .. }`; literals gain `scenes: vec![], folder: None`)

**Interfaces:**
- Produces:
  - `Status::InStash { scenes: Vec<String>, folder: Option<String> }`
  - `Status::Identified { label: String, more: usize, guess: bool, scenes: Vec<String>, folder: Option<String> }`
  - `pub fn shared_folder(paths: &[&str]) -> Option<String>`
  - `pub fn stash_link(base: &str, status: &Status) -> Option<String>`

- [ ] **Step 1: Write the failing tests** (in `provenance_tests.rs`, a new submodule)

```rust
mod link_tests {
    use super::*;

    fn in_stash(scenes: &[&str], folder: Option<&str>) -> Status {
        Status::InStash {
            scenes: scenes.iter().map(|s| s.to_string()).collect(),
            folder: folder.map(str::to_string),
        }
    }

    #[test]
    fn shared_folder_is_the_deepest_common_directory() {
        assert_eq!(
            shared_folder(&["Studio A/Rel/a.mp4", "Studio A/Rel/b.mp4"]),
            Some("Rel".into())
        );
        assert_eq!(
            shared_folder(&["Studio A/Rel/x/a.mp4", "Studio A/Rel/y/b.mp4"]),
            Some("Rel".into())
        );
        assert_eq!(shared_folder(&["Rel/a.mp4"]), Some("Rel".into()));
        assert_eq!(shared_folder(&["a.mp4", "b.mp4"]), None);
        assert_eq!(shared_folder(&["A/a.mp4", "B/b.mp4"]), None);
        assert_eq!(shared_folder(&[]), None);
    }

    #[test]
    fn one_scene_links_to_the_scene() {
        assert_eq!(
            stash_link("https://stash.example/", &in_stash(&["42"], Some("Rel"))),
            Some("https://stash.example/scenes/42".into())
        );
    }

    #[test]
    fn a_pack_links_to_a_search_by_its_folder() {
        let s = Status::Identified {
            label: "T".into(),
            more: 1,
            guess: false,
            scenes: vec!["1".into(), "2".into()],
            folder: Some("Jane & Joe Pack".into()),
        };
        assert_eq!(
            stash_link("https://stash.example", &s),
            Some("https://stash.example/scenes?q=Jane+%26+Joe+Pack".into())
        );
    }

    #[test]
    fn no_link_without_a_folder_base_or_linkable_status() {
        assert_eq!(stash_link("https://s", &in_stash(&["1", "2"], None)), None);
        assert_eq!(stash_link("", &in_stash(&["1"], None)), None);
        for s in [
            Status::Queued,
            Status::Downloading(5),
            Status::Added,
            Status::Failed(Failure::Lost),
        ] {
            assert_eq!(stash_link("https://s", &s), None, "{s:?}");
        }
    }
}
```

In `status_tests`, extend the two existing `Identified` expectations and the `in_stash`
test so they assert the new fields. In `identified_with_more_and_guess` the linked files'
paths are `p1` and `p2` (the `file` helper names them `p<scene>`); expect
`scenes: vec!["1".into(), "2".into()], folder: None` (no shared directory). For
`in_stash`, expect `Status::InStash { scenes: vec!["1".into()], folder: None }`. Add:

```rust
    #[test]
    fn scenes_and_folder_come_from_linked_files_only() {
        let mut a = file(Some("1"), None, None);
        a.path = "Studio A/Rel/a.mp4".into();
        let mut b = file(Some("2"), None, None);
        b.path = "Studio A/Rel/b.mp4".into();
        let mut nfo = file(None, None, None);
        nfo.path = "Studio A/Other/x.nfo".into();
        let d = synced(vec![a, b, nfo]);
        assert_eq!(
            status(&d, None, NOW),
            Status::InStash {
                scenes: vec!["1".into(), "2".into()],
                folder: Some("Rel".into())
            }
        );
    }
```

Read the test module first and adapt the expectations to how the existing tests build
their rows (the `file` and `synced` helpers); keep each assertion's intent.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test provenance 2>&1 | tail -15`
Expected: compile errors (no `shared_folder`, `stash_link`, unit variant `InStash`).

- [ ] **Step 3: Implement** (`provenance.rs`)

```rust
#[derive(Debug, Clone, PartialEq)]
pub enum Status {
    Queued,
    Downloading(u8),
    /// In Transmission or finished, no scene yet.
    Added,
    InStash {
        scenes: Vec<String>,
        folder: Option<String>,
    },
    Identified {
        label: String,
        more: usize,
        guess: bool,
        scenes: Vec<String>,
        folder: Option<String>,
    },
    Failed(Failure),
}

/// The last component of the deepest directory every path is under, or None when they
/// share none (or there are no paths). "Studio A/Rel/a.mp4" and "Studio A/Rel/b.mp4"
/// share "Rel".
pub fn shared_folder(paths: &[&str]) -> Option<String> {
    let dirs: Vec<Vec<&str>> = paths
        .iter()
        .map(|p| {
            let mut parts: Vec<&str> = p.split('/').collect();
            parts.pop(); // the file name
            parts
        })
        .collect();
    let first = dirs.first()?;
    let depth = (0..first.len())
        .take_while(|&i| dirs.iter().all(|d| d.get(i) == first.get(i)))
        .count();
    depth.checked_sub(1).map(|i| first[i].to_string())
}

/// Where a download's scenes are in Stash's web UI, at `base`: the scene, or for several,
/// Stash's scene search by their shared folder name (which Stash matches against paths).
/// Only statuses with scenes link.
pub fn stash_link(base: &str, status: &Status) -> Option<String> {
    let base = base.trim_end_matches('/');
    if base.is_empty() {
        return None;
    }
    let (Status::InStash { scenes, folder } | Status::Identified { scenes, folder, .. }) =
        status
    else {
        return None;
    };
    match (scenes.as_slice(), folder) {
        ([one], _) => Some(format!("{base}/scenes/{one}")),
        ([_, _, ..], Some(folder)) => {
            let q: String = form_urlencoded::byte_serialize(folder.as_bytes()).collect();
            Some(format!("{base}/scenes?q={q}"))
        }
        _ => None,
    }
}
```

In `status`, compute both once from `linked` (which `status` already builds) and use
them in the two variants:

```rust
    let scenes: Vec<String> = linked.iter().filter_map(|f| f.scene_id.clone()).collect();
    let folder = shared_folder(&linked.iter().map(|f| f.path.as_str()).collect::<Vec<_>>());
```

```rust
        return Status::Identified {
            label: …unchanged…,
            more: linked.len() - 1,
            guess: linked.iter().any(|f| outcome(f) == Some("llm")),
            scenes,
            folder,
        };
    }
    if !linked.is_empty() {
        return Status::InStash { scenes, folder };
    }
```

Place the two `let`s after the `Failed(Identify)` early return and before the
`Identified` check. In `page.rs` change the arms to `Status::InStash { .. }` and
`Status::Identified { label, more, guess, .. }`. In `page_tests.rs`, make the
`Status::InStash` and `Status::Identified { … }` literals compile with
`scenes: vec![], folder: None` (for `InStash`: `Status::InStash { scenes: vec![], folder: None }`).

- [ ] **Step 4: Run all tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass. The golden tests are untouched.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/provenance.rs packages/plab/src/provenance_tests.rs packages/plab/src/page.rs packages/plab/src/page_tests.rs
git commit -m "feat(galactica): plab statuses carry their stash scenes and a link to them"
```

---

### Task 2: Linked badges on the page

**Files:**
- Modify: `packages/plab/src/config.rs` (struct ~line 23, `from_env` ~52, tests ~103/162)
- Modify: `packages/plab/src/page.rs` (`Downloads`, `status_badge` ~120, `grabs_strip` ~165, `card` ~192, `render` ~528)
- Modify: `packages/plab/src/web.rs` (`WebState`, `downloads()`), `packages/plab/src/commands.rs` (`WebState {` ~190)
- Modify: `packages/plab/src/page_tests.rs`, `packages/plab/src/web_tests.rs` (`WebState {` ~184)
- Modify: `modules/hosts/galactica/services/plab/default.nix` (the `plab` wrapper's exports)

**Interfaces:**
- Consumes: `provenance::stash_link(base, &Status) -> Option<String>` (Task 1).
- Produces: `Downloads { by_topic, grabs, stash: Option<String> }`; `status_badge(s: &Status, link: Option<&str>) -> String`; `Config.stash_web_url: Option<String>`; `WebState.stash_web_url: Option<String>`.

- [ ] **Step 1: Write the failing tests**

`config.rs` tests: in the test that sets every variable (the one asserting
`c.stash_url == "http://stash/graphql"`), add `("PLAB_STASH_WEB_URL", "https://stash.example")`
and assert `c.stash_web_url.as_deref() == Some("https://stash.example")`. In the defaults
test, assert `c.stash_web_url == None`.

`page_tests.rs` (`status_tests` module):

```rust
    #[test]
    fn a_linked_badge_is_an_anchor() {
        let b = status_badge(
            &Status::InStash { scenes: vec!["42".into()], folder: None },
            Some("https://s/scenes?q=a&b"),
        );
        assert!(b.starts_with(r#"<a class="status badge"#), "{b}");
        assert!(b.contains(r#"href="https://s/scenes?q=a&amp;b""#), "{b}");
        assert!(b.contains(r#"target="_blank" rel="noreferrer""#), "{b}");
        assert!(b.contains(r#"title="Open in Stash""#), "{b}");
        assert!(b.contains(">in Stash</a>"), "{b}");
        let plain = status_badge(&Status::Added, None);
        assert!(plain.starts_with("<span"), "{plain}");
    }

    #[test]
    fn cards_and_grabs_link_when_stash_is_configured() {
        let one = Status::InStash { scenes: vec!["42".into()], folder: None };
        let downloads = Downloads {
            by_topic: HashMap::from([(1, one.clone())]),
            grabs: vec![(grab(2, "StudioA E1"), one)],
            stash: Some("https://stash.example".into()),
        };
        let out = super::render(
            &listing(ADDED, vec![tp(1, "[S.com] A - B")]),
            &set(&[1]),
            &set(&[]),
            ADDED + 7200,
            None,
            Section::Video,
            &downloads,
        );
        assert_eq!(out.matches(r#"href="https://stash.example/scenes/42""#).count(), 2);
    }
```

Update the existing `status_badge(&…)` calls in that module to pass `None` as the second
argument, and the existing `Downloads { … }` literals to add `stash: None`.

`web_tests.rs`: extend `a_downloading_topic_shows_its_progress`'s pattern in a new test.
The listed topic's download has one linked scene and the state's `stash_web_url` is
`Some("https://stash.example".into())`:

```rust
#[tokio::test]
async fn a_downloaded_topic_links_to_its_stash_scene() {
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.stash_web_url = Some("https://stash.example".into());
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    let id = fx.state.db.mark_added(crate::db::NewDownload {
        source: "plab",
        topic_id: Some(1),
        release_title: "Fresh Apple",
        section: Section::Video,
        download_dir: Some("/vault"),
        torrent_hash: Some("abc"),
        now: now(),
    })
    .unwrap();
    fx.state.db.save_files(id, &["Rel/a.mp4".into()]).unwrap();
    fx.state.db.link_scene("Rel/a.mp4", Some("42")).unwrap();
    let r = fx.get("/").await;
    assert!(r.text().contains(r#"href="https://stash.example/scenes/42""#), "{}", r.text());
}
```

(`save_files` records the paths and marks the download synced; `Section::Video` makes it
a row `download_rows` returns.)

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test 2>&1 | tail -15`
Expected: compile errors (`stash_web_url`, `Downloads.stash`, two-argument `status_badge`).

- [ ] **Step 3: Implement**

`config.rs`: field `pub stash_web_url: Option<String>,` (next to `stash_url`), and in
`from_env`: `stash_web_url: var("PLAB_STASH_WEB_URL"),`.

`page.rs`:

```rust
/// What became of the downloads the page shows: plab's by topic, and recent grabs.
#[derive(Debug, Default)]
pub struct Downloads {
    pub by_topic: HashMap<u64, Status>,
    pub grabs: Vec<(DownloadRow, Status)>,
    /// Stash's web address, for links to a download's scenes; None renders no links.
    pub stash: Option<String>,
}

impl Downloads {
    fn link(&self, s: &Status) -> Option<String> {
        provenance::stash_link(self.stash.as_deref()?, s)
    }
}
```

`status_badge(s: &Status, link: Option<&str>) -> String`: keep the match, then:

```rust
    let class = format!("status badge {color} badge-sm max-w-full truncate");
    match link {
        Some(href) => format!(
            r#"<a class="{class}" href="{}" target="_blank" rel="noreferrer" title="Open in Stash">{}</a>"#,
            e(href),
            e(&text)
        ),
        None => format!(r#"<span class="{class}"{tip}>{}</span>"#, e(&text)),
    }
```

(`tip` is only ever set for failures, which never link.) Make sure the unlinked `<span>`
output is byte-identical to before.

Thread the link: `card` already receives `status: Option<&Status>`. Give it
`link: Option<&str>` too, and render `status.map(|s| status_badge(s, link))`. In `render`,
compute it per card as
`let st = downloads.by_topic.get(&t.topic.row.id); let link = st.and_then(|s| downloads.link(s));`
and pass `link.as_deref()`. `grabs_strip` takes `&Downloads` (or the grabs plus the
`Downloads`) and calls `status_badge(s, downloads.link(s).as_deref())`. Import
`crate::provenance` as needed.

`web.rs`: `WebState` gains `pub stash_web_url: Option<String>,`. In `downloads()`, start
from `Downloads { stash: st.stash_web_url.clone(), ..Downloads::default() }`, including
on the early-return error path.

`commands.rs`: in `serve`'s `WebState { … }`, `stash_web_url: a.cfg.stash_web_url.clone(),`.
`web_tests.rs`'s `Fx::with` `WebState { … }`: `stash_web_url: None,`.

`default.nix`, in the `plab` wrapper next to `PLAB_PROWLARR_URL`:

```nix
        # Where the browser reaches Stash (the page links downloads to their scenes);
        # the daemon itself talks to Stash on localhost.
        export PLAB_STASH_WEB_URL="https://stash.${vars.domain}"
```

- [ ] **Step 4: Run all tests and clippy**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"; cargo clippy --all-targets -- -D warnings 2>&1 | grep -E "^error" | sort | uniq -c`
Expected: all pass, including the three golden tests; clippy shows only the 3 known
`collapsible_if` errors. Also `cd ../.. && nix develop -c just fmt` (alejandra on the
.nix file).

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/config.rs packages/plab/src/page.rs packages/plab/src/page_tests.rs packages/plab/src/web.rs packages/plab/src/web_tests.rs packages/plab/src/commands.rs modules/hosts/galactica/services/plab/default.nix
git commit -m "feat(galactica): plab badges link a download to its stash scenes"
```
