# vault-grab — automatic 1080p grabs of followed studios

**Host:** galactica · **Code:** `hosts/galactica/services/vault-grab/`

## Goal

Every new scene from a short list of followed studios lands in Transmission without a
click: one 1080p copy per scene, saved to `Vault/<Studio>`. The first run also picks up
the last 30 days.

## History: what this replaces

- **transmission-rss** (2023-11 to 2024-05) polled Jackett → TorrentGalaxy torznab feeds
  for four studios, HEVC only, one `Vault/<Studio>` directory each. Commit `eaa3be5f`
  dropped it. TorrentGalaxy is gone. Its config and `seen` file are still in
  `/var/data/transmission-rss` and are not used.
- **qBittorrent/qflood RSS rules** (2020 to 2023) did the same against Prowlarr and
  Jackett search URLs, with a single `1080p` rule into `Vault`. They have been dead
  since qBittorrent was removed. The files are still in `/var/data/qbittorrent*` and
  `/var/data/qflood`.
- **autobrr** runs on galactica but has never been configured: no feeds, filters or
  indexers in the live DB or in any of its backups.

## Why search and not RSS

Measured on 2026-10-24 through Prowlarr:

- One studio's current releases exist only on 1337x, as `<Studio> E#### … XXX 1080p MP4
  … [XC]` (also uploaded as 480p). PornoLab carries about half of them, days later or not
  at all.
- Another studio exists only on PornoLab, as `[Studio.com] Performer - Title [date, …,
  1080p, SiteRip]`. 1337x stopped carrying it in June.

So both indexers are needed. 1337x's RSS is site-wide, and a burst of uploads scrolls
past between polls. Searching per studio sees everything in the window, makes the
backfill free, and lets one scene be recognised across both naming schemes. autobrr was
rejected for the same reasons, and because its configuration would live in its database
rather than in this repository. Extending plab was rejected because plab only talks to
PornoLab.

## Components

```
hosts/galactica/services/vault-grab/
  default.nix     timer, service, sops secret, wrapper script
  main.py         rules, search, select, grab, state
  test_main.py    unittest, run with `python3 -m unittest -v` in this directory
  fixtures/       Prowlarr /api/v1/search JSON captured from galactica, titles intact
```

`default.nix` is added to `hosts/galactica/services/default.nix` imports.

### Reused from plab

`main.py` imports `transmission` from `hosts/galactica/services/plab/` (the wrapper puts
that directory on `PYTHONPATH`). It does not copy it. `transmission.add` gains a magnet
path: a `bytes` argument is sent as `metainfo`, and a `str` starting with `magnet:` is
sent as `filename`. plab's callers are unchanged and plab's tests still pass.

### Inputs

| What | Where |
|------|-------|
| Prowlarr | `http://127.0.0.1:9696`. The API key is read at run time from `<ApiKey>` in `/var/data/prowlarr/config.xml` (mode 644, owner `media`), so there is no second copy to drift. |
| Transmission | `http://${constellation.pia.namespaceAddress}:9091/transmission/rpc`, as plab uses. Never the Authelia-gated vhost. |
| Rules | `VAULT_GRAB_RULES_FILE`, set to the new sops secret `vault-grab-rules` (owner `media`). |
| State | `/var/lib/vault-grab/state.json` (`StateDirectory`). |

### The rules file

No studio name lives in the repository, the same convention as plab's `plab-filter`.
Tests use placeholder studios.

```ini
# one block per studio; [Name] is also the Vault subdirectory
[Studio A]
query = studioa
match = ^(\[studioa\.com\]|studioa e\d+\b)

[Studio B]
query = studiob.com
match = ^(\[studiob\.com\]|studio b\s)
```

- `query` is the Prowlarr search string.
- `match` is a case-insensitive regex that must match at the **start** of the title. A
  substring match is not enough: a PornoLab compilation whose credits mention a studio
  must not count as that studio's release.
- Blank lines and `#` comments are ignored. An unknown key, a block missing either key,
  or an invalid regex fails the run (exit 1).

Edit it with `sops set secrets/sops/galactica.yaml '["vault-grab-rules"]' '"…"'` and
deploy galactica. The next run uses it.

## A run

`vault-grab run`, every 3 h (`OnCalendar = *-*-* 01/3:30:00`, offset from plab's refresh,
plus `OnBootSec = 5min` and `Persistent = true`).

1. **Search.** For each studio, `GET /api/v1/search?query=<query>&type=search&limit=100`
   across all enabled torrent indexers. This adds no list of indexers to maintain.
