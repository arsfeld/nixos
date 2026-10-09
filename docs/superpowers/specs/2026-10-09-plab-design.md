# plab — popular tracker releases, one click into Vault

**Host:** galactica · **URL:** `https://plab.arsfeld.one` · **Code:** `hosts/galactica/services/plab/`

## Goal

A web page listing the most-seeded video releases uploaded to pornolab.net in the last
7 days, each card showing the post's images, with a button that sends the torrent to
Transmission so it downloads into the Stash library (`/mnt/storage/media/Vault`).

The name is deliberately neutral; the source site is named only in code and here.

## Why not Prowlarr alone

Prowlarr has the tracker configured (indexer 23) and its Transmission client already maps
category 6000 to the `Vault` client category. But it can't supply this page:

- A blank search returns the 50 *newest* uploads, not the most seeded, and offers no
  time window.
- Results carry no images — only the topic URL.
- Its grab API (`POST /api/v1/search {guid, indexerId}`) only accepts releases still in
  its short-lived search cache. Our list comes from our own scrape, which Prowlarr never
  saw, so every click would need a title search plus guid match first.

So plab logs into the tracker itself (it needs a session for images regardless) and adds
torrents to Transmission directly, using the same directory Prowlarr's `Vault` category
resolves to. Both routes land identically on disk.

## Components

Plain-stdlib Python run with `pkgs.python3`, the same pattern as `stash-identify`. No
pip dependencies.

| File | Responsibility |
|---|---|
| `lab.py` | Tracker client. Login, cookie jar, re-login on session expiry, windows-1251 decoding. `top(days, forums)` → tracker rows; `topic(id)` → post HTML; `torrent(id)` → `.torrent` bytes. |
| `parse.py` | Pure HTML → data. Tracker rows: topic id, title, size, seeders, leechers, completed, forum id, upload date. Post: ordered image URLs. No I/O. |
| `transmission.py` | `add(torrent_bytes)`: handles the `X-Transmission-Session-Id` 409 handshake, sends `torrent-add` with `metainfo` (base64) and `download-dir`. Returns Transmission's `result` / torrent name. |
| `store.py` | Files under the state dir: `cache.json`, `added.json`, `img/<sha1>`. Atomic writes, image pruning. |
| `page.py` | Pure render of the card grid and filter bar from the cache. Its static CSS and JS live in `assets.py`. |
| `labels.py` | Pure: `labels(title, forum)` → tags, quality, studio and category read from a release title. |
| `forums.py` | The video-forum allowlist (`FORUMS`), grouped by category name, and `category(forum_id)`. |
| `main.py` | `refresh`, `serve` and `set-cookie` subcommands. |
| `default.nix` | `plab` service, `plab-refresh` service + timer, sops secret, `media.services.plab`. |

### Deployment shape

- `media.services.plab` as a gateway-only entry (native service, no container), behind
  Authelia — no `bypassAuth`.
- `plab.service` runs `serve` as `media` with `StateDirectory = "plab"`, bound to
  `127.0.0.1:8577`. The gateway entry sets `host = "127.0.0.1"`, because its default
  (the hostname) resolves to `127.0.0.2` on galactica.
- `plab-refresh.service` runs `refresh`; `plab-refresh.timer` fires every 3 hours and on
  boot (`OnBootSec`), `Persistent = true`.
- Transmission is reached directly at `config.constellation.pia.namespaceAddress:9091`,
  never through the Authelia-gated vhost (see `transmission-vpn.nix`).
- `download-dir` = `${vars.storageDir}/media/Downloads/Vault` — the path Prowlarr's
  `Vault` category produces, a symlink to `../Vault`.

### Credentials

Tracker username and password copied once from Prowlarr's database into
`secrets/sops/galactica.yaml` as `plab-username` / `plab-password`, owned by `media`.
plab never reads Prowlarr at runtime.

### Login and captcha

The tracker's login form can demand an image captcha (Prowlarr's definition handles
`cap_sid` / `cap_code_*`), typically after failed attempts. plab persists its cookie jar
to `/var/lib/plab/cookies.txt` and logs in only when a response shows it is logged out
(the `{logout: 1}` handler in the top menu is missing), so logins are rare. If the login page
comes back with a captcha, plab does not retry: it logs that, `refresh` fails (old cache
stays) and `/add` returns "login needs captcha". Recovery is manual: log in once in a
browser, copy the `bb_data` cookie (domain `.pornolab.net`, path `/forum/`), and run
`sudo -u media plab set-cookie <value>` on galactica, which writes it into the jar. No
restart is needed: before logging in, `serve` checks whether `cookies.txt` is newer than
what it loaded, and if so reloads it and retries once without a login. Each request logs in
at most once, and `refresh` aborts on a `LoginError` rather than logging in per topic.

### Video-only filter

An allowlist of the tracker's forum ids in `forums.py`, built from its category tree:
everything video (clips, siterips, full movies, JAV, …) in; photo sets, comics/art and
games out. Sent as `f[]=` parameters so the tracker filters server-side.

## Data flow

### Refresh (`plab refresh`)

1. Fetch `tracker.php` with the forum allowlist, sorted by seeders descending
   (`o=10&s=2`, confirmed against Prowlarr's definition), restricted to the last 7 days
   with the form's time-window select (`tm`; its exact value for 7 days is read off the
   live search form during implementation). Keep the top 100 rows.
2. For each topic not already in the cache, fetch the topic page and extract its image
   URLs. Cached topics only get their seeder/leecher/completed counts updated. One
   second between tracker requests.
