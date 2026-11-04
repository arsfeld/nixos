# plab daily picks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** plab's `/` becomes **For you**, today's assistant picks. They are generated lazily by the
server once per local day and swapped into open tabs over SSE. The Tracker list moves to
`/tracker`, and the Assistant tab keeps chat and history.

**Architecture:** A daily is an ordinary `kind='recommend'` conversation. A new pure-ish
module, `src/assistant/daily.rs`, derives from `state.db` which daily to show, whether today
was attempted, and its error. `Assistant::ensure_daily` starts at most one generation, on a
detached task, guarded by an `AtomicBool`, and publishes `Event::AssistantDaily` when that
task ends. `GET /api/assistant/daily` and `POST /api/assistant/daily/refresh` expose it. The
Svelte app gets a `DailyView` at `/`, a `daily` store, and a `Picks.svelte` component shared
with `AssistantView`.

**Tech Stack:** Rust (axum, tokio, rusqlite, chrono, wiremock tests), Svelte 5 runes +
TypeScript + daisyUI, vitest.

**Spec:** `docs/superpowers/specs/2026-11-03-plab-daily-picks-design.md`

## Global Constraints

- Work on `master` in `/home/arosenfeld/Code/nixos`. Do not branch and do not use worktrees.
- Commits are conventional: `<type>(galactica): <subject>`. Never mention Claude.
- Rust tests: `cd packages/plab && cargo test` (all must pass). UI: `cd packages/plab/ui &&
  npm test && npm run check`. `check` fails on warnings, a11y warnings included.
- "Today" is galactica's local date: `chrono::Local`, formatted `YYYY-MM-DD`.
- Unfollowed dailies older than **30 days** are pruned. "Followed up" means **more than one
  visible user turn**, where a `plab_hidden` re-ask does not count.
- The SSE event's wire form is exactly `{"type": "assistantDaily"}`.
- `GET /api/assistant/daily` answers **200** even when the assistant is not ready, whether
  for lack of a key or of a prompt; the reason goes in `error`. `POST .../daily/refresh` answers
  409 while a generation runs.
- `POST /api/assistant/recommend` is removed.
- Do not add per-app firewall rules, new crates or new npm packages.

---

### Task 1: `daily.rs`, which derives the daily state from the DB

**Files:**
- Create: `packages/plab/src/assistant/daily.rs`
- Modify: `packages/plab/src/assistant/mod.rs` (add `pub mod daily;` beside `pub mod context;`)
- Modify: `packages/plab/src/db/assistant.rs` (add `conversations_of_kind`)

**Interfaces:**
- Produces:
  - `crate::db::Db::conversations_of_kind(&self, kind: &str) -> anyhow::Result<Vec<ConversationRow>>`, newest `created_at` first
  - `crate::assistant::daily::local_ymd(ts: i64) -> String`
  - `crate::assistant::daily::Daily { shown: Option<ConversationRow>, attempted_today: bool, error: Option<String> }`
  - `crate::assistant::daily::state(db: &Db, now: i64) -> anyhow::Result<Daily>`
  - `crate::assistant::daily::followed_up(db: &Db, id: i64) -> anyhow::Result<bool>`
  - `crate::assistant::daily::prune(db: &Db, now: i64) -> anyhow::Result<usize>`
  - `crate::assistant::daily::KEEP_DAYS: i64 = 30`

- [ ] **Step 1: Add the DB query.** In `src/db/assistant.rs`, add the following inside
  `impl Db`, after `conversations()`:

```rust
    /// Every conversation of one kind, newest first by creation.
    pub fn conversations_of_kind(&self, kind: &str) -> Result<Vec<ConversationRow>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT id, title, kind, created_at, updated_at FROM conversation
                 WHERE kind = ?1 ORDER BY created_at DESC, id DESC",
            )?;
            let rows = s.query_map(params![kind], ConversationRow::from_row)?;
            all(rows)
        })
    }
```

- [ ] **Step 2: Write `daily.rs` with its tests.** Write the tests first; the implementation
  is below them.