2. **Filter.** A result is a candidate when all of these hold:
   - `match` matches the start of the title;
   - its `publishDate` is within the last **30 days**;
   - the title says `1080p` or `1088p` (both occur);
   - it is not a pack or an image set (`\bpack\b`, `imageset`, `\d+ ролик`);
   - no 4-digit year in the title is earlier than last year. This drops re-uploads of
     old scenes, such as a `[2016 г.]` post or an `(E769) [2022 г.]` post published this
     month.
3. **Key.** Each candidate gets one or two scene keys:
   - `ep:<n>`, from an `E####` episode number anywhere in the title;
   - `name:<squashed>`, from the scene part of the title. Take the text after the
     `match` prefix and after any `E####`, cut it at the first of ` XXX`, `[` or `(`, map
     `&` to `and`, then lowercase it and keep only `[a-z0-9]`. So `Johanna & Lars - Park
     & Ohhh (E2274) [...]` and `… E2274 Johanna And Lars Park And Ohhh XXX 1080p …` both
     give `name:johannaandlarsparkandohhh`, and the first one also gives `ep:2274`.
     A name shorter than 8 characters is not used as a key.

   Keys are scoped per studio. A candidate is **already grabbed** if any of its keys is
   in that studio's state.
4. **Choose.** Candidates sharing a key in the same run are one scene. The run prefers
   any indexer other than PornoLab (no daily quota, and plab shares that quota), then
   more seeders.
5. **Grab.** Fetch the result's `downloadUrl` without following redirects. A 3xx to a
   `magnet:` link is added as a magnet. A 200 is added as `.torrent` bytes. Anything else
   is an error. The download directory is `${storageDir}/media/Downloads/Vault/<Name>`,
   the same tree plab and Prowlarr's `Vault` category use. Transmission creates the
   subdirectory.
6. **Record.** After a successful add, write all of the scene's keys to state with the
   title and the time, then save state atomically (temp file + rename) before the next
   grab. A crash therefore never re-grabs more than the one in flight, and Transmission
   treats a duplicate add as success anyway.

### Errors

| Failure | Behaviour |
|---------|-----------|
| A grab fails (PornoLab daily limit, dead magnet, Transmission down) | Logged, not recorded, so it is retried next run while the release stays inside the window. The run continues. |
| A studio's search fails | Logged. The other studios still run. The run exits 1. |
| Prowlarr unreachable, API key unreadable, rules invalid or missing | Exit 1 before any grab. |

Exit 1 triggers the existing `email@` OnFailure that every galactica service has. Grab
failures alone do not fail the run: a PornoLab limit would otherwise mail every 3 h for
a day.

### State

```json
{"studios": {"Studio A": {"ep:2274": {"title": "…", "at": "2026-10-24T…"},
                          "name:johannaandlarsparkandohhh": {"title": "…", "at": "…"}}}}
```

Entries are never pruned. They are tiny, and a scene outside the 30-day window is never
a candidate again anyway. A studio removed from the rules keeps its entries, so
re-adding it does not re-grab. Deleting `state.json` makes the next run re-grab the last
30 days. Transmission skips torrents it already has.

`vault-grab run --dry-run` does steps 1 to 4, prints what it would grab and why each
skipped result was skipped, and writes nothing. It is the first thing to run on
galactica after deploying.

## Service

- `systemd.services.vault-grab`: oneshot, `User`/`Group` = `media`,
  `StateDirectory = vault-grab`, `after`/`wants` `network-online.target`.
- `systemd.timers.vault-grab` as above.
- `environment.systemPackages` gets the `vault-grab` wrapper, so `sudo -u media vault-grab
  run --dry-run` works by hand.
- No `media.services` entry, no port and no firewall change. It only makes outbound
  calls, to Prowlarr on loopback and to Transmission in the PIA namespace.

## Testing

`test_main.py`, stdlib `unittest`, no network:

- Rules parsing: blocks, comments, missing keys, a bad regex.
- Filtering against the captured fixtures. The 480p twin, a pack, an old-year re-upload
  and the compilation whose credits mention a studio are all rejected. The 1080p and
  1088p scenes are kept.
- Keys: both naming schemes for the same scene yield a shared key. A short name is not
  a key.
- Choice: the non-PornoLab copy wins, then the one with more seeders.
- Grab: a 301-to-magnet and a 200 `.torrent` (fake opener), an error is not recorded, and
  state is saved after each grab.
- `transmission.add` with a magnet sends `filename`. plab's existing
  `test_transmission.py` still passes.

## Out of scope

- Studios beyond what the rules file lists, and resolutions other than 1080p.
- Upgrading a grabbed scene later, for example when a better copy appears.
- Any page or UI. The journal (`journalctl -u vault-grab`) is the record.
- Removing the dead transmission-rss and qBittorrent data directories. That is a
  separate cleanup.
