# Restore Fleet Backup Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore fleet-wide backup functionality, prevent root ownership regressions during restic prunes, remove decommissioned Hetzner targets, and resolve Sunday lock contention.

**Architecture:** Fix on-disk permissions for `/mnt/storage/backups/restic-server` so `restic-rest-server` can read index/data packs; configure `galactica`'s `storage` Backrest repo to target `rest:http://127.0.0.1:8000/` instead of a local path so prune/check operations are mediated by `rest-server` under user `restic`; remove the decommissioned Hetzner repo, plans, and secrets from `galactica`; and stagger `pegasus`'s backup schedule off `basestar`'s slot.

**Tech Stack:** NixOS, Backrest, restic, restic-rest-server, rustic, systemd.

## Global Constraints

- No disruption to active backup repositories or existing snapshot data.
- Ensure all files written to `/mnt/storage/backups/restic-server` maintain `restic:restic` ownership.
- Maintain existing retention and check policies for valid targets.
- All configuration changes must pass evaluation on `nixosConfigurations`.

---

### Task 1: Fix Permissions on Galactica's Restic Server & Verify Client Connectivity

**Files:**
- Operational fix on `galactica` host

- [x] **Step 1: Fix ownership and permissions on `/mnt/storage/backups/restic-server`**

```bash
ssh galactica "sudo chown -R restic:restic /mnt/storage/backups/restic-server && sudo chmod -R u+rwX,go-rwx /mnt/storage/backups/restic-server"
```

- [x] **Step 2: Verify restic index is readable from clients**

Test from `raider`:
```bash
sudo backup-status
```
Expected: `storage` repository query succeeds without `500 Internal Server Error` or permission denied.

- [x] **Step 3: Trigger a backup from `raider` to verify end-to-end write and forget**

```bash
sudo systemctl restart backrest
```
Verify `journalctl -u backrest -n 30` or wait for the backup/query cycle.

---

### Task 2: Prevent Root-Ownership Recurrence on Galactica

**Files:**
- Modify: `hosts/galactica/backup/backrest-client.nix:158-169`

- [x] **Step 1: Update `storage` repo URI in `backrest-client.nix`**

Change `storage.uri` from `/mnt/storage/backups/restic-server` to `rest:http://127.0.0.1:8000/` and update comments explaining that routing through `rest-server` preserves `restic:restic` ownership during scheduled prune and check tasks.

- [x] **Step 2: Verify `nix eval .#nixosConfigurations.galactica.config.system.build.toplevel`**

```bash
nix eval .#nixosConfigurations.galactica.config.system.build.toplevel
```

- [x] **Step 3: Commit**

```bash
git add hosts/galactica/backup/backrest-client.nix
git commit -m "fix(galactica): route storage repo through rest server to preserve restic permissions"
```

---

### Task 3: Remove Decommissioned Hetzner Backup Configuration

**Files:**
- Modify: `hosts/galactica/backup/backrest-client.nix`
- Modify: `docs/architecture/backup.md`

- [x] **Step 1: Remove Hetzner repo, plans, and secrets from `backrest-client.nix`**

Remove:
- `sops.secrets."hetzner-webdav-env"`
- `sops.secrets."hetzner-storagebox-ssh-key"`
- `constellation.backrest.repos.hetzner`
- `constellation.backrest.plans.hetzner-system`
- `constellation.backrest.plans.hetzner`

- [x] **Step 2: Update `docs/architecture/backup.md`**

Update the architecture document to remove references to the Hetzner Storage Box and note that offsite archive is handled by OVHcloud Cold Archive via `rustic`.

- [x] **Step 3: Verify evaluation of galactica**

```bash
nix eval .#nixosConfigurations.galactica.config.system.build.toplevel
```

- [x] **Step 4: Commit**

```bash
git add hosts/galactica/backup/backrest-client.nix docs/architecture/backup.md
git commit -m "refactor(galactica): remove decommissioned hetzner storage box backup config"
```

---

### Task 4: Stagger Sunday Backup Schedules to Eliminate Lock Collisions

**Files:**
- Modify: `hosts/pegasus/backup/backup-client.nix:44`

- [x] **Step 1: Update `pegasus` system plan cron schedule**

Change `schedule.cron` in `hosts/pegasus/backup/backup-client.nix` from `"30 3 * * 0"` to `"00 4 * * 0"` to avoid colliding with `basestar`'s daily `"30 3 * * *"` run on the shared `storage` repository.

- [x] **Step 2: Verify evaluation of pegasus**

```bash
nix eval .#nixosConfigurations.pegasus.config.system.build.toplevel
```

- [x] **Step 3: Commit**

```bash
git add hosts/pegasus/backup/backup-client.nix
git commit -m "fix(pegasus): stagger sunday backup schedule to avoid lock collision with basestar"
```

---

### Task 5: Deploy and Verify Fleet Backup Status

- [x] **Step 1: Deploy to `galactica` and `pegasus`**

Deploy the updated configurations to `galactica` and `pegasus`.

- [x] **Step 2: Run `backup-status` across the fleet**

Check `sudo backup-status` on:
- `galactica` (verify `local`, `pegasus`, `storage`, `ovh` are monitored; `hetzner` is absent)
- `basestar` (verify `storage` and `pegasus` are monitored)
- `pegasus` (verify `storage` is monitored)
- `raider` (verify `storage` is monitored)
