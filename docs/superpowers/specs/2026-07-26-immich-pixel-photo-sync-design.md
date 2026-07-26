# Immich → Pixel photo sync (design)

**Date:** 2026-07-26
**Host:** galactica
**Status:** Design approved, not implemented

## Problem

Photos reach Google Photos by a three-hop chain: iPhone → Resilio Sync → Pixel 3 XL →
Google Photos (which is free and unlimited for that device). The iPhone separately
uploads everything to Immich on galactica. Resilio is therefore redundant middleware —
galactica already holds every photo the Pixel needs.

Replace it: stage photos from Immich directly to the Pixel, and retire Resilio.

## Current state

Measured on galactica, 2026-07-26.

**Immich** (native NixOS service, `hosts/galactica/services/immich.nix`):

| Fact | Value |
|---|---|
| Assets | 20,171 — 10,446 images, 9,725 videos |
| Live Photo pairs | 8,257 (`asset.livePhotoVideoId` non-null) |
| Date range | 2009-09-24 → 2026-07-24 |
| `library/` on disk | 174 GB (`upload/` a further 11 GB) |
| Last 30 days | 1,857 assets / 8.4 GB |
| Trashed | 0 |
| Filesystem | `/mnt/storage`, single btrfs subvolume, 11 TB free |

Two users: `alex@rosenfeld.one` (20,015 assets) and `c.paradis.gaudet@gmail.com` (156).

**Storage label ≠ userId.** `alex@rosenfeld.one` has userId
`c85fe467-a36a-457a-a260-a67dfe2199da`, but the on-disk directory is `library/admin/`.
Immich names that directory from the user's *storage label*, which `immich.nix` binds to
the Authelia OIDC `preferred_username` claim. The label can therefore change without
warning. **Paths must be read from `asset."originalPath"`, never constructed.**

**2,506 basenames are duplicated** across the library (`IMG_2145.HEIC` recurs across
years), so any flat destination needs collision-safe naming.

**Network.** galactica (`192.168.18.31/24`) and pegasus (`192.168.18.5/24`) are at
different sites that both use `192.168.18.0/24`. The overlap rules out a Tailscale subnet
router. The Pixel is on pegasus's LAN. Both Pixels have been off the tailnet for months
(3 XL: 197 days; 4 XL: 47 days), and all six Syncthing devices on galactica currently
report `connected: false` — the existing sync mesh is entirely dead.

**Legacy state.** Resilio's `sync.dat` points at `/mnt/data/files/Sync/Camera11`,
`Camera13`, `/mnt/data/files/Photos/library/alex11`, `alex13` — none of which exist.
Syncthing has a `photosync` folder (`/mnt/data/files/PhotoSync`, 31 GB, `sendreceive`)
shared with a device named "Pixel 3 XL", and a `Photos` folder
(`/mnt/storage/files/SyncthingiPhonePhotos`, 15 GB) shared with the iPhone.

## Requirements

1. Sync only `alex@rosenfeld.one`'s assets. The second user's photos must not reach this
   Google account.
2. Both images and video.
3. Exclude trashed assets — they are pending deletion.
4. The Pixel is a **staging buffer**, not an archive: a rolling 30-day window, reaped
   afterwards. Google Photos accumulates permanently.
5. Live Photos must arrive in Google Photos as Live Photos, not as a still plus a
   detached clip.
6. Nothing may write to or delete from Immich's library.
7. Retire Resilio.

### Why 30 days

~8.4 GB / 1,857 assets at the current rate — comfortable on a 64 GB device. The margin
matters because retention is time-based on faith (see below), and this Pixel has a
demonstrated habit of being offline for long stretches.

### Non-requirement: backfill

The 174 GB history is not being pushed. Google Photos already holds it from years of
Resilio syncing.

## Key finding: Live Photos need muxing, not copying

The original assumption — that Immich had corrupted the Live Photo pairing — is wrong.
Immich stores originals byte-for-byte, and both halves retain the Apple pairing metadata:

```
IMMICH HEIC  [MakerNotes] ContentIdentifier : 64077B46-9811-4DEB-B86D-C6E8128CC6ED
IMMICH MOV   [QuickTime]  ContentIdentifier : 64077B46-9811-4DEB-B86D-C6E8128CC6ED
```

An Immich copy and a Resilio-era original from the same iPhone 15 Pro Max are
metadata-equivalent. Immich's storage template also keeps matching basenames in a shared
directory (`IMG_2145.heic` / `IMG_2145.mov`); the only visible difference is that Immich
lowercases the extension.

The breakage is on the receiving side. **Google Photos never pairs two separate files.**
A HEIC and a MOV uploaded side by side always become two items, `ContentIdentifier` or
not. Apple Live Photos survive only when the *iOS* Google Photos app uploads them,
because it reads the paired `PHAsset` directly. Resilio was not doing anything clever —
that path had the same limitation.

