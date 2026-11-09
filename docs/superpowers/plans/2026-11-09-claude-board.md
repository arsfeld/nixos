# Claude Board (phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An ESP32-S3 AMOLED board that shows every Claude Code session across the fleet and answers Claude's multiple-choice questions with a tap.

**Architecture:** Claude Code hooks on every host POST events to a Rust bridge on galactica. The bridge derives session state, holds question requests open, and relays both to the board over one WebSocket. The board is a thin ESP-IDF + LVGL client. A timeout or offline board makes the hook return no decision, so the terminal prompt appears as before.

**Tech Stack:** Rust (axum, tokio) for the bridge; bash + curl + jq for hooks; ESP-IDF v5.5.x, LVGL, Waveshare BSP for the board; nix (`media.services`, sops-nix, home-manager, `nixpkgs-esp-dev`).

**Spec:** `docs/superpowers/specs/2026-11-09-claude-board-design.md`. Phase 2 (runners, voice, spawn) is out of scope and gets its own brainstorm and plan after phase 1 works.

## Global Constraints

- Hooks never block or break a session: any failure exits 0 with no output.
- Bridge reachable on LAN and tailnet only; no public route and not behind Cloudflare. Tokens come from sops.
- A question id is unique and single-use; a late or replayed answer is ignored.
- Questions are answered by returning `allow` with `updatedInput` = the original `questions` array plus `answers` keyed by exact question text; multi-select labels are joined with commas. A bare `allow` leaves the question open.
- Wi-Fi SSID and password compiled into the firmware from a sops secret at build time; no on-device provisioning.
- Firmware: ESP-IDF v5.5.x, LVGL, BSP `waveshare/esp32_s3_touch_amoled_1_75`. Idle screen near-black and dimmed. State colours: working blue, waiting amber, idle grey, done green, error red.
- Take a full-flash backup before the first custom flash; the factory image (`firmware/ESP32-S3-Touch-AMOLED-1.75-FactoryOnly-260805.bin` at `0x0` in the Waveshare repo) restores the demo.
- Repo rules: commit straight to master (no branches); conventional commits `<type>(<scope>): <subject>`, scopes `modules`, `home`, `secrets` or a hostname, no mention of Claude or any model in commit messages; `git add -N` new files before any `nix build`; format with `just fmt`; secrets via `sops` non-interactively; never build or evaluate `cylon-link`; build one host toplevel at a time, niced.

## Review Focus

- Two sessions ask at once (same project, same host): each ask has its own id and answers never cross. Pinned in Task 3 and Task 5.
- The board disconnects while an ask is open: the hook gets no decision and the terminal prompt appears. Task 5.
- Question text with unicode, emoji or very long strings: the answer key must round-trip byte-exact; only the display truncates. Tasks 3 and 9.
- A session id reused after `SessionEnd`, `/resume` or restart: the card is revived, never duplicated. Task 2.
- Bridge down, slow or returning 5xx when a hook runs: the hook exits 0 quickly and a held ask returns nothing. Task 7.

## Decisions the spec left open

- Ask timeout: bridge `BRIDGE_ASK_TIMEOUT_SECS=90`; the hook's own `timeout` in settings is 120.
- `Stop` sets `done` (turn finished); `SessionStart` sets `idle`; `idle_prompt` notifications set `idle`.
- Cards expire after `BRIDGE_EXPIRE_SECS=21600` (6 h) with no event.
- Hooks reach the bridge at `https://claude-board.bat-boa.ts.net` (tailnet, every host); the board at `https://claude-board.arsfeld.one` (LAN DNS to galactica). The bridge rejects any request carrying a `Cf-*` header, because the `*.arsfeld.one` wildcard is also routed through Cloudflare.
- Firmware is built in a nix dev shell, not as a pure derivation: ESP-IDF's component manager needs network. `dependencies.lock` pins the components.

## File Structure

