---
title: Secure local ntfy
type: feat
status: active
date: 2026-04-15
deepened: 2026-04-15
origin: docs/brainstorms/2026-04-15-secure-local-ntfy-brainstorm.md
---

# Secure Local ntfy

## Enhancement Summary

**Deepened:** 2026-04-15 via parallel research (framework-docs, security,
simplicity, deployment-verification, pattern-recognition, python review).

**Key updates applied from research:**

1. **All three open questions resolved with upstream-source citations.**
   `NTFY_AUTH_USERS` uses comma separator (urfave/cli v2.27.7
   `defaultSliceFlagSeparator = ","`). Gatus's native ntfy alerter is
   disqualified (its `Token` field must start with `tk_`) — use the
   generic `custom` alerter with env interpolation. Bcrypt generation
   uses Python at cost 10 — `ntfy user hash` is interactive and cannot
   be piped.
2. **`curl -u user:pass` replaced with explicit `Authorization: Basic`
   header form** at every publisher. Basic-auth via `-u` leaks the
   password into `/proc/<pid>/cmdline` (world-readable) — unacceptable on
   workstations where arbitrary user processes could sample it.
3. **`modules/constellation/ntfy-client.nix` is NOT created.** Four lines
   of sops wiring per host is below the threshold where a wrapping
   constellation module pays for itself. Secret declared inline in each
   host's `configuration.nix`.
4. **Router removed from the claude-notify workstation list.** Headless
   appliance, no interactive Claude Code sessions; removal eliminates the
   ownership collision between `ntfy-webhook` and `arosenfeld` that was
   previously Open Question 5.
5. **Narrower sops recipients** for the publisher credential. Rather than
   adding `ntfy-publisher-env` to `common.yaml` (which would encrypt it
   to `raspi3`/`r2s`/`octopi` — embedded devices that never publish and
   materially widen blast radius on device theft), create a new
   `secrets/sops/ntfy-client.yaml` with only the 6 publishing hosts as
   recipients.
6. **Python script migrations include pre-existing bug fixes.** Missing
   `timeout=` in check-stock and ntfy-webhook-proxy, unreachable 200-OK
   branch in client-monitor, and a cooldown-not-updated-on-failure loop
   spam bug in client-monitor — all get fixed in the same commit as the
   auth migration since they're adjacent to the changed lines.
7. **Phase 3 validation expanded** with a locked-phone APNs push test
   (confirms iOS upstream path survives the flip), Authorization header
   passthrough sanity check via Caddy, `/config.js` + `/v1/health`
   unauthenticated-endpoint audit, and a `/proc/<pid>/environ` check to
   confirm ntfy actually loaded the env file (catches DynamicUser
   permission issues).
8. **Deploy ordering constraint documented.** Phase 1 must deploy storage
   alone (not in parallel with publishers) so the `publisher`/`reader`
   users exist before any publisher tries to authenticate.
9. **Rotation via `just rotate-ntfy-publisher` recipe**, not inline bash.
   Uses `jq -Rs .` unconditionally for JSON escaping (not conditionally,
   as the first version of the runbook suggested).
10. **Catalog fix is broader.** The pattern-reviewer found `Yarr` is also
    stale in `docs/services/catalog.md:88` (says host=cloud, actually on
    storage). Fix both rows in the same commit.

## Overview

Lock down `ntfy.arsfeld.one` (currently public, anonymous, both-way access)
so only our own machines can publish and only household members can read.
Enforcement lives inside ntfy itself — phones are not always on Tailscale,
so network-level auth is not an option. The service stays publicly reachable
via the existing Cloudflare → storage → Caddy → `ntfy-sh` path; the only
change at the edge is that ntfy now rejects anonymous requests.

