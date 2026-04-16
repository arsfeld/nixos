---
title: "feat(cottage): restic REST server backed by btrfs RAID1c3 data pool"
type: feat
status: completed
date: 2026-04-15
origin: docs/brainstorms/2026-04-15-cottage-restic-rest-target-brainstorm.md
---

## Completion notes (2026-04-15)

- All 4 phases committed and deployed (6 commits on master, tip
  `943db47`). Phase-3 server config hit a fix-forward after first
  deploy: systemd's `ReadWritePaths=dataDir` bind-mount failed with
  exit 226/NAMESPACE because the fresh pool had no
  `/mnt/storage/backups/restic-server` directory yet. Resolved by
  adding `systemd.tmpfiles.rules` for both `/mnt/storage/backups`
  and the restic subdir, protected by the existing
  `RequiresMountsFor=/mnt/storage`.
- Storage-side profiles were DRYed mid-execution (commit
  `fd0db78`) — the original plan's "two copies for clarity"
  rationale was overridden per user feedback. Exclusion lists and
  retention now factor through `mkRemoteProfile` + `systemExcludes`
  /`userExcludes`. Byte-identical nix-eval output verified vs HEAD
  for the Hetzner profiles before the refactor landed, so the
  existing Hetzner backups were unaffected.
- First `cottage-system` run completed successfully in **1h 02m 50s**:
  559,845 files, 224.041 GiB total, 108.347 GiB stored after dedup +
  compression (~52%). Snapshot `dd4803eb`, verified via
  `restic snapshots` over REST. `restic stats` reports 652k files,
  223.966 GiB total.
- `cottage` (user-data) profile **not yet run**. Deferred to its
  first weekly slot at **Mon 2026-04-20 00:33:18 EDT**. Expect a
  multi-hour first seed.
- **Gotcha encountered and worth remembering:** Storage's deploy
  SSH-session dropped during activation (many services including
  sshd + tailscaled were restarted due to drift from a long gap
  since last deploy). Activation completed on the server, but
  Colmena reported exit 255. Side effect: the two new
  `restic-backups-cottage{,-system}.timer` units came up `enabled`
  but `inactive` — systemd didn't start them as part of
  activation. Fixed manually with `systemctl start`. Next storage
  deploy should verify timers post-deploy.
- Skipped per user direction: restore test, prune dry-run, failure-
  alert smoke test. All three are easy to run later if wanted.

# feat(cottage): restic REST server backed by btrfs RAID1c3 data pool

## Overview

Bring cottage's five-disk data array back online as a btrfs RAID1c3 pool,
then stand up `services.restic.server` on cottage as a second offsite
backup target for storage. Tear out the half-baked Garage (S3-compatible)
setup along the way. Add two new restic profiles on storage
(`cottage-system`, `cottage`) that mirror the existing Hetzner profiles
so cottage becomes a true second copy of everything storage already
protects. Hetzner stays in place in parallel until the cottage pipeline
is validated.

## Problem Statement / Motivation

**Cottage is currently a dead end for backups.** Its data pool was wiped
during a prior migration; `/mnt/storage` isn't mounted; four of the five
4TB drives still carry stale bcachefs superblocks and a fifth has a
leftover `disk-data3-zfs` GPT partition from an earlier ZFS attempt.
`hosts/cottage/configuration.nix:14,20` explicitly disables the backup
module "until data pool is recreated."

Meanwhile, cottage was previously configured to run **Garage** — an
S3-compatible object store — purely so restic could talk S3 to it. That
brought a cluster layout, RPC secrets, admin tokens, a bucket-init
systemd oneshot, and two sops secrets (`garage-rpc-secret`,
`garage-admin-token`), all for the purpose of speaking restic. Garage
never held real backups. `services.restic.server` removes every one of
those moving parts and mirrors the pattern storage already runs
(`hosts/storage/backup/backup-server.nix`).

**Why we need a second offsite now.** Storage today has exactly one
offsite copy (Hetzner Storage Box via rclone+WebDAV). Cottage, once
healthy, lets us establish a real 3-2-1 posture while we validate
migrating fully off Hetzner.

## Proposed Solution

Phased rollout, each phase independently revertable:

