# Immich → Pixel Photo Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage the last 30 days of one Immich user's photos and videos into a flat directory on galactica — muxing Apple Live Photo pairs into Google Motion Photos — hand that directory to Syncthing for a Pixel 3 XL to pick up, and retire Resilio Sync.

**Architecture:** One new NixOS module, `constellation.immichPixelSync`, runs an hourly oneshot that queries Immich's Postgres directly and reconciles a flat staging directory against the result. Plain assets are hardlinked from Immich's library; Live Photo pairs are reflink-copied, given Motion Photo XMP by exiftool, and get their MOV appended in an `mpvd` box. Nothing ever writes into Immich's library. A separate `sendonly` Syncthing folder — declared where Syncthing already lives, not in the module — carries the directory to the phone.

**Tech Stack:** NixOS modules (haumea auto-discovery), Python 3 stdlib, `psql` (peer auth as the `immich` role), exiftool 13.x, btrfs reflinks/hardlinks, systemd timers, Syncthing.

**Source spec:** `docs/superpowers/specs/2026-07-26-immich-pixel-photo-sync-design.md`

---

## Deviations from the approved design

Five, all verified before writing this plan. Read these first — if any is unwelcome, say so before Task 3.

**1. No custom `.ExifTool_config` is needed.** The spec says `XMP-Container` is absent from exiftool and ships a custom config to add it. It checked the wrong group name. exiftool 13.59 already ships the namespace as **`XMP-GContainer`**, and the tag is named **`ContainerDirectory`** (id `Directory`, name `ContainerDirectory`). Verified end-to-end on a real HEIC:

```
$ exiftool -XMP-GCamera:MotionPhoto=1 \
    '-XMP-GContainer:ContainerDirectory=[{Item={Mime=image/heic,Semantic=Primary,Length=0,Padding=8}},{Item={Mime=video/quicktime,Semantic=MotionPhoto,Length=512,Padding=0}}]' \
    mux.heic
    1 image files updated
```

produces exactly the spec's RDF with the right namespace URIs (`http://ns.google.com/photos/1.0/container/` and `.../container/item/`); the `GContainer:`/`GItem:` prefixes differ from the spec's `Container:`/`Item:` but XML prefixes are arbitrary — the URIs are what Google's parser reads. Appending `struct.pack('>I', 8+len(video)) + b'mpvd' + video` afterwards leaves the file still parsing as `FileType: HEIC` with the container XMP intact. This deletes a whole component from the design.

**2. No `.state.json` manifest.** The staging directory listing *is* the state. Every staged filename is a pure function of its asset row (`ts_uuid8_stem[.MP].ext`), so reconciling is `set(desired_filenames)` vs `set(os.listdir())`. Files are only ever created by atomic rename or `os.link`, so a file present is a file complete. This preserves every behaviour the spec asks for — add/keep/delete, shrink guard, empty-result abort — and removes the "manifest and disk disagree" failure mode, which matters more than usual for a system whose bug deletes photos off a phone.

**3. Python lives in a sibling `.py` file, not inline in the Nix string.** The spec says "inline Python, following the `tablet-sync.nix` idiom", but the spec also requires unit tests for the reconciler, and inline Nix strings are not testable. `hosts/galactica/scripts/btrfs-convert-to-subvolume.{nix,py}` and `packages/check-stock/` are both existing precedents for a separate `.py`. Config reaches the script through environment variables set by the wrapper, so the pure functions stay import-clean.

**4. The Syncthing folder is declared in `hosts/galactica/services/files.nix`, not in the module.** The spec's own words: "the stager knows nothing about Syncthing." files.nix is where `services.syncthing` already lives. This also surfaces a hazard the spec did not: galactica's existing Syncthing folders (`photosync`, `Photos`) were created through the GUI, and `services.syncthing.overrideFolders` defaults to `true` — declaring *any* folder in Nix would **delete** them. Task 12 sets `overrideFolders = false` and `overrideDevices = false`.

**5. No log file, journald only.** `tablet-sync` writes a `.tablet-sync.log` into its sync directory. Here that directory is a Syncthing folder that Google Photos backs up, so a log file would sync to the phone. The unit is a systemd oneshot; `journalctl -u immich-pixel-sync` is the log.

---

## File structure

| File | Responsibility |
|---|---|
| `modules/constellation/immich-pixel-sync/default.nix` | NixOS module: options, wrapper package, tmpfiles, systemd service + timer. Knows nothing about Syncthing. |
| `modules/constellation/immich-pixel-sync/sync.py` | Everything else: selector query, naming, reconciler, muxer, stager, CLI. Pure functions kept free of globals so they are testable. |
| `modules/constellation/immich-pixel-sync/test_sync.py` | stdlib `unittest` over the pure functions plus one tmpdir hardlink test. No database, no exiftool — runs hermetically in a flake check. |
| `hosts/galactica/configuration.nix` | Enables the module and supplies the owner UUID. |
| `hosts/galactica/services/files.nix` | The `sendonly` Syncthing folder and the Pixel device. |
| `flake-modules/checks.nix` | Wires `test_sync.py` into `nix flake check`. |
| `justfile` | `just immich-pixel-sync-test`. |
| `hosts/galactica/services/media.nix`, `hosts/galactica/services/glance.nix`, `hosts/basestar/services/gatus.nix` | Resilio removal. |

haumea auto-loads `modules/`, so `default.nix` needs no explicit import. Non-`.nix` files are ignored by haumea's matcher (proof: `modules/constellation/pia-ca.rsa.4096.crt` exists today and galactica builds), so the `.py` files sit safely alongside it.

---

## Task 1: Verify the selector query against the live database

The spec's SQL was written against Immich 2.x table names measured on 2026-07-26. Confirm before building on it. Read-only; nothing to commit.

**Files:** none.

- [ ] **Step 1: Confirm the `asset` table and the columns the query needs exist**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media psql -X -h /run/postgresql -U immich -d immich' <<'SQL'
\d asset
SQL
```

Expected: a table description listing `id`, `ownerId`, `originalPath`, `originalFileName`, `fileCreatedAt`, `livePhotoVideoId`, `deletedAt`, `status`, `isOffline`.

If the table is called `assets` (Immich 1.x) rather than `asset`, every `asset` in the SQL constants below becomes `assets`. Note it and carry the change through Task 7.

- [ ] **Step 2: Confirm the owner UUID resolves to the right account**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media psql -X -A -t -h /run/postgresql -U immich -d immich' <<'SQL'
SELECT id, email FROM "user" ORDER BY email;
SQL
```

Expected: two rows; `alex@rosenfeld.one` should map to `c85fe467-a36a-457a-a260-a67dfe2199da`. Record whatever UUID it actually reports — that value goes into `hosts/galactica/configuration.nix` in Task 3.

If the table is `users` rather than `user`, adjust this one-off query; nothing in the module reads it.

- [ ] **Step 3: Run the real selector query and sanity-check the shape**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media psql -X -A -t -h /run/postgresql -U immich -d immich -v owner=c85fe467-a36a-457a-a260-a67dfe2199da -v days=30' <<'SQL'
SELECT count(*) FILTER (WHERE live_video IS NOT NULL) AS pairs,
       count(*)                                       AS total
