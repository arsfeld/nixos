# niks3-hook SQLITE_BUSY: single-connection queue patch

## Problem

During the 2026-10-11 weekly-update (03:05–03:42), raider's `niks3-hook`
auto-upload daemon logged ~760 `Failed to queue paths … database is locked (5)
(SQLITE_BUSY)` errors. `niks3-hook send` always exits 0, so no build failed, but
every path that hit the error was silently dropped from auto-upload — exactly the
local builds auto-upload exists to cache.

This is not basestar. basestar's niks3 keeps its state in Postgres; the only
SQLite in the path is the hook's local queue, `/var/lib/niks3-hook/upload-queue.db`
on raider. The single HTTP 500 seen in the same run was one narinfo GET from
basestar to `cache.arsfeld.dev` (R2, no server of ours), succeeded on retry, and
is out of scope.

## Cause

Upstream issue Mic92/niks3#409 was closed by `6b7d2e7f`, which moved the WAL and
`busy_timeout` pragmas into the DSN. raider runs that version and still fails.
`OpenQueue` leaves `database/sql`'s pool unbounded, so one process holds several
SQLite connections, and the hook server's `Enqueue` races the worker's
`FetchBatch`/`Remove`/`Retry` for SQLite's single write lock. Upstream's
`TestQueueConcurrentWriters` passes because it exercises only concurrent
`Enqueue`, not that mix.

Only this daemon ever opens the database (`send` talks to it over a socket), and
no queue method calls another while holding a transaction, so capping the pool
at one connection removes the contention: callers wait in Go for the connection
instead of SQLite returning BUSY.

## Rejected alternatives

- **Postgres.** Needs a server: on raider, a database for a path buffer; on
  basestar, the queue would fail in the very outages it exists to absorb. The
  hook is SQLite-only, so it would mean carrying a fork of its storage layer.
- **Retry on BUSY in the hook server.** Treats the symptom; the contention is
  self-inflicted.
- **Upstream PR.** Not opened, by policy. The patch is carried locally.

## Design

1. **Patch** `hosts/raider/niks3-hook-single-conn.patch`, a unified diff against
   the niks3 source:
   - `hook/queue.go`: `db.SetMaxOpenConns(1)` in `OpenQueue`, with a comment.
   - `hook/queue_test.go`: `TestQueueEnqueueDuringDrain` — 8 writers enqueueing
     while a loop runs `FetchBatch` → `Remove`/`Retry`, asserting no `Enqueue`
     error.
2. **Wiring** in `hosts/raider/configuration.nix`:
   `services.niks3-auto-upload.package` set to the module's default package with
   the patch appended via `overrideAttrs` (which preserves the `.override` the
   module uses to inject the socket path; `go.mod` is untouched, so `vendorHash`
   holds). The comment states why the patch exists and to delete it once the
   pinned niks3 contains an equivalent fix. If upstream changes `queue.go`, the
   patch fails to apply and the build fails loudly.

## Verification

- **Red:** the new test fails with SQLITE_BUSY against unpatched source. If it
  cannot be made to fail, the diagnosis is wrong; stop and re-investigate.
- **Green:** the patched package builds and the hook tests pass (in its
  `checkPhase` if it runs them, else `go test ./hook/` on the patched tree).
- **Live:** `just test raider`; after the next heavy build,
  `journalctl -u niks3-auto-upload | grep -c SQLITE_BUSY` is 0.

## Out of scope

The R2 500, basestar's niks3 server, and the uncommitted
`hosts/raider/weekly-update.nix` change.
