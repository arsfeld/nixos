# plab assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An on-demand Recommend button and a chat in plab that suggest what to watch (unwatched Stash scenes) and what to stream or download (releases on plab's lists), from recent views.

**Architecture:** Rust builds a taste profile from Stash play history plus a new plab stream log (`taste.rs`), and a prefiltered candidate set (`candidates.rs`). `assistant/` runs an OpenRouter tool-calling loop with read-only tools and stores every conversation in `state.db`. `web/assistant_routes.rs` serves it as JSON, resolving picks to the same card DTOs the lists use. A Svelte `/assistant` view renders transcripts with existing `Card`s and a new `SceneCard`.

**Tech Stack:** Rust (tokio, axum, rusqlite, reqwest, serde, chrono, wiremock for tests), Svelte 5 + TypeScript + vitest + daisyUI, OpenRouter chat completions with tools, Stash GraphQL.

**Spec:** `docs/superpowers/specs/2026-11-03-plab-assistant-design.md`

## Global Constraints

- Work on `master` directly; never branch or use worktrees. Commit after each task.
- Conventional commits: `feat(galactica): plab …` / `test(galactica): …` / `docs(galactica): …`. Never mention Claude.
- **No NSFW names or terms anywhere in the repo**: code, comments, tests, fixtures, commit messages. Test data uses neutral made-up names ("Studio A", "Performer B", "Alpha One"). Content-specific prompt text lives only in the `plab-site` secret.
- Run Rust commands from `packages/plab`: `cargo test`, `cargo clippy --all-targets -- -D warnings`. UI from `packages/plab/ui`: `npm test`, `npm run check`.
- New files are invisible to `nix build` until `git add`ed.
- Never hand-roll a third copy of near-duplicate code; factor a helper.
- Constants (exact values): view half-life 30 days; profile caps 15 per list; 20 recent lines in the prompt; plays looked back 60 days; candidates 25 per pool, 40 total; 6 tool rounds; stream-view dedupe window 6 hours; request body cap 16 KB (16384 bytes); chat title truncated to 60 characters; recommend title `Recommendations · <YYYY-MM-DD>`.
- `PLAB_ASSISTANT_MODEL` defaults to the parse model's value (`PLAB_PARSE_MODEL`, itself defaulting to `~deepseek/deepseek-flash-latest`).
- The model only advises: no tool may add, queue or stream anything.

## File map

| File | Responsibility |
|---|---|
| `src/db/schema_v7.sql` (new) | `stream_view`, `conversation`, `message` |
| `src/db/mod.rs` | v7 migration; stream-view and conversation methods |
| `src/web.rs` | record stream views; body + DELETE plumbing; `assistant` field; dispatch to routes |
| `src/taste.rs` (new) | pure: views → `Profile` |
| `src/candidates.rs` (new) | pure: profile + pools → `Vec<Candidate>` |
| `src/stash/library.rs` (new) | Stash reads: recent plays, unwatched, search, by ids |
| `src/config.rs`, `src/site.rs`, `src/llm.rs` | model setting, `assistant` prompt, raw `chat` call |
| `src/assistant/mod.rs` (new) | `Assistant`, the turn loop, storage of messages |
| `src/assistant/context.rs` (new) | gather views/profile/candidates from DB + Stash |
| `src/assistant/tools.rs` (new) | tool definitions and execution |
| `src/web/assistant_routes.rs` (new) | HTTP routes and transcript DTO |
| `src/app.rs`, `src/commands.rs`, `src/main.rs` | construct and wire the assistant |
| `ui/src/lib/{types,api,route,reducer}.ts`, `ui/src/lib/assistant.ts` (new), `ui/src/lib/assistant.svelte.ts` (new) | client data + store |
| `ui/src/components/{AssistantView,SceneCard}.svelte` (new), `Navbar.svelte`, `App.svelte` | UI |

---

### Task 1: Database v7 and the stream log

**Files:**
- Create: `packages/plab/src/db/schema_v7.sql`
- Modify: `packages/plab/src/db/mod.rs` (constants near line 90; `migrate` near line 270; new methods in `impl Db`; tests in `mod tests` at the bottom)
- Modify: `packages/plab/src/web.rs` (the `(Method::POST, StreamRoute::Topic(t))` arm, near line 213)

**Interfaces:**
- Produces (in `crate::db`):
  - `pub const STREAM_VIEW_GAP: i64 = 6 * 3600;`
  - `pub struct ConversationRow { pub id: i64, pub title: String, pub kind: String, pub created_at: i64, pub updated_at: i64 }` (derive `Debug, Clone, PartialEq`)
  - `pub struct MessageRow { pub seq: i64, pub role: String, pub content: String, pub at: i64 }` (same derives)
  - `Db::record_stream_view(&self, topic_id: u64, now: i64) -> Result<bool>` (true = recorded)
  - `Db::stream_views(&self, since: i64) -> Result<Vec<(u64, i64)>>` (topic id, started_at; newest first)
  - `Db::create_conversation(&self, title: &str, kind: &str, now: i64) -> Result<i64>`
  - `Db::conversations(&self) -> Result<Vec<ConversationRow>>` (newest `updated_at` first)
  - `Db::conversation(&self, id: i64) -> Result<Option<ConversationRow>>`
  - `Db::delete_conversation(&self, id: i64) -> Result<bool>` (true = existed)
  - `Db::append_message(&self, conversation: i64, role: &str, content: &str, now: i64) -> Result<i64>` (returns the new seq; bumps `updated_at`)
  - `Db::messages(&self, conversation: i64) -> Result<Vec<MessageRow>>` (by seq ascending)
  - `Db::delete_messages_from(&self, conversation: i64, seq: i64) -> Result<()>` (deletes seq >= `seq`)

- [ ] **Step 1: Write the schema**

`src/db/schema_v7.sql`:

```sql
-- One row per stream started from the page's Stream button. Streams never reach Stash, so
-- without this a streamed-but-never-downloaded release is invisible to the assistant.
CREATE TABLE stream_view (
  id INTEGER PRIMARY KEY,
  topic_id INTEGER NOT NULL,       -- tracker topic or external_release id
  started_at INTEGER NOT NULL
);
CREATE INDEX stream_view_topic ON stream_view(topic_id, started_at);
CREATE INDEX stream_view_at ON stream_view(started_at);

-- The assistant's conversations (design: 2026-11-03-plab-assistant-design.md).
CREATE TABLE conversation (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  kind TEXT NOT NULL,              -- 'recommend' | 'chat'
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- The full transcript as OpenRouter message objects (JSON), system context and tool calls
-- included, so a conversation resumes exactly as the model last saw it. Keys starting
-- with plab_ are plab's own and are stripped before sending.
CREATE TABLE message (
  id INTEGER PRIMARY KEY,
  conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  role TEXT NOT NULL,              -- 'system' | 'user' | 'assistant' | 'tool'
  content TEXT NOT NULL,
  at INTEGER NOT NULL,
  UNIQUE (conversation_id, seq)
);
```