FROM (
  SELECT a.id, v."originalPath" AS live_video
  FROM asset a
  LEFT JOIN asset v ON v.id = a."livePhotoVideoId"
  WHERE a."ownerId" = :'owner'::uuid
    AND a."deletedAt" IS NULL
    AND a.status = 'active'
    AND NOT a."isOffline"
    AND a."fileCreatedAt" > now() - make_interval(days => :days)
    AND NOT EXISTS (SELECT 1 FROM asset p WHERE p."livePhotoVideoId" = a.id)
) t;
SQL
```

Expected: `total` in the neighbourhood of 1,857 (the spec's measured 30-day count), `pairs` a healthy fraction of it. If `total` is 0, the window or the owner UUID is wrong — stop and re-check Step 2 before continuing.

- [ ] **Step 4: Grab one live pair to use in Task 2**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media psql -X -A -t -F"|" -h /run/postgresql -U immich -d immich -v owner=c85fe467-a36a-457a-a260-a67dfe2199da' <<'SQL'
SELECT a."originalPath", v."originalPath"
FROM asset a
JOIN asset v ON v.id = a."livePhotoVideoId"
WHERE a."ownerId" = :'owner'::uuid
  AND a."deletedAt" IS NULL
  AND lower(a."originalPath") LIKE '%.heic'
ORDER BY a."fileCreatedAt" DESC
LIMIT 1;
SQL
```

Expected: one line, two absolute paths under `/mnt/storage/files/Immich/library/`, separated by `|`. Keep both paths.

---

## Task 2: Prove the Motion Photo format on a real pair

**Format validation gates everything.** Every other decision is downstream of Google Photos rendering this as a Motion Photo. The bytes are provable now; the Google Photos half needs the phone and is Task 13.

**Files:**
- Create (throwaway, not committed): `/tmp/mux-probe.py` on galactica

- [ ] **Step 1: Write the probe script to galactica**

Substitute the two paths from Task 1 Step 4 into `IMAGE` and `VIDEO` in the heredoc below **before** running it — the heredoc is quoted, so nothing in it is expanded locally.

```bash
ssh root@galactica.bat-boa.ts.net 'cat > /tmp/mux-probe.py' <<'PY'
#!/usr/bin/env python3
"""One-shot proof that the mux produces a file Google Photos will accept."""
import os
import struct
import subprocess
import sys

IMAGE = "/mnt/storage/files/Immich/library/admin/REPLACE/ME.heic"
VIDEO = "/mnt/storage/files/Immich/library/admin/REPLACE/ME.mov"
OUT = "/tmp/probe/PROBE.MP.heic"

os.makedirs("/tmp/probe", exist_ok=True)
subprocess.run(["cp", "--reflink=auto", "--", IMAGE, OUT], check=True)

video = open(VIDEO, "rb").read()
directory = (
    "[{Item={Mime=image/heic,Semantic=Primary,Length=0,Padding=8}},"
    "{Item={Mime=video/quicktime,Semantic=MotionPhoto,Length=" + str(len(video)) + ",Padding=0}}]"
)
subprocess.run([
    "exiftool", "-overwrite_original", "-q",
    "-XMP-GCamera:MotionPhoto=1",
    "-XMP-GCamera:MotionPhotoVersion=1",
    "-XMP-GCamera:MotionPhotoPresentationTimestampUs=-1",
    "-XMP-GContainer:ContainerDirectory=" + directory,
    OUT,
], check=True)

with open(OUT, "ab") as fh:
    fh.write(struct.pack(">I", 8 + len(video)) + b"mpvd" + video)

data = open(OUT, "rb").read()
idx = data.rfind(b"mpvd")
declared = struct.unpack(">I", data[idx - 4:idx])[0]
print("image bytes :", os.path.getsize(IMAGE))
print("video bytes :", len(video))
print("output bytes:", len(data))
print("mpvd offset :", idx - 4)
print("declared len:", declared, "expected", 8 + len(video))
print("video intact:", data[idx + 4:] == video)
sys.exit(0 if declared == 8 + len(video) and data[idx + 4:] == video else 1)
PY
```

- [ ] **Step 2: Run it**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media python3 /tmp/mux-probe.py'
```

Expected: `declared len` equals `8 + video bytes`, `video intact: True`, exit 0.

If it exits with `FileNotFoundError`, the `IMAGE`/`VIDEO` constants were not substituted — redo Step 1.

- [ ] **Step 3: Confirm exiftool round-trips the container**

```bash
ssh root@galactica.bat-boa.ts.net 'exiftool -s -struct -FileType -XMP-GCamera:all -XMP-GContainer:all /tmp/probe/PROBE.MP.heic'
```

Expected, exactly this shape:

```
FileType                        : HEIC
MotionPhoto                     : 1
MotionPhotoPresentationTimestampUs: -1
MotionPhotoVersion              : 1
ContainerDirectory              : [{Item={Length=0,Mime=image/heic,Padding=8,Semantic=Primary}},{Item={Length=<video bytes>,Mime=video/quicktime,Padding=0,Semantic=MotionPhoto}}]
```

If `ContainerDirectory` is missing, exiftool on this host lacks `XMP-GContainer` — check `exiftool -ver` (needs 13.x) and `exiftool -listx -XMP-GContainer:all`. Only then does the spec's custom `.ExifTool_config` become necessary; stop and re-plan Task 8 if so.

- [ ] **Step 4: Confirm the source is untouched**

```bash
ssh root@galactica.bat-boa.ts.net 'stat -c "%n %i %s" /tmp/probe/PROBE.MP.heic <image path>'
```

Expected: two different inode numbers, and the source's size unchanged from Step 2's `image bytes`.

- [ ] **Step 5: Pull the file down for the Task 13 sideload**

```bash
scp root@galactica.bat-boa.ts.net:/tmp/probe/PROBE.MP.heic ~/PROBE.MP.heic
```

Keep it. Task 13 copies it to the Pixel by hand and confirms Google Photos renders it as a Motion Photo with HDR intact — that is the real gate, and it can happen in parallel with the rest of this plan.

No commit for this task.

---

## Task 3: Scaffold the module

Get a buildable skeleton in place: real options, real systemd unit, a `sync.py` that only parses arguments. This proves haumea picks up the new directory and that the option types check out before any logic exists.

**Files:**
- Create: `modules/constellation/immich-pixel-sync/default.nix`
- Create: `modules/constellation/immich-pixel-sync/sync.py`
- Create: `modules/constellation/immich-pixel-sync/test_sync.py`
- Modify: `hosts/galactica/configuration.nix`

- [ ] **Step 1: Write the module**

Create `modules/constellation/immich-pixel-sync/default.nix`:

```nix
# Immich → Pixel photo staging
#
# Builds a flat staging directory that is a pure function of one Immich query:
# every asset owned by `ownerId` whose `fileCreatedAt` falls inside a rolling
# window. Apple Live Photo pairs are muxed into Google Motion Photos so they
# arrive in Google Photos as a single item; everything else is hardlinked.
#
# The staging directory is the interface. This module knows nothing about
# Syncthing — declare the folder wherever Syncthing is configured (on galactica
# that is hosts/galactica/services/files.nix).
#
# Nothing here ever writes into Immich's library: plain assets are hardlinked,
# and muxed ones are reflink-copied into a scratch directory first.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.immichPixelSync;

  # Sibling of the staging directory, so reflink copies and the final rename stay
  # on one filesystem while staying outside the tree Syncthing exports.
  tmpDirectory = "${cfg.stagingDirectory}.tmp";
  stateDirectory = "/var/lib/immich-pixel-sync";

  immichPixelSync = pkgs.writeShellApplication {
    name = "immich-pixel-sync";
    runtimeInputs = [pkgs.coreutils pkgs.exiftool cfg.database.package];
    text = ''
      export IPS_STAGING_DIR=${escapeShellArg cfg.stagingDirectory}
      export IPS_TMP_DIR=${escapeShellArg tmpDirectory}
      export IPS_LOCK_FILE=${escapeShellArg "${stateDirectory}/lock"}
      export IPS_OWNER_ID=${escapeShellArg cfg.ownerId}
      export IPS_WINDOW_DAYS=${toString cfg.windowDays}
      export IPS_SHRINK_GUARD_PERCENT=${toString cfg.shrinkGuardPercent}
      export IPS_DB_NAME=${escapeShellArg cfg.database.name}
      export IPS_DB_USER=${escapeShellArg cfg.database.user}
      export IPS_DB_SOCKET=${escapeShellArg cfg.database.socketDirectory}
      exec ${pkgs.python3}/bin/python3 ${./sync.py} "$@"
    '';
  };
