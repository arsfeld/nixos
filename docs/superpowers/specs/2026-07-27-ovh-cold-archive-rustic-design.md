# OVH Cold Archive via rustic, replacing Hetzner (design)

**Date:** 2026-07-27
**Host:** galactica
**Status:** Design approved, not implemented.

## Problem

galactica's offsite backup lives on a Hetzner Storage Box at roughly €10.90/month. The
box is the durable copy: the other offsite copy, pegasus at the cottage, runs on old
drives and is not trusted. The Hetzner cost is the thing being optimised.

OVHcloud Cold Archive stores the same data at $0.002/GB/month — about €3.6/month for
this dataset — but it is tape, and restic has no way to use it. rustic does, via its
hot/cold repository split. So the change is: **new rustic-driven cold tier on OVH,
Hetzner box retired, Backrest and every other host untouched.**

## Current state

Measured on galactica and the Storage Box, 2026-07-27.

**Backrest** (`modules/constellation/backrest.nix`, `hosts/galactica/backup/backrest-client.nix`)
runs five plans against three repos:

| Repo | URI | Plans | Schedule |
|---|---|---|---|
| `local` | `/mnt/storage/backups/restic` | `local-system` | daily 02:30 |
| `hetzner` | `rclone:hetzner:backups/restic` | `hetzner-system`, `hetzner` | Sun 04:30, 05:30 |
| `pegasus` | `rest:http://pegasus.bat-boa.ts.net:8000/` | `pegasus-system`, `pegasus` | Sun 06:30, 07:30 |

**Local repo** (`restic stats --mode raw-data`): 488.096 GiB raw across 34 snapshots,
3,858,478 blobs, 3.08× compression. Its `index/` directory is 239 MB, `snapshots/` 136 KB.

**Hetzner Storage Box** `u547717`, BX21 (5.0 TB), 1.9 TB used (38%):

| Path | Size | What it is |
|---|---|---|
| `backups/restic` | 1.7 TiB | user data — `/home` + `/mnt/storage` |
| `backups/restic-system` | 171 GiB | system — `/` |
| `data/` | 101 GB | **orphaned.** A restic REST-server repo whose `index/`, `keys/` and `snapshots/` are all empty (emptied 2026-02-18). Dead packs, nothing to migrate. |
| `restic/` | 63 KB | stale, empty |

`rclone size hetzner:backups` reports 111,347 objects / 1.788 TiB (1,965,529,042,616 bytes).
That is the migration payload: **~1966 GB.**

**galactica's link:** 603.21 Mbit/s down, **157.94 Mbit/s up**. Seeding 1966 GB is ~28 h
at line rate; plan for 2–4 days throttled.

## Constraints established by research

**OVHcloud Cold Archive has two products and only one is usable.**

- **v1** is bucket-granular: seal the whole bucket to tape, and while sealed it accepts no
  reads and no writes, only listing. Incompatible with an incremental repo. Bills a 1 TiB
  minimum per bucket.
- **v2** (since November 2025) is an object-level storage class inside a normal
  S3-compatible bucket, billed from the first byte. **This is what the design uses.**

v2 facts, all from OVH's own docs:

| Property | Value |
|---|---|
| Storage price | $0.002/GB/month |
| Region | `eu-west-par` (Paris 3-AZ) **only** |
| Storage class string | `DEEP_ARCHIVE` — OVH maps Cold Archive to the AWS name |
| Restore API | standard `aws s3api restore-object` |
| Restore time | up to 48 h; minutes-to-hours for a few TB |
| Restore billing | restored copy billed at Standard rate for the requested `Days` |
| Ingress/egress | free |
| API calls | free |
| Minimum storage duration | **180 days.** Early delete bills `(180 − days used) × price` |
| Lifecycle transitions *into* Cold Archive | **not supported** — objects must be written directly in the class |

**rustic 0.11.3** is in nixpkgs on both stable and unstable, so no packaging work. Its
prune is already cold-aware: `--repack-cacheable-only` defaults to `true` on a hot/cold
repository, so prune never repacks cold data packs — it waits until every blob in a pack
is unused. `--keep-pack <DURATION>` (default `0d`) sets a minimum pack age before removal.