1. **Phase 0 — Data pool (destructive, manual on cottage).** Wipe the
   five 4TB drives, create a btrfs RAID1c3-data + RAID1c3-metadata pool,
   capture the UUID for the fileSystems entry. One-time SSH work.
2. **Phase 1 — Garage teardown (Nix commit).** Remove the Garage service,
   its systemd init oneshot, its users/groups, its sops secrets, and its
   data directory references from cottage.
3. **Phase 2 — Mount + backup client enable (Nix commit + deploy).**
   Declare `fileSystems."/mnt/storage"` by UUID, re-enable
   `./backup` import and `constellation.backup.enable` so cottage also
   backs itself up to storage via rustic.
4. **Phase 3 — Restic REST server on cottage (Nix commit + deploy).**
   Replace the Garage-era `hosts/cottage/backup/backup-server.nix` with
   a `services.restic.server --no-auth` block, add a firewall hole for
   `tailscale0:8000`, and pin the systemd unit to the data-pool mount so
   it can't accidentally write to the root SSD.
5. **Phase 4 — Storage-side profiles (Nix commit + deploy).** Add
   `cottage-system` and `cottage` profiles to
   `hosts/storage/backup/backup-restic.nix`, copying the Hetzner
   profiles almost verbatim but pointing at
   `rest:http://cottage.bat-boa.ts.net:8000/`.
6. **Phase 5 — Validation.** Manually trigger the small profile first,
   verify snapshots on cottage, then let the big profile run on its
   schedule. One practice restore.
7. **Phase 6 (future, out of scope).** Decommission Hetzner after the
   success criteria below are met.

## Technical Considerations

### Data pool topology (see brainstorm: docs/brainstorms/2026-04-15-cottage-restic-rest-target-brainstorm.md)

`mkfs.btrfs -L cottage-data -d raid1c3 -m raid1c3` across all five
4TB drives.

- **~6.67 TB usable** out of ~20 TB raw. Three copies of every block
  and every metadata extent.
- **Any 2 disks can fail** and the pool stays mountable — important on
  aging spinners where a second failure during resilver is the real
  failure mode for 1-copy-fault-tolerant setups.
- **Gentle resilvers.** btrfs only rewrites allocated blocks, not every
  sector. Less stress on the surviving old drives than ZFS raidz2 or
  mdraid would impose.
- **Checksums** catch bit rot silently — critical when the payload is
  restic pack files.
- **Simplest moving parts.** Pure btrfs, same tooling as the rest of
  cottage. No mdadm, no ZFS kernel module.
- **Chosen over plain RAID1** because the URE-during-rebuild trap on
  old 4TB drives makes single-copy-fault-tolerance too risky for a
  backup target.

### Pool is **not** managed by disko

`hosts/cottage/disko-config.nix:4` already carries the comment
"Storage disks not managed by disko" and that decision stands. Disko
would force destructive re-runs on every apply, which is wrong for a
long-lived data pool. The pool is `mkfs`'d manually once and then
declared via a UUID-keyed `fileSystems` entry.

### Mount options

Keyed by **filesystem UUID** (captured in Phase 0), not by-id device
paths, so a disk reshuffle or replacement doesn't break the mount:

```nix
fileSystems."/mnt/storage" = {
  device = "/dev/disk/by-uuid/<captured-in-phase-0>";
  fsType = "btrfs";
  options = [
    "compress=zstd"
    "noatime"
    "nofail"
    "x-systemd.device-timeout=30s"
  ];
};
```

- `nofail` + `x-systemd.device-timeout=30s` — if the pool is degraded
  past the point of mounting, cottage still boots. Precedent:
  `hosts/storage/hardware-configuration.nix:38` uses `nofail` +
  `compress=zstd`. `x-systemd.device-timeout` is new to this repo.
- `compress=zstd` + `noatime` — matches storage and raider btrfs
  conventions.
- No explicit service-dependency wiring. Unlike
  `hosts/storage/hardware-configuration.nix:21-33` (where Docker
  explicitly depends on `/mnt/storage`), cottage should let services
  gracefully degrade if the pool is missing — with one critical
  exception below.

### 🚨 Write-to-wrong-location gotcha (restic-rest-server)