in {
  options.constellation.immichPixelSync = {
    enable = mkEnableOption "staging recent Immich assets for a Pixel via Syncthing";

    ownerId = mkOption {
      type = types.str;
      example = "c85fe467-a36a-457a-a260-a67dfe2199da";
      description = ''
        Immich `asset."ownerId"` UUID whose assets are staged. Only this user's
        assets are ever copied; every other user's stay where they are.

        This is the account UUID, not the storage label — Immich names the
        on-disk directory from the OIDC `preferred_username` claim, which can
        change without warning. Paths are always read from the database.
      '';
    };

    stagingDirectory = mkOption {
      type = types.path;
      default = "/mnt/storage/files/PixelPhotoStage";
      description = ''
        Flat directory holding the staged assets. Must be on the same filesystem
        as Immich's library so hardlinks and reflinks work. Export this with
        Syncthing as a `sendonly` folder.
      '';
    };

    windowDays = mkOption {
      type = types.ints.positive;
      default = 30;
      description = ''
        Rolling window, in days, over `fileCreatedAt`. Assets that fall out of it
        are deleted from the staging directory — and therefore from the Pixel —
        on the next run. The phone is a buffer, not an archive.
      '';
    };

    shrinkGuardPercent = mkOption {
      type = types.ints.between 0 100;
      default = 50;
      description = ''
        Abort the run if it would shrink the staged set by more than this
        percentage, rather than mass-deleting off the phone. Skipped when the
        staging directory is empty, so first runs are never blocked. Override a
        single run with `immich-pixel-sync --force`.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "hourly";
      description = "systemd `OnCalendar` expression for the staging timer.";
    };

    user = mkOption {
      type = types.str;
      default = "media";
      description = ''
        User to run as. Must own Immich's library files (hardlinking someone
        else's file is refused by `fs.protected_hardlinks`) and must map to the
        Immich database role in PostgreSQL's ident map.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "media";
      description = "Group to run as.";
    };

    database = {
      name = mkOption {
        type = types.str;
        default = "immich";
        description = "Immich database name.";
      };

      user = mkOption {
        type = types.str;
        default = "immich";
        description = "PostgreSQL role to connect as, via peer auth over the socket.";
      };

      socketDirectory = mkOption {
        type = types.path;
        default = "/run/postgresql";
        description = "PostgreSQL unix socket directory.";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.postgresql;
        defaultText = literalExpression "pkgs.postgresql";
        description = "Package providing the `psql` client.";
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [immichPixelSync];

    systemd.tmpfiles.rules = [
      "d ${cfg.stagingDirectory} 0775 ${cfg.user} ${cfg.group} -"
      "d ${tmpDirectory} 0775 ${cfg.user} ${cfg.group} -"
      "d ${stateDirectory} 0755 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.immich-pixel-sync = {
      description = "Stage recent Immich assets for the Pixel";
      after = ["postgresql.service" "mnt-storage.mount"];
      requires = ["postgresql.service" "mnt-storage.mount"];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${immichPixelSync}/bin/immich-pixel-sync";
        User = cfg.user;
        Group = cfg.group;
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.immich-pixel-sync = {
      description = "Immich → Pixel staging timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
```

- [ ] **Step 2: Write the script skeleton**

Create `modules/constellation/immich-pixel-sync/sync.py`:

```python
#!/usr/bin/env python3
"""Stage recent Immich assets into a flat directory for Syncthing → Pixel → Google Photos.

The staging directory is the only state. Every staged filename is a pure function of
the asset row it came from, so a run reconciles by comparing the filenames the query
wants against the filenames already on disk — there is no manifest to drift out of
sync with reality.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


class Abort(Exception):
    """Stop the run before anything in the staging directory is touched."""


@dataclass(frozen=True)
class Config:
    staging: Path
    tmp: Path
    lock: Path
    owner_id: str
    window_days: int
    shrink_guard_percent: int
    db_name: str
    db_user: str
    db_socket: str

    @classmethod
    def from_env(cls) -> "Config":
        def need(name: str) -> str:
            value = os.environ.get(name)
            if not value:
                sys.exit(f"{name} is not set")
            return value

        return cls(
            staging=Path(need("IPS_STAGING_DIR")),
            tmp=Path(need("IPS_TMP_DIR")),
            lock=Path(need("IPS_LOCK_FILE")),
            owner_id=need("IPS_OWNER_ID"),
            window_days=int(need("IPS_WINDOW_DAYS")),
            shrink_guard_percent=int(need("IPS_SHRINK_GUARD_PERCENT")),
            db_name=need("IPS_DB_NAME"),
            db_user=need("IPS_DB_USER"),
            db_socket=need("IPS_DB_SOCKET"),
        )


def log(message: str) -> None:
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {message}", flush=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Stage recent Immich assets for the Pixel.")
    parser.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    parser.add_argument("--force", action="store_true", help="proceed past the shrink guard")
    parser.parse_args(argv)
    log("not implemented yet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Write a placeholder test so the file exists and discovery works**

Create `modules/constellation/immich-pixel-sync/test_sync.py`:

```python
"""Unit tests for the Immich → Pixel stager.

Deliberately hermetic: no database, no exiftool, no Immich library. Everything
tested here is a pure function or a tmpdir operation, so the whole file runs
inside a Nix build.
"""

import unittest

import sync


class ConfigTest(unittest.TestCase):
    def test_module_imports_without_any_environment(self):
        self.assertTrue(callable(sync.main))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: Enable the module on galactica**

In `hosts/galactica/configuration.nix`, immediately after the `constellation.tabletSync.enable = true;` block (around line 53), add:

```nix
  # Stage the last 30 days of Immich photos for the Pixel, which forwards them to
  # Google Photos. Replaces the old iPhone → Resilio → Pixel chain.
  constellation.immichPixelSync = {
    enable = true;
    # alex@rosenfeld.one. The on-disk directory is library/admin/ — that is the
    # storage label, not this UUID, and it can change; paths come from the database.
    ownerId = "c85fe467-a36a-457a-a260-a67dfe2199da";
    database.package = config.services.postgresql.package;
  };
```

Use whatever UUID Task 1 Step 2 actually reported.

- [ ] **Step 5: Format and build**

```bash
just fmt
nix build .#nixosConfigurations.galactica.config.system.build.toplevel -L
```

Expected: builds clean. Check the **last line** of output for the error count. If haumea complains about the `.py` files being loaded as modules, move them to `packages/immich-pixel-sync/` instead and update the `${./sync.py}` reference — but this should not happen (`modules/constellation/pia-ca.rsa.4096.crt` proves non-`.nix` files are skipped).

The timer is now declared but nothing is deployed yet — deployment is Task 11. Commits between here and there build; they are just not live.

- [ ] **Step 6: Commit**

```bash
git add modules/constellation/immich-pixel-sync hosts/galactica/configuration.nix
git commit -m "feat(galactica): scaffold immich-pixel-sync module"
```

---

## Task 4: Naming

Flat directory, 2,506 duplicated basenames, and Google's Motion Photo filename regex to satisfy. Pure functions, so genuine TDD.

**Files:**
- Modify: `modules/constellation/immich-pixel-sync/sync.py`
- Test: `modules/constellation/immich-pixel-sync/test_sync.py`

- [ ] **Step 1: Write the failing tests**

Replace the whole body of `test_sync.py` with:

```python
"""Unit tests for the Immich → Pixel stager.

Deliberately hermetic: no database, no exiftool, no Immich library. Everything
tested here is a pure function or a tmpdir operation, so the whole file runs
inside a Nix build.
"""

import unittest

import sync


def row(**overrides):
    """One row as the selector query returns it."""
    asset = {
        "id": "a1b2c3d4-1111-2222-3333-444455556666",
        "originalPath": "/mnt/storage/files/Immich/library/admin/2026/2026-07/IMG_2145.heic",
        "originalFileName": "IMG_2145.HEIC",
        "ts": "20260724_143022",
        "live_video": None,
    }
    asset.update(overrides)
    return asset


class IsMotionTest(unittest.TestCase):
    def test_an_asset_with_no_video_half_is_not_a_motion_photo(self):
        self.assertFalse(sync.is_motion(row()))

    def test_heic_plus_mov_is_a_motion_photo(self):
        self.assertTrue(sync.is_motion(row(live_video="/immich/IMG_2145.mov")))

    def test_a_primary_format_google_does_not_accept_is_not_muxed(self):
        asset = row(originalFileName="IMG_2145.PNG", live_video="/immich/IMG_2145.mov")
        self.assertFalse(sync.is_motion(asset))

    def test_a_video_format_the_spec_does_not_allow_is_not_muxed(self):
        asset = row(live_video="/immich/IMG_2145.avi")
        self.assertFalse(sync.is_motion(asset))


class StagedNameTest(unittest.TestCase):
    def test_a_plain_image_gets_a_sortable_prefix_and_a_lowercase_extension(self):
        self.assertEqual(
            sync.staged_name(row()),
            "20260724_143022_a1b2c3d4_IMG_2145.heic",
        )

    def test_a_live_pair_gets_the_MP_suffix_google_requires(self):
        self.assertEqual(
            sync.staged_name(row(live_video="/immich/IMG_2145.mov")),
            "20260724_143022_a1b2c3d4_IMG_2145.MP.heic",
        )

    def test_duplicate_basenames_do_not_collide(self):
        first = sync.staged_name(row())
        second = sync.staged_name(row(id="99998888-0000-0000-0000-000000000000"))
        self.assertNotEqual(first, second)

    def test_characters_android_rejects_are_replaced(self):
        self.assertEqual(
            sync.staged_name(row(originalFileName='we:ird?  name.heic')),
            "20260724_143022_a1b2c3d4_we_ird__name.heic",
        )

    def test_a_stem_that_sanitizes_away_to_nothing_still_produces_a_filename(self):
        self.assertEqual(
            sync.staged_name(row(originalFileName=":::.heic")),
            "20260724_143022_a1b2c3d4_photo.heic",
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
```

Expected: `AttributeError: module 'sync' has no attribute 'is_motion'` on every test.

- [ ] **Step 3: Implement**

In `sync.py`, add `import re` to the imports (keep them alphabetical: `argparse`, `os`, `re`, `sys`), then insert these constants after the docstring/imports block, before `class Abort`:

```python
# Google Photos only recognises a Motion Photo when the filename matches
#   ^([^\s\/\\][^\/\\]*MP)\.(JPG|jpg|JPEG|jpeg|HEIC|heic|AVIF|avif)$
# so a pair whose primary is any other format ships as a plain still.
MOTION_PRIMARY_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".heic": "image/heic",
    ".avif": "image/avif",
}

# The spec permits video/quicktime with HEVC, so no transcode is needed.
MOTION_VIDEO_MIME = {
    ".mov": "video/quicktime",
    ".mp4": "video/mp4",
}

# Characters Android's storage layer rejects in a filename.
_UNSAFE = re.compile(r'[\\/:*?"<>|\x00-\x1f]')
```

Then add these three functions after `log()`:

```python
def sanitize(stem: str) -> str:
    """Make a filename stem safe for Android's storage layer."""
    cleaned = _UNSAFE.sub("_", stem)
    cleaned = re.sub(r"\s+", "_", cleaned).strip("._")
    return cleaned or "photo"


def is_motion(asset: dict) -> bool:
    """True when both halves of a Live Photo pair are formats the spec allows."""
    if not asset.get("live_video"):
        return False
    image_ext = os.path.splitext(asset["originalFileName"])[1].lower()
    video_ext = os.path.splitext(asset["live_video"])[1].lower()
    return image_ext in MOTION_PRIMARY_MIME and video_ext in MOTION_VIDEO_MIME


def staged_name(asset: dict) -> str:
    """Flat, collision-safe staging filename.

        20260724_143022_a1b2c3d4_IMG_2145.MP.heic   live pair, muxed
        20260724_143022_a1b2c3d4_IMG_2146.heic      everything else

    2,506 basenames repeat across the library, so the asset UUID prefix is what
    keeps a flat directory honest. Google Photos takes its date from EXIF, so the
    timestamp is only there for sort order and legibility.
    """
    stem, extension = os.path.splitext(asset["originalFileName"])
    suffix = ".MP" if is_motion(asset) else ""
    return f"{asset['ts']}_{asset['id'][:8]}_{sanitize(stem)}{suffix}{extension.lower()}"
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
```

Expected: `Ran 9 tests` … `OK`.

- [ ] **Step 5: Commit**

```bash
git add modules/constellation/immich-pixel-sync
git commit -m "feat(modules): immich-pixel-sync staging filenames"
```

---

## Task 5: Reconciler

The add/keep/delete decision, plus the two aborts that stand between a bug and an emptied phone.

**Files:**
- Modify: `modules/constellation/immich-pixel-sync/sync.py`
- Test: `modules/constellation/immich-pixel-sync/test_sync.py`

- [ ] **Step 1: Write the failing tests**

Append to `test_sync.py`, before the `if __name__ == "__main__":` block:

```python
class PlanActionsTest(unittest.TestCase):
    def test_stages_what_is_missing_and_reaps_what_fell_out_of_the_window(self):
        desired = {"new.heic": row(), "kept.heic": row()}
        current = {"kept.heic", "old.heic"}
        to_add, to_delete = sync.plan_actions(desired, current, 50)
        self.assertEqual(set(to_add), {"new.heic"})
        self.assertEqual(to_delete, ["old.heic"])

    def test_an_empty_result_set_aborts_rather_than_deleting_everything(self):
        with self.assertRaises(sync.Abort):
            sync.plan_actions({}, {"kept.heic"}, 50)

    def test_the_shrink_guard_stops_a_mass_delete(self):
        desired = {"a.heic": row()}
        current = {f"{index}.heic" for index in range(10)}
        with self.assertRaises(sync.Abort):
            sync.plan_actions(desired, current, 50)

    def test_force_overrides_the_shrink_guard(self):
        desired = {"a.heic": row()}
        current = {f"{index}.heic" for index in range(10)}
        _, to_delete = sync.plan_actions(desired, current, 50, force=True)
        self.assertEqual(len(to_delete), 10)

    def test_the_shrink_guard_does_not_block_a_first_run(self):
        desired = {"a.heic": row()}
        to_add, to_delete = sync.plan_actions(desired, set(), 50)
        self.assertEqual(set(to_add), {"a.heic"})
        self.assertEqual(to_delete, [])

    def test_a_shrink_inside_the_threshold_is_allowed(self):
        desired = {f"{index}.heic": row() for index in range(7)}
        current = {f"{index}.heic" for index in range(10)}
        _, to_delete = sync.plan_actions(desired, current, 50)
        self.assertEqual(len(to_delete), 3)
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
```

Expected: `AttributeError: module 'sync' has no attribute 'plan_actions'` on the six new tests, the previous nine still passing.

- [ ] **Step 3: Implement**

Add to `sync.py`, after `staged_name()`:

```python
def plan_actions(
    desired: dict,
    current: set,
    shrink_guard_percent: int,
    force: bool = False,
) -> tuple[dict, list]:
    """Decide what to stage and what to reap.

    `desired` maps staging filename → asset row; `current` is the set of filenames
    already staged. Reaping falls out of the window rather than being separate
    logic, so there is one code path to get right instead of two.

    Raises Abort rather than proceeding when the result looks like a failure
    dressed up as an answer — a bug here deletes photos off a phone.
    """
    if not desired:
        raise Abort("query returned no assets; refusing to empty the staging directory")

    if current and not force:
        shrink = (len(current) - len(desired)) * 100 / len(current)
        if shrink > shrink_guard_percent:
            raise Abort(
                f"desired set is {shrink:.0f}% smaller than what is staged "
                f"({len(desired)} vs {len(current)}); refusing without --force"
            )

    to_add = {name: asset for name, asset in desired.items() if name not in current}
    to_delete = sorted(current - set(desired))
    return to_add, to_delete
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
```

Expected: `Ran 15 tests` … `OK`.

- [ ] **Step 5: Commit**

```bash
git add modules/constellation/immich-pixel-sync
git commit -m "feat(modules): immich-pixel-sync reconciler with shrink guard"
```

---

## Task 6: Motion Photo trailer and hardlink staging

Two small pieces that are testable without exiftool: the `mpvd` byte layout, and the hardlink that guarantees staging never costs disk space or endangers the original.

**Files:**
- Modify: `modules/constellation/immich-pixel-sync/sync.py`
- Test: `modules/constellation/immich-pixel-sync/test_sync.py`

- [ ] **Step 1: Write the failing tests**

Append to `test_sync.py`, before `if __name__ == "__main__":`:

```python
class MpvdBoxTest(unittest.TestCase):
    def test_the_box_declares_its_own_size_including_the_eight_byte_header(self):
        box = sync.mpvd_box(b"V" * 512)
        self.assertEqual(len(box), 520)
        self.assertEqual(box[0:4], (520).to_bytes(4, "big"))
        self.assertEqual(box[4:8], b"mpvd")
        self.assertEqual(box[8:], b"V" * 512)

    def test_an_empty_video_still_produces_a_well_formed_header(self):
        self.assertEqual(sync.mpvd_box(b""), (8).to_bytes(4, "big") + b"mpvd")


class StagePlainTest(unittest.TestCase):
    def test_staging_shares_the_inode_and_unlinking_leaves_the_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            original = Path(tmp) / "IMG_2145.heic"
            original.write_bytes(b"pixels")
            dest = Path(tmp) / "20260724_143022_a1b2c3d4_IMG_2145.heic"

            sync.stage_plain(row(originalPath=str(original)), dest)

            self.assertEqual(original.stat().st_ino, dest.stat().st_ino)
            dest.unlink()
            self.assertEqual(original.read_bytes(), b"pixels")
```

Add the two imports that needs at the top of `test_sync.py`, after `import unittest`:

```python
import tempfile
from pathlib import Path
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
```

Expected: `AttributeError: module 'sync' has no attribute 'mpvd_box'` and `... 'stage_plain'`.

- [ ] **Step 3: Implement**

Add `import struct` to `sync.py`'s imports (after `import sys`, keeping stdlib alphabetical: `argparse`, `os`, `re`, `struct`, `sys`). Add to `sync.py`, after `plan_actions()`:

```python
def mpvd_box(video: bytes) -> bytes:
    """Wrap the video in the ISO-BMFF box Google's parser looks for at the tail."""
    return struct.pack(">I", 8 + len(video)) + b"mpvd" + video


def stage_plain(asset: dict, dest: Path) -> None:
    """Hardlink the original into staging.

    No bytes copied, and unlinking the staged name later cannot touch Immich's
    original — the reap path only ever removes one of two names for one inode.
    """
    os.link(asset["originalPath"], dest)
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
```

Expected: `Ran 18 tests` … `OK`.

- [ ] **Step 5: Commit**

```bash
git add modules/constellation/immich-pixel-sync
git commit -m "feat(modules): immich-pixel-sync mpvd box and hardlink staging"
```

---

## Task 7: Selector

The one SQL query that is the source of truth for what should exist. Not unit-tested — it has no logic to test, only a shape contract that Task 1 verified against the live database and Task 11 verifies again on the host.

**Files:**
- Modify: `modules/constellation/immich-pixel-sync/sync.py`

- [ ] **Step 1: Add the query constant**

Add to `sync.py`, immediately after the `_UNSAFE` constant:

```python
# The only source of truth for what should be staged.
#
# The final NOT EXISTS clause drops MOV halves of Live Photo pairs: they ship
# embedded inside their still, never standalone. It is NOT EXISTS rather than
# NOT IN because NOT IN against a nullable column silently returns nothing.
#
# visibility = 'timeline' is redundant today — every non-timeline asset in the
# library is a Live Photo MOV half, which NOT EXISTS already drops — but Immich's
# 'locked' visibility is its PIN-protected folder. Without this clause, the day
# something is locked or archived is the day it silently ships to Google Photos.
#
# A pair is selected on its *image* asset's date and the video half is pulled via
# livePhotoVideoId regardless of its own timestamp, which keeps pairs atomic at
# the window boundary.
SQL = """
SELECT coalesce(json_agg(t), '[]'::json) FROM (
  SELECT a.id,
         a."originalPath",
         a."originalFileName",
         to_char(a."fileCreatedAt" AT TIME ZONE 'UTC', 'YYYYMMDD_HH24MISS') AS ts,
         v."originalPath" AS live_video
  FROM asset a
  LEFT JOIN asset v ON v.id = a."livePhotoVideoId"
  WHERE a."ownerId" = :'owner'::uuid
    AND a."deletedAt" IS NULL
    AND a.status = 'active'
    AND NOT a."isOffline"
    AND a.visibility = 'timeline'
    AND a."fileCreatedAt" > now() - make_interval(days => :days)
    AND NOT EXISTS (SELECT 1 FROM asset p WHERE p."livePhotoVideoId" = a.id)
  ORDER BY a."fileCreatedAt"
) t;
"""
```

Verified against the live database on 2026-07-26: the table is `asset` (singular), every column above exists, and the query returns 1,010 rows of which 847 have a `live_video`. psql's collation-mismatch warning goes to **stderr**, so reading `stdout` is safe.

- [ ] **Step 2: Add the fetch function**

Add `import json` and `import subprocess` to `sync.py`'s imports (final stdlib list: `argparse`, `fcntl`, `json`, `os`, `re`, `struct`, `subprocess`, `sys` — `fcntl` arrives in Task 9, add it then). Add after `stage_plain()`:

```python
def fetch_assets(cfg: Config) -> list:
    """Run the selector query.

    psql connects over the unix socket as the Immich role; galactica's ident map
    (`immich-users media immich`) lets the media user do that without a password.
    Raises CalledProcessError if the query fails, which the caller turns into an
    abort — an unreachable database must never read as "delete everything".
    """
    result = subprocess.run(
        [
            "psql", "-X", "-A", "-t", "-q",
            "-v", "ON_ERROR_STOP=1",
            "-h", cfg.db_socket,
            "-U", cfg.db_user,
            "-d", cfg.db_name,
            "-v", f"owner={cfg.owner_id}",
            "-v", f"days={cfg.window_days}",
            "-c", SQL,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout.strip() or "[]")
```

- [ ] **Step 3: Verify the module still imports and the tests still pass**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
```

Expected: `Ran 18 tests` … `OK`. (No new tests — nothing here is testable without a database.)

- [ ] **Step 4: Commit**

```bash
git add modules/constellation/immich-pixel-sync
git commit -m "feat(modules): immich-pixel-sync selector query"
```

---

## Task 8: Muxer

Reflink, XMP, append, atomic rename. Verified empirically in Task 2 — this is that probe turned into three functions.

**Files:**
- Modify: `modules/constellation/immich-pixel-sync/sync.py`

- [ ] **Step 1: Implement**

Add to `sync.py`, after `fetch_assets()`:

```python
def reflink_copy(src: Path, dst: Path) -> None:
    """Copy-on-write copy of the primary image.

    On btrfs this costs no space, and unlike a hardlink it guarantees the mux
    cannot write through into Immich's original.
    """
    subprocess.run(
        ["cp", "--reflink=auto", "--preserve=timestamps", "--", str(src), str(dst)],
        check=True,
        capture_output=True,
        text=True,
    )


def write_motion_xmp(path: Path, video_len: int, image_ext: str, video_ext: str) -> None:
    """Declare the Motion Photo container in XMP.

    exiftool 13.x ships the namespace as XMP-GContainer with the tag named
    ContainerDirectory, so no custom .ExifTool_config is needed. Padding=8 on the
    primary item accounts for the 8-byte `mpvd` header that separates the image
    bytes from the video.
    """
    directory = (
        "[{Item={Mime=" + MOTION_PRIMARY_MIME[image_ext]
        + ",Semantic=Primary,Length=0,Padding=8}},"
        "{Item={Mime=" + MOTION_VIDEO_MIME[video_ext]
        + ",Semantic=MotionPhoto,Length=" + str(video_len) + ",Padding=0}}]"
    )
    subprocess.run(
        [
            "exiftool", "-overwrite_original", "-q",
            "-XMP-GCamera:MotionPhoto=1",
            "-XMP-GCamera:MotionPhotoVersion=1",
            "-XMP-GCamera:MotionPhotoPresentationTimestampUs=-1",
            "-XMP-GContainer:ContainerDirectory=" + directory,
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def stage_motion(asset: dict, dest: Path, tmp_dir: Path) -> None:
    """Mux an Apple Live Photo pair into a Google Motion Photo.

    The XMP must be written *before* the video is appended: exiftool rewrites the
    ISO-BMFF box structure and would discard a trailing box it does not recognise.
    The HEIC passes through byte-identical, gain map and all, so HDR survives.
    """
    image = Path(asset["originalPath"])
    video = Path(asset["live_video"])
    scratch = tmp_dir / (dest.name + ".part")
    scratch.unlink(missing_ok=True)

    reflink_copy(image, scratch)
    video_bytes = video.read_bytes()
    write_motion_xmp(scratch, len(video_bytes), image.suffix.lower(), video.suffix.lower())
    with open(scratch, "ab") as handle:
        handle.write(mpvd_box(video_bytes))
    os.replace(scratch, dest)
```

- [ ] **Step 2: Verify the module still imports and the tests still pass**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
```

Expected: `Ran 18 tests` … `OK`.

- [ ] **Step 3: Commit**

```bash
git add modules/constellation/immich-pixel-sync
git commit -m "feat(modules): immich-pixel-sync live photo muxer"
```

---

## Task 9: Entry point

Lock, plan, dry-run, stage, reap.

**Files:**
- Modify: `modules/constellation/immich-pixel-sync/sync.py`

- [ ] **Step 1: Add the directory scan and scratch cleanup**

Add to `sync.py`, after `stage_motion()`:

```python
def scan_staged(staging: Path) -> set:
    """Filenames currently staged.

    Dotfiles are Syncthing's (.stfolder, .stignore, .stversions, in-flight temp
    files) and are none of this script's business.
    """
    return {
        entry.name
        for entry in staging.iterdir()
        if entry.is_file() and not entry.name.startswith(".")
    }


def clean_scratch(tmp: Path) -> None:
    """Drop half-written files left by a run that died mid-mux."""
    for leftover in tmp.glob("*.part"):
        leftover.unlink(missing_ok=True)
```

- [ ] **Step 2: Replace `main()`**

Add `import fcntl` to the imports (after `import argparse`), then replace the placeholder `main()` in `sync.py` with:

```python
def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Stage recent Immich assets for the Pixel.")
    parser.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    parser.add_argument("--force", action="store_true", help="proceed past the shrink guard")
    args = parser.parse_args(argv)

    cfg = Config.from_env()
    cfg.staging.mkdir(parents=True, exist_ok=True)
    cfg.tmp.mkdir(parents=True, exist_ok=True)
    cfg.lock.parent.mkdir(parents=True, exist_ok=True)

    lock_fd = open(cfg.lock, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another run holds the lock; exiting")
        return 0

    try:
        try:
            assets = fetch_assets(cfg)
        except subprocess.CalledProcessError as exc:
            log(f"ABORT: selector query failed: {(exc.stderr or '').strip()}")
            return 1

        desired = {staged_name(asset): asset for asset in assets}
        current = scan_staged(cfg.staging)

        try:
            to_add, to_delete = plan_actions(
                desired, current, cfg.shrink_guard_percent, args.force
            )
        except Abort as exc:
            log(f"ABORT: {exc}")
            return 1

        log(f"{len(desired)} desired, {len(current)} staged, +{len(to_add)} -{len(to_delete)}")

        if args.dry_run:
            for name in sorted(to_add):
                log(f"  + {name}")
            for name in to_delete:
                log(f"  - {name}")
            return 0

        clean_scratch(cfg.tmp)

        added = 0
        failed = 0
        for name, asset in sorted(to_add.items()):
            dest = cfg.staging / name
            try:
                if is_motion(asset):
                    stage_motion(asset, dest, cfg.tmp)
                else:
                    stage_plain(asset, dest)
                added += 1
            except Exception as exc:  # one bad asset must not take down the run
                log(f"  failed to stage {name}: {exc}")
                if is_motion(asset):
                    # Ship the still under the same name. One photo loses its
                    # motion, the run survives, and the name stays stable so the
                    # next run does not churn the phone by deleting and re-adding
                    # it. To retry the mux, delete the staged file.
                    try:
                        stage_plain(asset, dest)
                        log(f"  staged {name} without motion")
                        added += 1
                        continue
                    except Exception as fallback_exc:
                        log(f"  fallback also failed for {name}: {fallback_exc}")
                failed += 1

        for name in to_delete:
            (cfg.staging / name).unlink(missing_ok=True)

        log(f"done: +{added} -{len(to_delete)} failed={failed}")
        return 0
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
```

- [ ] **Step 3: Verify the tests still pass and the wrapper still builds**

```bash
cd modules/constellation/immich-pixel-sync && python3 -m unittest -v; cd -
just fmt
nix build .#nixosConfigurations.galactica.config.system.build.toplevel -L
```

Expected: `Ran 18 tests` … `OK`, and a clean build. Check the **last line** of the build output for the error count.

- [ ] **Step 4: Commit**

```bash
git add modules/constellation/immich-pixel-sync
git commit -m "feat(modules): immich-pixel-sync entry point"
```

---

## Task 10: Wire the tests into the flake

**Files:**
- Modify: `flake-modules/checks.nix`
- Modify: `justfile:203-205`

- [ ] **Step 1: Add the check**

In `flake-modules/checks.nix`, inside the `// { ... }` block, after the `harmonia-cache-test` entry, add:

```nix
          immich-pixel-sync-test =
            inputs.nixpkgs.legacyPackages.${system}.runCommand "immich-pixel-sync-test" {
              nativeBuildInputs = [inputs.nixpkgs.legacyPackages.${system}.python3];
            } ''
              cp ${../modules/constellation/immich-pixel-sync}/*.py .
              python3 -m unittest discover -v -s . -p 'test_*.py'
              touch $out
            '';
```

- [ ] **Step 2: Add the just recipe**

In `justfile`, after the `router-test` recipe (line 205), add:

```
# Immich → Pixel stager unit tests
immich-pixel-sync-test:
    nix build .#checks.x86_64-linux.immich-pixel-sync-test -L
```

- [ ] **Step 3: Run it**

```bash
just fmt
just immich-pixel-sync-test
```

Expected: the build log shows `Ran 18 tests` … `OK` and the derivation succeeds.

- [ ] **Step 4: Commit**

```bash
git add flake-modules/checks.nix justfile
git commit -m "test(modules): run immich-pixel-sync unit tests in nix flake check"
```

---

## Task 11: Deploy and verify on galactica

The first real run against 174 GB of photos. Dry-run first.

**Files:** none — this is deployment and verification.

- [ ] **Step 1: Deploy**

```bash
just deploy galactica
```

Expected: `colmena apply` completes. Check the **last line** for failures.

- [ ] **Step 2: Confirm the unit and directories exist**

```bash
ssh root@galactica.bat-boa.ts.net 'systemctl list-timers immich-pixel-sync --all; ls -ld /mnt/storage/files/PixelPhotoStage /mnt/storage/files/PixelPhotoStage.tmp /var/lib/immich-pixel-sync'
```

Expected: a timer scheduled hourly, and three directories owned by `media media`.

- [ ] **Step 3: Dry-run**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media /run/current-system/sw/bin/immich-pixel-sync --dry-run'
```

Expected: a line like `1010 desired, 0 staged, +1010 -0` followed by ~1,010 `+` lines, of which ~847 end in `.MP.heic`. (The spec's "1,857 assets in 30 days" counts MOV halves separately; 1010 + 847 = 1857. Staged *files* are 1,010 because each pair ships as one.) If the count is 0 or the run reports `ABORT: selector query failed`, stop — the query or the peer-auth mapping is wrong.

- [ ] **Step 4: Real run**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media /run/current-system/sw/bin/immich-pixel-sync'
```

Expected: `done: +1010 -0 failed=0`, or a small non-zero `failed` with per-asset reasons logged. Takes a few minutes — the mux reads and rewrites each of the 847 pairs.

- [ ] **Step 5: Verify a hardlinked still shares its inode with Immich's original**

```bash
ssh root@galactica.bat-boa.ts.net '
  set -eu
  cd /mnt/storage/files/PixelPhotoStage
  plain=$(ls | grep -v "\.MP\." | head -1)
  echo "staged: $plain"
  stat -c "%i %h %n" "$plain"
'
```

Expected: link count (`%h`) of at least 2 — the staged name and Immich's original are two names for one inode.

- [ ] **Step 6: Verify a muxed file is a real Motion Photo and does not share the original's inode**

```bash
ssh root@galactica.bat-boa.ts.net '
  set -eu
  cd /mnt/storage/files/PixelPhotoStage
  mp=$(ls | grep "\.MP\." | head -1)
  echo "staged: $mp"
  stat -c "%i %h %n" "$mp"
  exiftool -s -struct -FileType -XMP-GCamera:MotionPhoto -XMP-GContainer:ContainerDirectory "$mp"
'
```

Expected: link count `1` (a reflink is not a hardlink, so the original is safe), `FileType: HEIC`, `MotionPhoto: 1`, and a `ContainerDirectory` with `Semantic=Primary` then `Semantic=MotionPhoto`.

- [ ] **Step 7: Verify the declared video length matches the actual `mpvd` box**

```bash
ssh root@galactica.bat-boa.ts.net '
  cd /mnt/storage/files/PixelPhotoStage
  mp=$(ls | grep "\.MP\." | head -1)
  python3 - "$mp" <<PY
import struct, sys
data = open(sys.argv[1], "rb").read()
idx = data.rfind(b"mpvd")
declared = struct.unpack(">I", data[idx-4:idx])[0]
print("mpvd at", idx-4, "declared", declared, "trailing", len(data)-idx-4)
assert declared == len(data) - idx - 4 + 8, "mpvd box size does not match trailing bytes"
print("OK")
PY
'
```

Expected: `OK`.

- [ ] **Step 8: Confirm the staging directory size is in the right neighbourhood**

```bash
ssh root@galactica.bat-boa.ts.net 'du -sh --apparent-size /mnt/storage/files/PixelPhotoStage; ls /mnt/storage/files/PixelPhotoStage | wc -l; ls /mnt/storage/files/PixelPhotoStage.tmp'
```

Expected: roughly 8–9 GB apparent, ~1,010 files, and an **empty** `.tmp` directory (no leftover `.part` files).

- [ ] **Step 9: Confirm a second run is a no-op**

```bash
ssh root@galactica.bat-boa.ts.net 'sudo -u media /run/current-system/sw/bin/immich-pixel-sync'
```

Expected: `+0 -0` (or a handful of `+` if photos arrived in between). If this re-stages everything, the naming is not deterministic — that is a bug in `staged_name`, stop and fix it.

No commit for this task.

---

## Task 12: Syncthing transport

**Files:**
- Modify: `hosts/galactica/services/files.nix:43-47`

This task needs the Pixel's Syncthing device ID, so do Task 13 Steps 1–2 first.

- [ ] **Step 1: Declare the folder additively**

In `hosts/galactica/services/files.nix`, add to the `let` block at the top (after the `pkgs-unstable` binding, before `in`), substituting the device ID from Task 13 Step 2:

```nix
  # Syncthing device ID of the Pixel 3 XL, from Syncthing-Fork → Settings → Show
  # device ID. null means "phone not paired yet" — the folder is then not declared
  # at all, so the stager can keep running without a transport.
  pixelDeviceId = "XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX";
```

Then replace the existing `services.syncthing` block (lines 43-47):

```nix
  services.syncthing = {
    enable = true;
    guiAddress = "0.0.0.0:8384";
    group = "media";
  };
```

with:

```nix
  services.syncthing = {
    enable = true;
    guiAddress = "0.0.0.0:8384";
    group = "media";

    # Every other folder and device on this host was created through the GUI.
    # These default to true, which would delete anything Nix does not declare.
    overrideFolders = false;
    overrideDevices = false;

    settings = lib.mkIf (pixelDeviceId != null) {
      devices.pixel3xl = {
        id = pixelDeviceId;
        name = "Pixel 3 XL";
      };

      # sendonly here plus receiveonly on the phone means no deletion can ever
      # propagate backwards into the staging directory — and from there, nothing
      # can reach Immich, since staged files are only hardlinks and reflinks.
      folders.pixel-photo-stage = {
        id = "pixel-photo-stage";
        label = "Pixel Photo Stage";
        path = config.constellation.immichPixelSync.stagingDirectory;
        type = "sendonly";
        devices = ["pixel3xl"];
      };
    };
  };
```

- [ ] **Step 2: Build and deploy**

```bash
just fmt
nix build .#nixosConfigurations.galactica.config.system.build.toplevel -L
just deploy galactica
```

Expected: clean build, clean deploy. Check the **last line** of each for errors.

- [ ] **Step 3: Verify the existing GUI folders survived**

```bash
ssh root@galactica.bat-boa.ts.net 'systemctl status syncthing --no-pager | head -5'
```

Then open `https://syncthing.arsfeld.one` and confirm the `photosync` and `Photos` folders are still listed alongside the new `Pixel Photo Stage`. If they are gone, `overrideFolders` did not take — revert the deploy (`just deploy galactica` from the previous commit) and re-check.

- [ ] **Step 4: Commit**

```bash
git add hosts/galactica/services/files.nix
git commit -m "feat(galactica): export the Pixel photo staging dir over syncthing"
```

---

## Task 13: Pixel rollout and the Google Photos gate

Not expressible in Nix, and nothing reaches Google Photos until it is done. Requires physical access to a phone that has been offline for 197 days.

**Files:** none.

- [ ] **Step 1: Install Syncthing-Fork on the Pixel 3 XL**

Install **Syncthing-Fork** by Catfriend1 from F-Droid. The official Android app was discontinued in December 2024 and must not be used.

- [ ] **Step 2: Read the device ID and hand it to Task 12**

Syncthing-Fork → Settings → *Show device ID*. Copy the full ID into `pixelDeviceId` in `hosts/galactica/services/files.nix` and complete Task 12.

- [ ] **Step 3: Accept the folder receive-only**

On the phone, accept the incoming `pixel-photo-stage` folder. Set:
- Folder type: **Receive Only**
- Path: `/storage/emulated/0/PixelPhotoStage`

Receive-only on the phone plus send-only on galactica means nothing the phone does can propagate back.

- [ ] **Step 4: Sideload the Task 2 probe file and confirm the format — this is the gate**

Before waiting on a full sync, copy `~/PROBE.MP.heic` (from Task 2 Step 5) to the phone by hand — USB, or `adb push ~/PROBE.MP.heic /storage/emulated/0/DCIM/`.

Open Google Photos and confirm:
- It appears as **one** item, not a photo plus a separate video.
- It shows the Motion Photo badge and animates on long-press.
- HDR renders (the image should visibly brighten past SDR white on the Pixel's display).

**If it does not render as a Motion Photo, stop.** Everything downstream assumed this. Re-check the Task 2 Step 3 exiftool output against the spec and re-plan the muxer before enabling the backup in Step 6.

- [ ] **Step 5: Exempt Syncthing from battery optimisation**

Android Settings → Apps → Syncthing-Fork → Battery → **Unrestricted**. Then dock the phone on a charger with WiFi. The 30-day window is generous precisely because this phone has a demonstrated habit of being offline for months, but it cannot upload while asleep.

- [ ] **Step 6: Enable the Google Photos device-folder backup**

Google Photos → Library → *Back up device folders* → enable **PixelPhotoStage**.

This is a single folder because staging is flat: a nested date tree would surface as one togglable folder per month.

- [ ] **Step 7: Confirm the round trip**

Wait for Syncthing to report the folder `Up to Date` on the phone, then confirm in Google Photos that recent photos have appeared and that a Live Photo from the staged set shows the Motion Photo badge.

Tailscale on the phone is optional — the two sites both use `192.168.18.0/24`, so they cannot route to each other, and Syncthing does its own NAT traversal and relaying.

No commit for this task.

---

## Task 14: Retire Resilio

Only after Task 13 Step 7 confirms photos are reaching Google Photos through the new path.

**Files:**
- Modify: `hosts/galactica/services/media.nix:25,70-76`
- Modify: `hosts/galactica/services/glance.nix:132-136`
- Modify: `hosts/basestar/services/gatus.nix:55`

- [ ] **Step 1: Remove the service and its gateway entry**

In `hosts/galactica/services/media.nix`, delete line 25:

```nix
  media.services.resilio = {port = 9000;};
```

and delete lines 70-76:

```nix
  services.resilio = {
    enable = true;
    enableWebUI = true;
    httpListenAddr = "0.0.0.0";
  };

  users.users.rslsync.extraGroups = ["nextcloud" "media"];
```

- [ ] **Step 2: Remove the dashboard widget**

In `hosts/galactica/services/glance.nix`, delete lines 132-136:

```nix
    resilio = {
      name = "Resilio Sync";
      category = "Files";
      icon = "di:resilio-sync";
    };
```

- [ ] **Step 3: Remove the uptime check**

In `hosts/basestar/services/gatus.nix`, delete line 55 from `galacticaServiceNames`:

```nix
    "resilio"
```

- [ ] **Step 4: Confirm nothing else references it**

```bash
grep -rn "resilio\|rslsync" --include=*.nix .
```

Expected: no output.

- [ ] **Step 5: Build both affected hosts**

```bash
just fmt
nix build .#nixosConfigurations.galactica.config.system.build.toplevel -L
nix build .#nixosConfigurations.basestar.config.system.build.toplevel -L
```

Expected: both clean. Check the **last line** of each for the error count. (basestar is aarch64 and will build on the remote builder.)

- [ ] **Step 6: Commit**

```bash
git add hosts/galactica/services/media.nix hosts/galactica/services/glance.nix hosts/basestar/services/gatus.nix
git commit -m "refactor(galactica): retire resilio sync in favour of immich-pixel-sync"
```

- [ ] **Step 7: Deploy**

```bash
just deploy galactica basestar
```

- [ ] **Step 8: Confirm the unit is gone**

```bash
ssh root@galactica.bat-boa.ts.net 'systemctl status resilio 2>&1 | head -3'
```

Expected: `Unit resilio.service could not be found.`

`/var/lib/resilio-sync` stays on disk — it is not deleted as part of this work. The dead Syncthing `photosync` and `Photos` folders are also out of scope; they are separate legacy state.

---

## Task 15: Mark the design implemented

**Files:**
- Modify: `docs/superpowers/specs/2026-07-26-immich-pixel-photo-sync-design.md:5`
- Modify: `docs/superpowers/specs/2026-07-26-immich-pixel-photo-sync-design.md:120-131`

- [ ] **Step 1: Update the status line**

Replace line 5:

```markdown
**Status:** Design approved, not implemented
```

with:

```markdown
**Status:** Implemented — `modules/constellation/immich-pixel-sync/`
```

- [ ] **Step 2: Correct the tooling section**

The "Tooling decision" section says exiftool lacks the container namespace. Replace the second paragraph (lines 126-131):

```markdown
exiftool 13.59 (in nixpkgs) already knows `XMP-GCamera:MotionPhoto`,
`MotionPhotoVersion`, and `MotionPhotoPresentationTimestampUs` — the spec's `Camera:`
namespace is exiftool's `XMP-GCamera` — and it writes HEIC. **`XMP-Container` is absent**
and needs a custom `.ExifTool_config` shipped with the module. Verify with
`exiftool -listx -XMP-Container:all`.
```

with:

```markdown
exiftool 13.59 (in nixpkgs) already knows every tag this needs, and no custom
`.ExifTool_config` is required. The spec's `Camera:` namespace is exiftool's
`XMP-GCamera`; the spec's `Container:`/`Item:` namespaces are exiftool's
`XMP-GContainer`/`XMP-GItem`, written through the single tag
`XMP-GContainer:ContainerDirectory`. The XML prefixes exiftool emits differ from the
spec's, but the namespace URIs match, which is what Google's parser reads. Verify with
`exiftool -listx -XMP-GContainer:all` — note the group is `XMP-GContainer`, not
`XMP-Container`, which is why the original survey found nothing.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-26-immich-pixel-photo-sync-design.md
git commit -m "docs(galactica): mark immich-pixel-sync design implemented"
```

---

## Rollback

If staging misbehaves after Task 12, the phone is protected by three independent things: the folder is `sendonly` on galactica and `receiveonly` on the phone, so nothing propagates backwards; the shrink guard aborts any run that would delete more than half the staged set; and staged files are only hardlinks and reflinks, so nothing here can reach Immich's library.

To stop it entirely:

```bash
ssh root@galactica.bat-boa.ts.net 'systemctl disable --now immich-pixel-sync.timer'
```

Then set `constellation.immichPixelSync.enable = false;` in `hosts/galactica/configuration.nix` and redeploy. Photos already on the phone and in Google Photos are unaffected.