**This repo already had a rustic module.** `modules/rustic.nix`, retired in `362b751`
("refactor(modules): retire rustic and refresh backup docs"). It generated
`/etc/rustic/<name>.toml` via `pkgs.formats.toml`, per-profile systemd oneshot + timer,
`environmentFile` support, and a `rustic-<name>` wrapper script on PATH. It is the
starting point, not a rewrite.

## Cost

| | Now | After |
|---|---|---|
| Hetzner BX21 | ~€10.90/mo | — |
| OVH Cold Archive, 1966 GB @ $0.002 | — | $3.93/mo |
| OVH Standard, hot metadata @ ~$0.0081 | — | $0.16–0.41/mo |
| **Total** | **~€10.90/mo** | **~€3.8–4.0/mo** |

The Hetzner figure is BX21's last published price seen during research; confirm against the
current invoice. USD figures converted at roughly parity-minus-8%, which is close enough at
this magnitude to not change the decision. The hot-metadata line assumes 20–50 GB,
extrapolated from the local repo's 239 MB `index/` at 488 GiB plus an allowance for tree
packs — it is the least certain number here, and it is also the smallest.

**Saving ≈ €7/month, ≈ €84/year.** `--keep-pack 180d` keeps dead packs on tape for up to
six months, so steady state runs slightly above the naive figure.

A full 1966 GB restore held for 7 days costs roughly $4 at the Standard rate, with free
egress. This is not Glacier's retrieval trap.

## Design

### Topology

```
galactica
├── Backrest (restic) ─ tooling unchanged
│   ├── local     /mnt/storage/backups/restic     daily 02:30      system
│   └── pegasus   rest://pegasus:8000             Sun 06:30/07:30  system + user  [best-effort]
└── rustic (new) ─ constellation.rustic
    └── ovh       cold: <prefix>-backup-cold  Cold Archive v2, eu-west-par
                  hot:  <prefix>-backup-hot   Standard             Sun 04:30  system + user
```

Copy count stays at three. What changes is which copy is trusted: **OVH becomes the
durable tier**, pegasus is explicitly demoted to best-effort, local NAS remains the
fast-restore tier. basestar, raider and pegasus's own Backrest clients and the
`backrest.arsfeld.one` Authelia portal are untouched.

### Why two orchestrators

Backrest wraps restic, and restic has no hot/cold concept at all. A rustic cold repo
cannot live inside Backrest. Two alternatives were rejected:

- **Shim rustic behind `BACKREST_RESTIC_COMMAND`.** Backrest parses restic's JSON
  progress output and drives restic-specific subcommands, and the hot/cold setup lives in
  a TOML profile Backrest knows nothing about. A translation shim against two moving
  upstreams to save one systemd timer.
- **Migrate the fleet off Backrest to rustic.** basestar, raider and pegasus all back up
  *to* galactica's restic REST server through Backrest, and the public portal is built
  around Backrest's UI. A fleet-wide rewrite of a system unified three months ago, for
  zero additional saving.

The seam is clean: **Backrest owns the warm tiers, rustic owns the cold tier**, and they
never touch the same repo.

### Module: `modules/constellation/rustic.nix`

Resurrected from `362b751^:modules/rustic.nix`, reshaped to constellation conventions
(`constellation.rustic.enable`, `profiles.<name>`). Four changes from the retired version:

- **Prune split from backup.** The old module only ran `backup`. Prune on a cold repo
  should not run weekly — a separate `rustic-<name>-prune` timer, monthly.
- **`IOSchedulingClass = "idle"`.** Restores the per-plan ionice that the Backrest
  migration dropped (noted as deferred in `backrest-client.nix:11-15`). rustic gets its
  own unit, so it is free to reinstate here.
- **`OnFailure=`** into the ntfy path — the retired module had no failure reporting.
- **Its own repo password.** `restic-password` lives in `common.yaml` and is shared with
  basestar, pegasus and raider, so compromising raider would hand over the archive too. A
  galactica-only `rustic-ovh-password` in `galactica.yaml` narrows that for one sops
  entry. Recovery path is unchanged — both are in git, decryptable with the age key.