`services.restic.server.dataDir = "/mnt/storage/backups/restic-server"`.
With `nofail`, if `/mnt/storage` fails to mount at boot, that path
still exists as a regular directory on the root btrfs (SSD) and
restic-rest-server will happily create it and start accepting backups
into it. Storage's client will succeed, the backups will land on the
476 GB SSD instead of the 10 TB pool, and the SSD will fill up
silently.

**Fix:** add a systemd drop-in so `restic-rest-server.service` has
`RequiresMountsFor=/mnt/storage`. If the mount is missing, the service
fails cleanly, which triggers the existing email-on-failure alert.

```nix
systemd.services.restic-rest-server.unitConfig.RequiresMountsFor =
  "/mnt/storage";
```

### Unit-failure alerting is already free

The repo's `modules/systemd-email-notify.nix:83-92` auto-wires
`onFailure = ["email@%n.service"]` for **every** systemd service on
every host, rate-limited to 1 email per service per hour
(`modules/systemd-email-notify.nix:35`). Storage already runs with
`constellation.email.enable = true`, so:

- New `restic-backups-cottage.service` and
  `restic-backups-cottage-system.service` on storage → automatically
  email on failure.
- New `restic-rest-server.service` on cottage (where
  `constellation.email.enable = true`) → automatically emails if the
  mount-protection drop-in trips.

**No per-unit alerting wiring required.** This resolves the
"Fail with an alert" resolved-question from the brainstorm without
writing any new code.

### Firewall on cottage