- [ ] **Step 2: Write the failing tests** (append inside `mod tests` in `src/db/mod.rs`; use the module's existing `Db::open_in_memory()`)

```rust
#[test]
fn stream_views_dedupe_within_gap() {
    let db = Db::open_in_memory().unwrap();
    assert!(db.record_stream_view(7, 1_000).unwrap());
    assert!(!db.record_stream_view(7, 1_000 + STREAM_VIEW_GAP - 1).unwrap());
    assert!(db.record_stream_view(7, 1_000 + STREAM_VIEW_GAP).unwrap());
    assert!(db.record_stream_view(8, 1_001).unwrap());
    assert_eq!(
        db.stream_views(0).unwrap(),
        vec![(7, 1_000 + STREAM_VIEW_GAP), (8, 1_001), (7, 1_000)]
    );
    assert_eq!(db.stream_views(1_001).unwrap().len(), 2);
}

#[test]
fn conversations_round_trip() {
    let db = Db::open_in_memory().unwrap();
    let a = db.create_conversation("first", "chat", 10).unwrap();
    let b = db.create_conversation("second", "recommend", 20).unwrap();
    assert_eq!(db.append_message(a, "user", r#"{"role":"user","content":"hi"}"#, 30).unwrap(), 0);
    assert_eq!(db.append_message(a, "assistant", "{}", 31).unwrap(), 1);
    let list = db.conversations().unwrap();
    assert_eq!(list.iter().map(|c| c.id).collect::<Vec<_>>(), vec![a, b]);
    assert_eq!(list[0].updated_at, 31);
    let msgs = db.messages(a).unwrap();
    assert_eq!(msgs.iter().map(|m| (m.seq, m.role.as_str())).collect::<Vec<_>>(), vec![(0, "user"), (1, "assistant")]);
    db.delete_messages_from(a, 1).unwrap();
    assert_eq!(db.messages(a).unwrap().len(), 1);
    assert!(db.delete_conversation(a).unwrap());
    assert!(!db.delete_conversation(a).unwrap());
    assert!(db.messages(a).unwrap().is_empty());
    assert_eq!(db.conversation(b).unwrap().unwrap().kind, "recommend");
    assert!(db.conversation(a).unwrap().is_none());
}
```

Also find the existing migration test that asserts `user_version` (search `user_version` in `mod tests`) and make it expect `7`.

- [ ] **Step 3: Run to verify failure**

Run: `cargo test db::tests::stream_views db::tests::conversations`
Expected: compile errors (`record_stream_view` etc. not found).

- [ ] **Step 4: Implement**

In `src/db/mod.rs`: add `const SCHEMA_V7: &str = include_str!("schema_v7.sql");`, set `USER_VERSION` to `7`, and in `migrate` add after the `from < 6` block:

```rust
    if from < 7 {
        tx.execute_batch(SCHEMA_V7)?;
    }
```

Add the types next to `JobRunRow`, and these methods inside `impl Db`:

```rust
    /// Record that `topic_id` started streaming, unless it already did in the last
    /// `STREAM_VIEW_GAP` seconds: a reopen or a file switch is not a second view.
    pub fn record_stream_view(&self, topic_id: u64, now: i64) -> Result<bool> {
        self.with(|c| {
            let last: Option<i64> = c.query_row(
                "SELECT MAX(started_at) FROM stream_view WHERE topic_id = ?1",
                params![topic_id],
                |r| r.get(0),
            )?;
            if last.is_some_and(|l| now - l < STREAM_VIEW_GAP) {
                return Ok(false);
            }
            c.execute(
                "INSERT INTO stream_view (topic_id, started_at) VALUES (?1, ?2)",
                params![topic_id, now],
            )?;
            Ok(true)
        })
    }

    pub fn stream_views(&self, since: i64) -> Result<Vec<(u64, i64)>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT topic_id, started_at FROM stream_view WHERE started_at >= ?1
                 ORDER BY started_at DESC, id DESC",
            )?;
            let rows = s.query_map(params![since], |r| Ok((r.get(0)?, r.get(1)?)))?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn create_conversation(&self, title: &str, kind: &str, now: i64) -> Result<i64> {
        self.with(|c| {
            c.execute(
                "INSERT INTO conversation (title, kind, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
                params![title, kind, now],
            )?;
            Ok(c.last_insert_rowid())
        })
    }

    pub fn conversations(&self) -> Result<Vec<ConversationRow>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT id, title, kind, created_at, updated_at FROM conversation
                 ORDER BY updated_at DESC, id DESC",
            )?;
            let rows = s.query_map([], conversation_row)?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn conversation(&self, id: i64) -> Result<Option<ConversationRow>> {
        self.with(|c| {
            Ok(c.query_row(
                "SELECT id, title, kind, created_at, updated_at FROM conversation WHERE id = ?1",
                params![id],
                conversation_row,
            )
            .optional()?)
        })
    }

    pub fn delete_conversation(&self, id: i64) -> Result<bool> {
        self.with(|c| Ok(c.execute("DELETE FROM conversation WHERE id = ?1", params![id])? > 0))
    }

    pub fn append_message(&self, conversation: i64, role: &str, content: &str, now: i64) -> Result<i64> {
        self.with(|c| {
            let tx = c.transaction()?;
            let seq: i64 = tx.query_row(
                "SELECT COALESCE(MAX(seq) + 1, 0) FROM message WHERE conversation_id = ?1",
                params![conversation],
                |r| r.get(0),
            )?;
            tx.execute(
                "INSERT INTO message (conversation_id, seq, role, content, at) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![conversation, seq, role, content, now],
            )?;
            tx.execute(
                "UPDATE conversation SET updated_at = ?2 WHERE id = ?1",
                params![conversation, now],
            )?;
            tx.commit()?;
            Ok(seq)
        })
    }

    pub fn messages(&self, conversation: i64) -> Result<Vec<MessageRow>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT seq, role, content, at FROM message WHERE conversation_id = ?1 ORDER BY seq",
            )?;
            let rows = s.query_map(params![conversation], |r| {
                Ok(MessageRow { seq: r.get(0)?, role: r.get(1)?, content: r.get(2)?, at: r.get(3)? })
            })?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn delete_messages_from(&self, conversation: i64, seq: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "DELETE FROM message WHERE conversation_id = ?1 AND seq >= ?2",
                params![conversation, seq],
            )?;
            Ok(())
        })
    }
```

And the row mapper as a free function near `raw_topic`:

```rust
fn conversation_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ConversationRow> {
    Ok(ConversationRow {
        id: r.get(0)?,
        title: r.get(1)?,
        kind: r.get(2)?,
        created_at: r.get(3)?,
        updated_at: r.get(4)?,
    })
}
```

If `with` gives `&mut Connection` (it does), `c.transaction()` works as written.

- [ ] **Step 5: Record stream views** in `src/web.rs`, replacing the `(Method::POST, StreamRoute::Topic(t))` arm:

```rust
        (Method::POST, StreamRoute::Topic(t)) => {
            let r = st
                .streams
                .start(&*st.tracker, st.prowlarr.as_deref(), &st.db, engine, t, now())
                .await;
            // The assistant's view signal for releases that never reach Stash.
            if r.is_ok()
                && let Err(e) = st.db.record_stream_view(t, now())
            {
                info!(job = "web", "stream view {t}: {e:#}");
            }
            started(r)
        }
```

- [ ] **Step 6: Run tests**

Run: `cargo test` — Expected: all pass. Then `cargo clippy --all-targets -- -D warnings` — clean.

- [ ] **Step 7: Commit**

```bash
git add src/db/schema_v7.sql src/db/mod.rs src/web.rs
git commit -m "feat(galactica): plab records stream views and stores conversations"
```

---

### Task 2: Taste profile (`taste.rs`, pure)

**Files:**
- Create: `packages/plab/src/taste.rs`
- Modify: `packages/plab/src/main.rs` (add `mod taste;` in alphabetical order)

**Interfaces:**
- Produces (in `crate::taste`):
  - `pub struct Named { pub name: String, pub id: Option<String> }` (derive `Debug, Clone, PartialEq, Default`)
  - `pub struct View { pub at: i64, pub title: String, pub studio: Option<Named>, pub performers: Vec<Named>, pub tags: Vec<String>, pub o_count: u32, pub rating: Option<u32>, pub streamed: bool }` (derive `Debug, Clone, PartialEq, Default`)
  - `pub struct Weighted { pub name: String, pub id: Option<String>, pub weight: f64 }` (Serialize; `id` is `#[serde(skip)]`)
  - `pub struct Profile { pub studios: Vec<Weighted>, pub performers: Vec<Weighted>, pub tags: Vec<Weighted>, pub recent: Vec<String> }` (derive `Debug, Clone, PartialEq, Default, Serialize`)
  - `pub fn weight(v: &View, now: i64) -> f64`
  - `pub fn profile(views: &[View], now: i64) -> Profile`
  - `pub fn recent(views: &[View], n: usize) -> Vec<String>`
  - consts `HALF_LIFE_DAYS: f64 = 30.0`, `TOP: usize = 15`, `RECENT_LINES: usize = 20`

- [ ] **Step 1: Write the module with its tests first** (tests at the bottom; implementation bodies `todo!()` for this step)

Test block:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = 86400;

    fn named(n: &str) -> Named {
        Named { name: n.into(), id: Some(format!("id-{n}")) }
    }

    fn view(at: i64, studio: &str, performers: &[&str]) -> View {
        View {
            at,
            title: format!("Scene at {at}"),
            studio: Some(named(studio)),
            performers: performers.iter().map(|p| named(p)).collect(),
            ..View::default()
        }
    }

    #[test]
    fn weight_halves_every_thirty_days() {
        let now = 100 * DAY;
        let fresh = weight(&view(now, "A", &[]), now);
        let old = weight(&view(now - 30 * DAY, "A", &[]), now);
        assert!((fresh - 1.0).abs() < 1e-9);
        assert!((old - 0.5).abs() < 1e-9);
    }

    #[test]
    fn o_count_and_rating_boost() {
        let now = 0;
        let mut v = view(0, "A", &[]);
        v.o_count = 2;
        assert!((weight(&v, now) - 2.0).abs() < 1e-9);
        v.rating = Some(90);
        assert!((weight(&v, now) - 3.0).abs() < 1e-9);
    }

    #[test]
    fn profile_merges_case_insensitively_and_sorts() {
        let now = 0;
        let views = vec![
            view(0, "Studio A", &["Performer B"]),
            view(0, "studio a", &["Performer C"]),
            view(0, "Studio D", &["Performer B"]),
        ];
        let p = profile(&views, now);
        assert_eq!(p.studios[0].name, "Studio A");
        assert!((p.studios[0].weight - 2.0).abs() < 1e-9);
        assert_eq!(p.studios[0].id.as_deref(), Some("id-Studio A"));
        assert_eq!(p.performers[0].name, "Performer B");
        assert_eq!(p.performers.len(), 2);
    }

    #[test]
    fn profile_caps_each_list() {
        let views: Vec<View> = (0..20).map(|i| view(0, &format!("S{i}"), &[])).collect();
        assert_eq!(profile(&views, 0).studios.len(), TOP);
    }

    #[test]
    fn recent_lines_newest_first_and_mark_streams() {
        let mut a = view(DAY, "Studio A", &["Performer B", "Performer C"]);
        a.title = "Alpha".into();
        let b = View { at: 2 * DAY, title: "Beta".into(), streamed: true, ..View::default() };
        let lines = recent(&[a, b], 10);
        assert_eq!(lines[0], "1970-01-03 · Beta · streamed");
        assert_eq!(lines[1], "1970-01-02 · Alpha · Studio A · Performer B, Performer C");
        assert_eq!(profile(&[], 0).recent.len(), 0);
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test taste::` — Expected: panics at `todo!()`.

- [ ] **Step 3: Implement**

```rust
//! The taste profile: what recent views say about what to suggest next. Pure: the views
//! come from Stash's play history and plab's stream log (`assistant::context`).

use std::collections::HashMap;

use serde::Serialize;

/// A view's weight halves every this many days.
pub const HALF_LIFE_DAYS: f64 = 30.0;
/// Studios, performers and tags kept, each.
pub const TOP: usize = 15;
/// Recent views written into the prompt.
pub const RECENT_LINES: usize = 20;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Named {
    pub name: String,
    /// Stash's id, when the view came from Stash.
    pub id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct View {
    pub at: i64,
    pub title: String,
    pub studio: Option<Named>,
    pub performers: Vec<Named>,
    pub tags: Vec<String>,
    pub o_count: u32,
    /// Stash's rating100.
    pub rating: Option<u32>,
    /// From plab's stream log rather than Stash.
    pub streamed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Weighted {
    pub name: String,
    #[serde(skip)]
    pub id: Option<String>,
    pub weight: f64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize)]
pub struct Profile {
    pub studios: Vec<Weighted>,
    pub performers: Vec<Weighted>,
    pub tags: Vec<Weighted>,
    pub recent: Vec<String>,
}

/// Decay by age, boosted by o-count (×1.5 each) and rating (rating100 / 60; unrated ×1).
pub fn weight(v: &View, now: i64) -> f64 {
    let age_days = (now - v.at).max(0) as f64 / 86400.0;
    let decay = 0.5f64.powf(age_days / HALF_LIFE_DAYS);
    let o = 1.0 + 0.5 * f64::from(v.o_count);
    let r = v.rating.map_or(1.0, |r| f64::from(r) / 60.0);
    decay * o * r
}

fn add(map: &mut HashMap<String, Weighted>, name: &str, id: Option<&str>, w: f64) {
    let e = map.entry(name.to_lowercase()).or_insert_with(|| Weighted {
        name: name.to_string(),
        id: None,
        weight: 0.0,
    });
    e.weight += w;
    if e.id.is_none() {
        e.id = id.map(str::to_owned);
    }
}

fn top(map: HashMap<String, Weighted>) -> Vec<Weighted> {
    let mut v: Vec<Weighted> = map.into_values().collect();
    v.sort_by(|a, b| b.weight.total_cmp(&a.weight).then_with(|| a.name.cmp(&b.name)));
    v.truncate(TOP);
    v
}

fn line(v: &View) -> String {
    let day = chrono::DateTime::from_timestamp(v.at, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default();
    let mut parts = vec![day, v.title.clone()];
    if let Some(s) = &v.studio {
        parts.push(s.name.clone());
    }
    if !v.performers.is_empty() {
        let names: Vec<&str> = v.performers.iter().map(|p| p.name.as_str()).collect();
        parts.push(names.join(", "));
    }
    if v.streamed {
        parts.push("streamed".into());
    }
    parts.join(" · ")
}

/// The `n` newest views as one line each.
pub fn recent(views: &[View], n: usize) -> Vec<String> {
    let mut sorted: Vec<&View> = views.iter().collect();
    sorted.sort_by_key(|v| std::cmp::Reverse(v.at));
    sorted.into_iter().take(n).map(line).collect()
}

pub fn profile(views: &[View], now: i64) -> Profile {
    let (mut studios, mut performers, mut tags) = (HashMap::new(), HashMap::new(), HashMap::new());
    for v in views {
        let w = weight(v, now);
        if let Some(s) = &v.studio {
            add(&mut studios, &s.name, s.id.as_deref(), w);
        }
        for p in &v.performers {
            add(&mut performers, &p.name, p.id.as_deref(), w);
        }
        for t in &v.tags {
            add(&mut tags, t, None, w);
        }
    }
    Profile {
        studios: top(studios),
        performers: top(performers),
        tags: top(tags),
        recent: recent(views, RECENT_LINES),
    }
}
```

Until Task 6 uses these, add `#![allow(dead_code)]` at the top of the file with the comment `// Used by assistant (task 6); remove then.` — Task 6 removes it.

- [ ] **Step 4: Run tests** — `cargo test taste::` PASS; `cargo clippy --all-targets -- -D warnings` clean.

- [ ] **Step 5: Commit**

```bash
git add src/taste.rs src/main.rs
git commit -m "feat(galactica): plab taste profile from recent views"
```

---

### Task 3: Candidates (`candidates.rs`, pure)

**Files:**
- Create: `packages/plab/src/candidates.rs`
- Modify: `packages/plab/src/main.rs` (`mod candidates;`)

**Interfaces:**
- Consumes: `crate::taste::{Profile, Weighted}` (Task 2).
- Produces (in `crate::candidates`):
  - `pub struct SceneIn { pub id: String, pub title: String, pub studio: Option<String>, pub performers: Vec<String>, pub tags: Vec<String>, pub plays: u32 }`
  - `pub struct ReleaseIn { pub id: u64, pub title: String, pub studio: Option<String>, pub downloaded: bool, pub album: bool }`
  - `pub struct Candidate { #[serde(rename = "ref")] pub ref_: String, pub kind: &'static str, pub title: String, pub matched: Vec<String>, #[serde(skip)] pub score: f64 }` (derive `Debug, Clone, PartialEq, Serialize`); `kind` is `"watch"` or `"stream_or_download"`; refs are `s:<scene id>` and `t:<topic id>`
  - `pub fn candidates(profile: &Profile, scenes: &[SceneIn], releases: &[ReleaseIn]) -> Vec<Candidate>`
  - consts `PER_POOL: usize = 25`, `MAX: usize = 40`

- [ ] **Step 1: Write the failing tests** (bottom of the new file; bodies `todo!()`)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::taste::Weighted;

    fn w(name: &str, weight: f64) -> Weighted {
        Weighted { name: name.into(), id: None, weight }
    }

    fn profile() -> Profile {
        Profile {
            studios: vec![w("Studio A", 2.0)],
            performers: vec![w("Performer B", 1.0)],
            tags: vec![w("Outdoor", 0.5)],
            recent: vec![],
        }
    }

    fn scene(id: &str, studio: Option<&str>, performers: &[&str], plays: u32) -> SceneIn {
        SceneIn {
            id: id.into(),
            title: format!("Scene {id}"),
            studio: studio.map(Into::into),
            performers: performers.iter().map(|p| p.to_string()).collect(),
            tags: vec!["outdoor".into()],
            plays,
        }
    }

    fn release(id: u64, title: &str) -> ReleaseIn {
        ReleaseIn { id, title: title.into(), studio: None, downloaded: false, album: false }
    }

    #[test]
    fn scenes_score_by_studio_performers_and_tags() {
        let c = candidates(&profile(), &[scene("1", Some("studio a"), &["Performer B"], 0)], &[]);
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].ref_, "s:1");
        assert_eq!(c[0].kind, "watch");
        assert!((c[0].score - 3.5).abs() < 1e-9);
        assert_eq!(c[0].matched, vec!["Studio A", "Performer B", "Outdoor"]);
    }

    #[test]
    fn releases_match_whole_words_in_the_title() {
        let rs = [
            release(1, "Studio A - Night with Performer B [1080p]"),
            release(2, "Studio Ab something"),
            release(3, "Unrelated"),
        ];
        let c = candidates(&profile(), &[], &rs);
        assert_eq!(c.iter().map(|c| c.ref_.as_str()).collect::<Vec<_>>(), vec!["t:1"]);
        assert_eq!(c[0].kind, "stream_or_download");
    }

    #[test]
    fn exclusions() {
        let mut downloaded = release(1, "Studio A one");
        downloaded.downloaded = true;
        let mut album = release(2, "Studio A two");
        album.album = true;
        let c = candidates(
            &profile(),
            &[scene("9", Some("Studio A"), &[], 3)],
            &[downloaded, album],
        );
        assert!(c.is_empty());
    }

    #[test]
    fn caps_per_pool_and_overall() {
        let scenes: Vec<SceneIn> = (0..30).map(|i| scene(&i.to_string(), Some("Studio A"), &[], 0)).collect();
        let releases: Vec<ReleaseIn> = (0..30).map(|i| release(i, "Performer B release")).collect();
        let c = candidates(&profile(), &scenes, &releases);
        assert_eq!(c.len(), MAX);
        assert!(c.iter().filter(|c| c.kind == "watch").count() <= PER_POOL);
        assert!(c.iter().filter(|c| c.kind != "watch").count() >= MAX - PER_POOL);
    }

    #[test]
    fn empty_profile_falls_back_to_listing_order() {
        let releases: Vec<ReleaseIn> = (0..30).map(|i| release(i, "anything")).collect();
        let c = candidates(&Profile::default(), &[], &releases);
        assert_eq!(c.len(), PER_POOL);
        assert_eq!(c[0].ref_, "t:0");
        assert!(c[0].matched.is_empty());
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cargo test candidates::` fails at `todo!()`.

- [ ] **Step 3: Implement**

```rust
//! The assistant's shortlist: unwatched scenes and listed releases that share studios,
//! performers or tags with the taste profile. Pure; `assistant::context` builds the inputs.

use std::collections::HashMap;

use serde::Serialize;

use crate::taste::Profile;

pub const PER_POOL: usize = 25;
pub const MAX: usize = 40;

#[derive(Debug, Clone, PartialEq)]
pub struct SceneIn {
    pub id: String,
    pub title: String,
    pub studio: Option<String>,
    pub performers: Vec<String>,
    pub tags: Vec<String>,
    pub plays: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ReleaseIn {
    pub id: u64,
    pub title: String,
    /// The studio `labels` reads from the title, when it finds one.
    pub studio: Option<String>,
    pub downloaded: bool,
    pub album: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Candidate {
    #[serde(rename = "ref")]
    pub ref_: String,
    pub kind: &'static str,
    pub title: String,
    /// The profile terms it matched, strongest first.
    pub matched: Vec<String>,
    #[serde(skip)]
    pub score: f64,
}

/// Every profile term by lowercase name: its display name and summed weight, in profile
/// order (studios, performers, tags).
fn terms(p: &Profile) -> Vec<(String, String, f64)> {
    let mut by: HashMap<String, usize> = HashMap::new();
    let mut out: Vec<(String, String, f64)> = vec![];
    for w in p.studios.iter().chain(&p.performers).chain(&p.tags) {
        let key = w.name.to_lowercase();
        match by.get(&key) {
            Some(&i) => out[i].2 += w.weight,
            None => {
                by.insert(key.clone(), out.len());
                out.push((key, w.name.clone(), w.weight));
            }
        }
    }
    out
}

/// Whether `needle` (lowercase) occurs in `hay` (lowercase) with no letter or digit on
/// either side.
fn has_word(hay: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return false;
    }
    hay.match_indices(needle).any(|(i, _)| {
        let before = hay[..i].chars().next_back();
        let after = hay[i + needle.len()..].chars().next();
        !before.is_some_and(char::is_alphanumeric) && !after.is_some_and(char::is_alphanumeric)
    })
}

fn score(terms: &[(String, String, f64)], hit: impl Fn(&str) -> bool) -> (f64, Vec<String>) {
    let mut s = 0.0;
    let mut matched = vec![];
    for (key, name, w) in terms {
        if hit(key) {
            s += w;
            matched.push(name.clone());
        }
    }
    (s, matched)
}

fn best(mut v: Vec<Candidate>, n: usize) -> Vec<Candidate> {
    v.sort_by(|a, b| b.score.total_cmp(&a.score)); // stable: ties keep input order
    v.truncate(n);
    v
}

pub fn candidates(profile: &Profile, scenes: &[SceneIn], releases: &[ReleaseIn]) -> Vec<Candidate> {
    let terms = terms(profile);
    let releases = releases.iter().filter(|r| !r.downloaded && !r.album);
    if terms.is_empty() {
        return releases
            .take(PER_POOL)
            .map(|r| Candidate {
                ref_: format!("t:{}", r.id),
                kind: "stream_or_download",
                title: r.title.clone(),
                matched: vec![],
                score: 0.0,
            })
            .collect();
    }
    let scenes: Vec<Candidate> = scenes
        .iter()
        .filter(|s| s.plays == 0)
        .filter_map(|s| {
            let names: Vec<String> = s
                .studio
                .iter()
                .chain(&s.performers)
                .chain(&s.tags)
                .map(|n| n.to_lowercase())
                .collect();
            let (score, matched) = score(&terms, |k| names.iter().any(|n| n == k));
            (score > 0.0).then(|| Candidate {
                ref_: format!("s:{}", s.id),
                kind: "watch",
                title: s.title.clone(),
                matched,
                score,
            })
        })
        .collect();
    let releases: Vec<Candidate> = releases
        .filter_map(|r| {
            let title = r.title.to_lowercase();
            let studio = r.studio.as_deref().map(str::to_lowercase);
            let (score, matched) =
                score(&terms, |k| has_word(&title, k) || studio.as_deref() == Some(k));
            (score > 0.0).then(|| Candidate {
                ref_: format!("t:{}", r.id),
                kind: "stream_or_download",
                title: r.title.clone(),
                matched,
                score,
            })
        })
        .collect();
    let mut all = best(scenes, PER_POOL);
    all.extend(best(releases, PER_POOL));
    best(all, MAX)
}
```

Add the same `#![allow(dead_code)]` + comment as Task 2 (removed by Task 6).

- [ ] **Step 4: Run tests** — `cargo test candidates::` PASS; clippy clean.

- [ ] **Step 5: Commit**

```bash
git add src/candidates.rs src/main.rs
git commit -m "feat(galactica): plab assistant candidates from the taste profile"
```

---

### Task 4: Stash library reads (`stash/library.rs`)

**Files:**
- Create: `packages/plab/src/stash/library.rs`
- Modify: `packages/plab/src/stash/mod.rs` (add `pub mod library;` with the other `mod` lines at the top)

**Interfaces:**
- Produces (in `crate::stash::library`):
  - `pub struct Named { pub id: String, pub name: String }`
  - `pub struct ScenePaths { pub screenshot: Option<String> }` (Default)
  - `pub struct LibScene { pub id, title: Option<String>, date: Option<String>, studio: Option<Named>, performers: Vec<Named>, tags: Vec<Named>, play_count: Option<u32>, o_counter: Option<u32>, rating100: Option<u32>, last_played_at: Option<String>, paths: ScenePaths, files: Vec<super::types::VideoFile> }` — all `pub`, derive `Debug, Clone, PartialEq, Deserialize`
  - `impl LibScene { pub fn label(&self) -> String }` (title, else the first file's basename, else `scene <id>`)
  - `impl Stash`:
    - `pub async fn recent_plays(&self, limit: usize) -> anyhow::Result<Vec<LibScene>>` (played scenes, newest `last_played_at` first)
    - `pub async fn unwatched(&self, performer_ids: &[String], studio_ids: &[String], limit: usize) -> anyhow::Result<Vec<LibScene>>` (play_count 0, matching any id; merged, deduped by id, performers' hits first)
    - `pub async fn search_scenes(&self, q: &str, limit: usize) -> anyhow::Result<Vec<LibScene>>`
    - `pub async fn lib_scenes(&self, ids: &[String]) -> anyhow::Result<Vec<LibScene>>` (empty ids → `Ok(vec![])` without a request)

- [ ] **Step 1: Confirm the field and filter names against the live Stash schema** (read-only):

```bash
ssh galactica.bat-boa.ts.net 'curl -s localhost:9999/graphql -H "Content-Type: application/json" -d "{\"query\":\"{ s: __type(name: \\\"Scene\\\") { fields { name } } f: __type(name: \\\"SceneFilterType\\\") { inputFields { name } } }\"}"' | python3 -m json.tool | grep -E '"(play_count|o_counter|rating100|last_played_at|paths|performers|studios)"'
```

Expected: every name in the grep is present. If one differs (Stash renamed something), use the live name in `FIELDS` and the filters below and note it in the commit message. If ssh is unavailable, proceed with the names below.

- [ ] **Step 2: Write the failing tests** in `library.rs`. Follow the wiremock style of `src/stash/mod.rs`'s tests (see the `// --- transport and query shape` section near line 710 for the helpers used there; reuse them via `super::tests` only if they are `pub(super)`, otherwise write the small local helper below).

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use wiremock::matchers::{body_string_contains, method};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn scenes(v: Value) -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(json!({"data": {"findScenes": {"scenes": v}}}))
    }

    async fn stash(server: &MockServer) -> Stash {
        Stash::new(&format!("{}/graphql", server.uri()), None)
    }

    #[tokio::test]
    async fn recent_plays_reads_play_fields() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_string_contains("last_played_at"))
            .and(body_string_contains("GREATER_THAN"))
            .respond_with(scenes(json!([{
                "id": "4", "title": "Alpha", "studio": {"id": "s1", "name": "Studio A"},
                "performers": [{"id": "p1", "name": "Performer B"}], "tags": [],
                "play_count": 2, "o_counter": 1, "rating100": 80,
                "last_played_at": "2026-11-01T20:00:00Z",
                "paths": {"screenshot": "http://localhost:9999/scene/4/screenshot"},
                "files": [{"path": "/media/Vault/a.mp4", "duration": 60.0}]
            }])))
            .expect(1)
            .mount(&server)
            .await;
        let got = stash(&server).await.recent_plays(100).await.unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].studio.as_ref().unwrap().name, "Studio A");
        assert_eq!(got[0].o_counter, Some(1));
        assert_eq!(got[0].paths.screenshot.as_deref(), Some("http://localhost:9999/scene/4/screenshot"));
    }

    #[tokio::test]
    async fn unwatched_merges_performer_and_studio_hits() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_string_contains("performers: {value: $ids"))
            .respond_with(scenes(json!([{"id": "1"}, {"id": "2"}])))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(body_string_contains("studios: {value: $ids"))
            .respond_with(scenes(json!([{"id": "2"}, {"id": "3"}])))
            .mount(&server)
            .await;
        let got = stash(&server)
            .await
            .unwatched(&["p1".into()], &["s1".into()], 60)
            .await
            .unwrap();
        assert_eq!(got.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), vec!["1", "2", "3"]);
    }

    #[tokio::test]
    async fn unwatched_without_ids_asks_nothing() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(scenes(json!([]))).expect(0).mount(&server).await;
        assert!(stash(&server).await.unwatched(&[], &[], 60).await.unwrap().is_empty());
        assert!(stash(&server).await.lib_scenes(&[]).await.unwrap().is_empty());
    }

    #[test]
    fn label_falls_back_to_the_file_name() {
        let s: LibScene = serde_json::from_value(json!({
            "id": "5", "files": [{"path": "/media/Vault/dir/clip one.mp4"}]
        }))
        .unwrap();
        assert_eq!(s.label(), "clip one.mp4");
        let s: LibScene = serde_json::from_value(json!({"id": "6"})).unwrap();
        assert_eq!(s.label(), "scene 6");
    }
}
```

- [ ] **Step 3: Run to verify failure** — `cargo test stash::library` fails to compile.

- [ ] **Step 4: Implement**

```rust
//! Library reads for the assistant: what was played, what is unwatched, scene search.
//! Inherent methods on `Stash` (not `StashApi`): only the assistant uses them.