- `packages/claude-board-bridge/` — Rust crate and `package.nix`. Files: `src/protocol.rs` (wire types), `src/state.rs` (session registry), `src/asks.rs` (pending questions), `src/auth.rs` (tokens and the `Cf-*` guard), `src/http.rs` (hook endpoints), `src/board.rs` (WebSocket), `src/main.rs` (config, wiring). Tests in `tests/`, fixtures in `tests/fixtures/`.
- `modules/hosts/galactica/services/claude-board.nix` — service, secrets, gateway entry.
- `packages/claude-board-hook/` — `package.nix` plus `claude-board-hook` and `claude-board-install-hooks` scripts.
- `home/home.nix` — install the hook package and merge hooks into `~/.claude/settings.json`.
- `firmware/claude-board/` — ESP-IDF project. `components/board_proto/` is pure C (cJSON only) and host-tested; `main/` holds Wi-Fi, WebSocket and UI.
- `just/board.just` — recipes `test`, `build`, `flash`, `monitor`, `backup`, `restore`.
- `modules/flake/dev.nix`, `flake.nix` — `nixpkgs-esp-dev` input and `devShells.firmware`.
- `docs/superpowers/specs/2026-11-09-claude-board-hook-findings.md` — spike result (Task 1).

---

### Task 1: Hook spike (gates everything)

**Files:**
- Create: `packages/claude-board-bridge/tests/fixtures/*.json` (one recorded payload per hook event), `docs/superpowers/specs/2026-11-09-claude-board-hook-findings.md`
- Create (throwaway, not committed): `$SCRATCH/spike-hook.sh`, a command hook that appends its stdin and the event name to `$SCRATCH/events.jsonl`

**Interfaces:**
- Produces: the findings doc, answering the five questions below, and fixtures that Tasks 2 to 5 load.

This needs an interactive Claude Code 2.1.319 session in auto mode (`defaultMode: auto`), so the user runs it in a terminal while the agent watches `events.jsonl`.

- [ ] **Step 1: Write the throwaway recorder** and register it with `--settings` (not the real settings file) for `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `StopFailure`, `SessionEnd` and a `PermissionRequest` matcher `AskUserQuestion`.
- [ ] **Step 2: Drive one session** through: start, prompt, a turn that asks a multiple-choice question, an idle wait, a permission prompt in a non-auto session, a forced API error, `/resume`, exit.
- [ ] **Step 3: Make the `PermissionRequest` recorder answer** by printing `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{...questions, "answers":{...}}}}}` and observe whether Claude proceeds with the chosen answer and whether the terminal dialog disappears.
- [ ] **Step 4: Write the findings doc**, answering exactly: (a) does `PermissionRequest` fire for the question tool in auto mode; (b) does the `updatedInput` answer take effect; (c) what `Notification` types exist and which mean waiting; (d) is there an error event (`StopFailure` or similar); (e) which payload fields identify session and project (`session_id`, `cwd`).
- [ ] **Step 5: Gate.** If (a) or (b) is no, stop and return to brainstorming with the findings. If (d) is no, drop the `error` state from phase 1 and amend the spec. Copy real payloads into `tests/fixtures/` as `session_start.json`, `user_prompt_submit.json`, `notification_permission.json`, `notification_idle.json`, `stop.json`, `session_end.json`, `ask_user_question.json` (and `stop_failure.json` if it exists), with any secrets removed.
- [ ] **Step 6: Commit** `docs(modules): record claude hook behaviour findings`

---

### Task 2: Session registry (`state.rs`, `protocol.rs`)

**Files:**
- Create: `packages/claude-board-bridge/Cargo.toml`, `src/protocol.rs`, `src/state.rs`, `src/lib.rs`, `tests/state.rs`

**Interfaces:**
- Produces (`protocol.rs`): `enum State { Idle, Working, Waiting, Done, Error }` (serde lowercase); `struct Event { host: String, session: String, cwd: String, event: EventKind, ts: i64 }`; `enum EventKind { SessionStart, UserPromptSubmit, Notification { kind: String }, Stop, StopFailure, SessionEnd }` (serde tagged by `event`); `struct Session { host, session, project, cwd, state: State, since: i64 }` where `project` is the last path component of `cwd`.
- Produces (`state.rs`): `enum Change { Upsert(Session), Remove { host: String, session: String } }`; `struct Registry`; `Registry::new(expire_secs: i64) -> Registry`; `apply(&mut self, e: &Event) -> Option<Change>`; `set_waiting(&mut self, host: &str, session: &str, cwd: &str, ts: i64) -> Option<Change>`; `expire(&mut self, now: i64) -> Vec<Change>`; `snapshot(&self) -> Vec<Session>` sorted waiting first, then most recent `since`.

- [ ] **Step 1: Write failing tests in `tests/state.rs`**: `session_start_creates_idle`; `prompt_submit_sets_working`; `permission_notification_sets_waiting`; `idle_notification_sets_idle`; `stop_sets_done`; `stop_failure_sets_error`; `session_end_removes`; `unknown_notification_kind_changes_nothing` (returns `None`); `state_change_updates_since_only_when_state_changes`; `revived_session_is_not_duplicated` (`SessionStart`, `SessionEnd`, `SessionStart` with the same ids leaves one card; and an event for an unseen session id creates one); `snapshot_sorts_waiting_first`; `expire_removes_cards_without_events_for_expire_secs`; `project_is_last_path_component` (including trailing slash). Load the Task 1 fixtures where a payload shape matters.
- [ ] **Step 2: Run** `cd packages/claude-board-bridge && cargo test --test state` — Expected: FAIL (crate does not compile).
- [ ] **Step 3: Implement** the types and `Registry` per the interfaces; key the map by `(host, session)`.
- [ ] **Step 4: Run** `cargo test --test state` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(modules): add claude board session registry`