```rust
//! The daily picks shown on For you: which recommend conversation is shown, whether today
//! has been attempted, and which dailies count as followed up (kept, and listed in the
//! history) rather than unread (left out of the history, pruned after 30 days).
//! Design: docs/superpowers/specs/2026-11-03-plab-daily-picks-design.md

use anyhow::Result;
use serde_json::Value;

use super::{error_of, is_hidden, parse_final};
use crate::db::{ConversationRow, Db};

/// Unread dailies older than this are deleted when a new one is made.
pub const KEEP_DAYS: i64 = 30;

/// A timestamp's date on this machine's clock (galactica's local time), `YYYY-MM-DD`.
pub fn local_ymd(ts: i64) -> String {
    use chrono::TimeZone;
    chrono::Local
        .timestamp_opt(ts, 0)
        .single()
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

#[derive(Debug, Default, PartialEq)]
pub struct Daily {
    /// The newest recommend conversation whose answer has at least one pick.
    pub shown: Option<ConversationRow>,
    /// The newest recommend conversation was created today, whatever came of it.
    pub attempted_today: bool,
    /// Today's attempt has no good answer: its error, or that it never finished.
    pub error: Option<String>,
}

fn parsed(db: &Db, id: i64) -> Result<Vec<(String, Value)>> {
    Ok(db
        .messages(id)?
        .into_iter()
        .filter_map(|m| serde_json::from_str(&m.content).ok().map(|v| (m.role, v)))
        .collect())
}

/// User turns the user can see: the canned ask counts, a hidden re-ask does not.
fn user_turns(msgs: &[(String, Value)]) -> usize {
    msgs.iter().filter(|(r, v)| r == "user" && !is_hidden(v)).count()
}

/// The daily's answer: the first shown assistant message (not hidden, not a tool call).
fn first_answer(msgs: &[(String, Value)]) -> Option<&Value> {
    msgs.iter()
        .find(|(r, v)| {
            r == "assistant"
                && !is_hidden(v)
                && v.get("tool_calls").and_then(Value::as_array).is_none_or(|a| a.is_empty())
        })
        .map(|(_, v)| v)
}

fn has_picks(answer: Option<&Value>) -> bool {
    answer
        .and_then(|v| v.get("content")?.as_str())
        .and_then(parse_final)
        .is_some_and(|f| !f.picks.is_empty())
}

pub fn state(db: &Db, now: i64) -> Result<Daily> {
    let today = local_ymd(now);
    let mut d = Daily::default();
    for (i, row) in db.conversations_of_kind("recommend")?.into_iter().enumerate() {
        let msgs = parsed(db, row.id)?;
        let answer = first_answer(&msgs);
        if i == 0 && local_ymd(row.created_at) == today {
            d.attempted_today = true;
            d.error = match answer {
                Some(v) => error_of(v).map(str::to_owned),
                None => Some("today's picks did not finish".into()),
            };
        }
        if has_picks(answer) {
            d.shown = Some(row);
            break;
        }
    }
    Ok(d)
}

/// The user asked something of this conversation beyond its first question.
pub fn followed_up(db: &Db, id: i64) -> Result<bool> {
    Ok(user_turns(&parsed(db, id)?) > 1)
}

/// Delete the unread dailies older than `KEEP_DAYS`. Returns how many went.
pub fn prune(db: &Db, now: i64) -> Result<usize> {
    let cutoff = now - KEEP_DAYS * 86_400;
    let mut n = 0;
    for row in db.conversations_of_kind("recommend")? {
        if row.created_at < cutoff && !followed_up(db, row.id)? {
            db.delete_conversation(row.id)?;
            n += 1;
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const DAY: i64 = 86_400;
    /// Noon UTC: the same local date in any time zone from UTC-12 to UTC+11.
    const NOON: i64 = 20_000 * DAY + 43_200;

    fn answer(picks: Value) -> Value {
        json!({"role": "assistant", "content": json!({"text": "t", "picks": picks}).to_string()})
    }

    fn conv(db: &Db, at: i64, msgs: &[Value]) -> i64 {
        let id = db.create_conversation("Recommendations", "recommend", at).unwrap();
        for m in msgs {
            db.append_message(id, m["role"].as_str().unwrap(), &m.to_string(), at).unwrap();
        }
        id
    }

    fn ask() -> Value {
        json!({"role": "user", "content": "recommend"})
    }

    fn good() -> Vec<Value> {
        vec![json!({"role": "system", "content": "s"}), ask(), answer(json!([{"ref": "t:1", "action": "download", "reason": "r"}]))]
    }

    #[test]
    fn nothing_yet() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(state(&db, NOON).unwrap(), Daily::default());
    }

    #[test]
    fn yesterday_is_shown_and_today_is_not_attempted() {
        let db = Db::open_in_memory().unwrap();
        let y = conv(&db, NOON - DAY, &good());
        let d = state(&db, NOON).unwrap();
        assert_eq!(d.shown.map(|r| r.id), Some(y));
        assert!(!d.attempted_today);
        assert_eq!(d.error, None);
    }

    #[test]
    fn a_failed_today_keeps_yesterday_and_carries_the_error() {
        let db = Db::open_in_memory().unwrap();
        let y = conv(&db, NOON - DAY, &good());
        conv(&db, NOON, &[ask(), json!({"role": "assistant", "content": "", "plab_error": "boom"})]);
        let d = state(&db, NOON + 60).unwrap();
        assert_eq!(d.shown.map(|r| r.id), Some(y));
        assert!(d.attempted_today);
        assert_eq!(d.error.as_deref(), Some("boom"));
    }

    #[test]
    fn today_good_is_shown_without_error() {
        let db = Db::open_in_memory().unwrap();
        conv(&db, NOON - DAY, &good());
        let t = conv(&db, NOON, &good());
        let d = state(&db, NOON).unwrap();
        assert_eq!((d.shown.map(|r| r.id), d.attempted_today, d.error), (Some(t), true, None));
    }

    #[test]
    fn an_unfinished_today_is_an_error() {
        let db = Db::open_in_memory().unwrap();
        conv(&db, NOON, &[ask()]);
        let d = state(&db, NOON).unwrap();
        assert!(d.attempted_today && d.shown.is_none());
        assert_eq!(d.error.as_deref(), Some("today's picks did not finish"));
    }

    #[test]
    fn an_answer_without_picks_is_not_shown() {
        let db = Db::open_in_memory().unwrap();
        conv(&db, NOON - DAY, &[ask(), answer(json!([]))]);
        assert_eq!(state(&db, NOON).unwrap().shown, None);
    }

    #[test]
    fn followed_up_needs_a_second_visible_user_turn() {
        let db = Db::open_in_memory().unwrap();
        let mut msgs = good();
        msgs.push(json!({"role": "user", "content": "again", "plab_hidden": true}));
        let id = conv(&db, NOON, &msgs);
        assert!(!followed_up(&db, id).unwrap());
        db.append_message(id, "user", &json!({"role": "user", "content": "why?"}).to_string(), NOON).unwrap();
        assert!(followed_up(&db, id).unwrap());
    }

    #[test]
    fn prune_drops_only_old_unread_dailies() {
        let db = Db::open_in_memory().unwrap();
        let old = conv(&db, NOON - 31 * DAY, &good());
        let mut asked = good();
        asked.push(json!({"role": "user", "content": "why?"}));
        let kept = conv(&db, NOON - 31 * DAY, &asked);
        let recent = conv(&db, NOON - 29 * DAY, &good());
        let chat = db.create_conversation("c", "chat", NOON - 40 * DAY).unwrap();
        assert_eq!(prune(&db, NOON).unwrap(), 1);
        assert!(db.conversation(old).unwrap().is_none());
        for id in [kept, recent, chat] {
            assert!(db.conversation(id).unwrap().is_some());
        }
    }
}
```

  Add `pub mod daily;` to `src/assistant/mod.rs`, next to `pub mod context;`.

- [ ] **Step 3: Run the tests.** Run `cd packages/plab && cargo test assistant::daily`.
  Expected: all 8 pass. If `is_none_or` is unavailable on this toolchain, use
  `map_or(true, |a| a.is_empty())`.

- [ ] **Step 4: Run the full suite.** Run `cargo test`. Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/plab/src/assistant/daily.rs packages/plab/src/assistant/mod.rs packages/plab/src/db/assistant.rs
git commit -m "feat(galactica): plab derives the daily picks state from its recommend conversations"
```

---

### Task 2: `Assistant::ensure_daily` and the `AssistantDaily` event

**Files:**
- Modify: `packages/plab/src/assistant/mod.rs`
- Modify: `packages/plab/src/events.rs` (the `Event` enum)

**Interfaces:**
- Consumes: `daily::state`, `daily::prune`, and `daily::local_ymd` (Task 1).
- Produces:
  - `crate::events::Event::AssistantDaily`, a unit variant whose wire form is `{"type":"assistantDaily"}`
  - `Assistant::ensure_daily(self: &Arc<Self>, db: &Db, events: &crate::events::Events, now: i64, force: bool) -> Result<bool, TurnError>`.
    It returns `Ok(true)` when it started a generation, and `Ok(false)` when it did not need
    to or one is already running, unforced. It returns `Err(TurnError::Busy)` when forced
    while one runs, and `Err(TurnError::NotReady(_))` when the assistant is not ready.
  - `Assistant::daily_running(&self) -> bool`

- [ ] **Step 1: Add the event.** In `src/events.rs`, add the following to `enum Event`,
  before `Resync`:

```rust
    /// A daily picks generation ended (picks or an error): refetch /api/assistant/daily.
    AssistantDaily,
