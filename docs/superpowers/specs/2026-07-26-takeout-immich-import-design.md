# Google Takeout → Immich import (design)

**Date:** 2026-07-26
**Host:** galactica
**Status:** Approved. Phase 1 (extraction) started 2026-07-26 22:06 EDT.

## Problem

A 2024 Google Photos Takeout sits in `/mnt/storage/files/Takeout` and has never been
imported. Most of it is not in Immich, and a large part of it was never even
unpacked. The goal is to get all of it into Immich with its metadata and albums
intact, verified well enough that the 443 GiB of archives can later be deleted with
confidence.

## Current state

Measured on galactica, 2026-07-26. Immich is 3.0.3, native NixOS service, 20,171
tracked assets.

### The takeout

| Fact | Value |
|---|---|
| Location | `/mnt/storage/files/Takeout` |
| Total size | 443 GiB |
| Archives | 8 × `takeout-20240825T041432Z-00N.tgz`, ~440 GiB, dated 2024-08-25 |
| Archive integrity | All 8 have valid gzip magic and readable tar members |
| Partial extraction | `Takeout/Google Photos/`, 83 GiB on disk, 30,176 media files |
| Also present | `gpth-linux` (Sep 2023) and an empty `Output/` — a gpth run that never completed |

**The existing extraction is 63% incomplete.** Every media file in a Google Photos
takeout has a `<media>.json` sidecar. Checking each sidecar for its media file:

| | Count |
|---|---|
| Sidecars | 65,501 |
| Media present | 24,459 |
| **Media missing** | **41,042** |

The album folders extracted reasonably well; the authoritative `Photos from YYYY`
folders did not. `Photos from 2014` holds 1,460 sidecars and zero media; 2008, 2009
and 2014 have no media at all.

### Overlap with Immich

Every extracted media file was hashed and compared against `asset.checksum`:

| | Unique contents | Share |
|---|---|---|
| Present in Immich | 3,123 | 14.7% |
| **Absent from Immich** | **18,129** | **85.3%** |

The absent material is 70.0 GiB across 18,875 distinct files (24,999 paths, collapsing
to 18,129 distinct contents) — mostly JPEG, plus 378 NEF and 90 DNG raws. And that is
only the 37% that was extracted.

File paths (30,176) outnumber unique contents (21,252) because the takeout hardlinks
album/year duplicates. Link counts run 1–6+. This matters for extraction (below).

### Metadata survival

Contrary to the usual assumption that Google strips metadata, measured on an 873-file
sample of the extracted images:

| | Share |
|---|---|
| Has EXIF `DateTimeOriginal` | 95.6% |
| Has EXIF GPS | 60.5% |

So the files are largely self-describing already. Sidecars carry `title`,
`description`, `creationTime`, `photoTakenTime`, `geoData`, `people` and
`googlePhotosOrigin`, which covers the ~4.4% with no in-file date and the ~40% with
no in-file GPS.

Zero sidecars contain `fromPartnerSharing`, so partner-photo handling is moot.

### Not an Immich library

The `library` table is empty and no asset has a `libraryId`. Immich has never scanned
the takeout folder — it is inert data on disk.

## Approach

`immich-go upload from-google-photos`, run once across a complete extraction.

`immich-go` v0.32.0 is packaged in nixpkgs and explicitly targets Immich V3. It pairs
each media file with its JSON sidecar and applies the metadata through Immich's API —
photo-taken date, GPS, description, people tags, favorites, archived status — and
recreates Google albums as Immich albums. Files upload byte-for-byte as Google
exported them; nothing is rewritten. It deduplicates by checksum against the server,
so the 3,123 already-present photos are skipped and the run is restartable.

### Rejected: gpth first

`gpth` rebuilds the tree and bakes sidecar metadata into EXIF, making the files
self-describing. Rejected because its premise does not hold here: 95.6% of these
images already carry `DateTimeOriginal`. It would rewrite ~440 GiB to fix roughly 4%
of them, need another ~440 GiB for output, lose the Google-specific richness that
immich-go maps to real Immich fields, and — by changing the bytes — destroy the
checksum link back to the archives that Phase 6 depends on.

### Deferred: XMP sidecars

