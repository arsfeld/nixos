# Design: `media.services.<name>` — unified, declarative service definitions

**Date:** 2026-06-27
**Status:** Approved (design); pending implementation plan
**Scope:** `modules/media/` + all service files under `hosts/*/services/`

## Problem

Services are declared today through a **function helper**, `mkService`, imported per file
(`import "${self}/modules/media/__mkService.nix" {inherit lib;}`) and spliced into a
`lib.mkMerge [ … ]`. It works, but it has two costs:

1. **Not idiomatic / not discoverable.** `mkService` is a free-form function argument, not a
   NixOS option. It doesn't appear in option docs/search, isn't type-checked, and every call
   site carries `let mkService = import …; in lib.mkMerge [ … ]` boilerplate. Underneath it
   already writes to real submodule options (`media.containers.<name>`,
   `media.gateway.services.<name>`), so the function is a thin, undiscoverable facade over
   options that already exist.

2. **Every database-backed service reinvents provisioning.** `ask.nix` and `planka.nix` each
   carry ~40 lines of bespoke postgres setup (`ensureDatabases`/`ensureUsers`, a hardcoded
   podman-subnet `pg_hba` line, a `postStart` `ALTER USER` from a sops secret, a manual
   systemd `after`/`wants`, and a `<name>-db-password` secret). `db.nix` carries a third
   variant (trust auth) plus a hand-rolled MariaDB setup script for seafile/filerun/romm.
   The same job is expressed three different ways.

The goal: **simple, DRY, automatic.** Service definitions should not use creative per-service
methods to wire databases, credentials, or systemd dependencies.

## What NixOS itself does (and why this repo diverges)

NixOS has two idiomatic patterns, both **passwordless by default**:

- **`database.createLocally` + peer auth.** Dozens of upstream modules (atuin, keycloak,
  nextcloud, homebox, glitchtip, …) expose `services.<foo>.database.createLocally = true`,
  which enables postgres, adds `ensureDatabases`/`ensureUsers`, connects over the **local unix
  socket using peer authentication with no password**, and sets `after = ["postgresql.service"]`.
  `redis.createLocally` is the same idea over a redis socket.
- **`*PasswordFile`** for the rare case a password is genuinely needed — the module *reads* a
  runtime file but does **not** provision the password into the DB.

Crucially, `services.postgresql.ensureUsers` creates roles "identified using peer
authentication … without the need for a password" — it **cannot set a password**. There is no
generic "declare a dependency and auto-wire it" abstraction in NixOS; each module hand-codes
its own `createLocally`.

This repo's services are **containers**, which connect over TCP from the podman bridge as a
uid that is not the host role — so peer auth is unavailable. That impedance mismatch is the
entire reason `ask.nix`/`planka.nix` resort to TCP + scram + a sops password + a manual
`ALTER USER`: they are fighting the framework's passwordless design.

`db.nix` already found the NixOS-shaped answer for containers:
`ensureDatabases`/`ensureUsers` + a `host <db> <role> 10.88.0.0/16 trust` `pg_hba` line. That
is passwordless, matches what `ensureUsers` actually produces, and needs zero secret
machinery — it is the TCP analogue of peer auth. **This design generalizes that pattern.**

## Design

### 1. `media.services.<name>` option (replaces the `mkService` function)

`media.services` becomes an `attrsOf submodule`. A service file stops importing `mkService`
and wrapping everything in `lib.mkMerge`; it becomes a plain NixOS module that sets
`media.services.foo = { … }` alongside its `sops.secrets` / `systemd.services` in one `config`
block.

Option surface = today's `mkService` args, now declared and type-checked:

| Option | Type | Notes |
|---|---|---|
| `port` | `nullOr int` | required for containers; null = auto-assigned for gateway-only |
| `image` | `str` | defaults to `ghcr.io/linuxserver/<name>` |
| `container` | `nullOr submodule` | existing container body; null = gateway-only service |
| `cmd` | `nullOr (listOf str)` | container command |
| `host` | `nullOr str` | gateway host override (lowered with `mkForce`) |
| `bypassAuth` / `cors` / `funnel` / `insecureTls` | `bool` | forwarded to gateway `settings` |
| `tailscaleExposed` | `bool` | → `exposeViaTailscale` |
| `watchImage` | `bool` | image polling |
| `database` | submodule | see §2 |

The submodule's `config` lowers each entry into the **existing**
`media.containers.<name>` / `media.gateway.services.<name>` plumbing using the exact branch
logic `mkService` uses today (`container != null` → containers + optional gateway extras;
else → gateway-only). The container/gateway modules underneath are **unchanged**;
`media.containers` and `media.gateway.services` become pure implementation/lowering targets
(CLAUDE.md already documents them as "implementation details").

`media.services` is a free namespace (existing public options are only `media.config`,
`media.gateway`, `media.containers`).

### 2. Declarative database dependency (`createLocally`-style, trust auth)