---

### Task 3: Pending questions (`asks.rs`)

**Files:**
- Create: `packages/claude-board-bridge/src/asks.rs`, `tests/asks.rs`

**Interfaces:**
- Consumes: `protocol::Session` identity fields.
- Produces: `struct AskId(pub String)` (random, 128-bit hex); `struct Question { question: String, header: Option<String>, options: Vec<QuestionOption>, multi_select: bool }` and `struct QuestionOption { label: String, description: Option<String> }` (serde camelCase, matching the tool input); `enum Answered { Answers(BTreeMap<String, String>), Declined }`; `struct Asks`; `Asks::register(&self, host: &str, session: &str, project: &str, tool_input: serde_json::Value) -> (AskId, tokio::sync::oneshot::Receiver<Answered>)`; `Asks::answer(&self, id: &AskId, a: Answered) -> Result<(), AnswerError>` where `AnswerError` is `Unknown` (never issued, expired or already used); `Asks::cancel(&self, id: &AskId)`; `Asks::pending(&self) -> Vec<PendingAsk>` where `PendingAsk { id, host, session, project, questions: Vec<Question> }`; `Asks::cancel_session(&self, host: &str, session: &str) -> Vec<AskId>`.
- Produces: `fn build_decision(tool_input: &serde_json::Value, answers: &BTreeMap<String, String>) -> serde_json::Value` returning the full hook output `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{<tool_input with "answers" added>}}}}`.

- [ ] **Step 1: Write failing tests**: `answer_resolves_the_waiting_receiver`; `second_answer_with_same_id_is_unknown`; `unknown_id_is_unknown`; `two_asks_same_session_do_not_cross` (register two, answer the second first, each receiver gets its own); `cancel_makes_id_unknown`; `cancel_session_cancels_only_that_session`; `build_decision_preserves_questions_and_adds_answers`; `build_decision_keeps_unicode_and_long_keys_byte_exact` (emoji, combining characters, a 5,000-character question text); `multi_select_answer_is_passed_through_as_given` (the bridge does not re-join; the board sends the comma-joined string).
- [ ] **Step 2: Run** `cargo test --test asks` — Expected: FAIL.
- [ ] **Step 3: Implement** with `Mutex<HashMap<AskId, Entry>>`; `answer` removes the entry so ids are single-use.
- [ ] **Step 4: Run** `cargo test --test asks` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(modules): add claude board pending question store`

---

### Task 4: Auth and hook endpoints (`auth.rs`, `http.rs`)

**Files:**
- Create: `packages/claude-board-bridge/src/auth.rs`, `src/http.rs`, `tests/http.rs`

**Interfaces:**
- Consumes: `Registry`, `Asks`, `build_decision`, a broadcast channel `tokio::sync::broadcast::Sender<BoardMsg>` (type defined in `protocol.rs` in this task: `enum BoardMsg { State(Vec<Session>), Upsert(Session), Remove{host,session}, Question(PendingAsk), QuestionClear{id} }`).
- Produces: `struct Tokens { host: String, device: String }`; `fn check_bearer(headers: &HeaderMap, want: &str) -> Result<(), StatusCode>` using constant-time comparison; `fn reject_cloudflare(headers: &HeaderMap) -> Result<(), StatusCode>` (403 if any header name starts with `cf-`); `struct AppState { registry, asks, tx: Sender<BoardMsg>, tokens: Tokens, ask_timeout: Duration, board_connected: Arc<AtomicUsize> }`; `fn hook_router(state: AppState) -> axum::Router` with `POST /v1/event` (204) and `POST /v1/ask` (200 with decision JSON, or 204 for no decision).

- [ ] **Step 1: Write failing tests** (axum `oneshot` requests): `event_requires_host_token` (401 without, 401 wrong); `event_with_cloudflare_header_is_403` (`Cf-Ray` present, valid token); `event_updates_registry_and_broadcasts_upsert`; `ask_with_no_board_connected_returns_204_immediately`; `ask_returns_decision_when_answered` (spawn the request, wait for the `Question` broadcast, `answer` through `Asks`, expect 200 and the decision body); `ask_declined_returns_204`; `ask_times_out_with_204_and_broadcasts_question_clear` (short timeout); `ask_marks_session_waiting`; `a_later_event_for_the_session_clears_its_pending_ask` (broadcasts `QuestionClear`); `two_concurrent_asks_get_their_own_answers`.
- [ ] **Step 2: Run** `cargo test --test http` — Expected: FAIL.
- [ ] **Step 3: Implement** `/v1/ask` as: guard, register, broadcast `Question`, `tokio::time::timeout(ask_timeout, rx)`, on timeout or `Declined` cancel and broadcast `QuestionClear`, return 204.
- [ ] **Step 4: Run** `cargo test --test http` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(modules): add claude board hook endpoints`