### Profile

```toml
[repository]
repository    = "opendal:s3"     # cold
repo-hot      = "opendal:s3"     # hot
password-file = "/run/secrets/rustic-ovh-password"
warm-up-command      = "<warmup script> %id"
warm-up-wait-command = "<warmup-wait script> %id"
warm-up-batch        = 1

[repository.options-cold]
bucket                = "<prefix>-backup-cold"
endpoint              = "https://s3.eu-west-par.io.cloud.ovh.net"   # verify
region                = "eu-west-par"
default_storage_class = "DEEP_ARCHIVE"

[repository.options-hot]
bucket   = "<prefix>-backup-hot"
endpoint = "https://s3.eu-west-par.io.cloud.ovh.net"   # verify
region   = "eu-west-par"

[[backup.snapshots]]                          # replaces the hetzner-system plan
sources = ["/"]
globs   = ["!/home", "!/mnt", …]              # systemExcludes
label   = "system"

[[backup.snapshots]]                          # replaces the hetzner plan
sources = ["/home", "/mnt/storage"]
globs   = ["!/mnt/storage/media", …]          # userExcludes
label   = "user"

[forget]
prune        = false                          # weekly backups never prune; see below
keep-daily   = 7
keep-weekly  = 4
keep-monthly = 6
```

S3 credentials arrive via `environmentFile` from a `ovh-s3-env` sops secret in
`galactica.yaml`.

**`keep-pack` is CLI-only.** Verified against rustic 0.11.3: there is no `[prune]` section
in rustic's config file and `[forget]` carries no `keep-pack` key, but `rustic forget`
accepts the full set of PRUNE OPTIONS when invoked with `--prune`. So the monthly
`rustic-ovh-prune` unit runs:

```
rustic -P ovh forget --prune --keep-pack 180d
```

Retention still comes from `[forget]` in the profile; only the pack-age floor is passed on
the command line. It has no environment-variable equivalent, so it must live in the unit's
`ExecStart` — a detail worth a comment in the module, since silently losing it means
paying OVH's early-deletion penalty on every prune.

The effect: snapshots forget on the ladder above, but their exclusively-owned packs linger
on tape for up to six months. No early-deletion penalty is ever incurred.

### Exclude translation — the highest-risk item

restic takes `--exclude /mnt/storage/media`. rustic takes `globs = ["!/mnt/storage/media"]`.
There are three lists totalling roughly 60 patterns in `backrest-client.nix:24-98`
(`localSystemExcludes`, `systemExcludes`, `userExcludes`; only the latter two are in
scope).

Get one wrong in the permissive direction and several TB of Plex media is silently pushed
to tape at $0.002/GB with a 180-day minimum that cannot be cheaply undone. Get one wrong
the other way and something important is silently not backed up.

**Mitigation is a hard gate, not care:** `rustic backup --dry-run` for both snapshot
definitions, file count and byte total diffed against restic's view of the same paths,
before any real upload. See cutover step 2.

### Restore path

```bash
# warm-up-command — %id is the pack id; key layout is data/<first2>/<id>
aws s3api restore-object \
  --endpoint-url https://s3.eu-west-par.io.cloud.ovh.net \
  --bucket "$COLD_BUCKET" --key "data/${id:0:2}/$id" \
  --restore-request '{"Days":7}'

# warm-up-wait-command — poll rather than guess
aws s3api head-object --endpoint-url … --bucket "$COLD_BUCKET" --key "data/${id:0:2}/$id" \
  | grep 'ongoing-request="false"'
```

Both are `pkgs.writeShellScript` helpers wired into the profile. Using
`warm-up-wait-command` rather than a blind `warm-up-wait = "48h"` means a restore takes as
long as OVH actually takes.

The hot repo is Standard class, so `rustic snapshots`, `rustic ls` and `rustic find` need
no warm-up at all. Only real file data touches tape.

`awscli2` provides the CLI; it is only needed at restore time, not during backups.

### Notifications