```

  If any `match` on `Event` elsewhere stops compiling, add an arm that ignores the new
  variant, as for `Listing`.

- [ ] **Step 2: Write the failing tests.** Add them to `mod tests` in
  `src/assistant/mod.rs`:

```rust
    const NOON: i64 = 20_000 * 86_400 + 43_200;

    async fn next_daily(rx: &mut tokio::sync::broadcast::Receiver<crate::events::Event>) {
        while rx.recv().await.unwrap() != crate::events::Event::AssistantDaily {}
    }

    #[tokio::test]
    async fn the_daily_starts_once_per_day_unless_forced() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(final_reply("ok", json!([{"ref": "t:1", "action": "download", "reason": "r"}])))
            .expect(2)
            .mount(&server)
            .await;
        let a = std::sync::Arc::new(a);
        let events = crate::events::Events::default();
        let mut rx = events.subscribe();
        assert!(matches!(a.ensure_daily(&db, &events, NOON, false), Ok(true)));
        assert!(a.daily_running());
        // A second visit while it runs starts nothing; a forced one is refused.
        assert!(matches!(a.ensure_daily(&db, &events, NOON, false), Ok(false)));
        assert!(matches!(a.ensure_daily(&db, &events, NOON, true), Err(TurnError::Busy)));
        next_daily(&mut rx).await;
        assert!(!a.daily_running());
        let d = daily::state(&db, NOON).unwrap();
        assert!(d.attempted_today && d.shown.is_some());
        // Today is done: a visit starts nothing, Refresh starts another.
        assert!(matches!(a.ensure_daily(&db, &events, NOON + 60, false), Ok(false)));
        assert!(matches!(a.ensure_daily(&db, &events, NOON + 60, true), Ok(true)));
        next_daily(&mut rx).await;
        assert_eq!(db.conversations_of_kind("recommend").unwrap().len(), 2);
    }

    #[tokio::test]
    async fn a_failed_daily_is_kept_and_not_retried_today() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(ResponseTemplate::new(500))
            .expect(1)
            .mount(&server)
            .await;
        let a = std::sync::Arc::new(a);
        let events = crate::events::Events::default();
        let mut rx = events.subscribe();
        assert!(matches!(a.ensure_daily(&db, &events, NOON, false), Ok(true)));
        next_daily(&mut rx).await;
        let d = daily::state(&db, NOON).unwrap();
        assert!(d.attempted_today && d.shown.is_none());
        assert!(d.error.unwrap().contains("OpenRouter"));
        assert!(matches!(a.ensure_daily(&db, &events, NOON, false), Ok(false)));
    }

    #[test]
    fn the_daily_needs_a_prompt() {
        let llm = OpenRouter::new("http://x", "k".into(), "p".into(), "j".into());
        let a = std::sync::Arc::new(Assistant::new(llm, Stash::new("http://x", None), "m".into(), " ".into()));
        let db = Db::open_in_memory().unwrap();
        let events = crate::events::Events::default();
        assert!(matches!(a.ensure_daily(&db, &events, NOON, false), Err(TurnError::NotReady(_))));
    }
```

  Also change the title assertion in `a_tool_round_then_an_answer`. Recommend titles now use
  the local date, so the test must start at noon. Change
  `a.start(&db, Kind::Recommend, None, 86400)` to `a.start(&db, Kind::Recommend, None, 86400 + 43_200)`.
  The expected title stays `"Recommendations · 1970-01-02"`.

- [ ] **Step 3: Run the tests to see them fail.** Run `cargo test assistant::tests`. Expected:
  a compile error, because `ensure_daily` and `daily_running` do not exist yet.

- [ ] **Step 4: Implement.** In `src/assistant/mod.rs`:

  1. Change the imports to:

```rust
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
```

  2. In `title()`, change the `Kind::Recommend` arm to
     `format!("Recommendations · {}", daily::local_ymd(now))`.

  3. Add a `daily_running: AtomicBool` field to `struct Assistant`, and initialise it to
     `AtomicBool::new(false)` in `Assistant::new`.

  4. Add these, after the `TurnGuard` `Drop` impl:

```rust
/// Clears `daily_running` when a daily generation's task ends, however it ends.
struct DailyGuard<'a>(&'a AtomicBool);

impl Drop for DailyGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}
```

  5. Add these to `impl Assistant`, after `lock`:

```rust
    /// A daily picks generation is running.
    pub fn daily_running(&self) -> bool {
        self.daily_running.load(Ordering::SeqCst)
    }

    /// Start today's picks on their own task, unless today has been attempted (`force`
    /// skips that check) or a generation is running. Ok(true): one was started. While one
    /// runs, a visit is Ok(false) and a forced start is Busy. When the task ends, the flag is
    /// cleared and `Event::AssistantDaily` published, in that order, so a client refetching
    /// on the event sees it done.
    pub fn ensure_daily(
        self: &Arc<Self>,
        db: &Db,
        events: &crate::events::Events,
        now: i64,
        force: bool,
    ) -> Result<bool, TurnError> {
        self.ready()?;
        if self.daily_running.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() {
            return if force { Err(TurnError::Busy) } else { Ok(false) };
        }
        let attempted = match daily::state(db, now) {
            Ok(d) => d.attempted_today,
            Err(e) => {
                self.daily_running.store(false, Ordering::SeqCst);
                return Err(e.into());
            }
        };
        if attempted && !force {
            self.daily_running.store(false, Ordering::SeqCst);
            return Ok(false);
        }
        let (a, db, events) = (Arc::clone(self), db.clone(), events.clone());
        tokio::spawn(async move {
            let done = DailyGuard(&a.daily_running);
            if let Err(e) = a.start(&db, Kind::Recommend, None, now).await {
                // Failed before the conversation existed: store the failure as today's
                // attempt anyway, or every refetch on the event below would start another.
                tracing::info!(job = "assistant", "daily picks: {e}");
                let why = e.to_string();
                let stored = db
                    .create_conversation(&title(Kind::Recommend, None, now), Kind::Recommend.as_str(), now)
                    .and_then(|id| {
                        let msg = json!({"role": "assistant", "content": "", "plab_error": why});
                        db.append_message(id, "assistant", &msg.to_string(), now)
                    });
                if let Err(e) = stored {
                    tracing::warn!(job = "assistant", "daily picks: storing the failure: {e:#}");
                }
            }
            match daily::prune(&db, now) {
                Ok(0) => {}
                Ok(n) => tracing::info!(job = "assistant", "pruned {n} unread daily picks"),
                Err(e) => tracing::warn!(job = "assistant", "pruning daily picks: {e:#}"),
            }
            drop(done);
            events.publish(crate::events::Event::AssistantDaily);
        });
        Ok(true)
    }
