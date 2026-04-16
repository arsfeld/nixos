---
date: 2026-04-15
topic: Cottage restic REST server as a second offsite target for storage
status: brainstorm
---

# Cottage restic REST server as a second offsite backup target

## What We're Building

Bring cottage's data pool back online from scratch, then replace its
half-baked Garage (S3-compatible restic target) with a plain
`services.restic.server` instance, mirroring the pattern already in use
on storage (`hosts/storage/backup/backup-server.nix`). Add two new restic
profiles on storage that push to cottage with the same scope, schedule,
and retention as the existing Hetzner profiles, creating a second
offsite copy of everything storage already protects. Garage is torn out
entirely, including its config and sops secrets — it never held real
backups.

Cottage becomes the eventual replacement for Hetzner; for now it runs in
parallel so we can validate it before tearing Hetzner down.

## Prerequisite: Cottage Data Pool

Cottage's `/mnt/storage` does not currently exist — the previous pool
was wiped/abandoned. The backup work blocks on rebuilding it.

**Disk inventory (confirmed via SSH 2026-04-15):**

| Device | Size | Model             | Current state                      |
|--------|------|-------------------|------------------------------------|
| sdb    | 4 TB | ST4000VN000-1H4168 | Stale bcachefs superblock         |
| sdd    | 4 TB | ST4000VN008-2DR166 | Stale bcachefs superblock         |
| sde    | 4 TB | WDC WD40EFRX-68N32N0 | Stale bcachefs superblock       |
| sdf    | 4 TB | ST4000VN008-2DR166 | Stale GPT + `disk-data3-zfs` partlabel |
| sdg    | 4 TB | ST4000VN000-1H4168 | Stale bcachefs superblock         |

All five SMART-PASSED. `bcachefs` tools aren't even installed — the
superblocks are dead metadata, not a live filesystem. sdf's partition
label reveals a prior ZFS attempt. **Nothing of value lives on any of
these disks.** The `fstab` has no `/mnt/storage` entry.

**Topology decision: btrfs RAID1c3 for data AND metadata.**
`mkfs.btrfs -d raid1c3 -m raid1c3` across all five disks.

- **~6.67 TB usable** (out of ~20 TB raw).
- **Tolerates any 2 simultaneous disk failures** — critical on aging
  4TB spinners where a second failure during resilver is plausible.
- **Gentle resilvers.** btrfs only rewrites allocated blocks (unlike
  ZFS raidz2 or mdraid, which touch every sector), so recovery is
  less stressful on the surviving old drives.
- **Checksums catch bit rot** — important for a backup target where a
  silent flip corrupts a restic pack file.
- **Simplest moving parts.** Pure btrfs, same tooling as the rest of
  cottage. No mdadm, no ZFS kernel module.

Chosen over plain RAID1 because old disks + the URE-during-rebuild trap
make single-copy-fault-tolerance too risky, and 6.67 TB is still plenty
of headroom for storage's Hetzner payload (~2–5 TB deduped) plus
retention growth.

**Pool management: not via disko.** The existing
`hosts/cottage/disko-config.nix` already carries the comment "Storage
disks not managed by disko", and that decision stands — disko would
force destructive re-runs, which is wrong for a long-lived data pool.
Instead:

1. **One-time manual mkfs** on cottage (over SSH):
   - `wipefs -a /dev/sdb /dev/sdd /dev/sde /dev/sdf /dev/sdg` to clear
     stale bcachefs + GPT headers.
   - `sgdisk --zap-all /dev/sdf` for the GPT leftover.
   - `mkfs.btrfs -L cottage-data -d raid1c3 -m raid1c3 \
       /dev/disk/by-id/ata-...` (use `/dev/disk/by-id/` symlinks
     captured at plan time, not `/dev/sdX` which can reshuffle).
2. **Declarative mount** via a `fileSystems."/mnt/storage"` entry in
   `hosts/cottage/configuration.nix` (or a new
   `hosts/cottage/storage.nix`), keyed by filesystem UUID, with
   `compress=zstd,noatime` to match the rest of cottage.
3. **Boot behavior:** `nofail` + `x-systemd.device-timeout=30s` so a
   missing disk can't wedge cottage's boot. Cottage already sets
   `networking.useDHCP` to `wait = "background"` for similar reasons.

🚨 **Destructive prerequisite.** Wiping five disks requires the user to
run the `wipefs`/`sgdisk`/`mkfs.btrfs` commands (or confirm explicitly)
per global CLAUDE.md data-protection rules. The plan document will
capture the exact command list.

## Why This Approach

- **Symmetry with storage.** Cottage's server config becomes a ~7-line file
  identical in shape to the one storage already runs. The client side
  on storage is literal copy/paste of the two Hetzner profile blocks in
  `hosts/storage/backup/backup-restic.nix`, with only the repository URL
  changed.
- **Simplicity win.** Garage brought an S3 gateway, cluster layout, admin
  tokens, RPC secrets, a bucket-init oneshot, and two sops secrets — all
  for the purpose of speaking restic. restic REST removes every one of
  those moving parts.
- **No new abstractions.** We don't introduce a constellation module or a
  shared Nix helper to deduplicate the Hetzner/cottage profiles. Two
  near-identical blocks are clearer than a parameterized factory, and
  make it trivial to delete the Hetzner half later.
- **Matches existing trust model.** Tailscale-only, `--no-auth`, exactly
  like storage's server. No new secrets.

