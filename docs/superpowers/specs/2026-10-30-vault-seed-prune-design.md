# Vault seed pruning

## Problem

plab and vault-grab add torrents to Transmission under `Downloads/Vault`. Nothing ever
removes them. Transmission's global ratio and idle limits are off, and mydia's
remove-completed setting only applies to its own downloads. Torrents from PornoLab, a
ratio tracker, should keep seeding while they earn upload, but within limits. Torrents
from other trackers, mostly public ones, earn nothing by seeding.

`Downloads/Vault` is a symlink into the library, so removal always keeps the data
(`delete-local-data: false`). Taking a torrent out of Transmission never touches a file.

## Policy

Only torrents that meet both of these are considered:

- `downloadDir` is under the Vault download dir
- `percentDone == 1`

Anything still downloading, and anything outside Vault (mydia's downloads), is never
touched.

A torrent counts as **PornoLab** when any of its trackers' announce hosts contains
`plab` or `pornolab`. The live tracker host today is `plab.site`.

| Torrent | Removed when |
|---|---|
| Not PornoLab | Complete. Removed on the first run after it finishes. |
| PornoLab | `uploadRatio >= 2.0`, **or** idle for at least 7 days |
| PornoLab, cap | After the two rules above, if more than 50 remain, the longest-idle are removed until 50 are left |

**Idle** is `now - max(doneDate, activityDate)`. Counting from the completion time means
a torrent that just finished gets the full 7 days, even if its last activity was the
download itself. Once complete, `activityDate` only moves on uploads.

The three limits are module constants at the top of `prune.py`: `RATIO = 2.0`,
`IDLE_DAYS = 7`, `MAX_SEEDING = 50`.

## Components

All of this lives in `hosts/galactica/services/plab/`, next to the Transmission client
that plab and vault-grab already share.

- **`transmission.py`**:
  - The 409 session-id handshake is factored out of `add` into a private `_call(url,
    method, arguments)`.
  - New `torrents(url)` returns the list from `torrent-get`, with the fields `id`,
    `name`, `downloadDir`, `percentDone`, `uploadRatio`, `doneDate`, `activityDate`
    and `trackers`.
  - New `remove(url, ids)` calls `torrent-remove` with `delete-local-data: false`.
- **`prune.py`**: `decide(torrents, now, vault_dir) -> list[(id, name, reason)]`, a pure
  function. The whole policy lives here.
- **`main.py`**: a new subcommand, `prune [--dry-run]`. It fetches the torrents, calls
  `decide`, removes the chosen ones in one `torrent-remove` call (unless `--dry-run`),
  and logs one line per torrent with its name, reason, ratio and idle days. It reads
  `PLAB_TRANSMISSION_URL` and `PLAB_DOWNLOAD_DIR`, both of which the wrapper already
  exports.
- **`default.nix`**: a `plab-prune` oneshot service, using the existing `serviceConfig`
  (it runs as `media`), with an hourly timer (`OnCalendar = hourly`, `Persistent =
  true`). It's separate from `plab-refresh` so that a tracker login or captcha failure
  never blocks pruning. The header comment gains a line about
  `sudo -u media plab prune --dry-run`.

## Errors

- If Transmission can't be reached, or `torrent-remove` fails, the run raises and the
  unit fails. The next hourly run retries; there is no state to repair.
- Because data is never deleted, the worst a bug can do is end seeding early.

## Testing

`test_prune.py` exercises `decide` with fake torrent dicts:

- non-PornoLab complete → removed; non-PornoLab still downloading → kept
- PornoLab at ratio 2.0 → removed; at ratio 1.9 and recently active → kept
- PornoLab idle 7 days → removed; completed 2 days ago with no uploads → kept
- torrent outside Vault → never removed, whatever its tracker or state
- cap: 52 eligible PornoLab torrents → the 2 longest-idle are removed
- the PornoLab match checks every tracker, not only the first

`test_transmission.py` keeps its existing `add` tests, which now run through `_call`.
It gains one test each for `torrents` and `remove`, the latter asserting that
`delete-local-data` is `false`.

## Open item

PornoLab's minimum-seeding and hit-and-run rules weren't checked. If the tracker requires
a minimum seed time, `IDLE_DAYS` has to be at least that minimum.