What Android understands is Google's **Motion Photo**: a single file with the video
appended inside it. Per the [Motion Photo format 1.0 spec][spec], HEIC is a first-class
primary format:

```
[HEIC image boxes] → [mpvd box header, 8 bytes] → [video bytes]
```

with XMP `Container:Directory` listing `Semantic="Primary"` (`Padding=8`) then
`Semantic="MotionPhoto"` (`Length=<video size>`), plus `Camera:MotionPhoto=1`.

**No JPEG transcode is required.** Guides insisting on HEIC→JPEG predate HEIC support in
the spec. HEICs pass through byte-identical with their gain map intact — which matters,
because HDR in Google Photos requires exactly this: HEIC with ISO 21496-1 HDR from an
iPhone 15+ on iOS 18+.

So galactica muxes pairs into real Motion Photos before they reach the Pixel. This is
strictly better than the Resilio chain, which as a pure file-copier could not do it.

[spec]: https://developer.android.com/media/platform/motion-photo-format

### Tooling decision

`MotionPhoto2` is not in nixpkgs and its `requirements.txt` pulls `Gooey`, a wxPython GUI
toolkit — heavy for a headless server. The HEIC muxing path is short enough to own:
write XMP, append an 8-byte header plus the video.

exiftool 13.59 (in nixpkgs) already knows `XMP-GCamera:MotionPhoto`,
`MotionPhotoVersion`, and `MotionPhotoPresentationTimestampUs` — the spec's `Camera:`
namespace is exiftool's `XMP-GCamera` — and it writes HEIC. **`XMP-Container` is absent**
and needs a custom `.ExifTool_config` shipped with the module. Verify with
`exiftool -listx -XMP-Container:all`.

## Architecture

One new module, `modules/constellation/immich-pixel-sync.nix`, following the
`tablet-sync.nix` idiom: inline Python, a systemd timer, tmpfiles rules, gated on
`constellation.immichPixelSync.enable`. Enabled on galactica only.

It builds a flat staging directory that is a pure function of an Immich query, then hands
that directory to Syncthing. The staging directory is the interface: the stager knows
nothing about Syncthing, and Syncthing knows nothing about Immich. Either half can be
tested without the other.

```
Immich Postgres ──SQL──► stager ──┬─ live pair  ──► mux ──► NAME.MP.heic
                                  ├─ plain image ──► hardlink ──► NAME.heic
   /mnt/storage/files/Immich      └─ plain video ──► hardlink ──► NAME.mov
   library/admin/YYYY/YYYY-MM/                    │
                                                  ▼
                            /mnt/storage/files/PixelPhotoStage/   (flat, ~8.4 GB)
                                                  │
                                        Syncthing  sendonly
                                                  │
                                         ═══ tailnet / relay ═══
                                                  │
                                     Pixel 3 XL  receiveonly
                                     /storage/emulated/0/PixelPhotoStage
                                                  │
                                     Google Photos device-folder backup
```

### Component 1: selector

One SQL query, the only source of truth for what should exist.

```sql
SELECT a.id, a."originalPath", a."originalFileName", a.type,
       a."fileCreatedAt", v."originalPath" AS live_video
FROM asset a
LEFT JOIN asset v ON v.id = a."livePhotoVideoId"
WHERE a."ownerId" = 'c85fe467-a36a-457a-a260-a67dfe2199da'
  AND a."deletedAt" IS NULL AND a.status = 'active' AND NOT a."isOffline"
  AND a."fileCreatedAt" > now() - interval '30 days'
  AND NOT EXISTS (SELECT 1 FROM asset p WHERE p."livePhotoVideoId" = a.id)
```

The final clause drops MOV halves, which ship embedded rather than standalone. It uses
`NOT EXISTS` rather than `NOT IN` because `NOT IN` against a nullable column silently
returns nothing.

The owner UUID is a module option, not a literal, so the module stays reusable and the
value is visible in host config.

A Live Photo is selected on its *image* asset's date; the video half is pulled via
`livePhotoVideoId` regardless of its own timestamp. This keeps pairs atomic at the window
boundary.

### Component 2: muxer

For each asset with a `live_video`:

1. Reflink-copy the HEIC to a temp file — CoW, effectively free, and immune to
   write-through into Immich's original.
2. exiftool writes `XMP-Container:Directory` (Primary with `Padding=8`, then MotionPhoto
   with `Length=<video bytes>`) and `XMP-GCamera:MotionPhoto=1`.
3. Append `struct.pack('>I', 8 + len(video)) + b'mpvd' + video_bytes`.
4. Atomic rename into staging.

XMP must be written **before** the append: exiftool rewrites the box structure and would
discard a trailing box it does not recognise. The MOV needs no transcode — the spec
permits `video/quicktime` with HEVC.

### Component 3: naming

```
20260724_143022_a1b2c3d4_IMG_2145.MP.heic
```