```

  Note that `Db::create_conversation` and `append_message` return `anyhow::Result`. Adjust
  the `and_then` closure types if the compiler needs it.

- [ ] **Step 5: Run the tests.** Run `cargo test`. Expected: PASS, including the three new
  tests. `#[tokio::test]` is current-thread, so the spawned task does not run until the
  test awaits, which is what makes `daily_running()` and the Busy assertion deterministic.

- [ ] **Step 6: Commit.**

```bash
git add packages/plab/src/assistant/mod.rs packages/plab/src/events.rs
git commit -m "feat(galactica): plab assistant starts the daily picks once per day on its own task"
```

---

### Task 3: The daily routes, the history filter, and removing `/recommend`

**Files:**
- Modify: `packages/plab/src/web/assistant_routes.rs`
- Modify: `packages/plab/src/web_tests.rs` (the assistant section, about lines 1074–1275, and `app_routes_serve_the_index`)

**Interfaces:**
- Consumes: `Assistant::ensure_daily` and `daily_running` (Task 2), and
  `daily::{state, followed_up, local_ymd}` (Task 1).
- Produces the HTTP API the UI uses:
  - `GET /api/assistant/daily` returns `{"conversation": ConversationDto|null, "generatedOn": "YYYY-MM-DD"|null, "refreshing": bool, "error": string|null}`
  - `POST /api/assistant/daily/refresh` returns the same shape. It answers 409 while a
    generation runs, and 503 when no key or prompt is set.
  - `GET /api/assistant/conversations` leaves out recommend conversations that are not
    followed up.

- [ ] **Step 1: Rewrite the affected web tests.** In `src/web_tests.rs`:

  Replace `assistant_off_without_a_key` with:

```rust
#[tokio::test]
async fn assistant_off_without_a_key() {
    let fx = Fx::new();
    let r = fx.get("/api/assistant/conversations").await;
    assert_eq!(r.status, 503);
    assert!(r.text().contains("OpenRouter"));
    // For you is the landing page: it renders, and says why.
    let r = fx.get("/api/assistant/daily").await;
    assert_eq!(r.status, 200);
    let j = r.json();
    assert_eq!(j["conversation"], Value::Null);
    assert_eq!(j["refreshing"], false);
    assert!(j["error"].as_str().unwrap().contains("OpenRouter"));
    assert_eq!(fx.post("/api/assistant/daily/refresh").await.status, 503);
}
```

  Add this helper after `answer()`:

```rust
/// GET the daily, which starts today's generation, wait for it to end, and GET it again.
async fn daily_done(fx: &Fx) -> Value {
    let mut rx = fx.state.events.subscribe();
    let r = fx.get("/api/assistant/daily").await;
    assert_eq!(r.status, 200, "{}", r.text());
    assert_eq!(r.json()["refreshing"], true);
    while rx.recv().await.unwrap() != Event::AssistantDaily {}
    let j = fx.get("/api/assistant/daily").await.json();
    assert_eq!(j["refreshing"], false);
    j
}
```

  In `recommend_resolves_picks_and_drops_unknown_refs`, rename the test to
  `the_daily_resolves_picks_and_drops_unknown_refs`. Replace

```rust
    let r = fx.post("/api/assistant/recommend").await;
    assert_eq!(r.status, 200, "{}", r.text());
    let j = r.json();
```

  with

```rust
    let d = daily_done(&fx).await;
    assert_eq!(d["error"], Value::Null);
    assert_eq!(d["generatedOn"], crate::assistant::daily::local_ymd(now()));
    let j = d["conversation"].clone();
```

  and replace its last two lines (the `list` check) with:

```rust
    // An unread daily is not in the history; a follow-up puts it there.
    let list = fx.get("/api/assistant/conversations").await.json();
    assert_eq!(list.as_array().unwrap().len(), 0);
    let id = j["id"].as_i64().unwrap();
    fx.post_json(&format!("/api/assistant/conversations/{id}/messages"), json!({"text": "why?"}))
        .await;
    let list = fx.get("/api/assistant/conversations").await.json();
    assert_eq!(list[0]["kind"], "recommend");
```

  In `picks_off_the_advised_lists_are_dropped`, replace
  `let j = fx.post("/api/assistant/recommend").await.json();` with
  `let j = daily_done(&fx).await["conversation"].clone();`.

  Add these new tests:

```rust
#[tokio::test]
async fn the_daily_is_made_once_a_day() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(crate::llm::CHAT_PATH))
        .respond_with(answer(json!([{"ref": "s:4", "action": "watch", "reason": "r"}])))
        .expect(1)
        .mount(&server)
        .await;
    let fx = assistant_fx(&server).await;
    let first = daily_done(&fx).await;
    let again = fx.get("/api/assistant/daily").await.json();
    assert_eq!(again["refreshing"], false);
    assert_eq!(again["conversation"]["id"], first["conversation"]["id"]);
}

#[tokio::test]
async fn refresh_is_409_while_the_daily_runs() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(crate::llm::CHAT_PATH))
        .respond_with(answer(json!([])))
        .mount(&server)
        .await;
    let fx = assistant_fx(&server).await;
    assert_eq!(fx.get("/api/assistant/daily").await.json()["refreshing"], true);
    assert_eq!(fx.post("/api/assistant/daily/refresh").await.status, 409);
}

#[tokio::test]
async fn a_failed_daily_keeps_the_last_good_picks() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(crate::llm::CHAT_PATH))
        .respond_with(wiremock::ResponseTemplate::new(500))
        .expect(1)
        .mount(&server)
        .await;
    let fx = assistant_fx(&server).await;
    fx.save_video(&[listed(row(5, "Alpha One"), &[COVER])]);
    // Two days back, so a DST change cannot make it today.
    let then = now() - 2 * 86_400;
    let db = &fx.state.db;
    let old = db.create_conversation("Recommendations", "recommend", then).unwrap();
    let ans = json!({"role": "assistant", "content": json!({"text": "Old.", "picks": [
        {"ref": "t:5", "action": "download", "reason": "r"}]}).to_string()});
    db.append_message(old, "user", &json!({"role": "user", "content": "ask"}).to_string(), then).unwrap();
    db.append_message(old, "assistant", &ans.to_string(), then).unwrap();
    let d = daily_done(&fx).await;
    assert_eq!(d["conversation"]["id"], old);
    assert_eq!(d["generatedOn"], crate::assistant::daily::local_ymd(then));
    assert!(d["error"].as_str().unwrap().contains("OpenRouter"), "{d}");
    // Not retried on the next visit (the mock expects exactly one call).
    assert_eq!(fx.get("/api/assistant/daily").await.json()["refreshing"], false);
}

#[tokio::test]
async fn the_daily_says_why_the_assistant_is_not_ready() {
    let server = wiremock::MockServer::start().await;
    let fx = assistant_fx_with(&server, "  ").await;
    let r = fx.get("/api/assistant/daily").await;
    assert_eq!(r.status, 200);
    assert!(r.json()["error"].as_str().unwrap().contains("prompt"));
    assert_eq!(fx.post("/api/assistant/daily/refresh").await.status, 503);
}
```

  In `app_routes_serve_the_index`, add `"/tracker"` to the path list.

- [ ] **Step 2: Run the tests to see them fail.** Run `cargo test web_tests`. Expected:
  the new and rewritten assistant tests fail, with 404s on `/api/assistant/daily`.

- [ ] **Step 3: Implement the routes.** In `src/web/assistant_routes.rs`:

  1. Add a constant, and use it in `route()`'s existing 503:

```rust
const NO_KEY: &str = "the assistant needs an OpenRouter key";
```

  2. Split `transcript` so the daily can embed the DTO. Rename its body into
     `async fn build<B: Backends>(st: &WebState<B>, a: &Assistant, id: i64) -> Result<ConversationDto, Response<Body>>`.
     It returns `Err(not_found())` and `Err(text(500, …))` where it returned those responses
     before, and `Ok(ConversationDto { … })` at the end. Then:

```rust
async fn transcript<B: Backends>(st: &WebState<B>, a: &Assistant, id: i64) -> Response<Body> {
    match build(st, a, id).await {
        Ok(c) => json_body(&c),
        Err(r) => r,
    }
}
```

  3. Add the DTO and the handler:

```rust
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DailyDto {
    conversation: Option<ConversationDto>,
    generated_on: Option<String>,
    refreshing: bool,
    error: Option<String>,
}

/// For you. A GET starts today's picks if they have not been attempted; Refresh (`force`)
/// starts new ones regardless. Either way the answer is the picks to show now, and a
/// generation in flight ends with an `assistantDaily` event. A GET answers 200 even when
/// the assistant is not ready: the landing page must render, so the reason goes in `error`.
async fn daily<B: Backends>(st: &WebState<B>, force: bool) -> Response<Body> {
    let t = now();
    let Some(arc) = st.assistant.clone() else {
        if force {
            return text(503, NO_KEY);
        }
        return json_body(&DailyDto { conversation: None, generated_on: None, refreshing: false, error: Some(NO_KEY.into()) });
    };
    let mut not_ready = None;
    match arc.ensure_daily(&st.db, &st.events, t, force) {
        Ok(_) => {}
        Err(TurnError::NotReady(why)) if !force => not_ready = Some(why.to_string()),
        Err(e) => return turn_error(e),
    }
    let d = match assistant::daily::state(&st.db, t) {
        Ok(d) => d,
        Err(e) => return text(500, format!("{e:#}")),
    };
    let refreshing = arc.daily_running();
    let conversation = match &d.shown {
        Some(row) => match build(st, &arc, row.id).await {
            Ok(c) => Some(c),
            Err(r) => return r,
        },
        None => None,
    };
    json_body(&DailyDto {
        conversation,
        generated_on: d.shown.as_ref().map(|r| assistant::daily::local_ymd(r.created_at)),
        refreshing,
        error: not_ready.or(if refreshing { None } else { d.error }),
    })
}
```

  4. At the top of `route()`, before `let Some(arc) = st.assistant.clone() else`, add:

```rust
    match (method, rest) {
        (&Method::GET, "daily") => return daily(st, false).await,
        (&Method::POST, "daily/refresh") => return daily(st, true).await,
        _ => {}
    }
```

  5. Delete the `(&Method::POST, "recommend")` arm.

  6. In the `GET conversations` arm, drop unread dailies:

```rust
        (&Method::GET, "conversations") => {
            let rows = a.ready().and_then(|()| {
                let mut out = vec![];
                for c in st.db.conversations()? {
                    if c.kind != Kind::Recommend.as_str() || assistant::daily::followed_up(&st.db, c.id)? {
                        out.push(c);
                    }
                }
                Ok(out)
            });
            match rows {
                Ok(rows) => json_body(
                    &rows
                        .into_iter()
                        .map(|c| ConversationSummaryDto { id: c.id, title: c.title, kind: c.kind, updated_at: c.updated_at })
                        .collect::<Vec<_>>(),
                ),
                Err(e) => turn_error(e),
            }
        }
```

  `Kind` may now be used only by name in that arm, while `Kind::Chat` is still used by
  `POST conversations`. Keep the import.

- [ ] **Step 4: Run the tests.** Run `cargo test`. Expected: PASS. Then run
  `cargo clippy --all-targets 2>&1 | grep -E "^(warning|error)" | sort | uniq -c`. It should
  show no new warnings in the files you touched.

- [ ] **Step 5: Commit.**

```bash
git add packages/plab/src/web/assistant_routes.rs packages/plab/src/web_tests.rs
git commit -m "feat(galactica): plab serves the daily picks and keeps unread dailies out of the history"
```

---

### Task 4: UI types, API calls and pure daily helpers

**Files:**
- Modify: `packages/plab/ui/src/lib/types.ts`
- Modify: `packages/plab/ui/src/lib/api.ts`
- Create: `packages/plab/ui/src/lib/daily.ts`
- Create: `packages/plab/ui/src/lib/daily.test.ts`