This plan carries forward every decision from the brainstorm
(`docs/brainstorms/2026-04-15-secure-local-ntfy-brainstorm.md`) and
reshapes the implementation around three research findings that invalidate
parts of the brainstorm's assumed approach — documented below under
[Updates from Research](#updates-from-research).

## Problem Statement

`hosts/storage/services/ntfy.nix` runs `services.ntfy-sh` with:

- `auth-default-access` unset → defaults to `read-write` for everyone
- No `auth-file`, no users, no ACLs
- `bypassAuth = true` at the Caddy gateway (Authelia cannot front ntfy)
- Public hostname `ntfy.arsfeld.one` exposed via the wildcard cloudflared
  tunnel on storage

Consequences we want to close:

1. **Read leak** — anyone who guesses a topic name (`container-updates`,
   `product-available`, `claude`, `gatus`, etc.) can subscribe and read our
   notifications, including anything Claude Code's hook script sends.
2. **Publish abuse** — anyone can publish to any topic and hit our phones,
   including the phones of non-technical household members.
3. **Incoherent router alerting path** — `hosts/router/configuration.nix:152`
   still publishes router alerts to public `ntfy.sh/arsfeld-router`, which
   is both (a) leaking router event data to ntfy.sh's public channel and
   (b) reachable by anyone. Left alone, router alerts stay outside the
   lockdown even after we secure the local server.

## Proposed Solution

**Core decision (see brainstorm):** enable ntfy's built-in authentication
with `auth-default-access = deny-all`, two users total — `publisher`
(write `*`) and `reader` (read `*`). Publishers use basic auth with the
`publisher` credential; phones log in to the server with the `reader`
credential once via the mobile app's per-server login. Both credentials
live in sops.

**Implementation shape (shaped by research):**

- **Declarative users via env vars.** ntfy server v2.14.0+ supports
  `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`, `NTFY_AUTH_DEFAULT_ACCESS` as
  environment variables; the nixpkgs module exposes `environmentFile`
  which plumbs directly into `systemd.serviceConfig.EnvironmentFile`.
  **No preStart script, no `ntfy user add`, no SQLite hand-management.**
  This replaces the brainstorm's fallback "systemd oneshot wrapper" option.
  (See brainstorm "Open Questions" — this is now resolved.)
- **Keep the auth-file at its default location** (`/var/lib/ntfy-sh/user.db`)
  rather than moving it to `${configDir}/ntfy/user.db` as the brainstorm
  suggested. The default path is already covered by both `nas` (local) and
  `hetzner-system` (remote) restic profiles in
  `hosts/storage/backup/backup-restic.nix`, and moving it would require
  systemd unit overrides to work around `DynamicUser=true` +
  `ProtectSystem=full`. No relocation → no extra complexity.
- **Dark-launch rollout**: provision users with `auth-default-access =
  read-write` first (permissive, backwards-compatible), migrate publishers,
  verify each authenticates successfully against server logs, *then* flip
  the default to `deny-all`. Avoids a big-bang cutover that would silently
  break any publisher we overlooked.

## Resolved Open Questions

The three open questions from the initial plan are now answered with
upstream source citations. These are load-bearing — the plan's core
mechanics depend on them.

### R1. Multi-user `NTFY_AUTH_USERS` env-var delimiter: **comma**

Evidence chain (`binwiederhier/ntfy@v2.21.0`):
- `cmd/serve.go` registers `auth-users`/`auth-access`/`auth-tokens` as
  `urfave/cli` `StringSliceFlag` entries bound to `EnvVars: []string{"NTFY_AUTH_USERS"}` etc.
- `go.mod` pins `urfave/cli/v2` at v2.27.7
- `urfave/cli/v2.27.7/flag.go` defines `defaultSliceFlagSeparator = ","`
  and `flagSplitMultiValues` calls `strings.Split(val, sep)`
- `cmd/serve.go` `parseUsers`/`parseAccess` iterate the slice and
  `strings.Split(userLine, ":")` each element — 3 parts expected
- `user/manager.go` `DefaultUserPasswordBcryptCost = 10`; bcrypt alphabet
  is `$`, `/`, `.`, alphanumerics — **no commas** — so bcrypt hashes are
  comma-safe
- systemd `EnvironmentFile=` passes commas through unchanged (only `\`,
  `"`, `'` are special, and only in quoted values)

**Concrete shape that works** (verified against the parser):
```
NTFY_AUTH_DEFAULT_ACCESS=deny-all
NTFY_AUTH_USERS=publisher:$2a$10$aaa...:user,reader:$2a$10$bbb...:user
NTFY_AUTH_ACCESS=publisher:*:wo,reader:*:ro
```
No escaping, no multi-line encoding, no numbered `NTFY_AUTH_USERS_0/1`.

### R2. Gatus secret injection: **generic `custom` alerter, not the native ntfy alerter**

The native gatus ntfy alerter is **disqualified**. From
`TwiN/gatus@master/alerting/provider/ntfy/ntfy.go`:
```go
type Config struct {
  Topic string; URL string; Priority int; Token string; ...
}
const TokenPrefix = "tk_"
func (cfg *Config) Validate() error {
  if len(cfg.Token) > 0 && !strings.HasPrefix(cfg.Token, TokenPrefix) { return ErrInvalidToken }
}
// in Send(): request.Header.Set("Authorization", "Bearer "+token)
```
No `username`/`password`/`headers` fields. The `Token` field is hard-gated
on the `tk_` prefix and always emitted as `Bearer`. **Basic auth cannot be
smuggled through.**

The generic `custom` alerter (`TwiN/gatus@master/alerting/provider/custom/custom.go`)
accepts an arbitrary `Headers map[string]string` with no validation.

Gatus (v5.35.0 in nixpkgs unstable) expands `${VAR}` at config-load via
`os.ExpandEnv` in `TwiN/gatus@master/config/config.go`
(`parseAndValidateConfigBytes`). The nixpkgs module
(`nixos/modules/services/monitoring/gatus.nix` on `nixos-unstable`)
exposes `services.gatus.environmentFile` which wires through to systemd
`EnvironmentFile=`. Literal dollar signs use `$$` escaping.

**Working snippet:**
```nix
services.gatus.environmentFile = config.sops.secrets."ntfy-publisher-env".path;
services.gatus.settings.alerting.custom = {
  url = "https://ntfy.arsfeld.one/gatus";
  method = "POST";
  headers = {
    "Content-Type" = "text/plain";
    "Authorization" = "Basic \${NTFY_BASIC_AUTH_B64}";
    "Title" = "Gatus: [ENDPOINT_NAME]";
    "Priority" = "default";
    "Tags" = "warning";
  };
  body = "[ALERT_DESCRIPTION]";
};
```
The `\${...}` escapes past Nix string interpolation — the generated YAML
contains literal `${NTFY_BASIC_AUTH_B64}` which gatus substitutes at
config load. `[ENDPOINT_NAME]` / `[ALERT_DESCRIPTION]` are gatus's own
bracket placeholders, orthogonal to env expansion.

Requires storing `NTFY_BASIC_AUTH_B64=<base64(publisher:pass)>` in the
`ntfy-publisher-env` sops value alongside the plaintext.

### R3. Bcrypt generation: **Python bcrypt, cost 10**

`ntfy user hash` (`cmd/user.go` `execUserHash` → `readPasswordAndConfirm`
→ `util.ReadPassword`) **reads stdin twice** for password confirmation.
The plan's original `<<<"$PASS"` here-string form provides a single read
and fails the confirmation. No `--stdin` / `--password-file` flag exists.

**Working alternative:**
```bash
python3 -c \
  "import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())" \
  "$NEW_PASS"
```
Cost 10 exactly matches ntfy's `DefaultUserPasswordBcryptCost` in
`user/manager.go`, which the `parseUsers` validator checks. Requires
`python3Packages.bcrypt` in the dev shell (add to `flake-modules/dev.nix`
if missing).

## Updates from Research

Four remaining load-bearing corrections to the brainstorm (the rest,
including "storage does not self-publish", "home-manager has no sops
integration", the Caddy passthrough confirmation, and the stale catalog
entry, have been folded into the relevant sections below rather than
repeated here):

1. **Declarative auth via env vars.** ntfy v2.14.0+ supports
   `NTFY_AUTH_USERS` / `NTFY_AUTH_ACCESS` / `NTFY_AUTH_TOKENS` env vars.
   The nixpkgs module doesn't wrap them, but its generic
   `environmentFile` option feeds them to systemd `EnvironmentFile=`,
   which is the canonical pattern demonstrated by `nixos/tests/ntfy-sh.nix`.
   No preStart script, no `ntfy user add`, no SQLite hand-management.
2. **Auth file stays at default `/var/lib/ntfy-sh/user.db`.** Relocating
   it fights `DynamicUser=true` + `ProtectSystem=full` for zero benefit
   — the default path is already covered by storage's existing restic
   backups. The brainstorm's proposed `${configDir}/ntfy/user.db` is
   walked back.
3. **Router has two independent publishers.** The brainstorm listed the
   alertmanager → `ntfy-webhook-proxy` path;
   `hosts/router/services/client-monitor.py:15-16` is a second,
   independent publisher also currently pointing at public
   `ntfy.sh/arsfeld-router`. Both migrated; they use **different topics**
   (`router-alerts` and `router-clients`) so subscribers can mute one
   without the other.
4. **Declarative provisioning is authoritative** — a revert or stale
   branch deploy that drops a user from `NTFY_AUTH_USERS` deletes the DB
   row on next restart. Mitigation: a `just` pre-deploy guard that
   decrypts `ntfy-server-env` and greps for `reader:` as a safety net.

## Secret Layout

Two sops files. The publisher cred goes in a **new** `ntfy-client.yaml`
(scoped to 6 recipient hosts), not in the overly-broad `common.yaml`.

### New file: `secrets/sops/ntfy-client.yaml`

Add a creation rule to `.sops.yaml` with recipients = cloud, storage,
router, raider, g14, cottage (the 6 hosts that publish). **Explicitly
excluded:** `raspi3`, `r2s`, `octopi` — embedded devices that don't
publish. This narrows blast radius from device theft. Option of
migrating other broadly-encrypted secrets (`restic-password`,
`smtp_password`) to the same treatment is a follow-up, not in scope.

- **`ntfy-publisher-env`** — systemd env-file format:
  ```
  NTFY_PUBLISHER_USER=publisher
  NTFY_PUBLISHER_PASS=<plaintext>
  NTFY_BASIC_AUTH_B64=<base64(publisher:plaintext)>
  ```
  The `_B64` pre-computed value is for gatus's env interpolation (gatus
  can't base64-encode in-config). All three values must be regenerated
  together on rotation.

### `secrets/sops/storage.yaml`

- **`ntfy-server-env`** — single value, consumed only by `services.ntfy-sh`
  on storage:
  ```
  NTFY_AUTH_DEFAULT_ACCESS=read-write    # Phase 1 permissive
  # later, Phase 3: deny-all
  NTFY_AUTH_USERS=publisher:<bcrypt>:user,reader:<bcrypt>:user
  NTFY_AUTH_ACCESS=publisher:*:wo,reader:*:ro
  ```
  Contains bcrypt hashes of both `publisher` and `reader` plus the ACL
  lines. The `publisher` plaintext also lives in `ntfy-client.yaml`; both
  get rotated together. The `reader` plaintext lives only in a password
  manager for phone onboarding — not in sops.

**No separate `ntfy-reader-bcrypt` sops key.** The earlier plan suggested
caching the reader hash separately to avoid re-hashing on publisher
rotation. Dropped — bcrypt at cost 10 takes ~100ms, and the separate key
creates a drift surface (two copies of the same hash that must stay
consistent). Rotation re-hashes both users.

### Rotation

Rotation is wrapped in a `just rotate-ntfy-publisher` recipe in
`just/secrets.just` (the existing file is ragenix-era and stale; this
is a good opportunity to add modern sops recipes alongside the legacy
ones). The recipe handles all escaping correctly by default so there is
no runbook to memorize.

```just
rotate-ntfy-publisher:
    #!/usr/bin/env bash
    set -euo pipefail
    NEW_PASS=$(openssl rand -base64 24 | tr -d '\n=')
    NEW_BCRYPT=$(python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())' "$NEW_PASS")
    AUTH_B64=$(printf '%s:%s' publisher "$NEW_PASS" | base64 -w0)

    # Extract the unchanged reader bcrypt from the live server env.
    SERVER_NOW=$(sops -d --extract '["ntfy-server-env"]' secrets/sops/storage.yaml)
    READER_BCRYPT=$(echo "$SERVER_NOW" | grep NTFY_AUTH_USERS | sed -E 's/.*reader:([^:,]+):user.*/\1/')
    CURRENT_DEFAULT=$(echo "$SERVER_NOW" | grep NTFY_AUTH_DEFAULT_ACCESS | cut -d= -f2)

    PUB_ENV=$(printf 'NTFY_PUBLISHER_USER=publisher\nNTFY_PUBLISHER_PASS=%s\nNTFY_BASIC_AUTH_B64=%s\n' "$NEW_PASS" "$AUTH_B64")
    SERVER_ENV=$(printf 'NTFY_AUTH_DEFAULT_ACCESS=%s\nNTFY_AUTH_USERS=publisher:%s:user,reader:%s:user\nNTFY_AUTH_ACCESS=publisher:*:wo,reader:*:ro\n' "$CURRENT_DEFAULT" "$NEW_BCRYPT" "$READER_BCRYPT")

    # jq -Rs . is unconditional — always produces valid JSON-escaped string.
    sops set secrets/sops/ntfy-client.yaml '["ntfy-publisher-env"]' "$(echo -n "$PUB_ENV" | jq -Rs .)"
    sops set secrets/sops/storage.yaml '["ntfy-server-env"]' "$(echo -n "$SERVER_ENV" | jq -Rs .)"

    # Guard: fail if the reader line accidentally disappeared
    sops -d --extract '["ntfy-server-env"]' secrets/sops/storage.yaml | grep -q 'reader:' \
      || { echo "FATAL: reader user missing from ntfy-server-env"; exit 1; }

    just deploy storage cloud router raider g14 cottage
    echo "New publisher password (save to password manager): $NEW_PASS"
```

Reader rotation is a sibling `just rotate-ntfy-reader` recipe — same
shape but generates a new reader plaintext + bcrypt and prints it for
manual password-manager update + phone re-login.

**Cadence:** rotate quarterly (every ~90 days) or on any known
compromise signal. Record last rotation date in
`docs/services/catalog.md`'s Ntfy row.

**Why not rotate storage alone and let publishers keep their cached
values?** Because the publisher bcrypt is part of the server env file,
and all publishers need the new plaintext. They must deploy together.
`just deploy` parallelism is safe for rotation (user list is unchanged,
only hash values differ).

## Implementation Phases

### Deploy ordering constraint (CRITICAL)

Phase 1 must deploy **storage alone**, not in parallel with publishers.
Reason: publishers deployed before storage will try to auth against a
server that doesn't yet know about `publisher` + `reader`. In Phase 1
this is recoverable (permissive default still accepts anon), but it
muddies debugging. Deploy in this sequence:

1. **Phase 1**: `just test storage && just deploy storage` — alone.
   Verify via post-deploy checks below.
2. **Phase 2**: `just deploy cloud router raider g14 cottage` (parallel
   is fine) plus the storage-side publisher changes in
   `containers.nix` / `check-stock.nix` as a second storage deploy.
3. **Phase 3**: `just deploy storage` — flips deny-all. Alone.

Rotation after the feature is live is safe to run across all hosts in
parallel (the shape of `ntfy-server-env` and `ntfy-publisher-env`
doesn't change, only the hash values).

### Phase 1: Provision users with permissive default (non-breaking)

**Goal:** ntfy knows about `publisher` and `reader`; anonymous access still
works; publishers can start authenticating as soon as they're migrated.

**Pre-deploy checks:**

```bash
# 1. Confirm ntfy has NO EnvironmentFile yet
ssh storage.bat-boa.ts.net systemctl cat ntfy-sh | grep -c EnvironmentFile
# Expected: 0

# 2. CRITICAL: confirm user.db doesn't contain pre-existing hand-added
#    users. Declarative provisioning is authoritative — any user not in
#    NTFY_AUTH_USERS gets deleted on next restart.
ssh storage.bat-boa.ts.net 'sudo sqlite3 /var/lib/ntfy-sh/user.db \
  "SELECT user, role FROM user;" 2>/dev/null || echo "no db yet"'
# Expected: "no db yet" OR only the "*" anonymous row. STOP if other rows exist.

# 3. Confirm recent restic backup of /var/lib/ntfy-sh
ssh storage.bat-boa.ts.net 'systemctl list-timers | grep restic'

# 4. Confirm secret values never leak to /nix/store
just test storage
STORE=$(nix build .#nixosConfigurations.storage.config.system.build.toplevel --no-link --print-out-paths)
grep -rI "NTFY_PUBLISHER_PASS=" "$STORE/" 2>/dev/null
# Expected: zero matches
```

**Changes:**

- `hosts/storage/services/ntfy.nix`
  - Add `services.ntfy-sh.environmentFile = config.sops.secrets."ntfy-server-env".path;`
  - Add `sops.secrets."ntfy-server-env" = {};` (inherits `sopsFile =
    storage.yaml` automatically since storage is the host)
  - Add nothing to `settings` — the auth config lives entirely in the env
    file so it stays out of `/nix/store`
  - Leave `upstream-base-url = https://ntfy.sh` as-is (iOS push)
  - Leave `bypassAuth = true` on the media gateway (Authelia still cannot
    front ntfy)
- `.sops.yaml` — add a new `creation_rule` for
  `secrets/sops/ntfy-client.yaml` with recipients: cloud, storage,
  router, raider, g14, cottage (exclude raspi3/r2s/octopi).
- `secrets/sops/ntfy-client.yaml` — create via `sops set` with
  `ntfy-publisher-env` containing `NTFY_PUBLISHER_USER`,
  `NTFY_PUBLISHER_PASS`, `NTFY_BASIC_AUTH_B64`.
- `secrets/sops/storage.yaml` — add `ntfy-server-env` via `sops set`
  with `NTFY_AUTH_DEFAULT_ACCESS=read-write` (permissive for Phase 1).

All writes go through `sops set` (never interactive), values generated
programmatically via `openssl rand` + `python3 -c "import bcrypt;..."`.
No interactive TUI editing.

**Post-deploy validation:**

```bash
# 1. EnvironmentFile is wired
ssh storage.bat-boa.ts.net systemctl cat ntfy-sh | grep EnvironmentFile
# Expected: /run/secrets/ntfy-server-env

# 2. ntfy process ACTUALLY loaded the env vars (catches silent fallback
#    AND DynamicUser permission issues)
ssh storage.bat-boa.ts.net 'sudo cat /proc/$(pgrep -f "ntfy serve")/environ \
  | tr "\0" "\n" | grep NTFY_AUTH'
# Expected: 3 lines — DEFAULT_ACCESS, USERS, ACCESS. If missing, the env
# file wasn't read (likely a permissions issue with DynamicUser).

# 3. user.db contains the provisioned users
ssh storage.bat-boa.ts.net 'sudo sqlite3 /var/lib/ntfy-sh/user.db \
  "SELECT user, role FROM user;"'
# Expected: rows for "publisher" and "reader" plus "*" anon.

# 4. Functional: auth works end-to-end (use HEADER FORM, not -u, to avoid
#    /proc/<pid>/cmdline password exposure)
PUB_PASS=$(nix develop -c sops -d --extract '["ntfy-publisher-env"]' \
  secrets/sops/ntfy-client.yaml | awk -F= '/^NTFY_PUBLISHER_PASS=/ {print $2}')
PUB_B64=$(printf '%s:%s' publisher "$PUB_PASS" | base64 -w0)

curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Basic $PUB_B64" \
  -d "phase1-smoke" https://ntfy.arsfeld.one/_phase1_smoke
# Expected: 200

# 5. Sanity: wrong credential is actually rejected
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Basic $(printf 'publisher:wrong' | base64 -w0)" \
  -d x https://ntfy.arsfeld.one/_phase1_smoke
# Expected: 401

# 6. CRITICAL: anonymous should STILL work (Phase 1 goal)
curl -sS -o /dev/null -w '%{http_code}\n' -d anon https://ntfy.arsfeld.one/_phase1_smoke
# Expected: 200. If 403, default_access was set to deny-all prematurely —
# immediate rollback.

# 7. No secret plaintext in journal
ssh storage.bat-boa.ts.net 'journalctl -u ntfy-sh --since "10 min ago" \
  | grep -c "$PUB_PASS" || echo 0'
# Expected: 0
```

### Phase 2: Migrate publishers

Each migration is an independent commit. All publishers read the
plaintext from `/run/secrets/ntfy-publisher-env` via `EnvironmentFile=`
(system services) or by reading the file at runtime (user script).

**CRITICAL: never use `curl -u user:pass`.** The password lands in
`/proc/<pid>/cmdline` which is world-readable on Linux. Any local
process (including non-root processes on the same host) can sample it
during the curl's lifetime. Use the explicit header form instead:

```bash
curl -sS \
  -H "Authorization: Basic $(printf '%s:%s' "$NTFY_PUBLISHER_USER" "$NTFY_PUBLISHER_PASS" | base64 -w0)" \
  ...
```

This applies uniformly to image-watch (bash) and claude-notify (bash).
Python publishers use the stdlib equivalent (`base64.b64encode` → manual
`Authorization` header for urllib, or `auth=(user, pass)` kwarg for
`requests`, both of which build the header in-process).

**Secret declaration: once per host, not once per service file.**
Declare `sops.secrets."ntfy-publisher-env"` in a single central location
on each host (typically `hosts/<host>/configuration.nix` or a clearly
shared services file), then reference `config.sops.secrets."ntfy-publisher-env".path`
from each unit that needs it. Avoids the DRY violation of declaring the
same secret twice per host.

#### 2a. `modules/media/containers.nix` — container image watcher

Three curl invocations at `containers.nix:253-258`, `:275-280`, `:282-287`,
all hitting `https://ntfy.arsfeld.one/container-updates`.

DRY: since three curl calls share the same auth header, extract a bash
helper at the top of the script body and call it:

```bash
_ntfy_auth_header() {
  printf '%s:%s' "${NTFY_PUBLISHER_USER:-}" "${NTFY_PUBLISHER_PASS:-}" | base64 -w0
}

# replaces each of the 3 curl calls:
curl -s \
  -H "Authorization: Basic $(_ntfy_auth_header)" \
  -d "..." ... https://ntfy.arsfeld.one/container-updates || true
```

Add `serviceConfig.EnvironmentFile = config.sops.secrets."ntfy-publisher-env".path;`
to the generated `image-watch-${name}` unit. Declare
`sops.secrets."ntfy-publisher-env" = { sopsFile =
"${inputs.self}/secrets/sops/ntfy-client.yaml"; };` once in storage's
config. **Preserve** the `|| true` invariant from
`docs/plans/2026-03-24-feat-container-image-watcher-plan.md:64` — auth
failures are non-fatal.

#### 2b. `packages/check-stock/check-stock.py`

Python rewrite using `requests`' native `auth=` kwarg (no manual header
construction). Uses `os.environ.get` with truthiness check, not subscript
(avoid `KeyError`). Adds a pre-existing missing-`timeout=` fix while
touching the line:

```python
def send_notification_ntfy(url, title, server="ntfy.sh"):
    servers = {
        "ntfy.sh": "https://ntfy.arsfeld.one/product-available",
        "personal": "https://ntfy.arsfeld.one/product-available",
    }

    ntfy_user = os.environ.get("NTFY_PUBLISHER_USER")
    ntfy_pass = os.environ.get("NTFY_PUBLISHER_PASS")
    auth = (ntfy_user, ntfy_pass) if ntfy_user and ntfy_pass else None
    if auth is None:
        logger.warning(
            "NTFY_PUBLISHER_USER/NTFY_PUBLISHER_PASS not set; "
            "publishing unauthenticated"
        )

    try:
        targets = list(servers.values()) if server == "both" else [servers[server]]
        for target in targets:
            response = requests.post(
                target,
                data=f"{title} is available!".encode("utf-8"),
                headers={
                    "Click": url,
                    "Priority": "high",
                    "Email": "alex@rosenfeld.one",
                },
                auth=auth,
                timeout=10,  # NEW: fix pre-existing missing-timeout bug
            )
            server_name = target.split("//")[1].split("/")[0]
            logger.info(f"{server_name} response status: {response.status_code}")
            if response.status_code != 200:
                logger.error(f"{server_name} error response: {response.text}")
    except requests.exceptions.RequestException as e:
        logger.error(f"Failed to send ntfy notification: {e}", exc_info=True)
```

Also scrub `NTFY_PUBLISHER_*` from the `subprocess.Popen(["msmtp", ...])`
env at `check-stock.py:81` — defense in depth so a future msmtp change
can't log the parent env:

```python
clean_env = {k: v for k, v in os.environ.items() if not k.startswith("NTFY_PUBLISHER_")}
process = subprocess.Popen([...], env=clean_env, ...)
```

Nix side — wire the env file via `modules/check-stock.nix:70` `mkStockService`
using `lib.mkMerge` so the existing `ExecStart` isn't clobbered:

```nix
# In mkStockService:
serviceConfig = lib.mkMerge [
  { ExecStart = ["${pkgs.check-stock}/bin/check-stock ${url}"]; }
  { EnvironmentFile = config.sops.secrets."ntfy-publisher-env".path; }
];
```

Declare the sops secret once at `hosts/storage/configuration.nix:177-185`
(where check-stock is enabled). The `ntfy.sh`/`personal` dict collapse is
deferred — it's a stylistic cleanup for a follow-up commit.

#### 2c. `hosts/cloud/services/gatus.nix` — generic `custom` alerter

Gatus's **native** ntfy alerter is disqualified (see Resolved Open
Question R2 above — `Token` field gated on `tk_` prefix, no basic-auth
path, no `headers` field). Swap to the generic `custom` alerter with
env-interpolated basic auth header.

```nix
sops.secrets."ntfy-publisher-env" = {
  sopsFile = "${inputs.self}/secrets/sops/ntfy-client.yaml";
};
services.gatus.environmentFile = config.sops.secrets."ntfy-publisher-env".path;
services.gatus.settings.alerting.custom = {
  url = "https://ntfy.arsfeld.one/gatus";
  method = "POST";
  headers = {
    "Content-Type" = "text/plain";
    "Authorization" = "Basic \${NTFY_BASIC_AUTH_B64}";
    "Title" = "Gatus: [ENDPOINT_NAME]";
    "Priority" = "default";
    "Tags" = "warning";
  };
  body = "[ALERT_DESCRIPTION]";
};
# REMOVE: the old services.gatus.settings.alerting.ntfy block
```

Notes:

- `\${NTFY_BASIC_AUTH_B64}` escapes past Nix string interpolation, so the
  generated YAML contains the literal `${NTFY_BASIC_AUTH_B64}`, which
  gatus expands at config-load via its `os.ExpandEnv` pass.
- `[ENDPOINT_NAME]` and `[ALERT_DESCRIPTION]` are gatus's own bracket
  placeholders, orthogonal to env expansion — both pass through cleanly.
- `NTFY_BASIC_AUTH_B64` is pre-computed in the sops secret (gatus has no
  base64 helper). Rotation recipe regenerates it alongside the plaintext.
- Per-endpoint `alerts: [{type: custom, failure-threshold: ..., ...}]`
  entries don't change — they dispatch to the new `alerting.custom`
  block by name.

#### 2d. Router — two independent publishers

Router has no `router.yaml` sops file; the publisher credential comes
from the new `ntfy-client.yaml` (router is a recipient). The two
publishers use **different topics** so subscribers can mute one without
affecting the other.

**Publisher 1: Alertmanager → `ntfy-webhook-proxy`** (topic: `router-alerts`)

- `hosts/router/configuration.nix:152-153`: change
  `ntfyUrl = "https://ntfy.sh/arsfeld-router"` →
  `"https://ntfy.arsfeld.one/router-alerts"`.
- `hosts/router/ntfy-webhook.nix:10-142` (the `pkgs.writeScript` body):
  keep `NTFY_URL = "${config.router.alerting.ntfyUrl}"` Nix-templated
  (it's not a secret, and moving it to env is premature abstraction).
  Add `import os` and `import base64` to the import block. Compute the
  auth header **once at module scope**, not per-request:

  ```python
  def _build_auth_header():
      user = os.environ.get("NTFY_PUBLISHER_USER")
      password = os.environ.get("NTFY_PUBLISHER_PASS")
      if not user or not password:
          return None
      token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
      return f"Basic {token}"

  AUTH_HEADER = _build_auth_header()
  if AUTH_HEADER is None:
      print(
          "warning: NTFY_PUBLISHER_{USER,PASS} not set; publishing unauthenticated",
          file=sys.stderr, flush=True,
      )
  ```

  At the headers-dict construction site (~line 78-83), conditionally
  add `headers["Authorization"] = AUTH_HEADER` when non-None. Also add
  `timeout=10` to the `urllib.request.urlopen` call at ~line 116 (fix
  pre-existing missing-timeout bug).
- **Nix `$`-escaping hazard:** every bare `$` inside the script body is
  a Nix antiquotation trigger because the script is in `pkgs.writeScript`'s
  indented string. Keep credential references inside Python f-string
  braces (`f"{user}:{password}"`) — never `$user`.
- **Do NOT `sys.exit(1)` on missing creds.** The unit has
  `Restart=always` and would loop-spin. Log and continue unauthenticated;
  auth failures will surface as 401 errors in the journal after Phase 3.
- `hosts/router/ntfy-webhook.nix:144-182` (hardened systemd unit, runs as
  `ntfy-webhook` user): add `serviceConfig.EnvironmentFile =
  config.sops.secrets."ntfy-publisher-env".path;` and
  `sops.secrets."ntfy-publisher-env" = { sopsFile =
  "${inputs.self}/secrets/sops/ntfy-client.yaml"; owner = "ntfy-webhook";
  mode = "0400"; };`. No ownership collision with claude-notify because
  claude-notify is **excluded from router** (see Phase 2e).
- `hosts/router/services/monitoring.nix:363-374` — second alertmanager
  block that reads `alertingConfig.ntfyUrl`. No changes here; it routes
  through the same proxy.

**Publisher 2: `client-monitor.py`** (topic: `router-clients`)

Rewrite using stdlib-only manual basic auth, matching the existing
urllib style of the script. Also folds in two pre-existing bug fixes
that are adjacent to the changed lines.

Top of file:

```python
import os
import base64
import urllib.error  # NEW: explicit import; implicit via urllib.request but cleaner
# ... existing imports

NTFY_TOPIC  = os.environ.get("NTFY_TOPIC", "router-clients")
NTFY_SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.arsfeld.one")
NTFY_URL    = f"{NTFY_SERVER}/{NTFY_TOPIC}"
NTFY_USER   = os.environ.get("NTFY_PUBLISHER_USER")
NTFY_PASS   = os.environ.get("NTFY_PUBLISHER_PASS")

if not NTFY_USER or not NTFY_PASS:
    print(
        f"warning: NTFY_PUBLISHER_{{USER,PASS}} not set; publishing to {NTFY_URL} unauthenticated",
        flush=True,
    )
```

Replace `send_notification` at lines 162-180:

```python
def send_notification(self, title, message, priority="default", tags=""):
    try:
        data = message.encode("utf-8")
        headers = {"Title": title, "Priority": priority}
        if tags:
            headers["Tags"] = tags
        if NTFY_USER and NTFY_PASS:
            token = base64.b64encode(f"{NTFY_USER}:{NTFY_PASS}".encode("utf-8")).decode("ascii")
            headers["Authorization"] = f"Basic {token}"

        req = urllib.request.Request(NTFY_URL, data=data, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as response:
            if response.status == 200:
                print(f"Notification sent: {title}")
                return True
            print(f"Notification returned unexpected status {response.status}: {title}")
    except urllib.error.HTTPError as e:
        # NEW: explicit HTTPError handling — urllib raises on 4xx/5xx, so the
        # old `if response.status == 200` check was unreachable for auth errors.
        print(f"Failed to send notification ({e.code} {e.reason}): {title}")
    except Exception as e:
        print(f"Failed to send notification: {e}")
    return False
```

**Fix pre-existing cooldown bug** at `client-monitor.py:~240` — update
`last_notification[mac]` even on send failure, otherwise persistent
401s (after Phase 3 if we mis-wire something) loop-spam on every tick:

```python
if self.send_notification(title, message, priority="default", tags="computer,new"):
    self.last_notification[mac] = current_time
    print(f"New client notification sent: {mac} ({hostname})")
else:
    self.last_notification[mac] = current_time  # apply cooldown even on failure
    print(f"New client notification failed for {mac} ({hostname}); cooldown applied")
```

Wire `serviceConfig.EnvironmentFile =
config.sops.secrets."ntfy-publisher-env".path;` in
`hosts/router/services/client-monitor.nix`. Since `ntfy-webhook` already
owns the secret on router, either (a) reuse the same declaration and
make it readable by both users (owner = `ntfy-webhook`, group includes
client-monitor's user, mode `0440`), or (b) declare a second
`sops.secrets."ntfy-publisher-env-client-monitor"` entry backed by the
same cleartext. Lean toward (a); confirm at implementation time which
user client-monitor's unit runs as.

#### 2e. `home/scripts/claude-notify` — workstations

Runs as user `arosenfeld` via Claude Code hooks. Script at
`home/scripts/claude-notify:157-162` currently sends unauthenticated:

```bash
curl -s -H "Title: $TITLE" -H "Priority: $PRIORITY" -H "Tags: $TAGS" \
  -d "$MESSAGE" "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null 2>&1 || true
```

Change the script to source a credential file (if readable) and attach
a basic auth header via the **explicit header form** — not `-u`:

```bash
# Near the top, after NTFY_SERVER / NTFY_TOPIC are set:
NTFY_CREDENTIALS_FILE="${NTFY_CREDENTIALS_FILE:-/run/secrets/ntfy-publisher-env}"
if [[ -r "$NTFY_CREDENTIALS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$NTFY_CREDENTIALS_FILE"
fi

AUTH_HEADER=""
if [[ -n "${NTFY_PUBLISHER_USER:-}" && -n "${NTFY_PUBLISHER_PASS:-}" ]]; then
  AUTH_HEADER="Authorization: Basic $(printf '%s:%s' \
    "$NTFY_PUBLISHER_USER" "$NTFY_PUBLISHER_PASS" | base64 -w0)"
fi

# At the publish call:
curl -s \
  ${AUTH_HEADER:+-H "$AUTH_HEADER"} \
  -H "Title: $TITLE" -H "Priority: $PRIORITY" -H "Tags: $TAGS" \
  -d "$MESSAGE" "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null 2>&1 || true
```

Keep the `|| true` so auth failures never block Claude Code.

**Secret delivery — new pattern in this repo, wired inline per host:**

No new constellation module. Each host that runs home-manager for
`arosenfeld` declares the sops secret inline in its `configuration.nix`
(or an equivalent existing location):

```nix
sops.secrets."ntfy-publisher-env" = {
  sopsFile = "${inputs.self}/secrets/sops/ntfy-client.yaml";
  owner = "arosenfeld";
  mode = "0400";
};
```

Hosts that need this: **`cloud`, `cottage`, `g14`, `raider`, `storage`**.

**Router is excluded from claude-notify.** It's a headless appliance
with no interactive Claude Code sessions; adding the `arosenfeld`-owned
copy would either introduce an ownership collision with `ntfy-webhook`
or force mode `0444` (world-readable — unsafe on a host running several
other system daemons). If claude-notify on router is ever actually
needed, revisit then.

Storage, cloud, router, raider, g14, cottage already have
`constellation.sops.enable = true` and decrypt from `common.yaml` — the
new `ntfy-client.yaml` file uses the same sops-nix plumbing, no new
module imports required. Workstations that aren't in the recipient list
(raspi3, r2s, octopi) don't need this block; they don't run
claude-notify and their home-manager isn't enabled
(`flake-modules/lib.nix:72` `lightHosts`).

### Phase 3: Flip to deny-all

Same-session as Phase 1 + Phase 2 (do not leave the feature
half-rolled-out across multiple days — every hour the permissive default
is live is an hour of zero added protection while the new credential
already exists in sops).

**Go/No-Go gate** — all must be green:

- [ ] Every publisher from Phase 2 has published successfully with auth,
      verified via `journalctl -u ntfy-sh` on storage in the last 24h
- [ ] Both phones are logged into `ntfy.arsfeld.one` with `reader`
      credential
- [ ] Canary phone has received a push notification while **locked and
      offline from Tailscale** (tests the upstream → APNs → server-fetch
      path — see test below)
- [ ] `nix flake check` passes
- [ ] The new `ntfy-server-env` value, decrypted, literally contains
      `deny-all` (not `deny_all` or other typo — `sops -d --extract
      '["ntfy-server-env"]' secrets/sops/storage.yaml | grep DEFAULT_ACCESS`)
- [ ] `/proc/$(pgrep ntfy)/environ` on storage shows all three
      `NTFY_AUTH_*` vars (catches silent fallback + DynamicUser
      permission issues)
- [ ] Recent restic backup of `/var/lib/ntfy-sh/user.db` within 24h
- [ ] Rollback script pre-loaded in a second terminal
- [ ] ≥30 minutes uninterrupted time; both phones charged and present;
      spouse aware their phone may need re-login

**Locked-phone push test** (canary — CRITICAL pre-gate):

```bash
# 1. Lock the canary phone, put it face-down, wait 60s (Tailscale off)
# 2. Publish (use header form, never -u):
PUB_B64=$(printf '%s:%s' publisher "$PUB_PASS" | base64 -w0)
curl -sS \
  -H "Authorization: Basic $PUB_B64" \
  -d "canary locked-phone test $(date +%s)" \
  https://ntfy.arsfeld.one/canary
# 3. Verify phone wakes with push notification within ~10s
# 4. If not, iOS upstream path is broken — debug before Phase 3 flip
```

**Deploy:** regenerate `ntfy-server-env` with `deny-all` via the
rotation recipe logic (`just deploy storage` afterward). ntfy-sh
restarts, reloads env, re-provisions unchanged users, and starts
rejecting anonymous with 403.

**Post-flip validation** (run within 60 seconds of the deploy):

```bash
# 1. Confirm env actually updated (not stale from Phase 1)
ssh storage.bat-boa.ts.net 'sudo cat /proc/$(pgrep -f "ntfy serve")/environ \
  | tr "\0" "\n" | grep NTFY_AUTH_DEFAULT_ACCESS'
# Expected: NTFY_AUTH_DEFAULT_ACCESS=deny-all

# 2. Anonymous now blocked
curl -sS -o /dev/null -w '%{http_code}\n' -d x https://ntfy.arsfeld.one/_phase3_anon
# Expected: 403
curl -sS -o /dev/null -w '%{http_code}\n' \
  "https://ntfy.arsfeld.one/_phase3_anon/json?poll=1"
# Expected: 403

# 3. Authenticated publish still works
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Basic $PUB_B64" \
  -d x https://ntfy.arsfeld.one/_phase3_auth
# Expected: 200

# 4. Authenticated subscribe still works
READ_B64=$(printf '%s:%s' reader "$READ_PASS" | base64 -w0)
curl -sS -H "Authorization: Basic $READ_B64" \
  "https://ntfy.arsfeld.one/_phase3_auth/json?poll=1&since=1m"
# Expected: JSON containing "_phase3_auth"

# 5. Authorization header passthrough — confirm 401 comes from ntfy,
#    not Caddy intercepting
curl -sSv \
  -H "Authorization: Basic $(printf 'publisher:wrong' | base64 -w0)" \
  -d x https://ntfy.arsfeld.one/_phase3 2>&1 | grep -i 'www-authenticate'
# Expected: ntfy-sourced 401 (the server claims it). If no WWW-Authenticate,
# an intermediate proxy may be intercepting — investigate before trusting
# the lockdown.

# 6. Unauthenticated endpoints audit
curl -sS https://ntfy.arsfeld.one/v1/health
# Expected: {"healthy":true} — intentionally unauth, fine
curl -sS https://ntfy.arsfeld.one/config.js | grep -iE 'base_url|upstream|enable_login'
# Document what leaks; confirm nothing sensitive. Accepted (ntfy design).

# 7. 60-second failure watch on ntfy journal
ssh storage.bat-boa.ts.net 'journalctl -u ntfy-sh -f --since "1 min ago"' \
  | grep -E '40[13]|panic|error'
# ANY match → immediate rollback.

# 8. Locked-phone push test, one more time post-flip
#    (same as the pre-gate test above; confirms upstream path still works
#     under the new auth config)
```

**Post-flip cleanup (same commit):**

- Update `docs/services/catalog.md`: change Ntfy row host from `cloud`
  to `storage`, change Auth from `✗` to `✓`. **Also fix the stale
  `Yarr` row on the same section** — says `cloud` but `yarr.nix` lives
  at `hosts/storage/services/yarr.nix`, same pre-existing drift.

### Phone onboarding (concurrent with Phase 2, before Phase 3 gate)

Phone onboarding must happen **before** the Phase 3 Go/No-Go gate —
the gate explicitly requires both phones logged in with `reader`
credentials. Onboarding is wall-clock parallel with Phase 2 publisher
migrations (they don't block each other).

- Store the `reader` plaintext in a password manager (shared vault
  entry). Hand off to spouse via password-manager share — never
  via chat history or email.
- On each phone: install the ntfy app (Android/iOS) → add server
  `https://ntfy.arsfeld.one` → log in with `reader` + password →
  subscribe to desired topics (container-updates, product-available,
  router-alerts, router-clients, gatus, claude, etc.).
- The Android app's per-server user setting is at Settings → Users. iOS
  exposes an equivalent screen — verify UI details during onboarding.
  Credentials are stored per-server, so every subscription on
  `ntfy.arsfeld.one` automatically sends the `Authorization` header.

## System-Wide Impact

### Interaction Graph

```
publish event → curl/urllib with -u publisher:PASS
  → Cloudflare tunnel → cloudflared on storage
  → Caddy (ntfy.arsfeld.one vhost, bypassAuth=true, reverse_proxy :2586)
  → ntfy-sh (behind-proxy=true, declarative auth from EnvironmentFile)
    → auth check against in-memory users provisioned from NTFY_AUTH_USERS
    → ACL check against NTFY_AUTH_ACCESS
    → write to /var/lib/ntfy-sh/cache-file.db
    → fan out to connected subscribers
    → POST poke to https://ntfy.sh/<sha256(topic)> with body "New message"
    → APNs → iOS app wakes up
    → iOS app fetches real message from https://ntfy.arsfeld.one/topic
      using stored reader credentials
```

Anonymous subscribers in Phase 3 get 403 at the ntfy layer. Caddy does not
intercept. Cloudflare logs will show 403 responses — normal.

### iOS push leakage envelope

With `upstream-base-url = https://ntfy.sh` preserved, the following
metadata leaves the authenticated server on every publish to a
iOS-subscribed topic:

- SHA-256 hash of the topic name (the Firebase topic ID the client is
  subscribed to)
- Literal message body `"New message"` (the real message body stays on
  our server — the iOS client fetches it via authenticated GET after
  waking)
- Storage's egress IP (Cloudflare-fronted via the existing tunnel, so
  ntfy.sh sees Cloudflare IPs, not storage's real address)
- Timing metadata (when pokes are sent)

An adversary at ntfy.sh with a dictionary of likely topic names
(`gatus`, `router-alerts`, `container-updates`, etc.) can precompute
SHA-256 matches and correlate activity patterns. Accepted — the
alternative is losing iOS push entirely. If a topic name ever contains
truly sensitive material (it shouldn't — topic names are effectively
routing keys, not payload), rename it.

`upstream-access-token` is intentionally left unset. Per ntfy
maintainers (issue #1644 comments), that token is for ntfy.sh rate-limit
bypass under paid accounts, not for authenticating our self-hosted
server — setting it with our server's credentials would cause 401s
from ntfy.sh.

### Error Propagation

- **Publisher auth failure (wrong password after rotation)** →
  curl/urllib returns non-zero → `|| true` (or equivalent try/except)
  swallows → alert is lost silently. **Mitigation:** make every publisher
  script log the curl exit code to journal so a deploy-time regression
  shows up in `journalctl -u <publisher>`. Already the case for
  `containers.nix` since systemd logs stdout. Add explicit `echo` on
  non-zero to `claude-notify`.
- **ntfy restart during rotation** → 5-10 seconds of 503s, publishers that
  fire in that window lose their message. Acceptable for this personal
  notifier. Not acceptable for e.g. check-stock's hourly poll if it
  happens to coincide — extremely unlikely.
- **Env-file parsing failure** (bad sops template, trailing newline, etc.)
  → ntfy-sh fails to start. `systemctl status ntfy-sh` shows the error.
  Caught during `just test storage` before boot activation.
- **Mobile app 401 after password rotation** → user re-enters new
  password in app (documented in rotation runbook). Messages during the
  401 gap are buffered on the server (default cache: 12h per topic) so
  nothing is lost.

### State Lifecycle Risks

- **Declarative provisioning is authoritative.** If `NTFY_AUTH_USERS` is
  removed from the env file, ntfy deletes the corresponding DB rows on
  next restart. This is the intended behavior. A misedit to the env file
  (e.g. dropping the `reader` line) would lock out phones on next
  restart. **Mitigation:** rotation runbook documents the full env file
  shape; `nix flake check` and `just test storage` both catch syntactic
  problems; ntfy startup logs would show the actual user/ACL set.
- **/var/lib/ntfy-sh/user.db is persistent** and contains the provisioned
  users + any future manual tokens. Backed up by both `nas` and
  `hetzner-system` restic profiles. Losing storage's disk is recoverable
  from either backup; the sops files themselves are the ground truth for
  regenerating the DB from scratch if ever needed.
- **No orphan state.** Adding/removing users via the env file is
  idempotent. There is no "half-provisioned" state to clean up.

### API Surface Parity

Every publisher is a separate surface; the table of migrations in Phase 2
is the parity checklist. The `publisher` credential must work identically
from:

| Publisher | Host | Auth method |
|---|---|---|
| image-watch-* | storage | env file → curl `-u` |
| check-stock-* | storage | env file → python requests |
| gatus | cloud | TBD (see open questions) |
| ntfy-webhook-proxy | router | env file → python urllib |
| client-monitor | router | env file → python urllib |
| claude-notify | cloud,cottage,g14,raider,router,storage (user=arosenfeld) | /run/secrets read → curl `-u` |

### Integration Test Scenarios

Unit tests and `nix flake check` don't cover end-to-end auth. After
Phase 3:

1. **Cold anonymous publish** — `curl -d x https://ntfy.arsfeld.one/test`
   from any machine. Expect 403.
2. **Publisher publish with bad creds** — `curl -u publisher:wrong -d x
   https://ntfy.arsfeld.one/test`. Expect 401.
3. **Publisher publish with good creds** — expect 200, message appears in
   subscribed phone within seconds.
4. **Reader subscribe with bad creds** — expect 401.
5. **Reader subscribe + publish from another machine** — full round-trip.
6. **iOS / Android background push** — publish a message when the phone
   is locked and offline from Tailscale. Message arrives via ntfy.sh →
   APNs poke → foreground fetch → app displays. Confirms upstream push
   still works with auth enabled.
7. **Rotation** — rotate publisher password, redeploy, verify every
   publisher recovers without intervention.
8. **Router migration** — trigger a test router alert (`systemctl start
   node_exporter-test-alert` or equivalent) and verify it reaches the
   authenticated ntfy topic, not `ntfy.sh/arsfeld-router`.

## Acceptance Criteria

### Functional

- [ ] `curl -d x https://ntfy.arsfeld.one/any-topic` returns 403 (anonymous
      publish blocked)
- [ ] `curl https://ntfy.arsfeld.one/any-topic/json?poll=1` returns 403
      (anonymous subscribe blocked)
- [ ] `curl -u publisher:$PASS -d x https://ntfy.arsfeld.one/any-topic`
      returns 200 from storage, cloud, router, and a workstation
- [ ] Container image watcher publishes to `container-updates` with auth
      (verify in `journalctl -u image-watch-*`)
- [ ] Gatus alerts arrive with auth (verify by triggering a deliberate
      gatus failure)
- [ ] check-stock publishes to `product-available` with auth
- [ ] Router alertmanager path publishes to
      `ntfy.arsfeld.one/router-alerts` (new topic) with auth
- [ ] `client-monitor.py` on router publishes with auth
- [ ] `claude-notify` publishes with auth from at least one workstation
      (raider or g14)
- [ ] Both phones (Alex's and spouse's) receive a test message on each of
      the subscribed topics
- [ ] iOS push (if any iOS subscriber exists) still wakes the app via
      `upstream-base-url = https://ntfy.sh`

### Non-Functional

- [ ] No secret material in `/nix/store` — verify with `grep -r publisher
      /nix/store/*-ntfy-* 2>/dev/null` returning nothing for the password
      value (the username is fine)
- [ ] `just test storage`, `just test cloud`, `just test router`, `just
      test g14`, `just test raider` all succeed before the corresponding
      `just deploy`
- [ ] `nix flake check` passes
- [ ] `alejandra` + git pre-commit hooks pass on all touched files
- [ ] Publisher scripts retain `|| true` (or try/except equivalent) so
      auth failures never crash their host service

### Quality Gates

- [ ] `docs/services/catalog.md:87` updated: host `storage`, auth ✓
- [ ] Rotation runbook committed in the feature commit (in the commit
      message body, not as a separate doc unless it grows beyond ~20 lines)
- [ ] Every modified systemd service has journalctl evidence of successful
      publish post-deploy
- [ ] `upstream-base-url = https://ntfy.sh` preserved in
      `hosts/storage/services/ntfy.nix`

## Open Questions

Most questions from the initial plan are now [Resolved Open Questions](#resolved-open-questions)
above. Three real uncertainties remain for implementation time:

1. **Ntfy process ownership of `/run/secrets/ntfy-server-env` under
   `DynamicUser=true`.** The sops secret is owned by root with mode
   `0400` by default, but ntfy runs as a transient uid allocated at
   service start. Systemd `EnvironmentFile=` is parsed by PID 1 (root)
   before the process drops privileges, so this should be fine in
   practice — but verify via the Phase 1 `/proc/<pid>/environ` check.
   If the env vars aren't loaded, either (a) set mode `0444` on the
   secret (tmpfs-only, acceptable), or (b) set `owner = "ntfy-sh";
   group = "ntfy-sh";` and disable `DynamicUser` via a systemd override.
   Prefer (a).

2. **Router client-monitor's system user.** Pick (a) or (b) in Phase 2d
   based on what user `hosts/router/services/client-monitor.nix` runs
   the daemon as. Resolve by `grep -E 'User =' hosts/router/services/client-monitor.nix`
   during implementation. If it's the same `ntfy-webhook` user, reuse
   the same sops secret declaration; if it's a different user, use
   mode `0440` with a shared group or declare a second sops entry.

3. **`nix flake check` dev-shell bcrypt tool availability.** The
   rotation recipe uses `python3 -c "import bcrypt; ..."`. Confirm
   `python3Packages.bcrypt` is available from within `nix develop` —
   add to `flake-modules/dev.nix` if missing.

## Commit Plan

Proposed PR split for Phase 1 → Phase 3, matching recent repo commit
granularity (per `git log` showing ~1-2 hunks per commit on feature work).
Scopes match the dominant `<type>(<hostname|area>):` shape from recent
history, not the CLAUDE.md `secrets` scope (which is sanctioned but unused).

1. `chore(secrets): add ntfy-client.yaml sops file with publisher env`
   — new file with creation rule in `.sops.yaml`.
2. `chore(secrets): add ntfy-server-env to storage sops`
   — bcrypts + ACL lines. Permissive default for now.
3. `feat(storage): enable declarative ntfy auth via environmentFile`
   — the `services.ntfy-sh.environmentFile` wire, no publisher changes
   yet. Single-host deploy, Phase 1 validation runs here.
4. `feat(storage): authenticate image-watch ntfy publishes`
   — `modules/media/containers.nix` — extract `_ntfy_auth_header`, all
   three curl sites.
5. `feat(storage): authenticate check-stock ntfy publishes + fix timeout`
   — `packages/check-stock/check-stock.py` + `modules/check-stock.nix`.
6. `feat(cloud): authenticate gatus via generic custom alerter`
   — `hosts/cloud/services/gatus.nix` — swap native ntfy alerter.
7. `feat(router): migrate alertmanager ntfy-webhook to authenticated local ntfy`
   — `hosts/router/ntfy-webhook.nix` + `configuration.nix` url change.
8. `feat(router): migrate client-monitor to authenticated router-clients topic`
   — `hosts/router/services/client-monitor.py` + `client-monitor.nix`,
   including cooldown-on-failure fix.
9. `feat(home): authenticate claude-notify via /run/secrets/ntfy-publisher-env`
   — `home/scripts/claude-notify` + per-host `sops.secrets` wiring in
   cloud/cottage/g14/raider/storage.
10. `fix(storage): flip ntfy to deny-all default access`
    — regenerate `ntfy-server-env`. Phase 3.
11. `docs(services): fix stale host column for ntfy and yarr`
    — `docs/services/catalog.md`. Same commit could also add the
    `just rotate-ntfy-publisher` recipe if not landed earlier.

Commits 1–3 ship Phase 1. Commits 4–9 ship Phase 2 (each publisher
independently verifiable). Commit 10 ships Phase 3. Commit 11 is
cleanup.

If splitting this granularly feels over-engineered for a personal repo,
an acceptable collapse is: one commit for Phase 1 (1+2+3), one per
publisher (4–9 as-is, since each is a different code path), one for
Phase 3 (10), one for docs (11). Avoid collapsing across publishers —
if one breaks, bisect is your friend.

## Rollback Plan

Phase 1 is backwards-compatible (default access stays `read-write`). If
it fails:
- Revert the commit that added `environmentFile` / `sops.secrets."ntfy-server-env"`
- `just deploy storage`
- ntfy restarts with its prior anonymous config

Phase 3 (the flip to `deny-all`) is the only point where anonymous access
breaks. To roll back:
- Regenerate `ntfy-server-env` with `NTFY_AUTH_DEFAULT_ACCESS=read-write`
  and write it via `sops set` (or `git revert` the flip commit — same
  effect)
- `just deploy storage`
- **Do not re-hash the publisher bcrypt during rollback** — extract the
  existing bcrypt from the live `ntfy-server-env` value and reuse it,
  otherwise publishers with cached credentials (e.g. a running
  image-watch that was mid-curl) will see 401s until their next
  invocation

Publishers do **not** need to be rolled back in Phase 3 rollback —
they continue sending auth headers, and auth users still exist. The
only change is that anonymous access is restored.

**Point-of-no-return considerations:**

- Phase 1 has one subtle point-of-no-return: if `/var/lib/ntfy-sh/user.db`
  contained hand-added CLI users (it shouldn't — Phase 1 pre-check #2
  verifies this), the first ntfy-sh restart with declarative provisioning
  deletes them. Restore via `restic restore` from the pre-deploy backup.
- Phase 2 per-publisher rollback is free (git revert, redeploy the
  affected host). `claude-notify` has a `[[ -r $CREDENTIALS_FILE ]]`
  guard that makes it fall back to unauthenticated automatically, so
  even a partial revert is safe during Phase 1/2.
- Phase 3 rollback window is minutes. No point-of-no-return.

Since the roll-back is a single sops-file edit + redeploy of one host, we
do not need a separate safety net.

## Dependencies & Prerequisites

- ntfy server v2.14.0+ (declarative auth support). Nixpkgs unstable ships
  v2.21.0 already — **no flake update needed**.
- Restic backups (existing) cover `/var/lib/ntfy-sh/user.db` → no new
  backup config.
- sops-nix (existing, already wired on every host via
  `constellation.sops.enable`) → no new module imports.
- Dev shell tool for bcrypt generation → already have `nix-shell -p apacheHttpd`
  or can use `ntfy user hash` after adding `pkgs.ntfy-sh` to `nix develop`
  if it isn't already.

No external dependencies (no account creation at ntfy.sh, no new APIs).

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-04-15-secure-local-ntfy-brainstorm.md](../brainstorms/2026-04-15-secure-local-ntfy-brainstorm.md)
  — key decisions carried forward: (1) ntfy built-in auth over
  Tailscale-only, (2) two-user model (`publisher` + `reader`), (3) keep
  `upstream-base-url = https://ntfy.sh`, (4) credentials in sops, (5) keep
  `bypassAuth = true` at the Caddy gateway.

### Internal References

- `hosts/storage/services/ntfy.nix:1-19` — current server config
- `hosts/storage/services/default.nix:19` — storage imports ntfy module
- `modules/media/containers.nix:236-301` — image-watch publisher (3 curl sites at :253, :275, :282)
- `modules/media/__utils.nix:128-164` — gateway auth bypass + reverse_proxy
- `modules/constellation/sops.nix:24-28,65-73` — `commonSopsFile` pattern
- `modules/constellation/email.nix:60-63` — example `common.yaml` usage
- `modules/constellation/backup.nix:75-77` — example `common.yaml` usage
- `hosts/storage/backup/backup-restic.nix:17-93` — confirms `/var/lib/ntfy-sh` is covered
- `hosts/cloud/services/gatus.nix:120-132` — gatus alerter block
- `packages/check-stock/check-stock.py:26-57` — hardcoded URL dict
- `modules/check-stock.nix:70-85` — systemd unit generator
- `hosts/storage/configuration.nix:177-185` — check-stock enablement
- `hosts/router/configuration.nix:152-153` — ntfyUrl option value
- `hosts/router/alerting.nix:32-36,141-166` — alertmanager receivers
- `hosts/router/ntfy-webhook.nix:21,144-182` — Python proxy + hardened systemd unit
- `hosts/router/services/monitoring.nix:363-374` — second alertmanager block
- `hosts/router/services/client-monitor.py:15-16,162-180` — independent publisher
- `hosts/router/services/client-monitor.nix:39` — systemd unit
- `home/home.nix:19,94,104` — claude-notify installation + env
- `home/scripts/claude-notify:1-166` — full script, publish at :157-162
- `flake-modules/lib.nix:72` — `lightHosts` list defines which hosts run home-manager
- `flake-modules/hosts.nix:22-54` — host discovery + home-manager inclusion
- `.sops.yaml:16-53` — creation rules; no `router.yaml` rule
- `docs/services/catalog.md:87` — stale row, fix in this PR
- `docs/plans/2026-03-24-feat-container-image-watcher-plan.md:64` — prior
  invariant: "ntfy failures are non-fatal (`|| true`)". Preserved.
- `docs/plans/2026-03-20-refactor-migrate-all-secrets-to-sops-plan.md` —
  precedent for the sops-nix wiring model used throughout this repo

### External References

- ntfy v2.14.0 release notes (declarative auth) —
  https://github.com/binwiederhier/ntfy/blob/main/docs/releases.md
- ntfy config reference —
  https://docs.ntfy.sh/config/ (sections: "Access control", "Users via
  the config", "ACL entries via the config", "iOS instant notifications")
- ntfy publish reference —
  https://docs.ntfy.sh/publish/ (sections: "Username & password",
  "Access tokens")
- **nixpkgs ntfy-sh NixOS test (canonical declarative-auth example)** —
  https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/tests/ntfy-sh.nix
- nixpkgs ntfy-sh module —
  https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/services/misc/ntfy-sh.nix
- nixpkgs gatus module (exposes `environmentFile`) —
  https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/services/monitoring/gatus.nix
- gatus source — config env expansion —
  https://github.com/TwiN/gatus/blob/master/config/config.go
  (`parseAndValidateConfigBytes` → `os.ExpandEnv`)
- gatus source — native ntfy alerter (disqualified for basic auth) —
  https://github.com/TwiN/gatus/blob/master/alerting/provider/ntfy/ntfy.go
  (`TokenPrefix = "tk_"`)
- gatus source — generic custom alerter (supports arbitrary headers) —
  https://github.com/TwiN/gatus/blob/master/alerting/provider/custom/custom.go
- ntfy source — declarative auth parser —
  https://github.com/binwiederhier/ntfy/blob/main/cmd/serve.go
  (`parseUsers`, `parseAccess`, slice-flag registration)
- ntfy source — `user hash` interactive prompt —
  https://github.com/binwiederhier/ntfy/blob/main/cmd/user.go
  (`execUserHash` → `readPasswordAndConfirm` → twice-read)
- ntfy source — `DefaultUserPasswordBcryptCost = 10` —
  https://github.com/binwiederhier/ntfy/blob/main/user/manager.go
- urfave/cli v2.27.7 slice-flag comma delimiter —
  https://github.com/urfave/cli/blob/v2.27.7/flag.go
  (`defaultSliceFlagSeparator = ","`)
- ntfy GitHub issue #1419 — bcrypt `$` variable-substitution gotcha
  (Docker Compose only; systemd `EnvironmentFile=` is safe)
- ntfy GitHub issue #1644 — `upstream-access-token` clarification
  (needed only for ntfy.sh rate limit, not our local auth)
