# Claude Board Session Feed and Remote Approvals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show what each Claude Code session is doing (prompts, replies, tool calls) on the board's detail page, and let the board approve or deny any tool call.

**Architecture:** Hooks post feed entries to a new bridge endpoint `/v1/feed`; the bridge keeps a bounded in-memory ring buffer per session and streams it to a board socket that sent `watch`. Tool approvals reuse the existing held-question path: the bridge turns a `PermissionRequest` for any tool into a one-question ask with `Allow`/`Deny` options, so the board's question screen is unchanged.

**Tech Stack:** bash + jq (hooks), Rust/axum (bridge), Rust serde crate `claude-board-proto` (wire types + board `Model`), Rust + Slint (firmware UI crate `claude-board-ui`).

**Spec:** `docs/superpowers/specs/2026-11-09-claude-board-feed-design.md`

## Global Constraints

- Hooks never block or break a session: every failure is silent, exit 0, and a failed connection pauses attempts for one minute (the `down` marker).
- `/v1/feed` never touches the registry and never cancels held questions; `/v1/event` keeps its current meaning.
- Feed entry kinds: `prompt`, `tool`, `result`, `reply`. Truncation: prompt 2 KB, tool 300 chars, reply 4 KB. Tool output is never sent; `result` text is `ok` or `failed`.
- Bridge: 200 entries per session, in memory, dropped on `SessionEnd` and on expiry. History to a board: newest 50.
- Board keeps at most 50 entries per watched session and watches one session at a time.
- Wire format: `claude-board-proto` and `packages/claude-board-bridge/tests/fixtures/board/*.json` change together; `PROTOCOL_VERSION` becomes 2; unknown messages stay ignorable.
- Approval decisions: Allow → `{"behavior":"allow"}`; Deny → `{"behavior":"deny","message":"Denied from the board"}`; the question tool keeps `updatedInput.answers`.
- `PermissionRequest` hook is catch-all (no matcher), timeout 90.
- No NSFW names or terms anywhere; commit straight to master with conventional commits, scope `raider`/`galactica` style (`feat(raider): …` for board code), never mention Claude.
- Run Rust tests inside the dev shells: bridge/proto `nix develop -c bash -c 'cd packages/<crate> && cargo test'`; UI `nix develop .#firmware -c bash -c 'cd firmware/claude-board && cargo test -p claude-board-ui'`; hook `bash packages/claude-board-hook/test/test.sh`.

## Review Focus

- A board that sends `watch` while an entry is being appended receives the entry in both `history` and a queued `entry`: the board must show it once (dedupe by `n`). Pinned in Tasks 7 and 8.
- A hook on every tool call must not slow Claude: feed posts are fire-and-forget; a 2 s bridge delay must not delay the hook's exit. Pinned in Task 4.
- Multibyte text near a cap must never be cut mid-character, and an oversized request body must not grow the buffer past its caps. Pinned in Task 2.
- An approval answered with anything but exactly `Allow` or `Deny`, or arriving with no board connected, must fall through to the terminal (204), never allow. Pinned in Task 3.
- A board socket that drops and reconnects while on the detail page must resume the feed without duplicate rows. Pinned in Task 8.

---

### Task 1: Capture real hook payloads

**Files:**
- Create: `packages/claude-board-bridge/tests/fixtures/{permission_request_bash,pre_tool_use_bash,pre_tool_use_edit,post_tool_use_bash,post_tool_use_failure_bash}.json`
- Modify: `docs/superpowers/specs/2026-11-09-claude-board-hook-findings.md` (append a section)

**Interfaces:**
- Produces: the five payload fixtures (one JSON object each, exactly what Claude Code sent), and measured answers to: (a) does `PermissionRequest` carry a `tool_use_id`; (b) which hook fires for a failing Bash command (`PostToolUse` or `PostToolUseFailure`) and what its payload holds; (c) the field holding the edited text for `Edit` (`new_string`) and `Write` (`content`). Later tasks use the fixtures.