**Interfaces:**
- Consumes: the HTTP shape from Task 3, and `resolvePick` and `Resolved` from `lib/assistant.ts`
  (existing).
- Produces:
  - `types.ts`: `interface Daily { conversation: Conversation | null; generatedOn: string | null; refreshing: boolean; error: string | null }`, and a `ServerEvent` member `{ type: 'assistantDaily' }`
  - `api.ts`: `fetchDaily(): Promise<Daily>` and `postDailyRefresh(): Promise<Daily>`
  - `daily.ts`: `dailyAnswer(c: Conversation): TurnData | null`, `groupPicks(c: Conversation, t: TurnData): { watch: Resolved[]; get: Resolved[] }`, and `show(d: Daily | null): 'loading' | 'first' | 'picks' | 'empty'`

`postRecommend` stays in `api.ts` until Task 5 removes its only caller.

- [ ] **Step 1: Add the types.** In `types.ts`, add `| { type: 'assistantDaily' }` to
  `ServerEvent`, and after `Conversation`:

```ts
/** GET /api/assistant/daily: the picks For you shows. */
export interface Daily {
  conversation: Conversation | null;
  /** The local date the shown picks were made, YYYY-MM-DD. */
  generatedOn: string | null;
  /** Today's picks are being made; an `assistantDaily` event follows. */
  refreshing: boolean;
  /** Today's attempt failed, or the assistant is not set up. */
  error: string | null;
}
```

  In `api.ts`, add `Daily` to the type import, and below the assistant calls:

```ts
export const fetchDaily = () => getJson<Daily>(`${A}/daily`);
export const postDailyRefresh = () => sendJson<Daily>(`${A}/daily/refresh`, 'POST');
```

- [ ] **Step 2: Write the failing tests.** Create `daily.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { dailyAnswer, groupPicks, show } from './daily';
import type { Conversation, Daily, PickedTopic } from './types';

const topic = { id: 5, title: 'Alpha One', section: 'video' } as PickedTopic;
const conv: Conversation = {
  id: 1, title: 't', kind: 'recommend', updatedAt: 2, now: 3, topicUrl: 'u', degraded: [], scenesUnavailable: false,
  turns: [
    { seq: 1, role: 'user', text: 'ask', picks: [], error: null },
    { seq: 2, role: 'assistant', text: 'Here.', picks: [
      { ref: 't:5', action: 'download', reason: 'r' },
      { ref: 's:4', action: 'watch', reason: 'w' },
      { ref: 't:9', action: 'stream', reason: 'gone' },
    ], error: null },
    { seq: 3, role: 'user', text: 'why?', picks: [], error: null },
    { seq: 4, role: 'assistant', text: 'Because.', picks: [], error: null },
  ],
  topics: [topic],
  scenes: [{ ref: 's:4', id: '4', title: 'S', studio: null, performers: [], screenshot: null, link: null }],
};
const d = (over: Partial<Daily>): Daily => ({ conversation: null, generatedOn: null, refreshing: false, error: null, ...over });

describe('dailyAnswer', () => {
  it('is the first assistant turn, not a follow-up', () => {
    expect(dailyAnswer(conv)?.seq).toBe(2);
    expect(dailyAnswer({ ...conv, turns: [conv.turns[0]] })).toBeNull();
  });
});

describe('groupPicks', () => {
  it('splits watch from stream and download, dropping unresolved picks', () => {
    const g = groupPicks(conv, conv.turns[1]);
    expect(g.watch.map((r) => r.pick.ref)).toEqual(['s:4']);
    expect(g.get.map((r) => r.pick.ref)).toEqual(['t:5']);
  });
});

describe('show', () => {
  it('names what For you shows', () => {
    expect(show(null)).toBe('loading');
    expect(show(d({ refreshing: true }))).toBe('first');
    expect(show(d({ conversation: conv, refreshing: true }))).toBe('picks');
    expect(show(d({ error: 'no prompt' }))).toBe('empty');
  });
});
```

- [ ] **Step 3: Run the tests to see them fail.** Run `cd packages/plab/ui && npx vitest run src/lib/daily.test.ts`.
  Expected: FAIL, because `./daily` cannot be resolved.

- [ ] **Step 4: Implement `daily.ts`.**

```ts
import { resolvePick, type Resolved } from './assistant';
import type { Conversation, Daily, TurnData } from './types';

/** The daily's answer: its first assistant turn, the one that answers the canned ask. */
export function dailyAnswer(c: Conversation): TurnData | null {
  return c.turns.find((t) => t.role === 'assistant') ?? null;
}

/** A turn's resolvable picks: scenes to watch, and releases to stream or download. */
export function groupPicks(c: Conversation, t: TurnData): { watch: Resolved[]; get: Resolved[] } {
  const out: { watch: Resolved[]; get: Resolved[] } = { watch: [], get: [] };
  for (const p of t.picks) {
    const r = resolvePick(c, p);
    if (r) (r.kind === 'scene' ? out.watch : out.get).push(r);
  }
  return out;
}

/** What For you shows: nothing loaded yet, the very first picks being made, picks, or none. */
export function show(d: Daily | null): 'loading' | 'first' | 'picks' | 'empty' {
  if (d === null) return 'loading';
  if (d.conversation) return 'picks';
  return d.refreshing ? 'first' : 'empty';
}
```

- [ ] **Step 5: Run the tests and checks.** Run `npm test && npm run check`. Expected: PASS
  with 0 warnings.

- [ ] **Step 6: Commit.**

```bash
git add packages/plab/ui/src/lib/types.ts packages/plab/ui/src/lib/api.ts packages/plab/ui/src/lib/daily.ts packages/plab/ui/src/lib/daily.test.ts
git commit -m "feat(galactica): plab UI types and helpers for the daily picks"
```

---

### Task 5: The shared `Picks.svelte`, and the Assistant tab without Recommend

**Files:**
- Create: `packages/plab/ui/src/components/Picks.svelte`
- Modify: `packages/plab/ui/src/components/AssistantView.svelte`
- Modify: `packages/plab/ui/src/lib/assistant.svelte.ts` (remove `recommend` and the `postRecommend` import)
- Modify: `packages/plab/ui/src/lib/api.ts` (remove `postRecommend`)

**Interfaces:**
- Consumes: `Resolved` and `resolvePick` from `lib/assistant.ts`.
- Produces: `Picks.svelte`, with props `{ c: Conversation; items: Resolved[]; ongallery: (images: string[]) => void; onstream: (id: number) => void }`.
  It renders a grid with one card per item. A topic gets an action badge, its reason and
  `Card`; a scene gets `SceneCard`.