3. Download each topic's first image to `/var/lib/plab/img/<sha1-of-url>`.
4. Write `cache.json` atomically (temp file + rename). Prune topics that left the top
   100, and their images.

### Serve (`plab serve`)

- `GET /` — server-rendered grid, sorted by seeders. Header shows when the cache was
  last refreshed. Each card: thumbnail, title, size, seeders/leechers, upload date, link
  to the topic, **Add to Vault** button. Topics in `added.json` render as already added.
- Two indicators. A release uploaded under 24 h ago shows `uploaded N min/h ago` in
  the accent color in place of its date (server-side; a future timestamp reads 0 min).
  Client-side, `localStorage["plab.seen"]` holds `{prev, cur, at}`: the ids of the
  previous visit, of the current one, and when it began. Cards absent from `prev` get a
  NEW badge and the header gains "· N new", so NEW means "since your last visit", where a
  visit is separated from the next by 30 minutes: a reload inside that window keeps `prev`
  and only refreshes `cur`; after it, `prev` becomes `cur`. The old plain-array format is
  read as `prev = cur`. A first visit, or no localStorage, shows no badges.
- Labels (`labels.py`): the tags are the comma-separated tokens of the title's last bracket
  group that has a comma, lowercased and deduplicated, minus dates; the first resolution
  token (`1080p`, `4K`/`UHD` as `2160p`) becomes the quality; the studio is the first name
  in a leading `[...]`; the category is the forum's group in `forums.py` ("Other" if unknown).
  Each card carries them as `data-tags` (joined with `|`), `data-quality`, `data-studio`,
  `data-category`, plus `data-fresh` and `data-state` (`added`, `queued` or empty).
- Stronger indicators: a NEW card gets a larger badge and an accent outline (`.is-new`);
  a card under 24 h old also gets an orange badge on the thumbnail (`7h`, or `25m`).
- Filter bar, sticky at the top, filtering client-side by hiding cards (order stays by
  seeders): toggles for last 24 h, new only and hide added/queued; selects for category,
  quality and studio (options and counts from the current list); the 20 most common tags
  as chips plus a text input with a datalist of all tags. Selected tags are ANDed. A
  "Showing X of Y" count and Clear sit at the end. The state is written to the URL hash
  (`#h24=1&new=1&hide=1&cat=…&q=…&studio=…&tags=a,b`) and to `localStorage["plab.filters"]`;
  on load the hash wins, then storage. Filters apply after the NEW pass.
- Clicking a thumbnail opens an overlay with all of the post's images.
- `GET /img/<sha1>` — serves a cached image. For a URL not yet cached (non-first images
  of a post), fetches it, stores it, then serves it. Only URLs present in `cache.json`
  are fetchable, so this is not an open proxy.
- `POST /add/<topic>` — fetches the `.torrent` with the tracker session, calls
  `transmission.add`, records the topic in `added.json`, returns JSON. The button turns
  to "Added ✓" or shows the error inline via a small `fetch()`; no page reload.

### Daily download limit

The tracker allows this account 10 `.torrent` downloads per day. Past that, `dl.php`
answers with a logged-in HTML page ("Вы уже исчерпали суточный лимит…") instead of a
torrent; `lab.torrent` raises `LimitError` for it. Prowlarr/Radarr download through the
same account, so they share the quota and the web UI may hit it before plab does.

- `POST /add/<topic>` on a limit reply queues the topic in `queued.json` (oldest first)
  and replies `{"ok": true, "queued": true, "message": ...}`; the card shows a
  "Queued ⏳" button and the header gains "· N queued". Clicking the queued button cancels
  it (`POST /unqueue/<topic>`, idempotent) and the button returns to "Add to Vault".
- `plab refresh` (every 3 h) drains the queue before refreshing the list, oldest first.
  It stops at the first limit reply, keeping the rest queued, so no download is wasted
  on a page that is only the limit message. A deleted topic (`TrackerError`) is dropped;
  Transmission or network errors leave it queued. A `LoginError` aborts the run.
- Queued topics need not be on the current list.

Images are always proxied: the tracker and its image hosts block hotlinking, and the
browser never contacts them directly.

## Error handling

- Login or tracker-list failure: `refresh` exits non-zero and leaves `cache.json`
  untouched, so the page keeps the last good list; the header's "updated N hours ago"
  shows staleness.
- A single topic or image failing: that card gets no images / a placeholder; refresh
  continues.
- `/add`: on a login page instead of a torrent, re-login and retry once (unless the
  login itself hits a captcha — see "Login and captcha"). Any tracker or
  Transmission error is returned verbatim to the button.
- Only `POST` mutates; the vhost is Authelia-gated.

## Testing

- `test_parse.py` — `unittest` against trimmed, saved HTML fixtures (tracker page, topic
  page) in `fixtures/`: row fields, numeric parsing, forum ids, image extraction.
- `test_transmission.py` — a stub HTTP server that answers 409 with a session id first,
  asserting the retry and the request body (`metainfo`, `download-dir`).
- Run with `python3 -m unittest -v` in the directory, as `stash-identify` does.
- Live check after deploy: `systemctl start plab-refresh`, load the page, add one
  release, confirm it appears in `transmission-remote <ns>:9091 -l` with its files under
  `Vault`.

## Out of scope

Search, other trackers, other time windows or sort orders, per-category tabs, removing
torrents from the page, and notifications.