- [ ] **Step 1: Write a logging hook script** in the scratchpad that appends `$(cat)` to `$LOG` and, for `PermissionRequest`, prints `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`. Write a settings file registering it for `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` (no matcher).
- [ ] **Step 2: Run a session through it:** `claude -p "Run 'echo hi' with Bash, then run 'ls /nonexistent' with Bash, then create the file /tmp/claude-board-probe.txt containing x" --settings <file> --permission-mode default`. If `-p` does not fire a hook, start an interactive session with the same `--settings` and give it that prompt.
- [ ] **Step 3: Save one payload per fixture name** (pick the matching lines from `$LOG`; use `jq .` formatting). Replace real session ids and cwd with the values `00000000-0000-4000-8000-000000000001` and `/home/arosenfeld/Code/nixos`, as the existing fixtures do.
- [ ] **Step 4: Append the measurements (a)-(c) to the findings doc**, one paragraph each, saying plainly if something could not be observed.
- [ ] **Step 5: Verify** every fixture is valid JSON: `for f in packages/claude-board-bridge/tests/fixtures/*.json; do jq -e . "$f" >/dev/null || echo BAD $f; done` prints nothing.
- [ ] **Step 6: Commit** `docs(raider): record hook payloads for the claude-board feed`.

---

### Task 2: Bridge feed store

**Files:**
- Create: `packages/claude-board-bridge/src/feed.rs`
- Modify: `packages/claude-board-bridge/src/lib.rs` (add `pub mod feed;`)
- Test: `packages/claude-board-bridge/tests/feed.rs`