---

### Task 5: Board WebSocket and wiring (`board.rs`, `main.rs`)

**Files:**
- Create: `packages/claude-board-bridge/src/board.rs`, `src/main.rs`, `tests/board.rs`

**Interfaces:**
- Consumes: `AppState`, `BoardMsg`, `check_bearer`, `reject_cloudflare`.
- Produces: `fn board_router(state: AppState) -> axum::Router` with `GET /v1/board` (WebSocket, device token, `Cf-*` guard). Server to board JSON: `{"t":"state","sessions":[Session]}` on connect, then `{"t":"upsert","session":Session}`, `{"t":"remove","host":..,"session":..}`, `{"t":"question","id":..,"host":..,"session":..,"project":..,"questions":[Question]}` (all pending asks are re-sent on connect), `{"t":"question_clear","id":..}`. Board to server: `{"t":"answer","id":..,"answers":{"<question text>":"<label or comma-joined labels>"}}` and `{"t":"decline","id":..}`. `main.rs` reads env `BRIDGE_LISTEN`, `BRIDGE_HOST_TOKEN_FILE`, `BRIDGE_DEVICE_TOKEN_FILE`, `BRIDGE_ASK_TIMEOUT_SECS` (default 90), `BRIDGE_EXPIRE_SECS` (default 21600) and runs an expiry sweep every 60 s.

- [ ] **Step 1: Write failing tests** using a simulated board client (`tokio-tungstenite`) against a real listener on an ephemeral port: `connect_without_device_token_is_rejected`; `connect_with_cloudflare_header_is_rejected`; `new_board_gets_state_snapshot_and_pending_questions`; `event_is_pushed_as_upsert`; `answer_over_websocket_completes_the_hook_request` (end to end: POST `/v1/ask`, receive `question`, send `answer`, expect the hook response body); `decline_returns_no_decision`; `board_disconnect_mid_ask_returns_204_when_it_times_out_and_clears` (drop the socket, expect 204 after the timeout, not a hang); `answer_for_expired_id_is_ignored_and_connection_stays_open`; `board_count_drops_on_disconnect` (a new ask then returns 204 at once).
- [ ] **Step 2: Run** `cargo test --test board` — Expected: FAIL.
- [ ] **Step 3: Implement** `board_router` and `main`; `board_connected` increments per live socket.
- [ ] **Step 4: Run** `cargo test` — Expected: all tests PASS.
- [ ] **Step 5: Commit** `feat(modules): add claude board websocket and daemon`

---

### Task 6: Package and galactica service

**Files:**
- Create: `packages/claude-board-bridge/package.nix`, `modules/hosts/galactica/services/claude-board.nix`
- Modify: `secrets/sops/galactica.yaml` (add `claude-board-device-token`), `secrets/sops/common.yaml` (add `claude-board-host-token`)