use std::collections::HashSet;

use serde::Deserialize;
use serde_json::json;

use super::Stash;
use super::types::VideoFile;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Named {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
pub struct ScenePaths {
    #[serde(default)]
    pub screenshot: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LibScene {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub date: Option<String>,
    #[serde(default)]
    pub studio: Option<Named>,
    #[serde(default)]
    pub performers: Vec<Named>,
    #[serde(default)]
    pub tags: Vec<Named>,
    #[serde(default)]
    pub play_count: Option<u32>,
    #[serde(default)]
    pub o_counter: Option<u32>,
    #[serde(default)]
    pub rating100: Option<u32>,
    /// RFC 3339.
    #[serde(default)]
    pub last_played_at: Option<String>,
    #[serde(default)]
    pub paths: ScenePaths,
    #[serde(default)]
    pub files: Vec<VideoFile>,
}

impl LibScene {
    pub fn label(&self) -> String {
        if let Some(t) = self.title.as_deref().filter(|t| !t.trim().is_empty()) {
            return t.to_string();
        }
        match self.files.first() {
            Some(f) => f.path.rsplit('/').next().unwrap_or(&f.path).to_string(),
            None => format!("scene {}", self.id),
        }
    }
}

const FIELDS: &str = "id title date studio { id name } performers { id name } tags { id name } \
    play_count o_counter rating100 last_played_at paths { screenshot } files { path duration }";

const SCENES: &[&str] = &["findScenes", "scenes"];

impl Stash {
    pub async fn recent_plays(&self, limit: usize) -> anyhow::Result<Vec<LibScene>> {
        let q = format!(
            "query($n: Int!) {{ findScenes(
               scene_filter: {{play_count: {{value: 0, modifier: GREATER_THAN}}}},
               filter: {{sort: \"last_played_at\", direction: DESC, per_page: $n}})
               {{ scenes {{ {FIELDS} }} }} }}"
        );
        self.query(&q, json!({"n": limit}), SCENES).await
    }

    pub async fn unwatched(
        &self,
        performer_ids: &[String],
        studio_ids: &[String],
        limit: usize,
    ) -> anyhow::Result<Vec<LibScene>> {
        let mut seen = HashSet::new();
        let mut out = vec![];
        for (field, ids) in [("performers", performer_ids), ("studios", studio_ids)] {
            if ids.is_empty() {
                continue;
            }
            let q = format!(
                "query($ids: [ID!], $n: Int!) {{ findScenes(
                   scene_filter: {{play_count: {{value: 0, modifier: EQUALS}},
                                   {field}: {{value: $ids, modifier: INCLUDES}}}},
                   filter: {{sort: \"date\", direction: DESC, per_page: $n}})
                   {{ scenes {{ {FIELDS} }} }} }}"
            );
            let got: Vec<LibScene> = self.query(&q, json!({"ids": ids, "n": limit}), SCENES).await?;
            out.extend(got.into_iter().filter(|s| seen.insert(s.id.clone())));
        }
        Ok(out)
    }

    pub async fn search_scenes(&self, q: &str, limit: usize) -> anyhow::Result<Vec<LibScene>> {
        let query = format!(
            "query($q: String!, $n: Int!) {{ findScenes(filter: {{q: $q, per_page: $n}})
               {{ scenes {{ {FIELDS} }} }} }}"
        );
        self.query(&query, json!({"q": q, "n": limit}), SCENES).await
    }

    pub async fn lib_scenes(&self, ids: &[String]) -> anyhow::Result<Vec<LibScene>> {
        if ids.is_empty() {
            return Ok(vec![]);
        }
        let q = format!(
            "query($ids: [ID!]) {{ findScenes(ids: $ids, filter: {{per_page: -1}})
               {{ scenes {{ {FIELDS} }} }} }}"
        );
        self.query(&q, json!({"ids": ids}), SCENES).await
    }
}
```

Note: the test matchers `"performers: {value: $ids"` rely on the exact `format!` output above (`{field}: {{value: $ids` renders `performers: {value: $ids`). Keep them in step. `query` is a private method of `Stash` in the parent module; a child module can call it.

Add `#![allow(dead_code)]` + the Task-6 comment if clippy flags unused items.

- [ ] **Step 5: Run tests** — `cargo test stash::` PASS; clippy clean.

- [ ] **Step 6: Commit**

```bash
git add src/stash/library.rs src/stash/mod.rs
git commit -m "feat(galactica): plab reads play history and unwatched scenes from Stash"
```

---

### Task 5: Model setting, assistant prompt, raw chat call

**Files:**
- Modify: `packages/plab/src/config.rs` (struct field near line 26, `from_env` near line 63, tests near 126/155/182)
- Modify: `packages/plab/src/site.rs` (`Prompts` near line 50; `Site::example()` near line 97)
- Modify: `packages/plab/src/llm.rs` (`impl OpenRouter`)

**Interfaces:**
- Produces:
  - `Config::assistant_model: String` — `PLAB_ASSISTANT_MODEL`, defaulting to the resolved `parse_model`
  - `site::Prompts::assistant: String` — `#[serde(default)]`; empty means "not set"
  - `OpenRouter::chat(&self, body: &serde_json::Value) -> anyhow::Result<serde_json::Value>` — POST to `CHAT_PATH`, the raw reply

- [ ] **Step 1: Failing tests**

In `config.rs` tests: in the defaults test (the one asserting `parse_model` default at ~line 127) add `assert_eq!(c.assistant_model, "~deepseek/deepseek-flash-latest");`. In the all-set test (~line 155) add `("PLAB_ASSISTANT_MODEL", "a/m")` to the env list and `assert_eq!(c.assistant_model, "a/m");`. Add:

```rust
#[test]
fn assistant_model_follows_parse_model() {
    let c = Config::from_env(env(&[("PLAB_PARSE_MODEL", "p/m")]));
    assert_eq!(c.assistant_model, "p/m");
}
```

In `site.rs` tests add:

```rust
#[test]
fn assistant_prompt_is_optional() {
    let p: Prompts = serde_json::from_value(serde_json::json!({
        "parse": "p", "translate": "t", "classify": "c", "criteria": []
    }))
    .unwrap();
    assert!(p.assistant.is_empty());
}
```

In `llm.rs` tests add (wiremock is already used in that file's tests; follow its imports):

```rust
#[tokio::test]
async fn chat_posts_the_body_as_is() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(CHAT_PATH))
        .and(wiremock::matchers::header("Authorization", "Bearer k"))
        .and(wiremock::matchers::body_json(serde_json::json!({"model": "m", "messages": []})))
        .respond_with(wiremock::ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": 1})))
        .expect(1)
        .mount(&server)
        .await;
    let or = OpenRouter::new(&server.uri(), "k".into(), "p".into(), "j".into());
    let r = or.chat(&serde_json::json!({"model": "m", "messages": []})).await.unwrap();
    assert_eq!(r["ok"], 1);
}
```

- [ ] **Step 2: Run to verify failure** — `cargo test config:: site:: llm::` fails to compile.

- [ ] **Step 3: Implement**

`config.rs`: add `pub assistant_model: String,` after `parse_model`. In `from_env`, bind the parse model first and reuse it:

```rust
        let parse_model = or("PLAB_PARSE_MODEL", "~deepseek/deepseek-flash-latest");
        let assistant_model = or("PLAB_ASSISTANT_MODEL", &parse_model);
```

then use `parse_model,` and `assistant_model,` in the struct literal. (Match `or`'s actual signature; if it takes `&str` default and returns `String`, the above is exact.)

`site.rs` `Prompts`: add

```rust
    /// The assistant's system prompt. Empty (absent from the secret) leaves the assistant
    /// off: it answers 503 until the secret carries one.
    #[serde(default)]
    pub assistant: String,
```

and in `Site::example()` set `assistant: "You help choose what to watch or download next.".into(),`.

`llm.rs` in `impl OpenRouter`:

```rust
    /// A chat completion with a caller-built body (the assistant's tool loop), the raw reply.
    pub async fn chat(&self, body: &Value) -> anyhow::Result<Value> {
        self.post(CHAT_PATH, body).await
    }
```

- [ ] **Step 4: Run tests** — `cargo test` all PASS; clippy clean.

- [ ] **Step 5: Commit**

```bash
git add src/config.rs src/site.rs src/llm.rs
git commit -m "feat(galactica): plab assistant model setting and prompt slot"
```

---

### Task 6: The assistant (`assistant/`)

**Files:**
- Create: `packages/plab/src/assistant/mod.rs`, `packages/plab/src/assistant/context.rs`, `packages/plab/src/assistant/tools.rs`
- Modify: `packages/plab/src/main.rs` (`mod assistant;`)
- Modify: `packages/plab/src/taste.rs`, `src/candidates.rs`, `src/stash/library.rs` (remove the temporary `#![allow(dead_code)]` lines)

**Interfaces:**
- Consumes: Task 1 `Db` conversation methods; Task 2 `taste::{View, Named, Profile, profile, recent, RECENT_LINES}`; Task 3 `candidates::{candidates, SceneIn, ReleaseIn, Candidate}`; Task 4 `stash::library::LibScene` and `Stash::{recent_plays, unwatched, search_scenes, lib_scenes}`; Task 5 `OpenRouter::chat`; existing `db::{Section, Db::listing, Db::added, Db::externals, Db::topic, Kind}`, `labels::labels(title, forum) -> Labels` (field `studio: Option<String>`).
- Produces (in `crate::assistant`):
  - `pub struct Assistant` with `pub fn new(llm: OpenRouter, stash: Stash, model: String, prompt: String) -> Assistant`
  - `pub fn stash(&self) -> &Stash`
  - `pub fn ready(&self) -> Result<(), TurnError>`
  - `pub enum Kind { Recommend, Chat }` with `pub fn as_str(self) -> &'static str` (`"recommend"`, `"chat"`)
  - `pub async fn start(&self, db: &Db, kind: Kind, text: Option<&str>, now: i64) -> Result<i64, TurnError>` (creates, stores context, runs the first turn; returns the conversation id)
  - `pub async fn turn(&self, db: &Db, conversation: i64, text: Option<&str>, now: i64) -> Result<(), TurnError>` (`None` = retry the last user turn)
  - `pub fn lock(&self, conversation: i64) -> Result<TurnGuard<'_>, TurnError>` (public so tests can hold it)
  - `#[derive(Debug)] pub enum TurnError { NotReady(&'static str), NotFound, Busy, Failed(anyhow::Error) }` with `Display` and `From<anyhow::Error>`
  - `pub struct Final { pub text: String, pub picks: Vec<Pick> }`, `pub struct Pick { pub ref_: String, pub action: String, pub reason: String }` (Deserialize; `ref_` renamed `"ref"`; `picks`/`reason` default)
  - `pub fn parse_final(content: &str) -> Option<Final>` (tolerates a ```json fence)
  - `pub fn is_hidden(msg: &serde_json::Value) -> bool` (true when `plab_hidden` is true)
  - `pub fn error_of(msg: &serde_json::Value) -> Option<&str>` (the `plab_error` string)
  - `pub fn degraded_of(msg: &serde_json::Value) -> Vec<String>` (the system message's `plab_degraded`)
  - consts `MAX_ROUNDS: usize = 6`, `RECOMMEND_ASK: &str`
- `context.rs` produces `pub struct Context { pub profile: Profile, pub candidates: Vec<Candidate>, pub degraded: Vec<&'static str> }`, `pub async fn views(db: &Db, stash: &Stash, now: i64) -> (Vec<View>, bool /*stash ok*/)` and `pub async fn gather(db: &Db, stash: &Stash, now: i64) -> anyhow::Result<Context>`.
- `tools.rs` produces `pub fn definitions() -> Value` and `pub async fn run(stash: &Stash, db: &Db, name: &str, arguments: &str, now: i64) -> String`.

Stored message shapes (the `content` column, JSON):
- system: `{"role":"system","content":"…","plab_degraded":["stash"]}`
- user: `{"role":"user","content":"…"}`; a hidden re-ask adds `"plab_hidden":true`
- assistant with tools: the model's message verbatim (`role`, `content`, `tool_calls`)
- tool: `{"role":"tool","tool_call_id":"…","content":"…"}`
- assistant final: `{"role":"assistant","content":"<the JSON text>"}`
- error: `{"role":"assistant","content":"","plab_error":"…"}`

Messages sent to the model: every stored message except errors (hidden ones included), with every `plab_*` key removed.

- [ ] **Step 1: Write `context.rs`**

```rust
//! What the assistant knows before it is asked anything: recent views, the taste profile,
//! the shortlist. Stash being down degrades it to plab's own data rather than failing.

use std::collections::HashSet;

use crate::candidates::{self, Candidate, ReleaseIn, SceneIn};
use crate::db::{Db, Kind, Section};
use crate::stash::Stash;
use crate::stash::library::LibScene;
use crate::taste::{self, Named, Profile, View};

/// How far back views count.
pub const LOOKBACK: i64 = 60 * 86400;
/// Played scenes asked of Stash.
const PLAYS: usize = 100;
/// Unwatched scenes asked of Stash, per criterion.
const UNWATCHED: usize = 60;

pub struct Context {
    pub profile: Profile,
    pub candidates: Vec<Candidate>,
    pub degraded: Vec<&'static str>,
}

fn named(n: &crate::stash::library::Named) -> Named {
    Named { name: n.name.clone(), id: Some(n.id.clone()) }
}

fn played_at(s: &LibScene) -> Option<i64> {
    let t = s.last_played_at.as_deref()?;
    chrono::DateTime::parse_from_rfc3339(t).ok().map(|d| d.timestamp())
}

fn view_of(s: &LibScene, at: i64, streamed: bool) -> View {
    View {
        at,
        title: s.label(),
        studio: s.studio.as_ref().map(named),
        performers: s.performers.iter().map(named).collect(),
        tags: s.tags.iter().map(|t| t.name.clone()).collect(),
        o_count: if streamed { 0 } else { s.o_counter.unwrap_or(0) },
        rating: if streamed { None } else { s.rating100 },
        streamed,
    }
}

/// Stash plays and plab streams from the last `LOOKBACK`, and whether Stash answered.
pub async fn views(db: &Db, stash: &Stash, now: i64) -> (Vec<View>, bool) {
    let since = now - LOOKBACK;
    let mut ok = true;
    let mut out: Vec<View> = match stash.recent_plays(PLAYS).await {
        Ok(scenes) => scenes
            .iter()
            .filter_map(|s| played_at(s).filter(|&at| at >= since).map(|at| view_of(s, at, false)))
            .collect(),
        Err(e) => {
            tracing::info!(job = "assistant", "Stash plays: {e:#}");
            ok = false;
            vec![]
        }
    };
    let streams = db.stream_views(since).unwrap_or_else(|e| {
        tracing::info!(job = "assistant", "stream views: {e:#}");
        vec![]
    });
    // A streamed release matched to a scene takes that scene's studio, performers, tags.
    let mut by_scene: Vec<(i64, String, Option<String>)> = vec![]; // (at, title, scene id)
    for (topic, at) in streams {
        let title = db.topic(topic).ok().flatten().map(|t| t.row.title).unwrap_or_else(|| format!("release {topic}"));
        let scene = db.external(topic).ok().flatten().and_then(|e| e.scene_id);
        by_scene.push((at, title, scene));
    }
    let ids: Vec<String> = by_scene.iter().filter_map(|(_, _, s)| s.clone()).collect();
    let scenes = if ok && !ids.is_empty() {
        stash.lib_scenes(&ids).await.unwrap_or_else(|e| {
            tracing::info!(job = "assistant", "Stash scenes: {e:#}");
            ok = false;
            vec![]
        })
    } else {
        vec![]
    };
    for (at, title, scene) in by_scene {
        match scene.and_then(|id| scenes.iter().find(|s| s.id == id)) {
            Some(s) => out.push(View { title, ..view_of(s, at, true) }),
            None => out.push(View { at, title, streamed: true, ..View::default() }),
        }
    }
    (out, ok)
}

/// The releases on the Video and Indexers lists, as candidates' input.
fn releases(db: &Db) -> anyhow::Result<Vec<ReleaseIn>> {
    let added = db.added()?;
    let externals = db.externals()?;
    let mut seen = HashSet::new();
    let mut out = vec![];
    for section in [Section::Video, Section::Indexers] {
        for l in db.listing(section)?.topics {
            let row = &l.topic.row;
            if !seen.insert(row.id) {
                continue;
            }
            out.push(ReleaseIn {
                id: row.id,
                title: row.title.clone(),
                studio: crate::labels::labels(&row.title, row.forum).studio,
                downloaded: added.contains(&row.id),
                album: externals.get(&row.id).is_some_and(|e| e.kind == Kind::Album),
            });
        }
    }
    Ok(out)
}

pub async fn gather(db: &Db, stash: &Stash, now: i64) -> anyhow::Result<Context> {
    let (views, mut ok) = views(db, stash, now).await;
    let profile = taste::profile(&views, now);
    let ids = |ws: &[taste::Weighted], n: usize| -> Vec<String> {
        ws.iter().filter_map(|w| w.id.clone()).take(n).collect()
    };
    let scenes = if ok {
        match stash.unwatched(&ids(&profile.performers, 8), &ids(&profile.studios, 5), UNWATCHED).await {
            Ok(s) => s,
            Err(e) => {
                tracing::info!(job = "assistant", "Stash unwatched: {e:#}");
                ok = false;
                vec![]
            }
        }
    } else {
        vec![]
    };
    let scenes: Vec<SceneIn> = scenes
        .iter()
        .map(|s| SceneIn {
            id: s.id.clone(),
            title: s.label(),
            studio: s.studio.as_ref().map(|x| x.name.clone()),
            performers: s.performers.iter().map(|p| p.name.clone()).collect(),
            tags: s.tags.iter().map(|t| t.name.clone()).collect(),
            plays: s.play_count.unwrap_or(0),
        })
        .collect();
    let candidates = candidates::candidates(&profile, &scenes, &releases(db)?);
    Ok(Context { profile, candidates, degraded: if ok { vec![] } else { vec!["stash"] } })
}
```

Check `db.topic(id)` returns `Result<Option<Topic>>` (it does, line ~1138) and `db.external(id)` returns `Result<Option<External>>` (line ~1162). `Kind` must derive `PartialEq` (it does).

- [ ] **Step 2: Write `tools.rs`**

```rust
//! The assistant's read-only tools. Each returns a JSON string; a failure is a JSON
//! `{"error": …}` the model can read and correct, never an Err.

use serde_json::{Value, json};

use crate::db::{Db, Section};
use crate::stash::Stash;

/// Results per tool call.
const LIMIT: usize = 20;

pub fn definitions() -> Value {
    let q = json!({"type": "object", "properties": {"q": {"type": "string"}}, "required": ["q"]});
    json!([
        {"type": "function", "function": {
            "name": "search_lists",
            "description": "Search the releases currently on plab's lists by words in their titles. Returns refs usable as stream or download picks.",
            "parameters": q}},
        {"type": "function", "function": {
            "name": "find_stash_scenes",
            "description": "Search the Stash library. Returns refs usable as watch picks, with play counts.",
            "parameters": q}},
        {"type": "function", "function": {
            "name": "recent_views",
            "description": "The full list of recent views, newest first.",
            "parameters": {"type": "object", "properties": {}}}}
    ])
}

fn query(arguments: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(arguments).map_err(|e| format!("arguments are not JSON: {e}"))?;
    v.get("q")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|q| !q.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "q is required".into())
}

fn search_lists(db: &Db, q: &str) -> anyhow::Result<Value> {
    let words: Vec<String> = q.to_lowercase().split_whitespace().map(str::to_owned).collect();
    let mut out = vec![];
    for section in [Section::Video, Section::Indexers] {
        for l in db.listing(section)?.topics {
            let title = l.topic.row.title.to_lowercase();
            if words.iter().all(|w| title.contains(w.as_str()))
                && !out.iter().any(|v: &Value| v["ref"] == format!("t:{}", l.topic.row.id))
            {
                out.push(json!({"ref": format!("t:{}", l.topic.row.id), "title": l.topic.row.title}));
            }
            if out.len() == LIMIT {
                return Ok(Value::Array(out));
            }
        }
    }
    Ok(Value::Array(out))
}

pub async fn run(stash: &Stash, db: &Db, name: &str, arguments: &str, now: i64) -> String {
    let r: Result<Value, String> = match name {
        "search_lists" => match query(arguments) {
            Ok(q) => search_lists(db, &q).map_err(|e| format!("{e:#}")),
            Err(e) => Err(e),
        },
        "find_stash_scenes" => match query(arguments) {
            Ok(q) => stash
                .search_scenes(&q, LIMIT)
                .await
                .map(|scenes| {
                    Value::Array(
                        scenes
                            .iter()
                            .map(|s| {
                                json!({
                                    "ref": format!("s:{}", s.id),
                                    "title": s.label(),
                                    "studio": s.studio.as_ref().map(|x| &x.name),
                                    "performers": s.performers.iter().map(|p| &p.name).collect::<Vec<_>>(),
                                    "plays": s.play_count.unwrap_or(0),
                                })
                            })
                            .collect(),
                    )
                })
                .map_err(|e| format!("Stash: {e:#}")),
            Err(e) => Err(e),
        },
        "recent_views" => {
            let (views, _) = super::context::views(db, stash, now).await;
            Ok(json!(crate::taste::recent(&views, 100)))
        }
        other => Err(format!("unknown tool {other}")),
    };
    match r {
        Ok(v) => v.to_string(),
        Err(e) => json!({"error": e}).to_string(),
    }
}
```

- [ ] **Step 3: Write the failing tests for `mod.rs`** (at the bottom of `assistant/mod.rs`; implement the module with `todo!()` bodies first so the tests compile)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use wiremock::matchers::{body_string_contains, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn reply(message: Value) -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(json!({"choices": [{"message": message}]}))
    }

    fn final_reply(text: &str, picks: Value) -> ResponseTemplate {
        reply(json!({"role": "assistant", "content": json!({"text": text, "picks": picks}).to_string()}))
    }

    fn tool_call(name: &str, args: &str) -> ResponseTemplate {
        reply(json!({"role": "assistant", "content": null, "tool_calls": [
            {"id": "c1", "type": "function", "function": {"name": name, "arguments": args}}
        ]}))
    }

    /// OpenRouter and Stash on one mock server; Stash answers every query with no scenes.
    async fn fixture() -> (MockServer, Assistant, Db) {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/graphql"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"data": {"findScenes": {"scenes": []}}})))
            .mount(&server)
            .await;
        let llm = OpenRouter::new(&server.uri(), "k".into(), "p".into(), "j".into());
        let stash = Stash::new(&format!("{}/graphql", server.uri()), None);
        let a = Assistant::new(llm, stash, "m".into(), "Be helpful.".into());
        (server, a, Db::open_in_memory().unwrap())
    }

    fn roles(db: &Db, id: i64) -> Vec<String> {
        db.messages(id).unwrap().into_iter().map(|m| m.role).collect()
    }

    fn last(db: &Db, id: i64) -> Value {
        serde_json::from_str(&db.messages(id).unwrap().last().unwrap().content).unwrap()
    }

    #[tokio::test]
    async fn a_tool_round_then_an_answer() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .and(body_string_contains("tool_call_id"))
            .respond_with(final_reply("Try these.", json!([{"ref": "t:1", "action": "download", "reason": "r"}])))
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(tool_call("search_lists", r#"{"q":"alpha"}"#))
            .with_priority(2)
            .mount(&server)
            .await;
        let id = a.start(&db, Kind::Recommend, None, 86400).await.unwrap();
        assert_eq!(roles(&db, id), vec!["system", "user", "assistant", "tool", "assistant"]);
        let f = parse_final(last(&db, id)["content"].as_str().unwrap()).unwrap();
        assert_eq!(f.text, "Try these.");
        assert_eq!(f.picks[0].ref_, "t:1");
        let c = db.conversation(id).unwrap().unwrap();
        assert_eq!((c.kind.as_str(), c.title.as_str()), ("recommend", "Recommendations · 1970-01-02"));
    }

    #[tokio::test]
    async fn the_round_cap_stores_an_error() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(tool_call("recent_views", "{}"))
            .expect(MAX_ROUNDS as u64)
            .mount(&server)
            .await;
        let id = a.start(&db, Kind::Chat, Some("hello"), 0).await.unwrap();
        assert!(error_of(&last(&db, id)).unwrap().contains("rounds"));
    }

    #[tokio::test]
    async fn a_malformed_answer_is_re_asked_once() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(reply(json!({"role": "assistant", "content": "not json"})))
            .expect(2)
            .mount(&server)
            .await;
        let id = a.start(&db, Kind::Chat, Some("hello"), 0).await.unwrap();
        let msgs: Vec<Value> = db.messages(id).unwrap().iter().map(|m| serde_json::from_str(&m.content).unwrap()).collect();
        assert!(msgs.iter().any(is_hidden));
        assert!(error_of(msgs.last().unwrap()).is_some());
    }

    #[tokio::test]
    async fn retry_replaces_the_error() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(ResponseTemplate::new(500))
            .up_to_n_times(1)
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(final_reply("ok", json!([])))
            .with_priority(2)
            .mount(&server)
            .await;
        let id = a.start(&db, Kind::Chat, Some("hello"), 0).await.unwrap();
        assert!(error_of(&last(&db, id)).is_some());
        a.turn(&db, id, None, 1).await.unwrap();
        assert_eq!(roles(&db, id), vec!["system", "user", "assistant"]);
        assert!(error_of(&last(&db, id)).is_none());
    }

    #[tokio::test]
    async fn stash_down_is_degraded_not_fatal() {
        let server = MockServer::start().await;
        Mock::given(path("/graphql")).respond_with(ResponseTemplate::new(500)).mount(&server).await;
        Mock::given(path(crate::llm::CHAT_PATH)).respond_with(final_reply("ok", json!([]))).mount(&server).await;
        let llm = OpenRouter::new(&server.uri(), "k".into(), "p".into(), "j".into());
        let a = Assistant::new(llm, Stash::new(&format!("{}/graphql", server.uri()), None), "m".into(), "x".into());
        let db = Db::open_in_memory().unwrap();
        let id = a.start(&db, Kind::Chat, Some("hi"), 0).await.unwrap();
        let system: Value = serde_json::from_str(&db.messages(id).unwrap()[0].content).unwrap();
        assert_eq!(degraded_of(&system), vec!["stash"]);
    }

    #[tokio::test]
    async fn busy_and_missing() {
        let (_server, a, db) = fixture().await;
        let id = db.create_conversation("t", "chat", 0).unwrap();
        let _g = a.lock(id).unwrap();
        assert!(matches!(a.turn(&db, id, Some("x"), 0).await, Err(TurnError::Busy)));
        assert!(matches!(a.turn(&db, 999, Some("x"), 0).await, Err(TurnError::NotFound)));
    }

    #[test]
    fn not_ready_without_a_prompt() {
        let llm = OpenRouter::new("http://x", "k".into(), "p".into(), "j".into());
        let a = Assistant::new(llm, Stash::new("http://x", None), "m".into(), "  ".into());
        assert!(matches!(a.ready(), Err(TurnError::NotReady(_))));
    }

    #[test]
    fn parse_final_tolerates_a_fence() {
        let f = parse_final("```json\n{\"text\": \"hi\"}\n```").unwrap();
        assert_eq!(f.text, "hi");
        assert!(f.picks.is_empty());
        assert!(parse_final("[1]").is_none());
    }

    #[test]
    fn chat_titles_are_truncated() {
        assert_eq!(title(Kind::Chat, Some(&"x".repeat(80)), 0).chars().count(), 60);
    }
}
```

- [ ] **Step 4: Run to verify failure** — `cargo test assistant::` panics at `todo!()`.

- [ ] **Step 5: Implement `assistant/mod.rs`**

```rust
//! The plab assistant: on-demand recommendations and chat over OpenRouter, with read-only
//! tools. Every conversation is stored (`conversation`/`message` in state.db).
//! Design: docs/superpowers/specs/2026-11-03-plab-assistant-design.md

pub mod context;
pub mod tools;

use std::collections::HashSet;
use std::sync::Mutex;

use anyhow::Context as _;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::db::Db;
use crate::llm::OpenRouter;
use crate::stash::Stash;

pub const MAX_ROUNDS: usize = 6;
pub const RECOMMEND_ASK: &str = "Based on my recent views, recommend up to 5 scenes to watch and up to 5 releases to stream or download.";
const REASK: &str = "Reply with only the JSON object the instructions describe.";
const TITLE_CHARS: usize = 60;

/// How a final answer is shaped. Format, not content: it lives here, not in the secret.
const FINAL_FORMAT: &str = r#"When you answer, reply with only a JSON object:
{"text": "<your answer>", "picks": [{"ref": "<ref>", "action": "watch" | "stream" | "download", "reason": "<one line>"}]}
Use only refs given in CANDIDATES or returned by a tool. "watch" is for s: refs; "stream" and "download" are for t: refs. picks may be empty."#;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Recommend,
    Chat,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Recommend => "recommend",
            Kind::Chat => "chat",
        }
    }
}

#[derive(Debug)]
pub enum TurnError {
    NotReady(&'static str),
    NotFound,
    Busy,
    Failed(anyhow::Error),
}

impl std::fmt::Display for TurnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TurnError::NotReady(why) => f.write_str(why),
            TurnError::NotFound => f.write_str("no such conversation"),
            TurnError::Busy => f.write_str("a reply is already being written"),
            TurnError::Failed(e) => write!(f, "{e:#}"),
        }
    }
}