Timestamp for sort order and for the reaper; 8 characters of asset UUID to defuse the
2,506 duplicate basenames; the `MP` suffix required by the spec's filename regex
(`^([^\s\/\\][^\/\\]*MP)\.(JPG|jpg|JPEG|jpeg|HEIC|heic|AVIF|avif)`). Google Photos dates
from EXIF, so the prefix is cosmetically irrelevant. Non-motion files omit `.MP`.

Flat, not nested by date: Google Photos' device-folder backup is toggled per folder, and
a nested tree would surface as many folders each needing separate opt-in.

### Component 4: reconciler and reaper

A `.state.json` manifest in the staging directory maps asset id → staged filename. Each
run:

1. Computes the desired set from the query.
2. Stages what is missing (mux or hardlink).
3. Deletes what is no longer desired.

Reaping is a consequence of the window rather than separate logic, so there is one code
path to get right instead of two.

### Component 5: transport

A Syncthing `sendonly` folder on galactica exporting the staging directory, paired to the
Pixel as `receiveonly`. Syncthing already runs natively on galactica
(`hosts/galactica/services/files.nix`), tolerates months of downtime, resumes partial
transfers, and does its own NAT traversal — which matters, since the overlapping
`192.168.18.0/24` subnets mean the two sites cannot route to each other and Tailscale on
the phone is therefore optional.

`sendonly` on galactica plus `receiveonly` on the Pixel means no deletion can propagate
backwards.

## Retention is time-based on faith

There is no way to verify from galactica that Google Photos actually backed a file up.
Google removed the Library API's read scopes in March 2025; what remains sees only
API-created content. A server-side "confirm, then reap" loop is not buildable.

Retention therefore assumes a docked, charging Pixel on WiFi uploads within 30 days. This
is the design's main correctness assumption and the reason the window is generous.

## Failure handling

A bug here deletes files off the Pixel, so the failure paths are the load-bearing part.

- **Query fails or returns empty → abort before touching staging.** An empty result set
  must never be read as "delete everything."
- **Shrink guard:** if the desired set is smaller than the current manifest by more than
  `shrinkGuardPercent` (module option, default 50), abort and log rather than mass-delete.
  Proceeding requires the `--force` flag. The guard is skipped when the manifest is empty,
  so first runs are not blocked.
- **Mux failure → hardlink the bare HEIC and continue.** One photo loses motion; the run
  survives.
- `flock` against concurrent runs; `Nice=19` and `IOSchedulingClass=idle`; hourly timer
  with `Persistent=true` — matching `tablet-sync`.
- Staging holds only hardlinks and reflinks. Nothing writes into Immich's library.

## Testing

**Format validation gates everything.** Mux one known pair, copy it to the Pixel by hand,
confirm Google Photos renders it as a Motion Photo with HDR intact. Every other decision
here is downstream of that single fact being true.

Then:

- Unit-test the reconciler's add/keep/delete decisions against a synthetic manifest,
  including the empty-result and shrink-guard aborts.
- Verify the muxed output parses: `exiftool -XMP-Container:all -XMP-GCamera:all` round-trips,
  and the `mpvd` box offset matches the declared `Length`.
- `--dry-run` printing the plan without touching the filesystem.
- Confirm a staged hardlink shares an inode with its Immich original, and that deleting
  the staged copy leaves the original intact.

## Retiring Resilio

Remove `services.resilio` and `media.services.resilio`
(`hosts/galactica/services/media.nix`), the `users.users.rslsync` group memberships, the
glance widget (`hosts/galactica/services/glance.nix`), and the gatus check
(`hosts/basestar/services/gatus.nix`).

**`/var/lib/resilio-sync` stays on disk.** Not deleted as part of this work.

The dead Syncthing folders (`photosync`, `Photos`) are out of scope — they are separate
legacy state and removing them is not required for this to work.

## Manual Pixel-side steps

Not expressible in Nix, and nothing moves until they are done:

1. Install Syncthing-Fork (Catfriend1) from F-Droid. The official Android app was
   discontinued in December 2024.
2. Pair with galactica; accept the folder **receive-only** into
   `/storage/emulated/0/PixelPhotoStage`.
3. Google Photos → Library → Back up device folders → enable that folder.
4. Exempt Syncthing from battery optimisation; keep the phone charging.
5. Tailscale re-auth is optional.

## Known limitations

- **Storage Saver, not original quality.** The Pixel 3 XL's free unlimited tier dropped to
  Storage Saver in January 2022. Video is re-encoded to 1080p at Google's end regardless
  of what is sent.
- **Retention is unverifiable** (see above).
- **Every rollout step depends on physical access** to a phone that has been offline for
  197 days.
- **Storage-label coupling.** Reading `originalPath` from the database avoids constructing
  paths, but if the Authelia `preferred_username` claim changes, Immich relocates files on
  disk and the staged hardlinks point at the old inodes until the next run reconciles.