**Interfaces:**
- Produces: package `claude-board-bridge` (`rustPlatform.buildRustPackage`, `doCheck = true`, mirror `packages/plab/package.nix`'s `lib.fileset` source); a service listening on `127.0.0.1:8590` declared with `media.services.claude-board = { port = 8590; host = "127.0.0.1"; bypassAuth = true; tailscaleExposed = true; }` (the bridge enforces its own tokens and the `Cf-*` guard); a hardened `systemd.services.claude-board` (DynamicUser, `ProtectSystem=strict`, `NoNewPrivileges`) loading both token files through `LoadCredential`.

- [ ] **Step 1: Generate tokens non-interactively** (`openssl rand -hex 32`) and add them with `sops` without printing them.
- [ ] **Step 2: Write `package.nix`** and `git add -N` the new files; Run `nix build .#claude-board-bridge` — Expected: builds and runs `cargo test`.
- [ ] **Step 3: Write the service module**, then `just fmt`; Run `nix build .#nixosConfigurations.galactica.config.system.build.toplevel` (niced, alone) — Expected: builds.
- [ ] **Step 4: Commit, push, `just deploy galactica`**; Run `curl -s -o /dev/null -w '%{http_code}' -X POST https://claude-board.bat-boa.ts.net/v1/event` — Expected: `401`; the same with `-H 'Cf-Ray: x'` and a valid host token — Expected: `403`; `systemctl status claude-board` on galactica — Expected: active.
- [ ] **Step 5: Commit** `feat(galactica): add claude board bridge service`

---

### Task 7: Hooks and installer

**Files:**
- Create: `packages/claude-board-hook/package.nix`, `packages/claude-board-hook/claude-board-hook`, `packages/claude-board-hook/claude-board-install-hooks`, `packages/claude-board-hook/test.sh`
- Modify: `home/home.nix` (add the package to `home.packages`; add a `home.activation` entry that runs `claude-board-install-hooks`)

**Interfaces:**
- Produces: `claude-board-hook <event>` reads Claude Code's hook JSON from stdin and POSTs `{host: <hostname>, session: session_id, cwd, event, kind (notification type), ts}` to `https://claude-board.bat-boa.ts.net/v1/event`; with `ask` it POSTs `{host, session, cwd, tool_input}` to `/v1/ask`, prints the response body only on HTTP 200, and always exits 0. Token from `/run/secrets/claude-board-host-token`; missing file means a silent exit 0. `curl --max-time 3` for events, `--max-time 100` for ask. `claude-board-install-hooks` idempotently merges into `~/.claude/settings.json` (jq, atomic temp file and rename), preserving existing hooks (`claude-notify question …`, `codegraph prompt-hook`) and all other keys: entries for `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `StopFailure` (only if Task 1 found it), `SessionEnd` calling `claude-board-hook <event>`, plus `PermissionRequest` matcher `AskUserQuestion` calling `claude-board-hook ask` with `timeout: 120`. Add the secret `claude-board-host-token` to every host's sops declaration so `/run/secrets/` has it.

- [ ] **Step 1: Write `test.sh`** (runs a throwaway local `nc`/python HTTP stub): `event_posts_normalised_json`; `bridge_down_exits_0_quickly_with_no_output` (under 5 s); `bridge_500_exits_0_with_no_output`; `ask_204_prints_nothing`; `ask_200_prints_the_body_verbatim`; `missing_token_file_exits_0_silently`; `installer_is_idempotent` (run twice, diff empty); `installer_preserves_existing_hooks_and_keys`; `installer_survives_missing_settings_file`.
- [ ] **Step 2: Run** `bash packages/claude-board-hook/test.sh` — Expected: FAIL.
- [ ] **Step 3: Implement** both scripts as `writeShellApplication`s (shellcheck gates the build).
- [ ] **Step 4: Run** `bash packages/claude-board-hook/test.sh` — Expected: all PASS.
- [ ] **Step 5: Wire into `home/home.nix`**, `just fmt`, `git add -N`, then `just deploy raider galactica basestar`; Run `jq '.hooks | keys' ~/.claude/settings.json` — Expected: includes the new events and still `PreToolUse` and `UserPromptSubmit`.
- [ ] **Step 6: End to end.** In a real raider session, send a prompt; verify the bridge sees the events (`journalctl -u claude-board` on galactica); trigger a question and answer it through a simulated board client (`websocat`) — Expected: Claude proceeds with the chosen answer.
- [ ] **Step 7: Commit** `feat(home): install claude board hooks on every host`

---

### Task 8: Firmware toolchain, backup, hello world

**Files:**
- Modify: `flake.nix` (input `nixpkgs-esp-dev` following the repo's `nixpkgs`), `modules/flake/dev.nix` (add `devShells.firmware` from its ESP32-S3 shell, adding `cjson` and `just`), a raider module adding `arosenfeld` to `dialout`
- Create: `just/board.just`, `firmware/claude-board/` skeleton (`CMakeLists.txt`, `main/main.c`, `main/idf_component.yml` requiring `waveshare/esp32_s3_touch_amoled_1_75`, `sdkconfig.defaults`, `.gitignore` for `build/`, `sdkconfig`, `sdkconfig.defaults.local`)
- Create: `~/.local/share/esp32-amoled/full-flash-backup-2026-11-09.bin` (not committed)

**Interfaces:**
- Produces: `just board backup | build | flash | monitor | restore`; a firmware that lights the display with a test pattern and logs touch coordinates.

- [ ] **Step 1: Add the input and shell**, then Run `nix develop .#firmware -c idf.py --version` — Expected: ESP-IDF v5.5.x. If the flake's default is older than the Waveshare README's v5.5.4, override its `rev` in the input and set the hash.
- [ ] **Step 2: Add `dialout`**, deploy raider, re-login; Run `ls -l /dev/ttyACM0 && id` — Expected: the user can open the port without sudo.
- [ ] **Step 3: `just board backup`** (`esptool read-flash 0 0x2000000`); Verify the file is exactly 33,554,432 bytes; keep a sha256 next to it.
- [ ] **Step 4: Build and flash the skeleton** (`just board build && just board flash`); Expected: test pattern on the display, touch coordinates in `just board monitor`.
- [ ] **Step 5: Prove the way back:** `just board restore` writes the backup, and the demo UI boots; then re-flash the skeleton.
- [ ] **Step 6: Commit** `feat(raider): add esp32 firmware toolchain and board recipes`

---

### Task 9: Firmware protocol core (host-tested C)

**Files:**
- Create: `firmware/claude-board/components/board_proto/{board_proto.h,board_proto.c,CMakeLists.txt}`, `firmware/claude-board/components/board_proto/test/{test_board_proto.c,fixtures/*.json}` (copies of real bridge messages)

**Interfaces:**
- Produces: `typedef enum {ST_IDLE, ST_WORKING, ST_WAITING, ST_DONE, ST_ERROR} bp_state_t;` `typedef struct {char host[24]; char session[40]; char project[40]; bp_state_t state; int64_t since;} bp_session_t;` `typedef struct bp_model bp_model_t;` `bp_model_t *bp_model_new(void);` `int bp_apply(bp_model_t *m, const char *json, size_t len);` (returns 0 ok, nonzero on malformed input, never crashes) `size_t bp_sessions(const bp_model_t *m, const bp_session_t **out);` (waiting first, then newest) `const bp_ask_t *bp_current_ask(const bp_model_t *m);` with `bp_ask_t` exposing `id`, `project`, question count, question and option text; `char *bp_answer_json(const bp_ask_t *a, size_t question_index, const char *label);` and `char *bp_decline_json(const bp_ask_t *a);` (caller frees); `size_t bp_fit(const char *utf8, size_t max_bytes);` returns the byte length to display, cutting on a UTF-8 code-point boundary.

- [ ] **Step 1: Write failing tests** compiled with the host `cc` and nix `cjson` (`just board test`): `applies_state_snapshot`; `upsert_replaces_and_remove_deletes`; `sorts_waiting_first`; `question_message_sets_current_ask`; `question_clear_clears_only_matching_id`; `malformed_json_returns_error_and_keeps_model`; `answer_json_uses_exact_question_text_and_label` (compare bytes with a fixture); `unicode_and_emoji_round_trip_in_answer_key`; `very_long_question_is_stored_whole_and_answer_key_is_not_truncated`; `fit_never_splits_a_utf8_sequence`; `answer_for_second_question_waits_until_all_answered` (a multi-question ask only produces the final `answer` JSON after the last question).
- [ ] **Step 2: Run** `just board test` — Expected: FAIL.
- [ ] **Step 3: Implement** with cJSON; fixed-size buffers for display fields, heap for question text so keys are never truncated.
- [ ] **Step 4: Run** `just board test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(raider): add claude board firmware protocol core`

---

### Task 10: Firmware networking

**Files:**
- Create: `firmware/claude-board/main/{net.c,net.h}`, `just/board.just` recipe `creds` that writes `sdkconfig.defaults.local`
- Modify: `main/idf_component.yml`, `main/CMakeLists.txt`, `secrets/sops/raider.yaml` (add `claude-board-wifi-ssid`, `claude-board-wifi-pass`, `claude-board-device-token`)

**Interfaces:**
- Consumes: `bp_apply`.
- Produces: `void net_start(void (*on_message)(const char *json, size_t len), void (*on_status)(bool connected));` `bool net_send(const char *json);` The task connects to Wi-Fi (credentials from `CONFIG_CLAUDE_BOARD_WIFI_SSID` and `_PASS`), opens `wss://claude-board.arsfeld.one/v1/board` with `Authorization: Bearer` (the certificate bundle for TLS validation), reconnects with capped exponential backoff, and forwards each text frame to `on_message`. `just board creds` decrypts the three secrets into `sdkconfig.defaults.local` without printing them.

- [ ] **Step 1: Add the three secrets** non-interactively; Run `just board creds && git status --short` — Expected: `sdkconfig.defaults.local` is ignored and not listed.
- [ ] **Step 2: Implement `net.c`** with `esp_wifi`, `esp_websocket_client` and `esp_crt_bundle`; log connection state only, never the credentials.
- [ ] **Step 3: Flash and watch** `just board monitor` — Expected: joins BaconsHouse, connects the WebSocket, logs the received `state` snapshot (non-empty while a session is running on raider).
- [ ] **Step 4: Kill the bridge** (`systemctl stop claude-board` on galactica) — Expected: the board logs reconnect attempts with growing delay; restart it and the board reconnects.
- [ ] **Step 5: Commit** `feat(raider): add claude board firmware networking`

---

### Task 11: Firmware UI

**Files:**
- Create: `firmware/claude-board/main/{ui.c,ui.h,theme.h}`; Modify: `main/main.c`

**Interfaces:**
- Consumes: `bp_*` functions, `net_start`, `net_send`.
- Produces: screens per the spec. Idle: black, dimmed brightness, count of waiting sessions and a faint ring, chime when the waiting count rises. Sessions: swipeable list, waiting first, card shows project, host chip, state colour, time in state. Question: truncated text via `bp_fit`, up to four large option buttons, one question at a time, a small "answer on computer" button that sends `bp_decline_json`. Detail: project, host, state and time in state. Touching the idle screen wakes it; it dims again after 30 s without touch or change. All LVGL calls run under the BSP's display lock.

- [ ] **Step 1: Implement idle and sessions screens** driven by `bp_model`; Flash; Verify on the device with the user: start two sessions on raider and confirm each card's state changes as you prompt them.
- [ ] **Step 2: Implement the question screen**; Verify with a real question in a raider session: tapping an option answers it and Claude proceeds; the card clears from the board.
- [ ] **Step 3: Verify the edges** with the user: a long question and an emoji option label render without crashing and answers still match; two asks at once are shown in turn and each answers its own session; pressing "answer on computer" leaves the terminal prompt in place.
- [ ] **Step 4: Verify dimming and burn-in behaviour:** after 30 s idle the screen is near-black; a waiting session brightens it and chimes.
- [ ] **Step 5: Commit** `feat(raider): add claude board firmware screens`

---

### Task 12: Docs and wrap-up

**Files:**
- Modify: `CLAUDE.md` (a short "Claude Board" section: what it is, the hosts, `just board …`, the factory-restore command, the token and secret names, the `Cf-*` guard, the phase-2 pointer)
- Modify: the spec (record the decisions listed above under "Decisions the spec left open")

- [ ] **Step 1: Write the CLAUDE.md section** and amend the spec; `just fmt`.
- [ ] **Step 2: Final check:** `nix build .#claude-board-bridge`, `bash packages/claude-board-hook/test.sh`, `just board test`, and one more end-to-end question from a basestar session — Expected: all pass, and the board answers a basestar question too.
- [ ] **Step 3: Commit** `docs(modules): document claude board`