## Key Decisions

- **Data pool:** btrfs RAID1c3 data + RAID1c3 metadata across all 5
  drives, manually mkfs'd, declaratively mounted via
  `fileSystems."/mnt/storage"` (not disko-managed). ~6.67 TB usable,
  tolerates any 2 disk failures. See Prerequisite section above.
- **Topology role:** Additional tier alongside Hetzner, eventually
  replacing it. Both run in parallel during the validation period.
- **Scope:** Full mirror of both Hetzner profiles (`hetzner-system` for
  root/service configs/DBs, `hetzner` for `/home` + `/mnt/storage` user
  data).
- **Access:** Tailscale-only, `--no-auth`, bound to cottage's Tailscale
  interface on port 8000. Identical to storage's server.
- **Garage cleanup:** Remove all Nix config (`services.garage`,
  `garage-init` systemd unit, `garage` user/group, `garage-rpc-secret`
  and `garage-admin-token` sops entries) **and** delete
  `/mnt/storage/backups/garage` on cottage. Nothing of value lives there.
- **Repo path on cottage:** `/mnt/storage/backups/restic-server` — exact
  match for storage's convention.
- **Schedule & retention:** Match Hetzner exactly — weekly, `--keep-daily
  7 --keep-weekly 4 --keep-monthly 6` for both profiles.
- **Re-enable cottage backup module:** Uncomment `./backup` import and
  flip `constellation.backup.enable`. (Note: the constellation.backup
  module today is client-side only — we're re-enabling the local
  `hosts/cottage/backup/` directory, which will just hold the server
  config.)
- **Naming on storage:** Two new services `restic-backups-cottage` and
  `restic-backups-cottage-system`, parallel to the Hetzner names.

## Files In Scope

- **Data pool (manual, one-time, on cottage):** `wipefs`, `sgdisk`,
  `mkfs.btrfs -d raid1c3 -m raid1c3` across the 5 drives. No
  corresponding file in the repo — it's a ssh-time operation — but
  plan doc must list the exact command sequence.
- `hosts/cottage/configuration.nix` — add a
  `fileSystems."/mnt/storage"` entry keyed by UUID
  (`compress=zstd,noatime,nofail,x-systemd.device-timeout=30s`),
  uncomment `./backup` import, flip `constellation.backup.enable` to
  `true`, remove the "disabled until data pool is recreated" comment.
- `hosts/cottage/backup/backup-server.nix` — replace Garage-era content
  with `services.restic.server` block (mirror of
  `hosts/storage/backup/backup-server.nix`).
- `hosts/cottage/backup/default.nix` — drop Garage comment, keep the
  backup-server import.
- `hosts/cottage/services/default.nix` — remove `services.garage`,
  `garage` user/group, garage sops secrets, `garage-init` systemd
  unit (in backup-server.nix), and the tmpfiles rules for
  `/mnt/storage/backups/garage`.
- `secrets/sops/cottage.yaml` — drop `garage-rpc-secret` and
  `garage-admin-token`.
- `hosts/storage/backup/backup-restic.nix` — add two new profiles
  (`cottage-system`, `cottage`) copying the Hetzner exclusion lists,
  pointing at `rest:http://cottage.bat-boa.ts.net:8000/`. Add
  `TimeoutStartSec = "infinity"` and idle I/O scheduling on the new
  units, matching the Hetzner ones.

## Resolved Questions

- **Offline cottage handling:** Fail with an alert. Wire the unit
  failures into the existing email/metrics alerting so a silently
  offline cottage is noticed within a cycle or two. During planning,
  confirm whether this reuses storage's existing `OnFailure=` email
  hook or metrics-client unit failure alerts.
- **Initial seed:** No special seeding. Kick off the first weekly run
  and let it complete in its own time. `TimeoutStartSec = "infinity"`
  on the unit means a multi-day first run is fine.
- **Bandwidth cap:** None. Weekly cadence plus `RandomizedDelaySec =
  "1h"` is enough scheduling spread; if cottage's upstream is the
  bottleneck it just takes longer. No IOWeight / tc config.

## Open Questions

1. **Retention on cottage-side pruning.** Restic's `pruneOpts` run
   client-side (from storage) against the cottage repo. Confirm this
   works across the REST protocol — should be fine since the server
   isn't in `--append-only` mode, but worth a dry-run check.
2. **Decommission trigger for Hetzner.** What's the signal that we're
   confident enough in cottage to rip out the Hetzner profiles? (e.g.
   "N successful weekly runs + one successful restore drill").
3. **SMART monitoring of pool disks.** `services.smartd` is already
   enabled on cottage, but the new data pool members should be in its
   monitored list explicitly so degraded disks get surfaced before the
   pool tolerates its second failure.

## Non-Goals

- Not changing storage's local restic repo at `/mnt/storage/backups/restic`.
- Not touching the existing `constellation.backup` rustic-based module
  that other hosts use to push to storage.
- Not backing up media (`/mnt/storage/media`) — out of scope, same
  exclusion as Hetzner.
- Not introducing auth, append-only mode, or any new sops secrets on
  cottage.
- Not deduplicating the Hetzner and cottage profile definitions via a
  Nix helper — two copies now, delete one later.

## Next Step

Run `/ce:plan` to turn this into a concrete implementation plan, or
address the Open Questions first if any change the shape of the work.