impl From<anyhow::Error> for TurnError {
    fn from(e: anyhow::Error) -> Self {
        TurnError::Failed(e)
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Pick {
    #[serde(rename = "ref")]
    pub ref_: String,
    pub action: String,
    #[serde(default)]
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Final {
    pub text: String,
    #[serde(default)]
    pub picks: Vec<Pick>,
}

pub fn parse_final(content: &str) -> Option<Final> {
    let s = content.trim();
    let s = s.strip_prefix("```json").or_else(|| s.strip_prefix("```")).unwrap_or(s);
    let s = s.strip_suffix("```").unwrap_or(s).trim();
    let v: Value = serde_json::from_str(s).ok()?;
    if !v.is_object() {
        return None;
    }
    serde_json::from_value(v).ok()
}

pub fn is_hidden(msg: &Value) -> bool {
    msg.get("plab_hidden").and_then(Value::as_bool) == Some(true)
}

pub fn error_of(msg: &Value) -> Option<&str> {
    msg.get("plab_error").and_then(Value::as_str)
}

pub fn degraded_of(msg: &Value) -> Vec<String> {
    msg.get("plab_degraded")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn day(now: i64) -> String {
    chrono::DateTime::from_timestamp(now, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

fn title(kind: Kind, text: Option<&str>, now: i64) -> String {
    match kind {
        Kind::Recommend => format!("Recommendations · {}", day(now)),
        Kind::Chat => text.unwrap_or("").trim().chars().take(TITLE_CHARS).collect(),
    }
}

/// The stored message with plab's own keys removed: what the model is sent.
fn wire(mut msg: Value) -> Value {
    if let Some(o) = msg.as_object_mut() {
        o.retain(|k, _| !k.starts_with("plab_"));
    }
    msg
}

pub struct TurnGuard<'a> {
    busy: &'a Mutex<HashSet<i64>>,
    id: i64,
}

impl Drop for TurnGuard<'_> {
    fn drop(&mut self) {
        self.busy.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.id);
    }
}

pub struct Assistant {
    llm: OpenRouter,
    stash: Stash,
    model: String,
    prompt: String,
    busy: Mutex<HashSet<i64>>,
}

impl Assistant {
    pub fn new(llm: OpenRouter, stash: Stash, model: String, prompt: String) -> Assistant {
        Assistant { llm, stash, model, prompt, busy: Mutex::new(HashSet::new()) }
    }

    pub fn stash(&self) -> &Stash {
        &self.stash
    }

    pub fn ready(&self) -> Result<(), TurnError> {
        if self.prompt.trim().is_empty() {
            return Err(TurnError::NotReady("the assistant prompt is not set in plab-site"));
        }
        Ok(())
    }

    pub fn lock(&self, conversation: i64) -> Result<TurnGuard<'_>, TurnError> {
        let mut busy = self.busy.lock().unwrap_or_else(|e| e.into_inner());
        if !busy.insert(conversation) {
            return Err(TurnError::Busy);
        }
        Ok(TurnGuard { busy: &self.busy, id: conversation })
    }

    pub async fn start(&self, db: &Db, kind: Kind, text: Option<&str>, now: i64) -> Result<i64, TurnError> {
        self.ready()?;
        let ctx = context::gather(db, &self.stash, now).await?;
        let mut content = format!(
            "{}\n\nPROFILE:\n{}\n\nCANDIDATES:\n{}",
            self.prompt,
            serde_json::to_string(&ctx.profile).context("profile")?,
            serde_json::to_string(&ctx.candidates).context("candidates")?,
        );
        if !ctx.degraded.is_empty() {
            content.push_str("\n\nStash could not be reached: the profile has only plab's stream log, and there are no watch candidates.");
        }
        content.push_str("\n\n");
        content.push_str(FINAL_FORMAT);
        let id = db.create_conversation(&title(kind, text, now), kind.as_str(), now)?;
        let system = json!({"role": "system", "content": content, "plab_degraded": ctx.degraded});
        db.append_message(id, "system", &system.to_string(), now)?;
        self.turn(db, id, Some(text.unwrap_or(RECOMMEND_ASK)), now).await?;
        Ok(id)
    }

    fn store(&self, db: &Db, id: i64, msg: &Value, now: i64) -> anyhow::Result<()> {
        let role = msg.get("role").and_then(Value::as_str).unwrap_or("assistant");
        db.append_message(id, role, &msg.to_string(), now)?;
        Ok(())
    }

    fn fail(&self, db: &Db, id: i64, why: &str, now: i64) -> Result<(), TurnError> {
        tracing::info!(job = "assistant", "conversation {id}: {why}");
        self.store(db, id, &json!({"role": "assistant", "content": "", "plab_error": why}), now)?;
        Ok(())
    }

    /// The stored history as the model is sent it: errors dropped, plab keys stripped.
    fn history(&self, db: &Db, id: i64) -> anyhow::Result<Vec<Value>> {
        let mut out = vec![];
        for m in db.messages(id)? {
            let v: Value = serde_json::from_str(&m.content).context("stored message")?;
            if error_of(&v).is_none() {
                out.push(wire(v));
            }
        }
        Ok(out)
    }

    pub async fn turn(&self, db: &Db, id: i64, text: Option<&str>, now: i64) -> Result<(), TurnError> {
        self.ready()?;
        let _guard = self.lock(id)?;
        if db.conversation(id)?.is_none() {
            return Err(TurnError::NotFound);
        }
        match text {
            Some(t) => self.store(db, id, &json!({"role": "user", "content": t}), now)?,
            None => {
                // Retry: drop what the failed turn left after its user message.
                let msgs = db.messages(id)?;
                let Some(user) = msgs.iter().rev().find(|m| {
                    m.role == "user"
                        && serde_json::from_str::<Value>(&m.content).is_ok_and(|v| !is_hidden(&v))
                }) else {
                    return Err(TurnError::NotFound);
                };
                db.delete_messages_from(id, user.seq + 1)?;
            }
        }
        let mut reasked = false;
        for _ in 0..MAX_ROUNDS {
            let body = json!({"model": self.model, "messages": self.history(db, id)?, "tools": tools::definitions()});
            let reply = match self.llm.chat(&body).await {
                Ok(r) => r,
                Err(e) => return self.fail(db, id, &format!("OpenRouter: {e:#}"), now),
            };
            let Some(msg) = reply.pointer("/choices/0/message").cloned() else {
                return self.fail(db, id, "OpenRouter: no message in the reply", now);
            };
            let calls = msg.get("tool_calls").and_then(Value::as_array).cloned().unwrap_or_default();
            if !calls.is_empty() {
                self.store(db, id, &msg, now)?;
                for c in calls {
                    let name = c.pointer("/function/name").and_then(Value::as_str).unwrap_or("");
                    let args = c.pointer("/function/arguments").and_then(Value::as_str).unwrap_or("{}");
                    let result = tools::run(&self.stash, db, name, args, now).await;
                    let call_id = c.get("id").cloned().unwrap_or(Value::Null);
                    self.store(db, id, &json!({"role": "tool", "tool_call_id": call_id, "content": result}), now)?;
                }
                continue;
            }
            let content = msg.get("content").and_then(Value::as_str).unwrap_or("");
            if parse_final(content).is_some() {
                self.store(db, id, &json!({"role": "assistant", "content": content}), now)?;
                return Ok(());
            }
            if reasked {
                return self.fail(db, id, "the reply was not the JSON answer, twice", now);
            }
            reasked = true;
            self.store(db, id, &json!({"role": "assistant", "content": content, "plab_hidden": true}), now)?;
            self.store(db, id, &json!({"role": "user", "content": REASK, "plab_hidden": true}), now)?;
        }
        self.fail(db, id, &format!("the assistant used its {MAX_ROUNDS} rounds without answering"), now)
    }
}
```

Notes for the implementer:
- `a_malformed_answer_is_re_asked_once` expects exactly 2 chat calls: first malformed → hidden assistant + hidden re-ask; second malformed → error. That matches the loop.
- `the_round_cap_stores_an_error` expects exactly 6 calls.
- `retry_replaces_the_error`: the first call returns 500 → error stored; retry finds the last non-hidden user (seq 1), deletes seq ≥ 2, reruns → `["system","user","assistant"]`.
- `start` with Stash failing: `context::gather` must not return Err for Stash failures (only for DB errors) — it doesn't.
- Remove the temporary `#![allow(dead_code)]` lines from Tasks 2–4; if clippy then flags something still unused (e.g. `LibScene::date`), keep the field and allow it locally with a one-line reason, or drop it if nothing will use it.

- [ ] **Step 6: Run tests** — `cargo test` all PASS; `cargo clippy --all-targets -- -D warnings` clean.

- [ ] **Step 7: Commit**

```bash
git add src/assistant src/main.rs src/taste.rs src/candidates.rs src/stash/library.rs
git commit -m "feat(galactica): plab assistant turn loop with read-only tools"
```

---

### Task 7: HTTP API and wiring

**Files:**
- Create: `packages/plab/src/web/assistant_routes.rs`
- Modify: `packages/plab/src/web.rs` (WebState field; `handle` takes the body and dispatches `/api/assistant/` and DELETE; `mod assistant_routes;`)
- Modify: `packages/plab/src/api.rs` (make `fn topic` `pub(crate)`)
- Modify: `packages/plab/src/app.rs` (add `pub fn assistant`)
- Modify: `packages/plab/src/commands.rs` (WebState literal near line 291)
- Modify: `packages/plab/src/web_tests.rs` (Fx literal near line 190: `assistant: None`; helpers; tests)

**Interfaces:**
- Consumes: Task 6 `Assistant`, `Kind`, `TurnError`, `parse_final`, `is_hidden`, `error_of`, `degraded_of`; Task 4 `LibScene`; existing `api::{TopicDto, topic}`, `web::downloads`, `Db::{find, added, queued, externals}`, `site::get().topic_url()`.
- Produces HTTP:
  - `POST /api/assistant/recommend` → 200 `ConversationDto`
  - `POST /api/assistant/conversations` body `{"text": "…"}` → 200 `ConversationDto`
  - `POST /api/assistant/conversations/<id>/messages` body `{"text": "…"}` → 200 `ConversationDto`
  - `POST /api/assistant/conversations/<id>/retry` → 200 `ConversationDto`
  - `GET /api/assistant/conversations` → 200 `[ConversationSummaryDto]`
  - `GET /api/assistant/conversations/<id>` → 200 `ConversationDto`
  - `DELETE /api/assistant/conversations/<id>` → 204
  - Errors (text/plain): 503 no assistant / not ready, 404 unknown, 409 busy, 413 body > 16384 bytes, 400 bad JSON or empty text, 500 other.
- DTOs (serde `rename_all = "camelCase"`):
  - `ConversationSummaryDto { id: i64, title: String, kind: String, updated_at: i64 }`
  - `ConversationDto { id, title, kind, updated_at, now: i64, topic_url: String, degraded: Vec<String>, turns: Vec<TurnDto>, topics: Vec<TopicDto>, scenes: Vec<SceneDto> }`
  - `TurnDto { seq: i64, role: &'static str /* "user" | "assistant" */, text: String, picks: Vec<PickDto>, error: Option<String> }`
  - `PickDto { #[serde(rename = "ref")] ref_: String, action: String, reason: String }`
  - `SceneDto { #[serde(rename = "ref")] ref_: String, id: String, title: String, studio: Option<String>, performers: Vec<String>, screenshot: Option<String>, link: Option<String> }`

- [ ] **Step 1: Write the failing web tests** in `web_tests.rs`

Add to `Fx` (beside `post`):

```rust
    async fn send_body(&self, method: &str, path: &str, body: Vec<u8>) -> Reply {
        let req = Request::builder()
            .method(method)
            .uri(path)
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        let resp = router(self.state.clone()).oneshot(req).await.unwrap();
        let (parts, body) = resp.into_parts();
        Reply {
            status: parts.status.as_u16(),
            headers: parts.headers,
            body: body.collect().await.unwrap().to_bytes().to_vec(),
        }
    }

    async fn post_json(&self, path: &str, v: Value) -> Reply {
        self.send_body("POST", path, v.to_string().into_bytes()).await
    }
```

(If `send_to` can be generalized to take a body instead, do that and make `send_body` call it — don't keep two copies of the response-collecting code.)

A fixture with a live assistant (OpenRouter + Stash on one wiremock server):

```rust
async fn assistant_fx(server: &wiremock::MockServer) -> Fx {
    use wiremock::{Mock, ResponseTemplate, matchers::path};
    Mock::given(path("/graphql"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"data": {"findScenes": {"scenes": [
            {"id": "4", "title": "Alpha", "performers": [{"id": "p", "name": "Performer B"}],
             "paths": {"screenshot": "http://localhost:9999/scene/4/screenshot?t=1"}}
        ]}}})))
        .mount(server)
        .await;
    let uri = server.uri();
    Fx::with(FakeTracker::default(), move |_, st| {
        let llm = crate::llm::OpenRouter::new(&uri, "k".into(), "p".into(), "j".into());
        let stash = crate::stash::Stash::new(&format!("{uri}/graphql"), None);
        st.assistant = Some(Arc::new(crate::assistant::Assistant::new(llm, stash, "m".into(), "x".into())));
        st.stash_web_url = Some("https://stash.example".into());
    })
}

fn answer(picks: Value) -> wiremock::ResponseTemplate {
    wiremock::ResponseTemplate::new(200).set_body_json(json!({"choices": [{"message": {
        "role": "assistant", "content": json!({"text": "Here.", "picks": picks}).to_string()
    }}]}))
}
```

Tests:

```rust
#[tokio::test]
async fn assistant_off_without_a_key() {
    let fx = Fx::new();
    let r = fx.post("/api/assistant/recommend").await;
    assert_eq!(r.status, 503);
    assert!(r.text().contains("OpenRouter"));
}

#[tokio::test]
async fn recommend_resolves_picks_and_drops_unknown_refs() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(crate::llm::CHAT_PATH))
        .respond_with(answer(json!([
            {"ref": "t:5", "action": "download", "reason": "same studio"},
            {"ref": "s:4", "action": "watch", "reason": "same performer"},
            {"ref": "t:999", "action": "stream", "reason": "gone"},
            {"ref": "s:4", "action": "download", "reason": "wrong action for a scene"}
        ])))
        .mount(&server)
        .await;
    let fx = assistant_fx(&server).await;
    fx.save_video(&[listed(row(5, "Alpha One"), &[COVER])]);
    let r = fx.post("/api/assistant/recommend").await;
    assert_eq!(r.status, 200, "{}", r.text());
    let j = r.json();
    let turn = j["turns"].as_array().unwrap().last().unwrap().clone();
    assert_eq!(turn["role"], "assistant");
    assert_eq!(turn["text"], "Here.");
    let refs: Vec<&str> = turn["picks"].as_array().unwrap().iter().map(|p| p["ref"].as_str().unwrap()).collect();
    assert_eq!(refs, vec!["t:5", "s:4"]);
    assert_eq!(j["topics"][0]["id"], 5);
    assert_eq!(j["scenes"][0]["link"], "https://stash.example/scenes/4");
    assert_eq!(j["scenes"][0]["screenshot"], "https://stash.example/scene/4/screenshot?t=1");
    // The user's turn is the canned ask; system and tool messages are not shown.
    assert_eq!(j["turns"].as_array().unwrap().len(), 2);
    let list = fx.get("/api/assistant/conversations").await.json();
    assert_eq!(list[0]["kind"], "recommend");
}

#[tokio::test]
async fn chat_messages_get_and_delete() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(crate::llm::CHAT_PATH))
        .respond_with(answer(json!([])))
        .mount(&server)
        .await;
    let fx = assistant_fx(&server).await;
    let r = fx.post_json("/api/assistant/conversations", json!({"text": "something short"})).await;
    assert_eq!(r.status, 200, "{}", r.text());
    let id = r.json()["id"].as_i64().unwrap();
    assert_eq!(r.json()["title"], "something short");
    let r = fx.post_json(&format!("/api/assistant/conversations/{id}/messages"), json!({"text": "more"})).await;
    assert_eq!(r.json()["turns"].as_array().unwrap().len(), 4);
    assert_eq!(fx.get(&format!("/api/assistant/conversations/{id}")).await.status, 200);
    assert_eq!(fx.request("DELETE", &format!("/api/assistant/conversations/{id}")).await.status, 204);
    assert_eq!(fx.get(&format!("/api/assistant/conversations/{id}")).await.status, 404);
}

#[tokio::test]
async fn assistant_rejects_bad_bodies_and_busy_conversations() {
    let server = wiremock::MockServer::start().await;
    let fx = assistant_fx(&server).await;
    let big = vec![b'a'; 16 * 1024 + 1];
    assert_eq!(fx.send_body("POST", "/api/assistant/conversations", big).await.status, 413);
    assert_eq!(fx.post_json("/api/assistant/conversations", json!({"text": "  "})).await.status, 400);
    assert_eq!(fx.send_body("POST", "/api/assistant/conversations", b"{".to_vec()).await.status, 400);
    let id = fx.state.db.create_conversation("t", "chat", 0).unwrap();
    let a = fx.state.assistant.clone().unwrap();
    let _g = a.lock(id).unwrap();
    let r = fx.post_json(&format!("/api/assistant/conversations/{id}/messages"), json!({"text": "x"})).await;
    assert_eq!(r.status, 409);
}
```

`Value`/`json!` must be imported in `web_tests.rs` if they are not already (`use serde_json::{Value, json};`). Use whatever `save_video` signature the file has (it takes `&[Listed]`).

- [ ] **Step 2: Run to verify failure** — `cargo test web::tests::assistant web::tests::recommend web::tests::chat_messages` fails to compile (no `assistant` field).

- [ ] **Step 3: Plumbing in `web.rs`**

- Add to `WebState`: 

```rust
    /// The assistant; None without an OpenRouter key (its routes answer 503).
    pub assistant: Option<Arc<crate::assistant::Assistant>>,
```

- Add `mod assistant_routes;` near the top (the file lives at `src/web/assistant_routes.rs`).
- Change `handle` to take the body as its last extractor and pass it on:

```rust
async fn handle<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    State(st): State<Arc<WebState<T, C>>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Body,
) -> Response<Body> {
    let path = uri.path();
    if let Some(rest) = path.strip_prefix("/api/assistant/") {
        return assistant_routes::route(&st, &method, rest, body).await;
    }
    // … existing body unchanged …
```

(`Body` is `axum::body::Body`, already imported for responses.)

- `api.rs`: change `fn topic(` to `pub(crate) fn topic(`.

- [ ] **Step 4: Write `src/web/assistant_routes.rs`**

```rust
//! The assistant's routes (`/api/assistant/…`) and its transcript DTO. Picks resolve here,
//! at read time, so a release card shows its live status rather than the status it had
//! when the model named it.

use std::collections::{HashMap, HashSet};

use axum::body::Body;
use axum::http::{Method, Response};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{WebState, json_body, not_found, now, send, text};
use crate::api::TopicDto;
use crate::assistant::{self, Assistant, Kind, TurnError};
use crate::db::{ConversationRow, Listed, Section};
use crate::stash::library::LibScene;
use crate::tracker::TrackerApi;
use crate::transmission::TorrentClient;

/// Request bodies are a chat message: 16 KB is generous.
const BODY_LIMIT: usize = 16 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConversationSummaryDto {
    id: i64,
    title: String,
    kind: String,
    updated_at: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConversationDto {
    id: i64,
    title: String,
    kind: String,
    updated_at: i64,
    now: i64,
    topic_url: String,
    degraded: Vec<String>,
    turns: Vec<TurnDto>,
    topics: Vec<TopicDto>,
    scenes: Vec<SceneDto>,
}

#[derive(Serialize)]
struct TurnDto {
    seq: i64,
    role: &'static str,
    text: String,
    picks: Vec<PickDto>,
    error: Option<String>,
}

#[derive(Serialize)]
struct PickDto {
    #[serde(rename = "ref")]
    ref_: String,
    action: String,
    reason: String,
}

#[derive(Serialize)]
struct SceneDto {
    #[serde(rename = "ref")]
    ref_: String,
    id: String,
    title: String,
    studio: Option<String>,
    performers: Vec<String>,
    screenshot: Option<String>,
    link: Option<String>,
}

#[derive(Deserialize)]
struct TextBody {
    text: String,
}

fn turn_error(e: TurnError) -> Response<Body> {
    let code = match e {
        TurnError::NotReady(_) => 503,
        TurnError::NotFound => 404,
        TurnError::Busy => 409,
        TurnError::Failed(_) => 500,
    };
    text(code, e.to_string())
}

async fn read_text(body: Body) -> Result<String, Response<Body>> {
    let bytes = axum::body::to_bytes(body, BODY_LIMIT)
        .await
        .map_err(|_| text(413, "the message is too long"))?;
    let b: TextBody = serde_json::from_slice(&bytes).map_err(|e| text(400, format!("bad body: {e}")))?;
    let t = b.text.trim();
    if t.is_empty() {
        return Err(text(400, "text is required"));
    }
    Ok(t.to_string())
}

/// `conversations/<id>` and `conversations/<id>/<action>`.
fn conversation_path(rest: &str) -> Option<(i64, Option<&str>)> {
    let tail = rest.strip_prefix("conversations/")?;
    let (id, action) = match tail.split_once('/') {
        Some((id, a)) => (id, Some(a)),
        None => (tail, None),
    };
    Some((id.parse().ok()?, action))
}

pub(super) async fn route<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    method: &Method,
    rest: &str,
    body: Body,
) -> Response<Body> {
    let Some(a) = st.assistant.as_deref() else {
        return text(503, "the assistant needs an OpenRouter key");
    };
    let t = now();
    match (method, rest) {
        (&Method::GET, "conversations") => match st.db.conversations() {
            Ok(rows) => json_body(
                &rows
                    .into_iter()
                    .map(|c| ConversationSummaryDto { id: c.id, title: c.title, kind: c.kind, updated_at: c.updated_at })
                    .collect::<Vec<_>>(),
            ),
            Err(e) => text(500, format!("{e:#}")),
        },
        (&Method::POST, "recommend") => match a.start(&st.db, Kind::Recommend, None, t).await {
            Ok(id) => transcript(st, a, id).await,
            Err(e) => turn_error(e),
        },
        (&Method::POST, "conversations") => match read_text(body).await {
            Err(r) => r,
            Ok(msg) => match a.start(&st.db, Kind::Chat, Some(&msg), t).await {
                Ok(id) => transcript(st, a, id).await,
                Err(e) => turn_error(e),
            },
        },
        _ => match (method, conversation_path(rest)) {
            (&Method::GET, Some((id, None))) => transcript(st, a, id).await,
            (&Method::DELETE, Some((id, None))) => match st.db.delete_conversation(id) {
                Ok(true) => send(204, Vec::new(), "text/plain", "no-store"),
                Ok(false) => not_found(),
                Err(e) => text(500, format!("{e:#}")),
            },
            (&Method::POST, Some((id, Some("messages")))) => match read_text(body).await {
                Err(r) => r,
                Ok(msg) => match a.turn(&st.db, id, Some(&msg), t).await {
                    Ok(()) => transcript(st, a, id).await,
                    Err(e) => turn_error(e),
                },
            },
            (&Method::POST, Some((id, Some("retry")))) => match a.turn(&st.db, id, None, t).await {
                Ok(()) => transcript(st, a, id).await,
                Err(e) => turn_error(e),
            },
            _ => not_found(),
        },
    }
}

/// Stash's own screenshot URL names the address plab reached it at; the browser needs
/// Stash's public address with the same path.
fn rebase(url: &str, web: &str) -> String {
    let path = url
        .split_once("://")
        .and_then(|(_, rest)| rest.find('/').map(|i| &rest[i..]))
        .unwrap_or(url);
    format!("{}{path}", web.trim_end_matches('/'))
}

fn scene_dto(s: &LibScene, web: Option<&str>) -> SceneDto {
    SceneDto {
        ref_: format!("s:{}", s.id),
        id: s.id.clone(),
        title: s.label(),
        studio: s.studio.as_ref().map(|x| x.name.clone()),
        performers: s.performers.iter().map(|p| p.name.clone()).collect(),
        screenshot: web.and_then(|w| s.paths.screenshot.as_deref().map(|u| rebase(u, w))),
        link: web.map(|w| format!("{}/scenes/{}", w.trim_end_matches('/'), s.id)),
    }
}

async fn transcript<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    a: &Assistant,
    id: i64,
) -> Response<Body> {
    let t = now();
    let row: ConversationRow = match st.db.conversation(id) {
        Ok(Some(r)) => r,
        Ok(None) => return not_found(),
        Err(e) => return text(500, format!("{e:#}")),
    };
    let msgs = match st.db.messages(id) {
        Ok(m) => m,
        Err(e) => return text(500, format!("{e:#}")),
    };
    let mut degraded = vec![];
    let mut turns: Vec<(i64, &'static str, String, Vec<assistant::Pick>, Option<String>)> = vec![];
    for m in &msgs {
        let Ok(v) = serde_json::from_str::<Value>(&m.content) else { continue };
        if m.role == "system" {
            degraded = assistant::degraded_of(&v);
            continue;
        }
        if assistant::is_hidden(&v) || (m.role != "user" && m.role != "assistant") {
            continue;
        }
        if v.get("tool_calls").is_some_and(|c| c.as_array().is_some_and(|a| !a.is_empty())) {
            continue;
        }
        let content = v.get("content").and_then(Value::as_str).unwrap_or("");
        if m.role == "user" {
            turns.push((m.seq, "user", content.to_string(), vec![], None));
        } else if let Some(err) = assistant::error_of(&v) {
            turns.push((m.seq, "assistant", String::new(), vec![], Some(err.to_string())));
        } else if let Some(f) = assistant::parse_final(content) {
            turns.push((m.seq, "assistant", f.text, f.picks, None));
        }
    }
    // Resolve every ref once.
    let mut topic_ids: Vec<u64> = vec![];
    let mut scene_ids: Vec<String> = vec![];
    for (_, _, _, picks, _) in &turns {
        for p in picks {
            match (p.ref_.split_once(':'), p.action.as_str()) {
                (Some(("t", id)), "stream" | "download") => {
                    if let Ok(id) = id.parse::<u64>() && !topic_ids.contains(&id) {
                        topic_ids.push(id);
                    }
                }
                (Some(("s", id)), "watch") => {
                    if !scene_ids.iter().any(|s| s == id) {
                        scene_ids.push(id.to_string());
                    }
                }
                _ => {}
            }
        }
    }
    let downloads = super::downloads(st, t).await;
    let topics: Vec<TopicDto> = match resolve_topics(st, &topic_ids, &downloads, t) {
        Ok(v) => v,
        Err(e) => return text(500, format!("{e:#}")),
    };
    let scenes: Vec<SceneDto> = match a.stash().lib_scenes(&scene_ids).await {
        Ok(s) => s.iter().map(|s| scene_dto(s, st.stash_web_url.as_deref())).collect(),
        Err(e) => {
            tracing::info!(job = "web", "assistant scenes: {e:#}");
            if !degraded.iter().any(|d| d == "stash") {
                degraded.push("stash".into());
            }
            vec![]
        }
    };
    let known: HashSet<String> = topics
        .iter()
        .map(|t| format!("t:{}", t.id))
        .chain(scenes.iter().map(|s| s.ref_.clone()))
        .collect();
    let turns = turns
        .into_iter()
        .map(|(seq, role, text, picks, error)| TurnDto {
            seq,
            role,
            text,
            picks: picks
                .into_iter()
                .filter(|p| {
                    let ok_kind = matches!(
                        (p.ref_.as_bytes().first(), p.action.as_str()),
                        (Some(b't'), "stream" | "download") | (Some(b's'), "watch")
                    );
                    let ok = ok_kind && known.contains(&p.ref_);
                    if !ok {
                        tracing::debug!(job = "web", "assistant pick {} ({}) dropped", p.ref_, p.action);
                    }
                    ok
                })
                .map(|p| PickDto { ref_: p.ref_, action: p.action, reason: p.reason })
                .collect(),
            error,
        })
        .collect();
    json_body(&ConversationDto {
        id: row.id,
        title: row.title,
        kind: row.kind,
        updated_at: row.updated_at,
        now: t,
        topic_url: crate::site::get().topic_url(),
        degraded,
        turns,
        topics,
        scenes,
    })
}

fn resolve_topics<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    ids: &[u64],
    downloads: &crate::api::Downloads, // the type `super::downloads` returns
    now: i64,
) -> anyhow::Result<Vec<TopicDto>> {
    let added = st.db.added()?;
    let mut queued: HashSet<u64> = HashSet::new();
    for s in [Section::Video, Section::Indexers] {
        queued.extend(st.db.queued(s)?);
    }
    let externals: HashMap<u64, crate::db::External> = st.db.externals()?;
    let mut out = vec![];
    for &id in ids {
        if let Some((topic, _)) = st.db.find(id, now)? {
            let listed = Listed { topic, filters: vec![], curated_reason: None };
            out.push(crate::api::topic(&listed, &added, &queued, downloads, &externals));
        }
    }
    Ok(out)
}
```

The imports above match `web.rs`'s own (`crate::tracker::TrackerApi`, `crate::transmission::TorrentClient`, `crate::api::Downloads`). Make `json_body`, `not_found`, `send`, `text` and `now` visible to the child module: they are private fns in `web.rs`, which a child module can already use via `super::` — no visibility change needed.

- [ ] **Step 5: Construct and wire**

`src/app.rs`:

```rust
/// The assistant, or None without an OpenRouter key. Its own OpenRouter client, so the
/// web task and the jobs never share one; `base` is `llm::OPENROUTER` outside tests.
pub fn assistant(cfg: &Config, base: &str) -> anyhow::Result<Option<crate::assistant::Assistant>> {
    Ok(openrouter(cfg, base)?.map(|llm| {
        crate::assistant::Assistant::new(
            llm,
            stash(cfg),
            cfg.assistant_model.clone(),
            crate::site::get().prompts.assistant.clone(),
        )
    }))
}
```

`src/commands.rs` WebState literal: add `assistant: crate::app::assistant(&a.cfg, crate::llm::OPENROUTER)?.map(Arc::new),` (match how `app` is imported there). `web_tests.rs` Fx literal: add `assistant: None,`.

- [ ] **Step 6: Run tests** — `cargo test` all PASS; `cargo clippy --all-targets -- -D warnings` clean. Then build the package once: `cd /home/arosenfeld/Code/nixos && git add -N packages/plab && nix build .#plab --no-link` (it runs `cargo test` in checkPhase). 

- [ ] **Step 7: Commit**

```bash
git add src/web.rs src/web src/api.rs src/app.rs src/commands.rs src/web_tests.rs
git commit -m "feat(galactica): plab serves the assistant's conversations"
```

---

### Task 8: The Assistant tab (UI)

**Files:**
- Modify: `packages/plab/ui/src/lib/types.ts`, `api.ts`, `route.ts`, `route.test.ts`, `reducer.ts`
- Create: `packages/plab/ui/src/lib/assistant.ts`, `assistant.test.ts`, `assistant.svelte.ts`
- Create: `packages/plab/ui/src/components/AssistantView.svelte`, `SceneCard.svelte`
- Modify: `packages/plab/ui/src/components/Navbar.svelte`, `packages/plab/ui/src/App.svelte`

**Interfaces:**
- Consumes: Task 7 HTTP API and DTO shapes (camelCase JSON).
- Produces: `Route` variant `{ view: 'assistant'; id: number | null }`; store `assistant` with `load()`, `open(id)`, `recommend()`, `newChat(text)`, `send(text)`, `retry()`, `remove(id)`, `apply(ev)`.

- [ ] **Step 1: Types** — append to `types.ts`:

```ts
export interface SceneCardData {
  ref: string;
  id: string;
  title: string;
  studio: string | null;
  performers: string[];
  screenshot: string | null;
  link: string | null;
}

export type PickAction = 'watch' | 'stream' | 'download';

export interface PickData {
  ref: string;
  action: PickAction;
  reason: string;
}

export interface TurnData {
  seq: number;
  role: 'user' | 'assistant';
  text: string;
  picks: PickData[];
  error: string | null;
}

export interface ConversationSummary {
  id: number;
  title: string;
  kind: 'recommend' | 'chat';
  updatedAt: number;
}

export interface Conversation extends ConversationSummary {
  now: number;
  topicUrl: string;
  degraded: string[];
  turns: TurnData[];
  topics: Topic[];
  scenes: SceneCardData[];
}
```

- [ ] **Step 2: Failing tests**

`route.test.ts` — add:

```ts
it('parses the assistant routes', () => {
  expect(parse('/assistant', '')).toEqual({ view: 'assistant', id: null });
  expect(parse('/assistant/12', '')).toEqual({ view: 'assistant', id: 12 });
  expect(parse('/assistant/x', '')).toEqual({ view: 'assistant', id: null });
});
```

(Match the file's existing `describe`/`it` imports.)

`assistant.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { resolvePick, lastFailed, upsertSummary } from './assistant';
import type { Conversation, Topic } from './types';

const topic = { id: 5, title: 'Alpha One' } as Topic;
const conv: Conversation = {
  id: 1, title: 't', kind: 'chat', updatedAt: 2, now: 3, topicUrl: 'u', degraded: [],
  turns: [
    { seq: 1, role: 'user', text: 'hi', picks: [], error: null },
    { seq: 2, role: 'assistant', text: 'x', picks: [
      { ref: 't:5', action: 'download', reason: 'r' },
      { ref: 's:4', action: 'watch', reason: 'w' },
      { ref: 't:9', action: 'stream', reason: 'missing' },
    ], error: null },
  ],
  topics: [topic],
  scenes: [{ ref: 's:4', id: '4', title: 'S', studio: null, performers: [], screenshot: null, link: null }],
};

describe('resolvePick', () => {
  it('finds topics and scenes by ref', () => {
    const [a, b, c] = conv.turns[1].picks.map((p) => resolvePick(conv, p));
    expect(a).toEqual({ kind: 'topic', topic, pick: conv.turns[1].picks[0] });
    expect(b?.kind).toBe('scene');
    expect(c).toBeNull();
  });
});

describe('lastFailed', () => {
  it('is true only when the last turn is an error', () => {
    expect(lastFailed(conv)).toBe(false);
    const failed = { ...conv, turns: [...conv.turns, { seq: 3, role: 'assistant' as const, text: '', picks: [], error: 'boom' }] };
    expect(lastFailed(failed)).toBe(true);
  });
});

describe('upsertSummary', () => {
  it('moves the conversation to the top', () => {
    const list = [{ id: 2, title: 'b', kind: 'chat' as const, updatedAt: 1 }, { id: 1, title: 'old', kind: 'chat' as const, updatedAt: 0 }];
    expect(upsertSummary(list, conv).map((c) => [c.id, c.title])).toEqual([[1, 't'], [2, 'b']]);
  });
});
```

- [ ] **Step 3: Run to verify failure** — `cd ui && npm test` fails (module not found / route mismatch).

- [ ] **Step 4: Implement**

`route.ts`: extend the type and add the case before `default`:

```ts
export type Route =
  | { view: Section }
  | { view: 'search'; q: string }
  | { view: 'jobs' }
  | { view: 'assistant'; id: number | null };
```

```ts
  if (path === '/assistant' || path.startsWith('/assistant/')) {
    const n = Number(path.slice('/assistant/'.length));
    return { view: 'assistant', id: Number.isInteger(n) && n > 0 ? n : null };
  }
```

(Put the `if` before the `switch`.)

`reducer.ts`: widen `applyTopic`'s first parameter from `Iterable<List>` to `Iterable<{ topics: Topic[] }>` (import `Topic` if needed) so a conversation's topics get live events too. Existing callers are unaffected.

`assistant.ts`:

```ts
import type { Conversation, ConversationSummary, PickData, SceneCardData, Topic } from './types';

export type Resolved =
  | { kind: 'topic'; topic: Topic; pick: PickData }
  | { kind: 'scene'; scene: SceneCardData; pick: PickData };

/** A pick's card data, or null when the server could not resolve it. */
export function resolvePick(c: Conversation, pick: PickData): Resolved | null {
  if (pick.ref.startsWith('t:')) {
    const id = Number(pick.ref.slice(2));
    const topic = c.topics.find((t) => t.id === id);
    return topic ? { kind: 'topic', topic, pick } : null;
  }
  const scene = c.scenes.find((s) => s.ref === pick.ref);
  return scene ? { kind: 'scene', scene, pick } : null;
}

export function lastFailed(c: Conversation): boolean {
  return c.turns.at(-1)?.error != null;
}

export function upsertSummary(list: ConversationSummary[], c: Conversation): ConversationSummary[] {
  const s: ConversationSummary = { id: c.id, title: c.title, kind: c.kind, updatedAt: c.updatedAt };
  return [s, ...list.filter((x) => x.id !== c.id)];
}
```

`api.ts` — add (and import the new types):

```ts
async function sendJson<T>(url: string, method: string, body?: unknown): Promise<T> {
  const r = await reach(() =>
    fetch(url, {
      method,
      headers: body === undefined ? undefined : { 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
  );
  if (!r.ok) {
    const plain = r.headers.get('content-type')?.startsWith('text/plain');
    throw new HttpError((plain && (await r.text())) || `HTTP ${r.status}`, r.status);
  }
  return (r.status === 204 ? undefined : await r.json()) as T;
}

const A = '/api/assistant';
export const fetchConversations = () => getJson<ConversationSummary[]>(`${A}/conversations`);
export const fetchConversation = (id: number) => getJson<Conversation>(`${A}/conversations/${id}`);
export const postRecommend = () => sendJson<Conversation>(`${A}/recommend`, 'POST');
export const postChat = (text: string) => sendJson<Conversation>(`${A}/conversations`, 'POST', { text });
export const postMessage = (id: number, text: string) =>
  sendJson<Conversation>(`${A}/conversations/${id}/messages`, 'POST', { text });
export const postRetry = (id: number) => sendJson<Conversation>(`${A}/conversations/${id}/retry`, 'POST');
export const deleteConversation = (id: number) => sendJson<void>(`${A}/conversations/${id}`, 'DELETE');
```

Refactor `getJson`'s error branch and `sendJson`'s into one small `async function fail(r: Response): Promise<never>` so the error-text logic exists once.

`assistant.svelte.ts`:

```ts
import { deleteConversation, fetchConversation, fetchConversations, postChat, postMessage, postRecommend, postRetry } from './api';
import { upsertSummary } from './assistant';
import { applyTopic } from './reducer';
import { router } from './router.svelte';
import type { Conversation, ConversationSummary, ServerEvent } from './types';

class AssistantStore {
  list = $state<ConversationSummary[]>([]);
  current = $state<Conversation | null>(null);
  busy = $state(false);
  error = $state<string | null>(null);

  private async run(f: () => Promise<Conversation>) {
    this.busy = true;
    this.error = null;
    try {
      const c = await f();
      this.current = c;
      this.list = upsertSummary(this.list, c);
      if (router.route.view !== 'assistant' || router.route.id !== c.id) router.go(`/assistant/${c.id}`);
    } catch (e) {
      this.error = e instanceof Error ? e.message : String(e);
    } finally {
      this.busy = false;
    }
  }

  async load() {
    try {
      this.list = await fetchConversations();
      this.error = null;
    } catch (e) {
      this.error = e instanceof Error ? e.message : String(e);
    }
  }

  async open(id: number | null) {
    if (id === null) {
      this.current = null;
      return;
    }
    if (this.current?.id === id) return;
    try {
      this.current = await fetchConversation(id);
      this.error = null;
    } catch (e) {
      this.error = e instanceof Error ? e.message : String(e);
    }
  }

  recommend = () => this.run(postRecommend);
  newChat = (text: string) => this.run(() => postChat(text));
  send = (text: string) => {
    const c = this.current;
    return c ? this.run(() => postMessage(c.id, text)) : this.newChat(text);
  };
  retry = () => {
    const c = this.current;
    return c ? this.run(() => postRetry(c.id)) : Promise.resolve();
  };

  async remove(id: number) {
    try {
      await deleteConversation(id);
      this.list = this.list.filter((c) => c.id !== id);
      if (this.current?.id === id) router.go('/assistant');
    } catch (e) {
      this.error = e instanceof Error ? e.message : String(e);
    }
  }

  apply(ev: ServerEvent) {
    if (this.current) applyTopic([this.current], ev);
  }
}

export const assistant = new AssistantStore();
```

`SceneCard.svelte`:

```svelte
<script lang="ts">
  import type { SceneCardData } from '../lib/types';

  let { scene, reason }: { scene: SceneCardData; reason: string } = $props();
  let failed = $state(false);
</script>

<div class="card bg-base-200 shadow-sm overflow-hidden">
  <figure class="relative aspect-[16/10] bg-black">
    {#if scene.screenshot && !failed}
      <img class="w-full h-full object-cover" loading="lazy" src={scene.screenshot} alt="" onerror={() => (failed = true)} />
    {/if}
    <span class="badge badge-primary font-bold absolute top-2 left-2">watch</span>
  </figure>
  <div class="card-body p-3 gap-1">
    <h3 class="font-semibold leading-tight">{scene.title}</h3>
    {#if scene.studio}<p class="text-sm text-base-content/70">{scene.studio}</p>{/if}
    {#if scene.performers.length}<p class="text-sm text-base-content/70">{scene.performers.join(', ')}</p>{/if}
    <p class="text-sm italic">{reason}</p>
    {#if scene.link}
      <div class="card-actions justify-end">
        <a class="btn btn-sm btn-primary" href={scene.link} target="_blank" rel="noopener">Open in Stash</a>
      </div>
    {/if}
  </div>
</div>
```

`AssistantView.svelte` — layout: two columns (`grid md:grid-cols-[16rem_1fr] gap-4`). Read `ListView.svelte` first and mirror how it mounts `Gallery` and `Player` and what it passes to `Card` (`section`, `now`, `topicUrl`, `isNew`, `fs`, `stream`, `ongallery`, `onstream`); use `new FilterState(null)` for `fs`, `isNew={false}`, `section="video"`, `now={c.now}`, `topicUrl={c.topicUrl}`, and the same `stream` flag source ListView uses.

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import { lastFailed, resolvePick } from '../lib/assistant';
  import { assistant } from '../lib/assistant.svelte';
  import { FilterState } from '../lib/filters.svelte';
  import { link, router } from '../lib/router.svelte';
  import Card from './Card.svelte';
  import Navbar from './Navbar.svelte';
  import SceneCard from './SceneCard.svelte';
  // + Gallery and Player exactly as ListView imports and binds them

  const fs = new FilterState(null);
  let draft = $state('');

  onMount(() => void assistant.load());
  $effect(() => {
    if (router.route.view === 'assistant') void assistant.open(router.route.id);
  });

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    const t = draft.trim();
    if (!t || assistant.busy) return;
    draft = '';
    await assistant.send(t);
  }
</script>

<Navbar />
<div class="grid md:grid-cols-[16rem_1fr] gap-4">
  <aside class="flex flex-col gap-2">
    <div class="flex gap-2">
      <button class="btn btn-primary btn-sm flex-1" disabled={assistant.busy} onclick={() => assistant.recommend()}>Recommend</button>
      <a class="btn btn-sm" href="/assistant" use:link>New chat</a>
    </div>
    <ul class="menu menu-sm bg-base-200 rounded-box w-full">
      {#each assistant.list as c (c.id)}
        <li class="flex-row">
          <a class={['flex-1 truncate', assistant.current?.id === c.id && 'menu-active']} href={`/assistant/${c.id}`} use:link>{c.title}</a>
          <button class="btn btn-ghost btn-xs" aria-label="Delete" onclick={() => assistant.remove(c.id)}>✕</button>
        </li>
      {/each}
    </ul>
  </aside>

  <section class="flex flex-col gap-4 min-w-0">
    {#if assistant.error}<div class="alert alert-error">{assistant.error}</div>{/if}
    {#if assistant.current}
      {@const c = assistant.current}
      {#if c.degraded.includes('stash')}
        <div class="alert alert-warning text-sm">Stash could not be reached: no watch picks, and the profile has only streams.</div>
      {/if}
      {#each c.turns as turn (turn.seq)}
        {#if turn.role === 'user'}
          <div class="chat chat-end"><div class="chat-bubble">{turn.text}</div></div>
        {:else if turn.error}
          <div class="alert alert-error">
            <span>{turn.error}</span>
            {#if lastFailed(c) && turn === c.turns.at(-1)}
              <button class="btn btn-sm" disabled={assistant.busy} onclick={() => assistant.retry()}>Retry</button>
            {/if}
          </div>
        {:else}
          <div class="chat chat-start"><div class="chat-bubble chat-bubble-neutral whitespace-pre-wrap">{turn.text}</div></div>
          {#if turn.picks.length}
            <div class="grid gap-3 grid-cols-[repeat(auto-fill,minmax(18rem,1fr))]">
              {#each turn.picks as pick (pick.ref + pick.action)}
                {@const r = resolvePick(c, pick)}
                {#if r?.kind === 'topic'}
                  <div class="flex flex-col gap-1">
                    <span class="text-sm italic"><span class="badge badge-sm mr-1">{pick.action}</span>{pick.reason}</span>
                    <Card topic={r.topic} section="video" now={c.now} topicUrl={c.topicUrl} isNew={false} {fs}
                      stream={true}
                      ongallery={(images) => gallery?.open(images)} onstream={(id) => player?.open(id)} />
                  </div>
                {:else if r?.kind === 'scene'}
                  <SceneCard scene={r.scene} reason={pick.reason} />
                {/if}
              {/each}
            </div>
          {/if}
        {/if}
      {/each}
    {:else}
      <p class="text-base-content/60">Press Recommend for picks from your recent views, or ask something below.</p>
    {/if}

    {#if assistant.busy}<div class="flex items-center gap-2 text-sm"><span class="loading loading-dots loading-sm"></span>Thinking…</div>{/if}

    <form class="join w-full" onsubmit={submit}>
      <input class="input join-item w-full" placeholder="Ask the assistant…" bind:value={draft} disabled={assistant.busy} maxlength="4000" />
      <button class="btn btn-primary join-item" disabled={assistant.busy || !draft.trim()}>Send</button>
    </form>
  </section>
</div>
```

`stream={true}`: every pick resolved as a topic is a stream or download pick from the Video or Indexers lists, which ListView streams (`section === 'video' || section === 'indexers'`). ListView renders `<Navbar>` itself, so AssistantView does too. Mount Gallery and Player the way ListView does: `let gallery = $state<ReturnType<typeof Gallery>>();`, `let player = $state<ReturnType<typeof Player>>();`, and the same `<Gallery bind:this={gallery} />` / `<Player bind:this={player} />` elements (copy their exact props from ListView).

`Navbar.svelte`: add `['assistant', '/assistant', 'Assistant']` to `tabs` after `games`.

`App.svelte`: import `AssistantView` and `assistant` store; in `live.on` add `assistant.apply(ev);`; add a branch `{:else if router.route.view === 'assistant'}<AssistantView />` before the `search` branch.

- [ ] **Step 5: Run checks** — `cd ui && npm test && npm run check` — all pass, no warnings (svelte-check runs with `--fail-on-warnings`).

- [ ] **Step 6: Build the package** — from the repo root: `git add -N packages/plab/ui && nix build .#plab --no-link`. Expected: success (the UI build runs vitest and svelte-check). No new npm deps, so `npmDepsHash` is unchanged.

- [ ] **Step 7: Commit**

```bash
git add ui/src
git commit -m "feat(galactica): plab Assistant tab with recommendations and chat"
```

---

### Task 9: Secret, docs, verification (controller, not a subagent)

- [ ] **Step 1: Add the prompt to `plab-site`.** Read the current keys: `nix develop -c sops --decrypt secrets/sops/galactica.yaml | grep -n plab-site` (find which file holds it via `grep -rn plab-site modules/hosts/galactica/services/plab/default.nix` and `.sops.yaml`). Set `prompts.assistant` inside the JSON value non-interactively (`sops --set` on the decrypted JSON path, or decrypt → edit with a script → encrypt), so the value is a short neutral system prompt: role (helps choose what to watch or download from the user's library and lists), use the profile and candidates, prefer variety, keep reasons to one line, be honest when nothing fits.
- [ ] **Step 2: Module comment.** In `modules/hosts/galactica/services/plab/default.nix`'s header comment, add two lines: the Assistant tab (on-demand, OpenRouter, read-only tools), its design path, and that `PLAB_ASSISTANT_MODEL` defaults to the parse model.
- [ ] **Step 3: Full verification.** `cd packages/plab && cargo test && cargo clippy --all-targets -- -D warnings`; `cd ui && npm test && npm run check`; `nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link` (one host, niced).
- [ ] **Step 4: Commit** `docs(galactica): plab assistant in the module notes` (plus the secret change as `chore(secrets): plab assistant prompt`).
- [ ] **Step 5: Ask the user** whether to deploy galactica now.