Cottage does **not** disable `networking.firewall` globally (storage
does, which is why storage's port 8000 is implicitly reachable). We
expose port 8000 only on the Tailscale interface:

```nix
networking.firewall.interfaces.tailscale0.allowedTCPPorts = [8000];
```

Stricter than storage's own accidental exposure; matches the stated
"Tailscale-only" trust model from the brainstorm.

### Storage-side profile duplication (YAGNI on abstraction)

The two new profiles copy the exclusion lists from the existing
`hetzner-system` and `hetzner` profiles verbatim. **We deliberately do
not factor a shared helper.** Two near-identical blocks are clearer
than a parameterized factory and make it trivial to delete the Hetzner
half later when we decommission (see brainstorm Non-Goals).

Scope parity (see brainstorm: docs/brainstorms/2026-04-15-cottage-restic-rest-target-brainstorm.md):

| Profile         | Paths                   | Schedule | Retention                             |
|-----------------|-------------------------|----------|---------------------------------------|
| cottage-system  | `/` (same excludes as hetzner-system) | weekly + 1h jitter | `-d 7 -w 4 -m 6` |
| cottage         | `/home`, `/mnt/storage` (same excludes as hetzner) | weekly + 1h jitter | `-d 7 -w 4 -m 6` |

Matching `systemd.services` overrides to set
`TimeoutStartSec = "infinity"` (huge initial seeds) and
`IOSchedulingClass = "idle"` on the system one.

## System-Wide Impact

### Interaction graph

- **Cottage boot**: `sd*` → udev → btrfs device-scan → `mnt-storage.mount`
  → [if success] `restic-rest-server.service` starts and listens on
  `0.0.0.0:8000`; [if fail] `restic-rest-server.service` is blocked by
  `RequiresMountsFor` and `systemd-email-notify` sends an email.
- **Storage weekly timer** → `restic-backups-cottage.timer` fires →
  `restic-backups-cottage.service` → `rclone`-free restic call over
  Tailscale to `cottage.bat-boa.ts.net:8000` → cottage's
  `restic-rest-server.service` writes into
  `/mnt/storage/backups/restic-server/`.
- **Cottage rustic client** (now re-enabled via
  `constellation.backup.enable`) → weekly push of `/var/lib`, `/home`,
  `/root` → `storage.bat-boa.ts.net:8000` → storage's existing
  `restic-rest-server`. This was always the intent; it was blocked
  only because the backup module was disabled alongside the pool.

### Error propagation

- **Cottage offline during storage's weekly run**: restic client times
  out → unit fails → `email@restic-backups-cottage.service` fires →
  next week retries. `TimeoutStartSec=infinity` means a slow run is
  not a failed run.
- **Cottage pool missing**: `restic-rest-server.service` fails to
  start (blocked by `RequiresMountsFor`), email fires, no backups get
  written to wrong location. Boot still completes thanks to `nofail`.
- **Disk degraded (1 of 5 failed)**: pool keeps working (2-failure
  tolerance); smartd notifications surface the failing drive via the
  already-enabled `services.smartd.notifications.mail`.
- **Disk degraded (2 of 5 failed)**: pool is still readable; writes
  may or may not succeed depending on allocation. Priority action:
  physical replacement. Hetzner backup is still intact as the true
  safety net during validation.

### State lifecycle risks

- **Partial restic writes over flaky Tailscale**: restic's pack-file
  model handles interrupted transfers cleanly — a truncated pack
  isn't referenced by any index, so next run re-uploads. No orphan
  cleanup needed.
- **First-run repo init**: storage's client uses `initialize = true`
  (matching the existing Hetzner pattern). If cottage's repo directory
  doesn't exist yet, restic creates it on first connect.
- **Garage teardown**: removing the `garage` user/group, RPC secret,
  and admin token is safe because Garage never held real backups and
  its data directory (`/mnt/storage/backups/garage`) won't exist
  after the pool is recreated — there's nothing to clean up
  post-mkfs.

### API surface parity

Only one "API surface" exists: `services.restic.server` on port 8000.
Storage has it; cottage will have it. The restic client config on
storage is the only other consumer and gets two new profiles that are
structurally identical to the existing Hetzner ones.

### Integration test scenarios (manual — NixOS doesn't unit-test this)

1. **Cottage reboots with all disks present** → `/mnt/storage` mounts
   → `restic-rest-server.service` becomes active → storage's next
   weekly run succeeds.
2. **Cottage reboots with one disk yanked** → pool mounts degraded →
   `restic-rest-server.service` comes up → backups still land. smartd
   should notify about the missing device.
3. **Cottage reboots with two disks yanked** → pool still mounts →
   verify restic write path. This is the failure mode that RAID1c3
   exists to survive.
4. **Storage runs weekly job while cottage is powered off** →
   `restic-backups-cottage.service` fails → email arrives → next week
   retries and succeeds.
5. **Pool UUID changes** (post-repair / post-rebuild) → `fileSystems`
   entry stops matching → boot continues via `nofail` →
   `restic-rest-server` blocked → email. Requires human to update the
   UUID in the Nix config.

## Acceptance Criteria

### Data pool

- [x] `wipefs -a` run against all five pool disks (by-id paths) and
      `sgdisk --zap-all /dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2Y01G`
      run on the ex-ZFS drive.
- [x] `mkfs.btrfs -L cottage-data -d raid1c3 -m raid1c3 <5 by-id paths>`
      succeeds.
- [x] `btrfs filesystem show cottage-data` reports 5 devices, RAID1c3
      data profile, RAID1c3 metadata profile.
- [x] Filesystem UUID captured: `01cdd316-d539-42a4-b87c-de5d14d40c94`.
- [x] `mount -o compress=zstd,noatime LABEL=cottage-data /mnt/storage`
      succeeds; `btrfs filesystem usage` reports ~6.06 TiB estimated
      free (data ratio 3.00, metadata ratio 3.00).

### Garage teardown

- [x] `services.garage` block removed from
      `hosts/cottage/services/default.nix`.
- [x] `garage` user/group removed.
- [x] `garage-rpc-secret` and `garage-admin-token` removed from
      `secrets/sops/cottage.yaml` via `sops secrets/sops/cottage.yaml`.
      (Entire file deleted — those were its only entries.)
- [x] `garage-init` systemd oneshot removed from
      `hosts/cottage/backup/backup-server.nix`.
- [x] Related tmpfiles rules for `/mnt/storage/backups/garage` removed.
- [x] `nix build .#nixosConfigurations.cottage.config.system.build.toplevel`
      succeeds.

### Mount and client enable

- [x] `fileSystems."/mnt/storage"` declared in cottage config by UUID
      with `compress=zstd,noatime,nofail,x-systemd.device-timeout=30s`.
- [x] `./backup` import uncommented in
      `hosts/cottage/configuration.nix`.
- [x] `constellation.backup.enable = true` flipped on cottage.
- [x] "Disabled until data pool is recreated" comment removed from
      the backup-related lines.
- [ ] `just deploy cottage` succeeds; `systemctl status
      mnt-storage.mount` shows active on cottage. (deferred to Deploy phase)
- [ ] `systemctl list-timers | grep rustic` shows the constellation
      backup timer active on cottage. (deferred to Deploy phase)

### Restic REST server on cottage

- [x] `hosts/cottage/backup/backup-server.nix` now holds a
      `services.restic.server` block identical in shape to
      `hosts/storage/backup/backup-server.nix`, with dataDir
      `/mnt/storage/backups/restic-server`.
- [x] `systemd.services.restic-rest-server.unitConfig.RequiresMountsFor
      = "/mnt/storage"` drop-in present (verified via nix eval).
- [x] `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [8000]`
      added on cottage (verified via nix eval).
- [ ] `curl -s http://cottage.bat-boa.ts.net:8000/` from a Tailscale
      peer returns the restic-rest-server banner. (deferred to Deploy phase)
- [ ] `curl -s http://<cottage-lan-ip>:8000/` from outside Tailscale
      fails (firewall). (deferred to Deploy phase)

### Storage-side profiles

- [x] `cottage-system` profile added to
      `hosts/storage/backup/backup-restic.nix`, mirroring
      `hetzner-system` with `repository =
      "rest:http://cottage.bat-boa.ts.net:8000/"`. Both system
      profiles now share a common exclude list via `mkRemoteProfile`.
- [x] `cottage` profile added, mirroring `hetzner`. User profiles
      also share via `mkRemoteProfile`.
- [x] Both new units get `TimeoutStartSec = "infinity"` and the big
      user-data one gets `IOSchedulingClass = "idle"`.
- [x] `just deploy storage` succeeds (SSH session dropped mid-activation
      but the profile activated successfully on the host).
- [x] `systemctl list-timers | grep restic-backups-cottage` shows
      both timers active on storage. (Required manual `systemctl start`
      after the deploy — the activation didn't start them, likely due
      to the sshd/tailscaled restart cascade.)

### Validation

- [x] `systemctl start restic-backups-cottage-system` on storage
      completed in 1h 02m 50s; snapshot `dd4803eb` verified via
      `restic snapshots` over REST. 108.347 GiB stored, 559,845 files.
- [ ] First `restic-backups-cottage` run — **deferred** to first
      weekly slot at Mon 2026-04-20 00:33:18 EDT.
- [ ] Test restore — **skipped per user direction**.
- [ ] `restic prune` dry-run over REST — **skipped per user direction**.
- [ ] Simulated failure / alert smoke test — **skipped per user
      direction**. (Framework is free: `systemd-email-notify.nix`
      auto-wires `OnFailure=email@%n.service` for every service.)

## Success Metrics

- Two consecutive successful weekly runs of both cottage profiles.
- One successful point-in-time restore from the cottage repo.
- No `email@restic-backups-cottage*.service` emails during the
  validation window (i.e. no spurious failures).
- smartd stays quiet on all 5 pool disks through the validation
  window.

Once all four hold, the plan meets its bar and the Hetzner
decommission conversation is unblocked (out of scope here).

## Dependencies & Risks

### Dependencies

- **Cottage must be physically reachable over SSH** for Phase 0.
- **cottage's `constellation.email.enable`** is already on — prereq
  for unit-failure alerting to work.
- **restic-password** sops entry: already present in
  `secrets/sops/common.yaml:7` and used by
  `modules/constellation/backup.nix:76-77` via
  `config.constellation.sops.commonSopsFile`. **No new sops work
  required on cottage.** Storage's own copy is already declared at
  `hosts/storage/backup/backup-restic.nix:6`.

### Risks

- **🚨 Destructive disk operations (Phase 0).** Wiping five drives is
  irreversible. Global CLAUDE.md requires user confirmation before
  running `wipefs`, `sgdisk --zap-all`, or `mkfs.btrfs`. Plan-as-
  written must not run these without explicit approval. Cottage's
  disks hold no current data (verified: nothing mounted at
  `/mnt/storage`, no fstab entry, stale superblocks only), so risk is
  low, but the rule stands.
- **Old disks, long initial seed.** First `cottage` (user-data)
  profile run could take days over cottage's upstream. `TimeoutStart
  Sec=infinity` handles it; the only risk is an impatient human
  stopping the unit.
- **UUID drift.** If the pool is ever destroyed and recreated (e.g.
  after a double failure), the fileSystems UUID needs to be updated
  manually in the Nix config. Flagged in the runbook.
- **firewall default on cottage.** Unlike storage, cottage has
  `networking.firewall` enabled by default. If the Tailscale-scoped
  rule is mistyped, cottage becomes an ordinary LAN-exposed restic
  server. The acceptance criteria include a negative curl test from
  outside Tailscale.
- **No precedent in repo for multi-disk btrfs.** This plan is the
  first — no existing recipe to copy. Mitigation: the one-off mkfs
  is standard upstream btrfs, and mount-by-UUID matches storage.

## Files In Scope

### Modified

- `hosts/cottage/configuration.nix` — add `fileSystems."/mnt/storage"`,
  uncomment `./backup` import, flip `constellation.backup.enable = true`,
  delete the "disabled until data pool is recreated" comment.
- `hosts/cottage/backup/backup-server.nix` — **replace** Garage-era
  content with `services.restic.server` block, firewall rule, and
  `RequiresMountsFor` drop-in.
- `hosts/cottage/backup/default.nix` — drop the Garage-era comment,
  keep the `./backup-server.nix` import.
- `hosts/cottage/services/default.nix` — remove `services.garage`,
  `garage` user/group, garage sops secret declarations.
- `secrets/sops/cottage.yaml` — delete `garage-rpc-secret` and
  `garage-admin-token` entries via `sops secrets/sops/cottage.yaml`.
- `hosts/storage/backup/backup-restic.nix` — add two new profiles
  (`cottage-system`, `cottage`) copying the Hetzner exclusion lists,
  pointing at `rest:http://cottage.bat-boa.ts.net:8000/`. Add matching
  `systemd.services` overrides.

### Not modified (intentional)

- `hosts/cottage/disko-config.nix` — leaves the "Storage disks not
  managed by disko" decision in place.
- `modules/constellation/backup.nix` — cottage plugs into the existing
  client-side module as-is; no helper factoring.
- `hosts/storage/backup/backup-server.nix` — storage's existing restic
  server is unchanged; cottage mirrors its shape but doesn't replace
  it.

## Runbook (Phase-by-Phase)

### Phase 0 — Data pool (manual, on cottage, destructive 🚨)

**Requires explicit user confirmation before running.**

Pool members (by-id, captured 2026-04-15):

```
/dev/disk/by-id/ata-ST4000VN000-1H4168_Z3051HFQ   # sdb
/dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2WDVD   # sdd
/dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K7HJ9TV6  # sde
/dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2Y01G   # sdf (ex-ZFS, needs sgdisk)
/dev/disk/by-id/ata-ST4000VN000-1H4168_Z304SS33   # sdg
```

```bash
ssh root@cottage

# 1. Clear stale bcachefs superblocks and GPT headers
wipefs -a /dev/disk/by-id/ata-ST4000VN000-1H4168_Z3051HFQ \
         /dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2WDVD \
         /dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K7HJ9TV6 \
         /dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2Y01G \
         /dev/disk/by-id/ata-ST4000VN000-1H4168_Z304SS33

# 2. sdf specifically has a ZFS-era GPT partition table — zap it
sgdisk --zap-all /dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2Y01G

# 3. Create the pool
mkfs.btrfs -L cottage-data -d raid1c3 -m raid1c3 \
  /dev/disk/by-id/ata-ST4000VN000-1H4168_Z3051HFQ \
  /dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2WDVD \
  /dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K7HJ9TV6 \
  /dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2Y01G \
  /dev/disk/by-id/ata-ST4000VN000-1H4168_Z304SS33

# 4. Capture the UUID (save this for Phase 2)
btrfs filesystem show cottage-data
# -> copy the UUID value

# 5. Sanity mount
mkdir -p /mnt/storage
mount -o compress=zstd,noatime LABEL=cottage-data /mnt/storage
df -h /mnt/storage   # should report ~6.67 TB
umount /mnt/storage
```

### Phase 1 — Garage teardown commit

1. Edit `hosts/cottage/services/default.nix`: remove `services.garage`,
   `users.users.garage`, `users.groups.garage`, the two
   `sops.secrets.garage-*` entries, and the `systemd.tmpfiles.rules`
   for the garage data dir.
2. Edit `hosts/cottage/backup/backup-server.nix`: temporarily leave it
   as a stub (or skip to Phase 3 directly — see "Ordering note" below).
3. `nix develop -c sops secrets/sops/cottage.yaml` — delete
   `garage-rpc-secret` and `garage-admin-token`.
4. `nix develop -c just build cottage` — look at the last line for
   error count; expect zero.
5. Commit: `chore(cottage): remove half-baked Garage setup`.

**Ordering note:** Phase 1 and Phase 3 can be collapsed into a single
commit that replaces the Garage `backup-server.nix` with the new
restic-server version in one atomic change. Split only if desirable
for bisectability.

### Phase 2 — Mount + client enable commit

1. Edit `hosts/cottage/configuration.nix`:
   - Uncomment `./backup` import.
   - Set `constellation.backup.enable = true`.
   - Remove the "Disabled until data pool is recreated" comment.
   - Add a new top-level block:
     ```nix
     fileSystems."/mnt/storage" = {
       device = "/dev/disk/by-uuid/<UUID-FROM-PHASE-0>";
       fsType = "btrfs";
       options = [
         "compress=zstd"
         "noatime"
         "nofail"
         "x-systemd.device-timeout=30s"
       ];
     };
     ```
2. `nix develop -c just build cottage` — verify zero errors.
3. `just deploy cottage`.
4. On cottage: `systemctl status mnt-storage.mount` → active;
   `systemctl list-timers | grep rustic` → rustic@storage timer listed.
5. Commit: `feat(cottage): mount btrfs RAID1c3 data pool and re-enable
   constellation backup`.

### Phase 3 — Restic REST server commit

1. Replace `hosts/cottage/backup/backup-server.nix` with:
   ```nix
   {...}: {
     services.restic.server = {
       enable = true;
       extraFlags = ["--no-auth"];
       dataDir = "/mnt/storage/backups/restic-server";
     };

     networking.firewall.interfaces.tailscale0.allowedTCPPorts = [8000];

     systemd.services.restic-rest-server.unitConfig.RequiresMountsFor =
       "/mnt/storage";
   }
   ```
2. Ensure `hosts/cottage/backup/default.nix` still imports
   `./backup-server.nix` and has no Garage-era comments.
3. `nix develop -c just build cottage` → zero errors.
4. `just deploy cottage`.
5. On cottage: `systemctl status restic-rest-server` → active.
6. From a Tailscale peer: `curl -s http://cottage.bat-boa.ts.net:8000/`
   → returns restic-rest-server banner.
7. Commit: `feat(cottage): run services.restic.server as second offsite
   target`.

### Phase 4 — Storage-side profiles commit

1. Edit `hosts/storage/backup/backup-restic.nix`: after the existing
   `hetzner` profile, add:
   ```nix
   cottage-system = {
     paths = ["/"];
     exclude = [ /* same list as hetzner-system */ ];
     repository = "rest:http://cottage.bat-boa.ts.net:8000/";
     passwordFile = config.sops.secrets."restic-password".path;
     initialize = true;
     timerConfig = {
       OnCalendar = "weekly";
       RandomizedDelaySec = "1h";
     };
     pruneOpts = [
       "--keep-daily 7"
       "--keep-weekly 4"
       "--keep-monthly 6"
     ];
   };

   cottage = {
     paths = ["/home" "/mnt/storage"];
     exclude = [ /* same list as hetzner */ ];
     repository = "rest:http://cottage.bat-boa.ts.net:8000/";
     passwordFile = config.sops.secrets."restic-password".path;
     initialize = true;
     timerConfig = {
       OnCalendar = "weekly";
       RandomizedDelaySec = "1h";
     };
     pruneOpts = [
       "--keep-daily 7"
       "--keep-weekly 4"
       "--keep-monthly 6"
     ];
   };
   ```
   Do **not** refactor the shared exclusion lists into a `let` binding
   — keep the copies distinct.
2. Extend the `systemd.services` block at the bottom of the file:
   ```nix
   restic-backups-cottage.serviceConfig = {
     TimeoutStartSec = "infinity";
   };
   restic-backups-cottage-system.serviceConfig = {
     TimeoutStartSec = "infinity";
     IOSchedulingClass = "idle";
   };
   ```
3. `nix develop -c just build storage` → zero errors.
4. `just deploy storage`.
5. Verify timers present on storage.
6. Commit: `feat(storage): add cottage as second offsite restic
   target`.

### Phase 5 — Validation

1. **Small one first:**
   `ssh root@storage systemctl start restic-backups-cottage-system`.
   Watch with `journalctl -u restic-backups-cottage-system -f`.
2. Snapshot check from any machine with `restic` and the password:
   ```
   restic -r rest:http://cottage.bat-boa.ts.net:8000/ snapshots
   ```
3. **Big one:** let it run on schedule, or kick it off manually
   overnight.
4. **Practice restore:**
   ```
   restic -r rest:http://cottage.bat-boa.ts.net:8000/ restore latest \
     --target /tmp/cottage-test --include /home/arosenfeld/.bashrc
   ```
5. **Prune dry-run** (resolves open question 1):
   `restic -r rest:http://cottage.bat-boa.ts.net:8000/ prune
   --dry-run`.
6. **Failure-alert smoke test:** on cottage,
   `systemctl stop restic-rest-server`, then on storage
   `systemctl start restic-backups-cottage-system`. Expect a failure
   email within the hour. Re-enable restic-rest-server afterward.

## Open Questions Inherited from Brainstorm

1. **Prune over REST protocol** (see brainstorm: docs/brainstorms/2026-04-15-cottage-restic-rest-target-brainstorm.md).
   Validated in Phase 5 step 5. No special handling required — the
   server is not in `--append-only` mode.
2. **Hetzner decommission trigger.** Proposed success criteria: "2
   consecutive successful weekly runs of both cottage profiles + one
   successful restore drill + no failure emails during validation."
   Actual decommission is out of scope for this plan — captured here
   as a forward pointer for a follow-up PR.
3. **smartd monitored devices listing.** No precedent in the repo for
   `services.smartd.devices` — all current users let smartd auto-scan.
   Leaving auto-scan as-is for now; revisit if a disk silently drops
   out of monitoring after the pool is live.

## Non-Goals

- Not changing storage's local restic repo at
  `/mnt/storage/backups/restic`.
- Not touching the existing `constellation.backup` rustic module used
  by other hosts.
- Not backing up media (`/mnt/storage/media`) — same exclusion as
  Hetzner.
- Not introducing auth, append-only mode, or any new sops secrets on
  cottage.
- Not deduplicating the Hetzner and cottage profile definitions via a
  Nix helper — two copies now, delete one later.
- Not decommissioning Hetzner in this PR.
- Not managing the data pool via disko.

## Sources & References

### Origin

- **Brainstorm document:** `docs/brainstorms/2026-04-15-cottage-restic-rest-target-brainstorm.md`. Key decisions carried forward:
  1. btrfs RAID1c3 data + RAID1c3 metadata across all 5 drives;
  2. `services.restic.server --no-auth`, Tailscale-only;
  3. Full mirror of both Hetzner profiles, matching schedule +
     retention, no shared helper;
  4. Complete Garage teardown (config + sops secrets);
  5. Fail-with-alert for offline cottage (implemented for free via
     existing `systemd-email-notify` module).

### Internal references

- `hosts/storage/backup/backup-server.nix:1-7` — the template this
  plan mirrors for cottage.
- `hosts/storage/backup/backup-restic.nix:50-93` — `hetzner-system`
  profile template.
- `hosts/storage/backup/backup-restic.nix:96-170` — `hetzner`
  profile template.
- `hosts/storage/backup/backup-restic.nix:174-185` — existing
  `systemd.services` restic overrides pattern.
- `hosts/storage/hardware-configuration.nix:35-39` — `fileSystems`
  UUID + btrfs + `nofail` template.
- `modules/systemd-email-notify.nix:83-92` — auto-applied
  `onFailure = ["email@%n.service"]` for every service. No per-unit
  wiring needed.
- `modules/constellation/backup.nix:74-93` — client-only rustic
  module. Flipping enable on cottage produces only a client, not a
  server.
- `secrets/sops/common.yaml:7` — shared `restic-password` entry used
  by the client module.
- `hosts/cottage/configuration.nix:14,20` — the `./backup` import and
  `constellation.backup.enable = false` lines to flip.
- `hosts/cottage/services/default.nix:1-68` — current Garage config
  to tear out.
- `hosts/cottage/backup/backup-server.nix:1-75` — current Garage init
  oneshot to delete.