Immich's Sidecar Write job fires on edits; a full backfill for existing assets is an
open feature request (immich #26789). The working option is the third-party
`immich-metadata-exporter`. Out of scope here, available later as an independent step.
Metadata durability rests on the Immich database in the meantime, which is backed up
daily and was verified current.

### Why not read the archives directly

immich-go cannot. The TGZ-support PR (simulot/immich-go#1038) was closed unmerged:
its reader restarts the gzip stream for every file opened, which does not work for
50 GiB multi-part archives. Extraction to disk is required.

## Phases

Each phase gates the next. Nothing destructive happens in any of them.

### Phase 0 — Prerequisites

- **Manual step:** create an Immich API key in the UI on the admin account. The
  server has zero API keys and one cannot be minted from the database.
- Key lives in `/root/immich-takeout.env` (mode 0600) as `IMMICH_API_KEY=`, supplied
  via systemd `EnvironmentFile` so it stays out of git and out of the process list.
  Deleted when the migration ends. The same key serves `--admin-api-key`.
- Space: extraction ~440 GiB, Immich growth ~400 GiB. 11 T free, so ~10.8 T of 21 T
  at peak.

### Phase 1 — Extract

`/root/takeout-extract.sh` → `/mnt/storage/files/Takeout/extracted/`.

A **fresh** directory, not the existing partial tree, whose provenance is unknown
(which archives, interrupted where, whether gpth touched it). The old tree stays as a
fallback until Phase 6 passes.

Archives extract **sequentially in numeric order**. Parallel gzip streams thrash the
array, and a tar hardlink entry can reference a file stored by an earlier archive.
Each archive's exit code and stderr are recorded and scanned for `Cannot hard link` —
a silent hardlink failure is how an extraction looks complete while missing files.

Guards: 100 GiB free-space floor checked before each archive; `--no-same-owner`;
`Nice=10` and `IOSchedulingClass=idle` so Plex and the *arr stack keep working.

Runs under `systemd-run` to survive disconnects. Expect 5–8 hours.

### Phase 2 — Verify the extraction (gate)

Re-run the sidecar check. **The gate is missing-media reaching 0** (from 41,042
today). If it does not, stop and find out why rather than importing a known-incomplete
set — the point of this exercise is to be able to delete the archives afterwards.

Record the final media count as the denominator for Phase 6.

### Phase 3 — Dry run (gate)

`immich-go … --dry-run` over the full tree. Confirms file count, album count,
duplicate skips, and sidecar matching before 400 GiB moves.

Specifically decides the `.MP` question: 2,948 Google motion-photo stubs. If Immich
rejects the extension, add `--exclude-extensions=.MP` rather than let 2,948 errors
bury the real ones.

### Phase 4 — Import

```
immich-go upload from-google-photos \
  --server=http://localhost:15777 \
  --api-key="$IMMICH_API_KEY" \
  --admin-api-key="$IMMICH_API_KEY" \
  --concurrent-tasks=4 \
  --client-timeout=60m \
  --pause-immich-jobs=true \
  --on-errors=continue \
  --include-unmatched \
  --manage-raw-jpeg=StackCoverRaw \
  --manage-burst=Stack \
  --session-tag \
  --no-ui \
  --log-file=/var/log/immich-takeout-import.log \
  /mnt/storage/files/Takeout/extracted
```

Chosen deliberately:

| Flag | Why |
|---|---|
| `--include-unmatched` | Nothing left behind. Unmatched files still get EXIF dates, which 95.6% have. |
| no `--include-trashed` | Deletions stay deleted. |
| `--manage-raw-jpeg=StackCoverRaw`, `--manage-burst=Stack` | Readable timeline; every file still stored and reachable in its stack. |
| `--concurrent-tasks=4` | Conservative for 100k-scale on a spinning array shared with other services. Default is 16. |
| `--on-errors=continue` | One bad file must not kill a multi-hour run. |
| `--no-ui` | Runs under systemd, not a terminal. |

Kept at defaults: `--include-archived=true` (the takeout has a real `Archive`
folder), `--sync-albums=true`, `--people-tag=true`, `--takeout-tag=true`,
`--include-partner=true` (moot).

### Phase 5 — Immich processing

Upload finishing is not the job finishing. Immich then generates thumbnails,
transcodes video, and runs face detection and CLIP over tens of thousands of new
assets — plausibly longer than the upload. `--pause-immich-jobs` holds these off
during upload and releases them after. Watch the queues drain before declaring done.

### Phase 6 — Verify the import (gate)

Content-level, not count-level, because this is what earns the right to delete
443 GiB. `scripts/verify-takeout-import.py` hashes every file in the extracted tree
and compares against Immich's asset checksums.

**Success is zero takeout files whose content is absent from Immich**, allowing only
the deliberate exclusions (trashed, and `.MP` if excluded). Anything else is listed by
path and explained. Plus: album count matches, and a spot-check of dates and GPS on
the ~4.4% of images with no in-file EXIF, since those depend entirely on sidecars.

### Phase 7 — Deletion (deferred)

Not part of this work. Documented for later, on explicit instruction only: Phase 6
clean, a current Immich DB backup confirmed, then extracted tree first (reproducible
from the archives) and archives last.

## Risks

| Risk | Mitigation |
|---|---|
| Cross-archive tar hardlinks fail silently | Per-archive stderr captured and scanned for `Cannot hard link`; ordered extraction |
| Disk exhaustion | 100 GiB floor before each archive; 11 T free against ~840 GiB needed |
| Multi-hour run dies with the SSH session | `systemd-run` transient units, log files on disk |
| `.MP` stubs flood the error log | Dry run decides; `--exclude-extensions` if needed |
| Import competes with Plex/*arr for IO | `Nice`/`idle` IO class on extraction, `--concurrent-tasks=4` on import |
| Partial import leaves ambiguous state | immich-go dedupes by checksum, so re-running is safe and cheap; `--session-tag` and `--takeout-tag` give a precise handle on everything imported |

## Out of scope

The 21,708 orphaned files in Immich's `library/` (93.7 GiB) with no database row, and
the ~3,300 of them whose content is in no Immich asset — photos Immich has lost track
of. Also the ~92.7 GiB of thumbnails and transcodes belonging to three user IDs that
do not exist in the `user` table. Folding this cleanup into a 65,000-file import would
make both harder to verify. Tracked as follow-up.

Separately: 140 originals (Jan–Mar 2026 iPhone uploads) are missing from Immich, 38 of
them recoverable byte-identically from `SyncthingiPhonePhotos`/`PhotoSync`/`Sync`.
Unrelated to the takeout; also follow-up.

## Artifacts

- `scripts/verify-takeout-import.py` — Phase 2 and Phase 6 checker
- `/root/takeout-extract.sh` on galactica — Phase 1 (operational, not repo state)