**Interfaces:**
- Consumes: `claude_board_proto::FeedEntry`, `FeedKind` (Task 5 defines them; Task 2 may be done after Task 5 — see ordering note at the end).
- Produces:
  - `pub struct Feed` with `Feed::new() -> Feed`, `append(&self, host: &str, session: &str, kind: FeedKind, text: &str, ts: i64) -> FeedEntry` (assigns the next per-session `n` starting at 1, truncates `text` to the kind's byte cap on a char boundary, trims the buffer to 200), `history(&self, host: &str, session: &str, limit: usize) -> Vec<FeedEntry>` (newest `limit`, oldest first), `drop_session(&self, host: &str, session: &str)`.
  - Byte caps: `prompt` 2048, `tool` 1200 (300 chars at 4 bytes), `result` 16, `reply` 4096.

- [ ] **Step 1: Write failing tests in `tests/feed.rs`:** `n_is_per_session_and_starts_at_one`; `buffer_keeps_only_the_newest_200` (append 205, `history(.., 500)` has 200 entries, first `n == 6`); `history_returns_newest_limit_oldest_first` (limit 50 of 205 → `n` 156..=205 ascending); `drop_session_forgets_entries_and_restarts_numbering`; `truncation_never_splits_a_character` (a `reply` of 5000 × `"é"` → stored length ≤ 4096 and valid UTF-8 whose last char is `é`); `unknown_session_history_is_empty`.
- [ ] **Step 2: Run** `cargo test --test feed` — expect compile failure (module missing).
- [ ] **Step 3: Implement `Feed`** in `src/feed.rs`: `Mutex<HashMap<(String, String), (u64, VecDeque<FeedEntry>)>>`; reuse `claude_board_proto::fit` for the char-boundary cut.
- [ ] **Step 4: Run** `cargo test --test feed` — expect all pass.
- [ ] **Step 5: Commit** `feat(galactica): store a bounded feed per claude-board session`.

---

### Task 3: Bridge approvals for any tool

**Files:**
- Modify: `packages/claude-board-bridge/src/asks.rs` (add `register_approval`, `build_approval_decision`), `packages/claude-board-bridge/src/http.rs` (`AskReq`, `ask`)
- Test: `packages/claude-board-bridge/tests/asks.rs`, `packages/claude-board-bridge/tests/http.rs`

**Interfaces:**
- Produces:
  - `Asks::register_approval(&self, host: &str, session: &str, project: &str, tool_name: &str, summary: &str) -> (AskId, oneshot::Receiver<Answered>)` — a `PendingAsk` with one `Question { question: "<tool_name>: <summary>", header: Some("Approve"), options: [Allow, Deny] (no descriptions), multi_select: false }`; the question text is cut to 500 bytes on a char boundary.
  - `pub fn build_approval_decision(answers: &BTreeMap<String, String>) -> Option<Value>` — value `"Allow"` → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`; `"Deny"` → same with `{"behavior":"deny","message":"Denied from the board"}`; anything else or an empty map → `None`.
  - `POST /v1/ask` body gains optional `tool_name` (default `"AskUserQuestion"`) and `summary` (default `""`). `AskUserQuestion` behaves exactly as today. Any other `tool_name` registers an approval and answers with `build_approval_decision`; `None` → 204.

- [ ] **Step 1: Write failing tests.** `tests/asks.rs`: `approval_ask_has_allow_and_deny_options`; `approval_decision_allow_and_deny_match_the_hook_output`; `approval_decision_for_any_other_label_is_none` (labels `"allow"`, `"Maybe"`, `""`, and an empty map). `tests/http.rs` (follow the existing ask tests there): `bash_approval_allow_returns_allow_decision`; `bash_approval_deny_returns_deny_with_message`; `approval_with_no_board_connected_is_204_immediately`; `approval_unknown_label_is_204`; `approval_decline_is_204`; `ask_user_question_without_tool_name_still_works`.
- [ ] **Step 2: Run** `cargo test --test asks --test http` — expect the new tests to fail.
- [ ] **Step 3: Implement** the two functions and branch `ask` on `tool_name`; share the register/hold/answer flow with the existing question path rather than copying it (extract the part that differs: how the ask is registered and how the answer becomes a decision).
- [ ] **Step 4: Run** `cargo test` in the bridge crate — expect all pass, including every pre-existing test.
- [ ] **Step 5: Commit** `feat(galactica): hold tool approvals on the claude-board bridge`.

---

### Task 4: Hook: feed events, scrubbing, approvals for any tool, installer

**Files:**
- Modify: `packages/claude-board-hook/claude-board-hook`, `packages/claude-board-hook/claude-board-install-hooks`, `packages/claude-board-hook/test/stub.py`, `packages/claude-board-hook/test/test.sh`

**Interfaces:**
- Produces (consumed by Task 2/3's endpoints):
  - New events accepted by `claude-board-hook`: `pre_tool_use`, `post_tool_use`, `post_tool_use_failure`.
  - Feed post: `POST /v1/feed` with `{host, session, kind, text, ts}`; `kind` ∈ `prompt|tool|result|reply`. `user_prompt_submit` posts `prompt` (`.prompt`, 2048 chars) in addition to `/v1/event`; `stop` posts `reply` (`.last_assistant_message`, 4096 chars) in addition; `pre_tool_use` posts `tool`; `post_tool_use` posts `result` `ok`; `post_tool_use_failure` posts `result` `failed`. An empty text posts nothing.
  - Tool text is `"<tool_name>: <summary>"`, newlines collapsed to spaces, first 300 chars. Summary by tool: Bash → `.tool_input.command`; Edit/MultiEdit/Write/Read/NotebookEdit → `.tool_input.file_path` (or `.notebook_path`); Grep/Glob → `.tool_input.pattern`; WebFetch → `.tool_input.url`; any other tool → empty.
  - Scrub (applied to tool text and to approval summaries): `Authorization: <value>` → `Authorization: [redacted]`; `Bearer <token>` → `Bearer [redacted]`; `<NAME containing TOKEN|SECRET|PASSWORD|PASSWD|KEY, any case>=<value>` → `<NAME>=[redacted]`.
  - `ask` body gains `tool_name` and `summary` (the tool text's summary part, scrubbed; for Edit/Write it is the path followed by ` - ` and the first 80 chars of `new_string`/`content`, scrubbed).
  - Feed posts run in a background subshell so the hook returns immediately; on failure they still `touch` the `down` marker.
  - Installer: adds `PreToolUse`, `PostToolUse`, `PostToolUseFailure` entries (`plain("pre_tool_use")` etc.) and replaces the `AskUserQuestion`-matcher `PermissionRequest` entry with a catch-all (no `matcher` key) `claude-board-hook ask`, `timeout: 90`.
- `stub.py` gains a `"feed"` key in its behaviour file (default `[204, ""]` when absent) for `/v1/feed`.

- [ ] **Step 1: Write failing tests in `test.sh`** (use the Task 1 fixtures; add a `wait_reqs N` helper that polls `$TMP/log` up to 3 s, since feed posts are asynchronous): `pre_tool_use_posts_a_tool_entry` (`"Bash: <command>"`, path `/v1/feed`, kind `tool`); `edit_tool_entry_uses_the_file_path`; `post_tool_use_posts_result_ok`; `post_tool_use_failure_posts_result_failed`; `user_prompt_submit_posts_event_and_prompt_feed`; `stop_posts_event_and_reply_feed`; `empty_reply_posts_no_feed`; `tool_text_is_cut_to_300_chars_and_newlines_collapsed`; `scrub_redacts_authorization_bearer_and_token_assignments` (inputs `curl -H "Authorization: Bearer abc123" x`, `GITHUB_TOKEN=ghp_x gh api`, `password=hunter2 run`; none of `abc123`, `ghp_x`, `hunter2` may appear in the posted body); `feed_post_does_not_delay_the_hook` (stub `feed` delay 2 s, hook exit in under 1 s); `feed_failure_creates_the_down_marker`; `ask_for_bash_posts_tool_name_and_summary`; `installer_adds_tool_feed_hooks`; `installer_ask_hook_has_no_matcher`; keep `installer_is_idempotent` passing (re-run installer twice, files equal).
- [ ] **Step 2: Run** `bash packages/claude-board-hook/test/test.sh` — expect the new checks to FAIL and old ones to pass.
- [ ] **Step 3: Implement** in `claude-board-hook`: extend the event `case`; factor the summary/scrub/truncate logic into one `jq` + `sed -E` helper function used by both the feed path and `ask` (no duplicated expressions); add `post_feed kind text` that backgrounds its `curl` with the same bearer-header and `--max-time 3` as `/v1/event`. Update the header comment's event list.
- [ ] **Step 4: Update the installer** per the Interfaces block and the stub as described.
- [ ] **Step 5: Run** `bash packages/claude-board-hook/test/test.sh` — expect every check `ok`, no `FAIL`.
- [ ] **Step 6: Commit** `feat(raider): forward tool calls, replies and approvals from the claude-board hook`.

---

### Task 5: Protocol: feed messages, fixtures, version 2

**Files:**
- Modify: `packages/claude-board-proto/src/lib.rs`, `packages/claude-board-bridge/src/protocol.rs` (re-export), `packages/claude-board-bridge/tests/wire.rs`
- Create: `packages/claude-board-bridge/tests/fixtures/board/{history,entry}.json`

**Interfaces:**
- Produces in `claude_board_proto`:
  - `pub enum FeedKind { Prompt, Tool, Result, Reply, #[serde(other)] Other }` (lowercase on the wire; `Other` last).
  - `pub struct FeedEntry { pub n: u64, pub ts: i64, pub kind: FeedKind, pub text: String }`.
  - `BoardMsg::History { host: String, session: String, entries: Vec<FeedEntry> }` (`"t":"history"`), `BoardMsg::Entry { host: String, session: String, #[serde(flatten)] entry: FeedEntry }` (`"t":"entry"`).
  - `ClientMsg::Watch { host: String, session: String }` (`"t":"watch"`), `ClientMsg::Unwatch` (`"t":"unwatch"`).
  - `PROTOCOL_VERSION = 2`; `hello.json` fixture updated to `{"t":"hello","version":2}`.
- Fixtures: `history.json` = `{"t":"history","host":"raider","session":"s-1","entries":[{"n":1,"ts":1000,"kind":"prompt","text":"fix the build"},{"n":2,"ts":1001,"kind":"tool","text":"Bash: just build raider"},{"n":3,"ts":1002,"kind":"result","text":"failed"},{"n":4,"ts":1003,"kind":"reply","text":"The build failed: missing input."}]}`; `entry.json` = `{"t":"entry","host":"raider","session":"s-1","n":5,"ts":1004,"kind":"tool","text":"Edit: modules/x.nix"}`.

- [ ] **Step 1: Write failing tests:** in proto, `history_and_entry_fixtures_round_trip` (covered by the existing every-fixture test once raised to `n >= 10`), `unknown_feed_kind_parses_as_other`, `watch_and_unwatch_serialise_to_the_firmware_shape` (`{"t":"watch","host":"h","session":"s"}`, `{"t":"unwatch"}`); in the bridge `tests/wire.rs`, `history_matches_the_firmware_fixture` and `entry_matches_the_firmware_fixture`.
- [ ] **Step 2: Run** `cargo test` in both crates — expect failures.
- [ ] **Step 3: Implement** the types and fixtures; update the `hello` fixture and the `PROTOCOL_VERSION` doc comment.
- [ ] **Step 4: Run** `cargo test` in both crates — expect all pass.
- [ ] **Step 5: Commit** `feat(raider): add feed messages to the claude-board protocol`.

---

### Task 6: Bridge feed endpoint and watch

**Files:**
- Modify: `packages/claude-board-bridge/src/http.rs` (`AppState.feed`, `POST /v1/feed`, `/v1/event` SessionEnd), `packages/claude-board-bridge/src/board.rs`, `packages/claude-board-bridge/src/main.rs` (expiry sweep)
- Test: `packages/claude-board-bridge/tests/http.rs`, `packages/claude-board-bridge/tests/board.rs`

**Interfaces:**
- Consumes: `Feed` (Task 2), `FeedKind`/`BoardMsg::{History,Entry}`/`ClientMsg::{Watch,Unwatch}` (Task 5).
- Produces: `AppState.feed: Arc<Feed>`; `POST /v1/feed` (host token; body `{host, session, kind, text, ts}`; 204; 400 on a bad body or unknown `kind`; request bodies over 16 KiB → 413 via axum's body limit) appends and sends `BoardMsg::Entry` on `s.tx`. Per socket, `board::serve` keeps `watching: Option<(String, String)>`: `Watch` sets it and replies `History` (newest 50); `Unwatch` clears it; an `Entry` from the broadcast is forwarded only when it matches `watching`. A `SessionEnd` event and the expiry sweep call `feed.drop_session`.

- [ ] **Step 1: Write failing tests** (follow `tests/board.rs` for socket setup): `feed_requires_the_host_token`; `feed_bad_kind_is_400`; `feed_entry_is_not_sent_to_a_board_that_is_not_watching`; `watch_replies_with_history_then_streams_entries`; `watch_other_session_receives_no_entries`; `unwatch_stops_entries`; `watch_unknown_session_gets_empty_history`; `feed_never_cancels_a_held_question` (hold an ask, post a `tool` feed entry for the same session, the ask is still pending); `session_end_drops_the_feed`; `oversized_feed_body_is_rejected`; `lagged_socket_resends_history_for_its_watched_session`.
- [ ] **Step 2: Run** `cargo test --test http --test board` — expect the new tests to fail.
- [ ] **Step 3: Implement** the endpoint, per-socket watch state, and the `SessionEnd`/expiry drops. On `RecvError::Lagged`, after the fresh snapshot also resend `History` for `watching`.
- [ ] **Step 4: Run** `cargo test` in the bridge crate — expect all pass.
- [ ] **Step 5: Commit** `feat(galactica): stream a watched session's feed to the board`.

---

### Task 7: Board model: watching and the feed buffer

**Files:**
- Modify: `packages/claude-board-proto/src/model.rs`

**Interfaces:**
- Consumes: Task 5's types.
- Produces on `Model`: `watch(&mut self, host: &str, session: &str) -> ClientMsg` (sets the target, clears the buffer, returns `ClientMsg::Watch`); `unwatch(&mut self) -> Option<ClientMsg>` (`Some(Unwatch)` only if watching; clears target and buffer); `rewatch_msg(&self) -> Option<ClientMsg>` (the `Watch` for the current target, for after a reconnect); `watching(&self) -> Option<(&str, &str)>`; `feed(&self) -> &[FeedEntry]`; `pub const FEED_CAP: usize = 50`. `apply` handles `History` (replaces the buffer with the newest 50, only when host and session match the target) and `Entry` (appended only when matching and `n` greater than the last held `n`; trimmed to 50). Non-matching feed messages return `Applied::Ignored`. A `state` snapshot does not touch the feed.

- [ ] **Step 1: Write failing tests** using the `history` and `entry` fixtures: `history_for_the_watched_session_fills_the_buffer`; `history_for_another_session_is_ignored`; `entry_appends_and_is_capped_at_50`; `entry_with_a_seen_n_is_ignored` (a history ending at `n=4`, an entry `n=4` or lower is ignored: the watch-race duplicate); `a_new_history_replaces_stale_entries` (reconnect); `unwatch_clears_and_only_returns_a_message_when_watching`; `rewatch_msg_is_none_when_not_watching`; `state_snapshot_keeps_the_feed`.
- [ ] **Step 2: Run** `cargo test` in `packages/claude-board-proto` — expect failures.
- [ ] **Step 3: Implement** the feed fields and methods on `Model`.
- [ ] **Step 4: Run** `cargo test` in the proto crate — expect all pass.
- [ ] **Step 5: Commit** `feat(raider): hold the watched session's feed in the board model`.

---

### Task 8: Controller: watch lifecycle and feed rows

**Files:**
- Modify: `firmware/claude-board/ui/src/controller.rs`, `firmware/claude-board/ui/src/view.rs`, `firmware/claude-board/ui/ui/theme.slint` (add `enum FeedKind { prompt, tool, reply }` and `struct FeedRow { kind: FeedKind, text: string, failed: bool }` beside `OptionRow`), `firmware/claude-board/ui/ui/app.slint` (properties `feed: [FeedRow]`, `expanded-text: string`; remove `detail-summary`/`detail-recent`; callbacks `entry-tapped(int)`, `expanded-closed()`)
- Test: `firmware/claude-board/ui/tests/controller.rs`, unit tests in `view.rs`

**Interfaces:**
- Consumes: Task 7's `Model` methods; the controller's `Outbox`.
- Produces: `pub fn feed_rows(entries: &[FeedEntry]) -> Vec<FeedRowData>` in `view.rs`, where `FeedRowData { kind, text: String, failed: bool }` is the plain struct the controller maps to Slint's `FeedRow`. Rules: `prompt`/`tool`/`reply` become rows with the entry text; a `result` with text `failed` sets `failed` on the nearest preceding `tool` row not already marked, a `result` of `ok` produces no row; unknown kinds are dropped.
- Controller: entering a detail (by row or rim tap) sends `model.watch(..)`; leaving it (back, the session disappearing, opening another detail) sends `model.unwatch()`; `set_link(true)` while on a detail sends `rewatch_msg()`. Tapping a feed row sets `expanded-text` to that row's full text; `expanded-closed` and `back_tapped` clear it. Empty feed shows the text `No activity yet` (a property `feed-empty: bool`).

- [ ] **Step 1: Write failing tests.** `view.rs`: `feed_rows_drops_ok_results`; `feed_rows_marks_the_nearest_unmarked_tool_failed` (tool, tool, failed → second marked; another failed → first marked); `feed_rows_ignores_unknown_kinds`. `tests/controller.rs` (follow its existing fake-`Outbox` pattern): `opening_a_detail_sends_watch`; `going_back_sends_unwatch`; `opening_another_session_unwatches_the_first_then_watches_the_second`; `link_coming_back_up_on_a_detail_resends_watch`; `link_up_on_the_list_sends_nothing`; `session_removed_while_watched_sends_unwatch`; `history_then_a_duplicate_entry_shows_each_row_once`; `tapping_a_row_expands_its_full_text_and_back_closes_it`.
- [ ] **Step 2: Run** `cargo test -p claude-board-ui` — expect failures.
- [ ] **Step 3: Implement** `feed_rows`, the Slint declarations and the controller changes. Route every nav change through one `set_nav` that compares the old and new detail target and emits watch/unwatch, instead of sending at each call site.
- [ ] **Step 4: Run** `cargo test -p claude-board-ui` — expect all pass (the Slint file must compile for the tests to run).
- [ ] **Step 5: Commit** `feat(raider): watch a session's feed from the board detail page`.

---

### Task 9: Detail page feed rendering

**Files:**
- Modify: `firmware/claude-board/ui/ui/detail.slint`, `firmware/claude-board/ui/examples/preview.rs` (a preview screen with a sample feed)
- Test: `firmware/claude-board/ui/tests/render.rs`

**Interfaces:**
- Consumes: `FeedRow`, `feed`, `feed-empty`, `expanded-text`, `entry-tapped`, `expanded-closed` from Task 8.
- Produces: `DetailPage` showing, under the unchanged header (host, project, state pill), a `Flickable` feed in the same 300 px column. Row styling: prompt = `Theme.text`, wrapped, at most 3 lines; tool = JetBrains Mono 12 px, one line elided, in `Theme.muted`, with a `Theme.error`-coloured marker when `failed`; reply = wrapped, at most 5 lines. Newest at the bottom; follows new rows unless scrolled up (re-arms when scrolled back to the bottom). Tap on a row calls `entry-tapped(i)`. When `expanded-text` is non-empty a full-page overlay shows it in a scrollable wrapped text; tapping the overlay calls `expanded-closed()`. When `feed-empty` the page shows `No activity yet` in `Theme.muted`.

- [ ] **Step 1: Write failing render tests** (headless, pixel checks as in the existing tests): `feed_page_shows_the_empty_text` (feed empty, `feed-empty` true → some non-background pixels in the feed area; with `feed-empty` false and no rows → none); `a_failed_tool_row_draws_the_error_colour` (one failed tool row → a pixel near `Theme.error` in the feed area, none when `failed` is false); `feed_follows_the_newest_row` (30 rows whose last row is a failed tool → the error colour is visible without scrolling); `expanded_overlay_covers_the_feed` (set `expanded-text` → the feed's row pixels are no longer visible, overlay text pixels are).
- [ ] **Step 2: Run** `cargo test -p claude-board-ui --test render` — expect failures.
- [ ] **Step 3: Implement** the feed in `detail.slint`. Use whichever of Slint's `max-lines`/elide text properties the vendored Slint version supports for the line limits. Add the preview screen and run `just board preview`; read the PNG to check the layout fits inside the 466 px circle (nothing clipped at the round edge).
- [ ] **Step 4: Run** `cargo test -p claude-board-ui` — expect all pass.
- [ ] **Step 5: Commit** `feat(raider): draw the session feed on the board detail page`.

---

### Task 10: End to end, docs, deploy

**Files:**
- Modify: `CLAUDE.md` ("Claude Board" section: new hook events, `/v1/feed`, watch protocol, approvals for every tool, protocol version 2, "tool output is never sent"), `docs/superpowers/specs/2026-11-09-claude-board-feed-design.md` (record the deviations listed in Step 4)

- [ ] **Step 1: Full test run:** bridge, proto, UI and hook suites all pass with the commands in Global Constraints.
- [ ] **Step 2: Build the firmware** `just board build` (host only; do not flash unless asked). Expect a clean build and a `heap:` margin note is not required.
- [ ] **Step 3: Deploy the bridge:** `just deploy galactica`; then `claude-board-install-hooks` on raider so the new hooks are registered. Confirm the registered hooks: `jq '.hooks | keys' ~/.claude/settings.json` lists `PreToolUse`, `PostToolUse`, `PostToolUseFailure`.
- [ ] **Step 4: Verify against the live bridge** with a real session: a `tool` entry reaches `/v1/feed` (watch with a WebSocket client or the board); a Bash approval appears as `Bash: <command>` with Allow/Deny and answering Allow runs the command. While an approval is held, note whether the terminal permission dialog is visible. If it is not, lower the ask timeout for approvals and record that in the spec. Also record: the empty feed shows "No activity yet" instead of "ended" (a session that is gone closes the detail page), and the board does not check `PROTOCOL_VERSION` (an older bridge ignores `watch`, leaving the page empty).
- [ ] **Step 5: Update `CLAUDE.md` and the spec**, then commit `docs(raider): document the claude-board feed and approvals`.

---

## Ordering note

Tasks 2, 3 and 6 use the types from Task 5, so do Task 5 first. Suggested order: 1, 5, 2, 3, 6, 4, 7, 8, 9, 10. Task 4 (hook) is independent of the Rust tasks after Task 1.
