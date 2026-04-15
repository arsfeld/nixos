---
date: 2026-04-15
topic: secure-local-ntfy
---

# Secure Local ntfy

## What We're Building

Lock down `ntfy.arsfeld.one` (currently public and unauthenticated) so that
only our own machines can publish to topics and only household members can
subscribe. The service stays publicly reachable — phones are not always on
Tailscale — so enforcement happens inside ntfy itself via its built-in auth.

## Why This Approach

- **Tailscale-only** was rejected: the phone (primary subscriber) is not
  always on the tailnet, and we want notifications to arrive on cellular.
- **ntfy's built-in auth with `auth-default-access = deny-all`** is the
  minimum viable lockdown that works with the existing mobile clients and
  keeps iOS push working through `upstream-base-url = https://ntfy.sh`.
- **Two shared accounts, one writer and one reader.** Every machine that
  publishes uses the same `publisher` credential; every phone that
  subscribes uses the same `reader` credential. Blast radius from either
  leaking is "someone can spam/read my notifications" — acceptable because
  rotation is a single sops secret edit plus a phone re-login.

## Key Decisions

- **Auth model:** `auth-default-access = deny-all`, two users total:
  - `publisher` — write access to `*` — used by every publishing machine
  - `reader` — read access to `*` — used by every subscribing phone
    (Alex's and wife's). Same credential on both devices.
- **Credential storage:** sops, same pattern as every other secret in this
  repo. Publishers on storage/cloud/router read the secret from
  `/run/secrets/...`. Workstation publishers (claude-notify) read it from
  their host's sops secrets too.
- **Auth file location:** `${configDir}/ntfy/user.db` on storage, covered by
  the existing backup module.
- **iOS push compatibility:** keep `upstream-base-url = https://ntfy.sh`.
  The upstream server only receives a wake-up poke; message payload and
  auth enforcement stay on our server.
- **Gateway:** `bypassAuth = true` stays in `media.gateway.services.ntfy`.
  Authelia still cannot sit in front of ntfy; ntfy's own auth replaces it.
- **Provisioning:** users created declaratively if the nixpkgs module
  exposes user config, otherwise via a systemd oneshot that runs `ntfy user
  add` idempotently from a sops-provided password file. Plan phase to
  confirm which.

## Known Publishers to Migrate

All of these need the `publisher` credential wired in:

- `modules/media/containers.nix` — container image watcher (`container-updates`)
- `hosts/storage/services/ntfy.nix` — the server itself (self-publishes?)
- `hosts/cloud/services/gatus.nix` — health check alerts
- `packages/check-stock/check-stock.py` — `product-available`
- `home/scripts/claude-notify` — per-project Claude Code hooks
- `hosts/router/alerting.nix` + `hosts/router/configuration.nix` — currently
  publishes to `ntfy.sh/arsfeld-router`; migrate to the local server at the
  same time so the router is actually covered by the lockdown

## Onboarding for Subscribers

Both phones do the same one-time setup: install the ntfy app, add server
`https://ntfy.arsfeld.one`, log in with the shared `reader` credential,
subscribe to the desired topics. Credential handoff via password manager.

## Open Questions

- Does the nixpkgs `services.ntfy-sh` module support declarative users in
  `settings`, or do we need a systemd oneshot wrapper? (Plan phase to check.)
- Does `claude-notify` on workstations already read from sops, or does it
  need a new secret path wired into home-manager? (Plan phase to audit.)

## Next Steps

→ `/ce:plan` for implementation details