- [ ] **Step 1: Create `Picks.svelte`.** Its markup is moved verbatim from
  `AssistantView.svelte`'s picks grid:

```svelte
<script lang="ts">
  import type { Resolved } from '../lib/assistant';
  import { FilterState } from '../lib/filters.svelte';
  import type { Conversation } from '../lib/types';
  import Card from './Card.svelte';
  import SceneCard from './SceneCard.svelte';

  let {
    c,
    items,
    ongallery,
    onstream,
  }: {
    c: Conversation;
    items: Resolved[];
    ongallery: (images: string[]) => void;
    onstream: (id: number) => void;
  } = $props();

  const fs = new FilterState(null);
</script>

<div class="grid gap-3 grid-cols-[repeat(auto-fill,minmax(18rem,1fr))]">
  {#each items as r, i (i)}
    {#if r.kind === 'topic'}
      <div class="flex flex-col gap-1">
        <span class="text-sm italic"><span class="badge badge-sm mr-1">{r.pick.action}</span>{r.pick.reason}</span>
        <Card topic={r.topic} section={r.topic.section} now={c.now} topicUrl={c.topicUrl} isNew={false} {fs} stream={true} {ongallery} {onstream} />
      </div>
    {:else}
      <SceneCard scene={r.scene} reason={r.pick.reason} />
    {/if}
  {/each}
</div>
```

- [ ] **Step 2: Use it in `AssistantView.svelte`.**
  - Replace the whole `{#if turn.picks.length} … {/if}` block with:

```svelte
          {@const items = turn.picks.map((p) => resolvePick(c, p)).filter((r) => r !== null)}
          {#if items.length}
            <Picks {c} {items} ongallery={(images) => gallery?.open(images)} onstream={(id) => player?.open(id)} />
          {/if}
```

    A `{@const}` must be the first child of its block. If the `{:else}` branch places it
    after other markup, wrap that branch's content so it comes first, or compute `items`
    inside `Picks` from `turn.picks` instead.
  - Remove the now-unused imports: `Card`, `SceneCard` and `FilterState`, along with the
    `fs` constant. Import `Picks`.
  - Replace the button row with just the New chat link:
    `<a class="btn btn-sm" href="/assistant" use:link>New chat</a>`, dropping the
    Recommend button.
  - Change the empty-state text to `Ask something below; today's picks are on For you.`

  In `assistant.svelte.ts`, delete the `recommend = …` line and the `postRecommend` import.
  In `api.ts`, delete `postRecommend`.

- [ ] **Step 3: Verify.** Run `cd packages/plab/ui && npm test && npm run check && npm run build`.
  Expected: PASS, with 0 warnings, and the build succeeds.

- [ ] **Step 4: Commit.**

```bash
git add packages/plab/ui/src
git commit -m "refactor(galactica): plab pick cards are one component, and the Assistant tab drops Recommend"
```

---

### Task 6: The For you view at `/`, and the Tracker list at `/tracker`

**Files:**
- Create: `packages/plab/ui/src/lib/daily.svelte.ts`
- Create: `packages/plab/ui/src/components/DailyView.svelte`
- Modify: `packages/plab/ui/src/lib/route.ts`, `packages/plab/ui/src/lib/route.test.ts`
- Modify: `packages/plab/ui/src/components/Navbar.svelte`, `packages/plab/ui/src/components/ListView.svelte:55`
- Modify: `packages/plab/ui/src/App.svelte`
- Modify: `modules/hosts/galactica/services/plab/default.nix` (the module notes on the assistant)

**Interfaces:**
- Consumes: `fetchDaily` and `postDailyRefresh` (Task 4), `dailyAnswer`, `groupPicks` and
  `show` (Task 4), `Picks.svelte` (Task 5), `applyTopic` from `lib/reducer.ts`, and `Latest`
  from `lib/latest.ts`, whose API is `next(key): number` and `current(key, token): boolean`.
- Produces: the route `{ view: 'daily' }`, and `daily`, a store with `data`, `error`, `busy`,
  `load()`, `refresh()` and `apply(ev)`.

- [ ] **Step 1: Update the route tests.** In `route.test.ts`, change the first test's
  assertions on `/` and `/nowhere`, and add the one for `/tracker`:

```ts
  expect(parse('/', '')).toEqual({ view: 'daily' });
  expect(parse('/tracker', '')).toEqual({ view: 'video' });
  expect(parse('/nowhere', '')).toEqual({ view: 'daily' });
```

  Keep `parse('/search', '?q=')` → `{ view: 'video' }`. An empty search lands on the Tracker
  list.

- [ ] **Step 2: Run the tests to see them fail.** Run `npx vitest run src/lib/route.test.ts`.
  Expected: FAIL.

- [ ] **Step 3: Update the routes.** In `route.ts`:
  - Add `| { view: 'daily' }` to `Route`.
  - Add `case '/tracker': return { view: 'video' };`.
  - Change `default:` to `return { view: 'daily' };`, and add `case '/':` falling through
    to it.
  - Update the doc comment to "anything unknown is For you".

  In `Navbar.svelte`, make the tabs:

```ts
  const tabs = [
    ['daily', '/', 'For you'],
    ['video', '/tracker', 'Tracker'],
    ['indexers', '/indexers', 'Indexers'],
    ['albums', '/albums', 'Albums'],
    ['games', '/games', 'Games'],
    ['assistant', '/assistant', 'Assistant'],
    ['jobs', '/jobs', 'Jobs'],
  ] as const;
```

  In `ListView.svelte:55`, change `href="/"` to `href="/tracker"`.

- [ ] **Step 4: Create the store `lib/daily.svelte.ts`.**

