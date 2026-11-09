#!/usr/bin/env bash
# Tests for claude-board-hook and claude-board-install-hooks. Run: bash packages/claude-board-hook/test/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOK="$HERE/../claude-board-hook"
INSTALL="$HERE/../claude-board-install-hooks"
FIX="$ROOT/packages/claude-board-bridge/tests/fixtures"
TMP="$(mktemp -d)"
trap 'kill $STUB 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1${2:+: $2}"; }
check() { # name, condition-result
  if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

printf 'secret-token' >"$TMP/token"
export CLAUDE_BOARD_TOKEN_FILE="$TMP/token" CLAUDE_BOARD_HOST=testhost CLAUDE_BOARD_STATE_DIR="$TMP/state"
mkdir -p "$TMP/state"

behave() { printf '%s' "$1" >"$TMP/behaviour.json"; : >"$TMP/log"; }
reqs() { wc -l <"$TMP/log" | tr -d ' '; }
last() { tail -n1 "$TMP/log"; }

behave '{"event":[204,""],"ask":[204,""]}'
python3 "$HERE/stub.py" "$TMP/log" "$TMP/behaviour.json" >"$TMP/port" &
STUB=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"
export CLAUDE_BOARD_URL="http://127.0.0.1:$PORT"

run() { # args..., stdin from $IN
  OUT="$(bash "$HOOK" "$@" <"$IN" 2>"$TMP/err")"; RC=$?
}

# --- event normalisation -----------------------------------------------------------
IN="$FIX/notification_permission.json"; behave '{"event":[204,""],"ask":[204,""]}'
run notification
check event_exits_0_silently "$([ $RC = 0 ] && [ -z "$OUT" ] && echo 0 || echo 1)"
check event_uses_bearer_token "$(last | jq -e '.auth == "Bearer secret-token"' >/dev/null && echo 0 || echo 1)"
check event_hits_event_path "$(last | jq -e '.path == "/v1/event"' >/dev/null && echo 0 || echo 1)"
check event_posts_normalised_json "$(last | jq -e '.body | fromjson | (.host=="testhost" and .session=="00000000-0000-4000-8000-000000000001" and .cwd=="/home/arosenfeld/Code/nixos" and .event=="notification" and .kind=="permission_prompt" and (.ts|type)=="number")' >/dev/null && echo 0 || echo 1)"

IN="$FIX/stop.json"; run stop
check stop_event_has_no_kind "$(last | jq -e '.body | fromjson | (.event=="stop" and (has("kind")|not))' >/dev/null && echo 0 || echo 1)"

mkdir -p "$TMP/work/proj"
(cd "$TMP/work/proj" && IN="$FIX/stop_failure.json" && jq 'del(.cwd)' "$FIX/stop_failure.json" >"$TMP/nocwd.json" && bash "$HOOK" stop_failure <"$TMP/nocwd.json")
check missing_cwd_falls_back_to_pwd "$(last | jq -e --arg d "$TMP/work/proj" '.body | fromjson | .cwd == $d' >/dev/null && echo 0 || echo 1)"

# --- failure modes: the hook must never block or break a session ---------------------------------
before=$(reqs); : >"$TMP/log"
IN="$FIX/stop.json"
export CLAUDE_BOARD_TOKEN_FILE="$TMP/nonexistent"; run stop
check missing_token_file_exits_0_silently_and_sends_nothing "$([ $RC = 0 ] && [ -z "$OUT" ] && [ "$(reqs)" = 0 ] && echo 0 || echo 1)"
export CLAUDE_BOARD_TOKEN_FILE="$TMP/token"

printf 'not json at all' >"$TMP/garbage"; IN="$TMP/garbage"; run stop
check malformed_stdin_exits_0_and_sends_nothing "$([ $RC = 0 ] && [ -z "$OUT" ] && [ "$(reqs)" = 0 ] && echo 0 || echo 1)"

IN="$FIX/stop.json"
behave '{"event":[500,"boom"],"ask":[500,"boom"]}'
run stop
check bridge_500_event_exits_0_silently "$([ $RC = 0 ] && [ -z "$OUT" ] && echo 0 || echo 1)"
IN="$FIX/ask_user_question.json"; rm -rf "$TMP/state"/*; run ask
check bridge_500_ask_exits_0_with_no_output "$([ $RC = 0 ] && [ -z "$OUT" ] && echo 0 || echo 1)"

rm -rf "$TMP/state"/*
IN="$FIX/stop.json"
t0=$(date +%s.%N); CLAUDE_BOARD_URL="http://127.0.0.1:1" bash "$HOOK" stop <"$IN" >"$TMP/out" 2>&1; RC=$?; t1=$(date +%s.%N)
check bridge_down_exits_0_quickly_with_no_output "$([ $RC = 0 ] && [ ! -s "$TMP/out" ] && awk "BEGIN{exit !($t1-$t0 < 3)}" && echo 0 || echo 1)"
behave '{"event":[204,""],"ask":[204,""]}'
CLAUDE_BOARD_URL="$CLAUDE_BOARD_URL" bash "$HOOK" stop <"$IN"
check a_recent_failure_makes_the_next_call_skip_the_bridge "$([ "$(reqs)" = 0 ] && echo 0 || echo 1)" "reached the bridge during the back-off"
find "$TMP/state" -type f -exec touch -d '5 minutes ago' {} +
bash "$HOOK" stop <"$IN"
check the_backoff_ends_after_a_minute "$([ "$(reqs)" = 1 ] && echo 0 || echo 1)"

# --- ask ---------------------------------------------------------------------------
rm -rf "$TMP/state"/*
IN="$FIX/ask_user_question.json"
behave '{"event":[204,""],"ask":[204,""]}'
run ask
check ask_204_prints_nothing "$([ $RC = 0 ] && [ -z "$OUT" ] && echo 0 || echo 1)"
check ask_posts_tool_input_to_ask_path "$(last | jq -e --slurpfile f "$FIX/ask_user_question.json" '.path=="/v1/ask" and (.body|fromjson|(.host=="testhost" and .session==$f[0].session_id and .cwd==$f[0].cwd and .tool_input==$f[0].tool_input))' >/dev/null && echo 0 || echo 1)"
DEC='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"answers":{"Which colour?":"Blue"}}}}}'
behave "$(jq -cn --arg b "$DEC" '{event:[204,""],ask:[200,$b]}')"
run ask
check ask_200_prints_the_body_verbatim "$([ $RC = 0 ] && [ "$OUT" = "$DEC" ] && echo 0 || echo 1)"
behave '{"event":[204,""],"ask":[200,"<html>not json</html>"]}'
run ask
check ask_200_with_a_non_json_body_prints_nothing "$([ $RC = 0 ] && [ -z "$OUT" ] && echo 0 || echo 1)"

# --- installer ---------------------------------------------------------------------
S="$TMP/settings.json"
cat >"$S" <<'JSON'
{"theme":"dark","statusLine":{"type":"command","command":"x"},
 "hooks":{"PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"claude-notify question t"}]}],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"codegraph prompt-hook"}]}]}}
JSON
CLAUDE_SETTINGS="$S" bash "$INSTALL"; RC=$?
check installer_succeeds "$([ $RC = 0 ] && echo 0 || echo 1)"
check installer_preserves_other_keys "$(jq -e '.theme=="dark" and .statusLine.command=="x"' "$S" >/dev/null && echo 0 || echo 1)"
check installer_preserves_existing_hooks "$(jq -e '(.hooks.PreToolUse|length)==1 and (.hooks.PreToolUse[0].hooks[0].command|startswith("claude-notify")) and (.hooks.UserPromptSubmit|map(.hooks[0].command)|index("codegraph prompt-hook")) != null' "$S" >/dev/null && echo 0 || echo 1)"
check installer_adds_every_board_hook "$(jq -e '[.hooks.SessionStart,.hooks.UserPromptSubmit,.hooks.Notification,.hooks.Stop,.hooks.StopFailure,.hooks.SessionEnd] | all(.[]; map(.hooks[].command) | any(startswith("claude-board-hook ")))' "$S" >/dev/null && echo 0 || echo 1)"
check installer_adds_the_ask_hook_with_a_timeout "$(jq -e '.hooks.PermissionRequest | map(select(.matcher=="AskUserQuestion")) | (length==1 and .[0].hooks[0].command=="claude-board-hook ask" and .[0].hooks[0].timeout==90)' "$S" >/dev/null && echo 0 || echo 1)"
cp "$S" "$TMP/first.json"
CLAUDE_SETTINGS="$S" bash "$INSTALL"
check installer_is_idempotent "$(cmp -s "$S" "$TMP/first.json" && jq -e '.hooks.Stop | map(select(.hooks[0].command=="claude-board-hook stop")) | length==1' "$S" >/dev/null && echo 0 || echo 1)"
# stale board entries (old arguments) are replaced, not duplicated
jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"claude-board-hook stale_arg"}]}]' "$S" >"$TMP/stale.json"; cp "$TMP/stale.json" "$S"
CLAUDE_SETTINGS="$S" bash "$INSTALL"
check installer_drops_stale_board_entries "$(jq -e '[.hooks.Stop[].hooks[].command] | (index("claude-board-hook stale_arg")==null and (map(select(.=="claude-board-hook stop"))|length)==1)' "$S" >/dev/null && echo 0 || echo 1)"
rm -f "$TMP/new/settings.json"
CLAUDE_SETTINGS="$TMP/new/settings.json" bash "$INSTALL"
check installer_creates_a_missing_settings_file "$(jq -e '.hooks.Stop|length==1' "$TMP/new/settings.json" >/dev/null && echo 0 || echo 1)"
printf '{ this is not json' >"$TMP/bad.json"; cp "$TMP/bad.json" "$TMP/bad.orig"
CLAUDE_SETTINGS="$TMP/bad.json" bash "$INSTALL" 2>"$TMP/bad.err"; RC=$?
check installer_refuses_invalid_json_and_leaves_it_untouched "$([ $RC = 1 ] && grep -q "not valid JSON" "$TMP/bad.err" && cmp -s "$TMP/bad.json" "$TMP/bad.orig" && echo 0 || echo 1)"

echo "---- $pass passed, $fail failed"
[ "$fail" = 0 ]