Backrest's ntfy POST is currently inline in `backrest.nix:78-91`. Rather than write a
second copy for rustic, factor the curl invocation into one shared `writeShellScript`
helper:

- Backrest keeps calling it as an `actionCommand` — it needs Backrest's `{{.Repo.Id}}`
  template expansion, so it cannot become a systemd unit.
- rustic units get `OnFailure = ["backup-notify@rustic-ovh.service"]`, a templated unit
  invoking the same helper.

Same `ntfy-publisher-env` secret, same `https://ntfy.arsfeld.one/backups` topic. One feed,
unchanged from the operator's side.

## Cutover

Ordered so nothing is destroyed until the replacement is proven.

1. Module and profile land with the timer **disabled**. Buckets and S3 credentials created
   in the existing OVH project; `rustic-ovh-password` and `ovh-s3-env` added to
   `galactica.yaml`.
2. **Exclude parity gate.** `rustic backup --dry-run` for both snapshot definitions; diff
   file count and byte total against restic's view. Do not proceed until they agree within
   an explained delta.
3. Seed manually via `systemd-run`, bandwidth-limited so it does not saturate the
   household link. ~29 h at line rate; expect 2–4 days.
4. Verify with `rustic check` — metadata only, reads the hot repo. **Not** `--read-data`,
   which would warm the entire cold repo and bill for it.
5. **Restore drill** on a handful of known files. Exercises both warm-up scripts end to
   end and produces real timings.
6. Enable the weekly timer. Observe two cycles.
7. Strip the `hetzner` repo and its two plans from `backrest-client.nix`; drop the
   `hetzner-webdav-env` and `hetzner-storagebox-ssh-key` sops secrets; update
   `docs/architecture/backup.md` and `docs/hosts/storage.md`.
8. **Cancel the Hetzner Storage Box.** Destroys 1.9 TB including the 101 GB orphaned
   `data/` repo. Gated on step 5 passing and at least two verified OVH snapshots, and on
   explicit operator confirmation at the time.

## Testing

- `nix build .#nixosConfigurations.galactica.config.system.build.toplevel` — check the
  last line for the error count.
- The exclude parity dry-run diff (cutover step 2). This is the gate that matters.
- Manual `systemctl start rustic-ovh` for the first run; inspect the profile log.
- `rustic check` after seeding.
- The restore drill (cutover step 5).
- Failure path: force a failing rustic invocation and confirm ntfy fires.
- After removal: `just build galactica` clean, and `systemctl list-timers` showing no
  Hetzner remnants.

## Open questions

Recorded rather than guessed. None of them change the architecture.

- **Separate retrieval fee?** OVH documents that restored objects are billed at the
  Standard rate for the requested `Days`, and that egress is free. Whether there is an
  additional per-GB retrieval charge on top could not be confirmed — the pricing page did
  not render. Resolve before cutover step 5.
- **`%id` batching semantics.** `rustic restore --help` documents `--warm-up-batch` but not
  the substitution format when batch > 1. Verify against 0.11.3 before relying on it;
  fallback is `warm-up-batch = 1`.
- **Rebuilding a lost hot repo from cold.** Undocumented. Mitigated by siting the hot
  bucket in OVH rather than on galactica, so it survives the disaster the cold tier exists
  for.
- **`eu-west-par` S3 endpoint hostname.** Assumed `https://s3.eu-west-par.io.cloud.ovh.net`
  by analogy with OVH's other regions; confirm in the OVH console when creating the
  buckets.

## Sources

- [OVHcloud Cold Archive — Overview](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/cold-archive-overview)
- [OVHcloud Cold Archive — FAQ](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/cold-archive-faq)
- [OVHcloud — Restoring an archived object from Cold Archive storage class](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-restoring-objects)
- [OVHcloud Cold Archive product page](https://www.ovhcloud.com/en/public-cloud/cold-archive/)
- [rustic — Cold Storage](https://rustic.cli.rs/docs/commands/init/cold_storage.html)
- [rustic — FAQ](https://rustic.cli.rs/docs/FAQ.html)
- [rustic `config/full.toml`](https://github.com/rustic-rs/rustic/blob/main/config/full.toml)