```ts
import { fetchDaily, postDailyRefresh } from './api';
import { Latest } from './latest';
import { applyTopic } from './reducer';
import type { Daily, ServerEvent } from './types';

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** For you: the picks on show, refetched when a generation ends (`assistantDaily`). */
class DailyStore {
  data = $state<Daily | null>(null);
  /** A request failed (not today's picks: that is `data.error`). */
  error = $state<string | null>(null);
  busy = $state(false);
  private latest = new Latest<'load'>();

  /** Fetch the picks; on a new day this is also what starts today's. */
  async load() {
    const token = this.latest.next('load');
    try {
      const d = await fetchDaily();
      if (this.latest.current('load', token)) {
        this.data = d;
        this.error = null;
      }
    } catch (e) {
      if (this.latest.current('load', token)) this.error = message(e);
    }
  }

  async refresh() {
    if (this.busy || this.data?.refreshing) return;
    this.busy = true;
    this.latest.next('load'); // a load in flight must not overwrite this answer
    try {
      this.data = await postDailyRefresh();
      this.error = null;
    } catch (e) {
      this.error = message(e);
    } finally {
      this.busy = false;
    }
  }

  apply(ev: ServerEvent) {
    if (ev.type === 'assistantDaily') void this.load();
    else if (this.data?.conversation) applyTopic([this.data.conversation], ev);
  }
}

export const daily = new DailyStore();
```

- [ ] **Step 5: Create `components/DailyView.svelte`.**

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import { dailyAnswer, groupPicks, show } from '../lib/daily';
  import { daily } from '../lib/daily.svelte';
  import { link } from '../lib/router.svelte';
  import Gallery from './Gallery.svelte';
  import Navbar from './Navbar.svelte';
  import Picks from './Picks.svelte';
  import Player from './Player.svelte';

  let gallery = $state<ReturnType<typeof Gallery>>();
  let player = $state<ReturnType<typeof Player>>();
  let expanded = $state(false);

  onMount(() => void daily.load());

  const d = $derived(daily.data);
  const c = $derived(d?.conversation ?? null);
  const answer = $derived(c ? dailyAnswer(c) : null);
  const groups = $derived(c && answer ? groupPicks(c, answer) : { watch: [], get: [] });
  const ongallery = (images: string[]) => gallery?.open(images);
  const onstream = (id: number) => player?.open(id);
</script>

<Navbar />
<section class="flex flex-col gap-4">
  <div class="flex flex-wrap items-center gap-2">
    <h2 class="text-lg font-semibold">{d?.generatedOn ? `Picks for ${d.generatedOn}` : 'Picks'}</h2>
    {#if d?.refreshing}
      <span class="flex items-center gap-1 text-sm text-base-content/60"><span class="loading loading-dots loading-sm"></span>refreshing…</span>
    {/if}
    <span class="flex-1"></span>
    {#if c}<a class="btn btn-sm" href={`/assistant/${c.id}`} use:link>Ask about these</a>{/if}
    <button class="btn btn-primary btn-sm" disabled={daily.busy || d?.refreshing} onclick={() => daily.refresh()}>Refresh</button>
  </div>

  {#if daily.error}<div role="alert" class="alert alert-error">{daily.error}</div>{/if}
  {#if d?.error}
    <div role="alert" class="alert alert-error">
      <span>{d.error}</span>
      <button class="btn btn-sm" disabled={daily.busy || d.refreshing} onclick={() => daily.refresh()}>Retry</button>
    </div>
  {/if}

  {#if show(d) === 'loading'}
    <span class="loading loading-dots loading-md"></span>
  {:else if show(d) === 'first'}
    <div class="flex items-center gap-2 text-base-content/60"><span class="loading loading-dots loading-sm"></span>Picking for today…</div>
  {:else if c}
    {#if c.degraded.includes('stash')}
      <div role="alert" class="alert alert-warning text-sm">Stash could not be reached: no watch picks, and the profile has only streams.</div>
    {/if}
    {#if c.scenesUnavailable}
      <div role="alert" class="alert alert-warning text-sm">Stash is not answering; watch picks are hidden.</div>
    {/if}
    {#if answer?.text}
      <button class={['text-left whitespace-pre-wrap text-base-content/80', !expanded && 'line-clamp-3']} onclick={() => (expanded = !expanded)}>{answer.text}</button>
    {/if}
    {#if groups.watch.length}
      <h3 class="font-semibold">Watch</h3>
      <Picks {c} items={groups.watch} {ongallery} {onstream} />
    {/if}
    {#if groups.get.length}
      <h3 class="font-semibold">Stream / download</h3>
      <Picks {c} items={groups.get} {ongallery} {onstream} />
    {/if}
  {/if}
</section>

<Gallery bind:this={gallery} />
<Player bind:this={player} />
```

- [ ] **Step 6: Wire `App.svelte`.**
  - Import `DailyView` and `{ daily } from './lib/daily.svelte'`.
  - In `live.on`, add `daily.apply(ev);`.
  - In `live.onReconnect`, add `if (router.route.view === 'daily') void daily.load();`.
  - Add `{:else if router.route.view === 'daily'}<DailyView />` before the `search` branch.
    The final `{:else}` branch is then left with `Section` views only.

- [ ] **Step 7: Update the module notes.** In
  `modules/hosts/galactica/services/plab/default.nix`, replace the paragraph that starts
  `# Assistant (the page's Assistant tab): on demand only, never scheduled.` with:

```nix
# Assistant: For you (`/`, the landing page) shows today's picks, made lazily: the first
# visit of a local day starts one generation on the server (deduped across tabs; an
# assistantDaily SSE event swaps it in) while the last good picks stay on screen. A failed
# day is not retried until tomorrow or Refresh. Nothing is scheduled. The Assistant tab is
# chat and history; a daily joins the history once followed up, and unread dailies are
# pruned after 30 days. Picks come from a profile of recent Stash plays plus plab's stream
# log (stream_view), with read-only tools over OpenRouter. Its system prompt is
# `prompts.assistant` in plab-site (For you shows why without it), and
# PLAB_ASSISTANT_MODEL defaults to the parse model. The Tracker list is at /tracker.
# Design: docs/superpowers/specs/2026-11-03-plab-assistant-design.md and
# docs/superpowers/specs/2026-11-03-plab-daily-picks-design.md
```

- [ ] **Step 8: Verify.** Run `cd packages/plab/ui && npm test && npm run check && npm run build`.
  Expected: PASS, with 0 warnings. Then, from the repo root, run `nix fmt -- --check
  modules/hosts/galactica/services/plab/default.nix`; if it fails, run `nix develop -c alejandra
  modules/hosts/galactica/services/plab/default.nix`.

- [ ] **Step 9: Commit.**

```bash
git add packages/plab/ui/src modules/hosts/galactica/services/plab/default.nix
git commit -m "feat(galactica): plab lands on For you, today's assistant picks; Tracker moves to /tracker"
```

---

### Task 7: Build the package (controller)

- [ ] Run `nix build .#plab -L 2>&1 | grep -E "error|warning: unused" | head` from the repo
  root. Expected: no errors. Fix anything it shows before reporting done.