```nix
media.services.ask = {
  port = 3000;
  container = { configDir = null; environmentFiles = [ … ]; };
  database.postgres = true;   # replaces ~40 lines of provisioning
};
```

`database` is a submodule. **This iteration implements `postgres` only** (see non-goals re:
mysql). It accepts either a bool or a submodule `{ name ? "<service-name>"; }` so a service can
override the db/role name when the app demands it (e.g. `database.postgres = { name = "morphic"; }`).

When `database.postgres` is enabled, the module auto-generates for a service named `<name>`:

- `services.postgresql.enable = true` + `enableTCPIP = true`
- `ensureDatabases = ["<dbname>"]`
- `ensureUsers = [{ name = "<dbname>"; ensureDBOwnership = true; }]`
- a `pg_hba` line appended via `mkAfter`: `host <dbname> <dbname> 10.88.0.0/16 trust`
  (passwordless TCP — the analogue of peer auth)
- systemd ordering: the container unit (`${backend}-<name>`) gets
  `after`/`wants` = `["postgresql.service"]`
- a passwordless connection injected into the container environment — a `DATABASE_URL`
  (`postgresql://<dbname>@host.containers.internal:5432/<dbname>`) plus discrete
  `PG*`/`DB_*` vars, so apps can consume whichever form they expect.

**No** sops secret, **no** `ALTER USER`, **no** hand-written `pg_hba`, **no** manual systemd
dependency in any postgres-backed service file.

**MySQL/MariaDB is deferred** to a follow-up spec. MariaDB has no `trust` equivalent over TCP
(its passwordless `ensureUsers` accounts are unix-socket-only, unreachable from a container),
so a clean passwordless mirror of the postgres story isn't possible. The only consumers
(seafile — 3 databases + a root-access init step — plus filerun/romm) keep their current
bespoke `db.nix` setup for now, the same way `planka.nix` stays bespoke.

### 3. Redis — not reinvented

Redis is already idiomatic upstream (`redis.createLocally`, `services.redis.servers.<name>`,
unix sockets), and most redis usage in the repo already goes through it. The design does
**not** add a `database.redis` provisioner. Services needing redis keep declaring
`services.redis.servers.<name>` in their own module and referencing it. Revisit only if a
clear duplication emerges (YAGNI).

### 4. Automatic systemd ordering

Any declared `database.*` dependency wires the container unit's `after`/`wants` automatically.
Service files no longer hand-write `systemd.services."${backend}-<name>".after =
["postgresql.service"]`.

### 5. Migration: big-bang

- Convert all 37 `mkService` call sites to `media.services.<name>` in one pass.
- Delete `modules/media/__mkService.nix`.
- Postgres-backed services (`ask`/morphic, `bitmagnet`) drop their inline provisioning in favor
  of `database.postgres`; the redundant central postgres declarations in `db.nix` are reduced
  accordingly. (MySQL consumers untouched — deferred.)
- Update `CLAUDE.md` (the `mkService` section and the "mkService is the only way" rule) and the
  `mkservice-mandatory` memory to describe `media.services.<name>` as the single entry point.

## Scope boundaries (explicit non-goals)

- **No** unix-socket bind-mount peer-auth mode — purest but fiddly with container uids; out of
  scope. Trust auth on the podman subnet is the chosen mechanism.
- **No** `database.redis` provisioner (see §3).
- **MySQL/MariaDB provisioning is deferred** to a follow-up spec (see §2). seafile/filerun/romm
  keep their current `db.nix` setup.
- **`planka.nix` is not folded in** as part of this work. Its `--network=host` and
  URL-encoded-password env are a known, separate wart; planka keeps its bespoke module until a
  dedicated cleanup. (It can adopt `media.services` + `database.postgres` later.)
- The central `services.postgresqlBackup` / `services.mysqlBackup` in `db.nix` **stay** — they
  back up `ensureDatabases`, which the new mechanism still populates.

## Affected files (indicative)

- `modules/media/__mkService.nix` — deleted.
- `modules/media/` — new `services.nix` (the `media.services` option + lowering + database
  provisioning), imported alongside `containers.nix`/`gateway.nix`.
- `hosts/*/services/*.nix` — all 37 `mkService` sites converted; DB-backed ones simplified.
- `hosts/galactica/services/db.nix` — central postgres declarations reduced as services adopt
  `database.postgres` (mysql section untouched).
- `CLAUDE.md`, memory `mkservice-mandatory.md` — updated.

## Success criteria

- No file imports `__mkService.nix`; the file is gone.
- `media.services.<name>` is a discoverable, type-checked NixOS option.
- A new postgres-backed container service needs only `database.postgres = true` — no
  per-service sops secret, `pg_hba`, `ALTER USER`, or systemd dependency.
- All hosts (`galactica`, `basestar`, `pegasus`, `raider`) build; deployed services keep their
  current routing/auth/exposure behavior.
