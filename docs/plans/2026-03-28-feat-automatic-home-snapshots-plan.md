---
title: "feat: Automatic /home Snapshots on Raider"
type: feat
status: completed
date: 2026-03-28
origin: docs/brainstorms/2026-03-28-home-snapshots-brainstorm.md
---

# feat: Automatic /home Snapshots on Raider

## Overview

Add automatic btrfs snapshots of `/home` on raider using the NixOS `services.btrbk` module. This provides fast local recovery from accidental file deletions, complementing the existing Rustic remote backups.

## Problem Statement / Motivation

Raider has weekly remote backups via Rustic, but no local snapshot protection. If a file is accidentally deleted, recovery requires restoring from the remote backup server -- slow and potentially lossy (up to a week of data). Local btrfs snapshots provide instant, browsable file recovery.

## Proposed Solution

Create `hosts/raider/btrbk.nix` that:

1. Mounts the top-level btrfs volume (subvolid=5) of the Samsung 850 EVO at `/mnt/btrfs-home`
2. Configures btrbk to take hourly snapshots of the `/home` subvolume
3. Stores snapshots at `/mnt/btrfs-home/.snapshots/`
4. Applies tiered retention: 48 hourly, 7 daily, 4 weekly

### Why a top-level mount is needed

btrbk's `volume`/`subvolume` model requires the volume path to be a mount where the target subvolume is a visible child. Since `/home` is mounted as a subvolume directly (not as the top-level volume), btrbk cannot see it as a child of `/home`. Mounting the top-level (subvolid=5) at `/mnt/btrfs-home` exposes the `home` subvolume to btrbk.

## Technical Considerations

### Filesystem layout

- The Samsung 850 EVO 1TB has one btrfs partition with a single subvolume `/home`
- Top-level volume mount at `/mnt/btrfs-home` uses `subvolid=5`, matching `/home`'s mount options (`compress=zstd`, `noatime`)
- No `nofail` needed -- the existing `/home` mount already hard-depends on this SSD; if the disk fails, the system cannot function regardless

### Rustic interaction

- Rustic backs up `/var/lib`, `/home`, `/root` with a glob exclusion `!/mnt`
- Snapshots at `/mnt/btrfs-home/.snapshots/` are outside Rustic's source paths entirely
- No Rustic configuration changes needed

### btrbk configuration details

- `snapshotOnly = true` -- local snapshots only, no remote backup target
- `onCalendar = "hourly"` -- systemd timer fires every hour
- `timestamp_format = "long"` -- produces `home.20260328T1200` style names (day-only default is insufficient for hourly)
- `snapshot_preserve_min = "2d"` -- keep ALL snapshots unconditionally for 2 days (must be set explicitly; btrbk defaults to `"all"` which never deletes)
- `snapshot_preserve = "48h 7d 4w"` -- tiered retention beyond the 2-day floor
- Snapshot directory (`.snapshots`) must be pre-created via `systemd.tmpfiles.rules` with 0755 permissions (btrbk does not create it)

### Recovery workflow

To recover a deleted file:
```bash
# Browse available snapshots
ls /mnt/btrfs-home/.snapshots/

# Find and copy the file
cp /mnt/btrfs-home/.snapshots/home.20260328T1200/arosenfeld/path/to/file ~/path/to/file
```

## Acceptance Criteria

- [x] `hosts/raider/btrbk.nix` created with btrbk instance configuration
- [x] Top-level btrfs volume mounted at `/mnt/btrfs-home` via `fileSystems`
- [x] Snapshot directory `/mnt/btrfs-home/.snapshots/` pre-created with 0755 permissions
- [x] btrbk configured with `snapshotOnly = true`, hourly timer, tiered retention
- [x] `timestamp_format = "long"` for hourly-granularity snapshot names
- [x] `btrbk.nix` imported in `hosts/raider/configuration.nix`
- [x] Configuration builds: `nix build .#nixosConfigurations.raider.config.system.build.toplevel`
- [x] btrbk added to `environment.systemPackages` for CLI access (dry-run, manual snapshot)

## MVP

### hosts/raider/btrbk.nix

```nix
# Automatic btrfs snapshots of /home using btrbk
# Provides fast local recovery from accidental file deletions.
# Snapshots browsable at /mnt/btrfs-home/btrbk_snapshots/
{pkgs, ...}: {
  # Mount the top-level btrfs volume so btrbk can see the /home subvolume
  fileSystems."/mnt/btrfs-home" = {
    device = "/dev/disk/by-id/ata-Samsung_SSD_850_EVO_1TB_S3PJNF0J907619X-part1";
    fsType = "btrfs";
    options = ["subvolid=5" "noatime" "compress=zstd"];
  };

  # Pre-create the snapshot directory (btrbk does not create it)
  systemd.tmpfiles.rules = [
    "d /mnt/btrfs-home/.snapshots 0755 root root"
  ];

  services.btrbk.instances."home" = {
    onCalendar = "hourly";
    snapshotOnly = true;
    settings = {
      timestamp_format = "long";
      snapshot_preserve_min = "2d";
      snapshot_preserve = "48h 7d 4w";
      volume."/mnt/btrfs-home" = {
        snapshot_dir = ".snapshots";
        subvolume."home" = {};
      };
    };
  };

  environment.systemPackages = [pkgs.btrbk];
}
```

### hosts/raider/configuration.nix (import change)

Add `./btrbk.nix` to the imports list:

```nix
imports = [
  ./hardware-configuration.nix
  ./disko-config.nix
  ./btrbk.nix
  ./fan-control.nix
  # ... rest of imports
];
```

## Success Metrics

- Snapshots are created hourly and visible at `/mnt/btrfs-home/btrbk_snapshots/`
- Old snapshots are pruned according to the retention policy
- No noticeable performance impact on desktop usage

## Dependencies & Risks

- **Disk space**: Snapshots are CoW and only consume space for changed blocks. On a 1TB drive, tiered retention (max ~59 snapshots) should be minimal overhead for typical /home usage. Heavy churn (large file downloads/deletions) could increase consumption.
- **Not a backup**: Snapshots reside on the same physical disk. Disk failure destroys both data and all snapshots. Rustic remote backups remain essential for disaster recovery.
- **Device path**: The `fileSystems` entry uses the disko-assigned partition path (`-part1`). If disko regenerates partition layout, this may need updating.

## Sources & References

- **Origin brainstorm:** [docs/brainstorms/2026-03-28-home-snapshots-brainstorm.md](docs/brainstorms/2026-03-28-home-snapshots-brainstorm.md) -- decided on btrbk over snapper/custom timers, raider-only scope, tiered retention
- NixOS btrbk module: `<nixpkgs>/nixos/modules/services/backup/btrbk.nix`
- btrbk retention docs: https://digint.ch/btrbk/doc/btrbk.conf.5.html
- Raider disko config: `hosts/raider/disko-config.nix`
- Rustic backup module: `modules/constellation/backup.nix` (existing `/mnt` exclusion covers snapshot path)
