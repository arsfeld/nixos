# Claude board: hook spike findings (Claude Code 2.1.319)

Run on raider on 2026-11-09 with throwaway recorder hooks, in real interactive
sessions driven through tmux (auto mode and default mode). Real payloads,
sanitised, are in `packages/claude-board-bridge/tests/fixtures/`.

## Answers to the five questions

**(a) Does `PermissionRequest` fire for the question tool in auto mode?**
Yes. `tool_name: "AskUserQuestion"`, `permission_mode: "auto"`. It also fires
for ordinary tools in default mode (a `Bash` write command).

**(b) Does the `updatedInput` answer take effect?** Yes. A command hook that
printed
`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{<tool_input>,"answers":{"<question text>":"<label>"}}}}}`
was accepted ("Allowed by PermissionRequest hook"), the terminal dialog never
appeared, and Claude reported the chosen option back correctly. Phase 1 is
feasible.

**(c) Notification types.** Observed: `permission_prompt` ("Claude needs your
permission", fires when a permission dialog is shown) and `idle_prompt`
("Claude is waiting for your input", fires after about a minute idle). Payload
field is `notification_type`. No notification fires when a `PermissionRequest`
hook answers the question itself. Other types may exist; the bridge ignores
unknown ones.

**(d) Is there an error event?** Yes: `StopFailure`, with an `error` string
(observed `model_not_found`) and `last_assistant_message`. Its payload has no
`cwd` field.

**(e) Identity fields.** `session_id` and `cwd` on every event except
`StopFailure`, which lacks `cwd`. `SessionStart` also has `source`
(`startup` or `resume`) and `model`. `SessionEnd` has `reason` (observed
`prompt_input_exit`). `Stop` has `last_assistant_message`.

## Consequences for the plan

- A resumed session keeps its `session_id` and starts with `source: "resume"`,
  so a card is revived rather than duplicated (Task 2).
- When several hooks match one `PermissionRequest`, all of them run (a
  matcher-specific and a generic hook both fired). The board hook must not
  assume it is the only one.
- `claude-board-hook` must take the project directory from `$PWD` when the
  payload has no `cwd` (Task 7), and the bridge keeps the last known `cwd` for
  a session when an event arrives without one (Task 2).
- `idle_prompt` follows `Stop` by about a minute, so a `done` card becomes
  `idle` shortly after, as the plan's state table has it.
- The user's existing `PreToolUse` hook on the question tool (an ntfy
  notification) still runs alongside; no conflict seen.
