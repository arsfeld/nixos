# plab streaming — watch a release from the swarm, keep nothing

**Host:** galactica · **Code:** `packages/plab/`, `modules/hosts/galactica/services/plab/` ·
**Builds on:** `2026-11-01-plab-rust-merge-design.md`, `2026-10-30-plab-live-search-design.md`

## Goal

A **Stream** button on every plab card (weekly list and search results) that plays the
release while it downloads, without adding it to Vault. Only the chosen file is fetched,
pieces under the playhead first, so seeking works. The data is scratch: it is deleted when
the stream stops, goes idle, or either service restarts. Add to Vault is unchanged.

Playback is in-page through `<video>` when the browser can decode the file, and always
through a copyable URL for VLC/mpv, reachable from the tailnet. No transcoding or remuxing.

## Constraints

- **Peer traffic stays in the PIA namespace.** plab runs on the host (it talks to Stash,
  Prowlarr and the tracker), so it cannot open peer connections itself; embedding a torrent
  engine in plab is out.
- **Seeking needs on-demand pieces.** Many mp4s keep their `moov` index at the end, so a
  front-to-back download (Transmission's `sequential_download`) stalls the start and every
  seek. rqbit's stream endpoint prioritizes the pieces under each read.

## Components

### `plab-stream` (new unit, PIA namespace)

`rqbit server start` (rqbit 8.1.1 from nixpkgs), confined with
`vpnConfinement.vpnNamespace = config.constellation.pia.namespace`, as `media`.

- Flags: `--disable-persistence`, `--disable-tcp-listen`, `--disable-upnp-port-forward`,
  `--http-api-listen-addr <namespaceAddress>:<streamPort>`; output folder
  `${vars.storageDir}/media/Downloads/.plab-stream`. Storage rather than root: root has
  ~108 GB free and a release can be 20 GB or more.
- No forwarded port: rqbit connects out only. Transmission keeps PIA's single forwarded
  port and `constellation.pia.consumers` is untouched (a consumer requires an
  `onPortChange`). The API port is opened from the host through VPN-Confinement's
  `portMappings` on the PIA namespace, the same mechanism that exposes Transmission's RPC.
- `ExecStartPre` empties the output folder. Together with `--disable-persistence`, every
  start is empty: this is the "don't persist" guarantee, independent of plab's bookkeeping.
- `PartOf = plab.service` and ordered before it, so restarting plab restarts the engine and
  neither side remembers a stream the other forgot.
- The rqbit API is reached only by plab. It gets no gateway entry and no tsnsrv node.

### `rqbit.rs` (plab)

A client for the rqbit HTTP API, against `PLAB_RQBIT_URL`:

| Call | rqbit endpoint |
|---|---|
| `list(bytes)` → files (index, path, length) | `POST /torrents?list_only=true` |
| `add(bytes, file)` → torrent id | `POST /torrents?only_files=<i>&overwrite=true` |
| `select(id, file)` | `POST /torrents/{id}/update_only_files` `{"only_files":[i]}` |
| `stats(id)` → downloaded, total, rate, peers | `GET /torrents/{id}/stats/v1` |
| `delete(id)` (torrent and files) | `POST /torrents/{id}/delete` |
| stream URL | `GET /torrents/{id}/stream/{file}` |

### Grabbed torrents are kept (`torrent_file` table)

The tracker caps `.torrent` downloads (plab already sees this as `TrackerError::Limit`
and queues Add to Vault when it hits it). Every `.torrent` a stream grabs is therefore
stored, so the grab is never spent twice and the file is on hand for a proper download
later:

```sql
CREATE TABLE torrent_file (
  topic_id INTEGER PRIMARY KEY,
  data BLOB NOT NULL,              -- the .torrent bytes as the tracker served them
  fetched INTEGER NOT NULL         -- unix time
);
```

- In `state.db`, added by the existing schema migration. Kept indefinitely: a `.torrent` is
  tens of kilobytes. Only the media data is scratch, never the torrent file.
- `Db::torrent_file(topic)` / `Db::store_torrent_file(topic, bytes, now)`; the store
  is `INSERT OR REPLACE`.
- A stream reads the table first and calls the tracker only on a miss, storing the bytes
  before handing them to rqbit, so a failed rqbit add still keeps the file.
- On `Limit` with nothing stored, the stream fails with the tracker's message (`429`). It
  does not queue: a stream is wanted now or not at all.
- Using the stored file elsewhere (Add to Vault, draining the queue) is the "download it
  properly later" step and is out of scope here; this design only guarantees the file is
  there.

### `stream.rs` (plab)

The stream table, in memory: topic id → rqbit id, file list, selected file, last read.

- Limits: at most **2** concurrent streams; a third evicts the least recently read.
  A stream idle for **30 min** (no bytes read) is deleted by a reaper task that runs every
  minute. The clock is injected so tests drive it.
- Starting a topic that already has a stream returns that stream unchanged.
- Default file: the largest file with a video extension (`mp4 mkv avi wmv mov m4v ts webm`).
  A torrent with none is refused before anything is added.

### Routes (plab web)

On the existing Authelia-gated `plab.arsfeld.one`:

- `POST /stream/<topic>` — start (or return) the stream. Returns JSON: files, selected
  file, stream path.
- `POST /stream/<topic>/select/<file>` — switch the fetched file.
- `GET /stream/<topic>` — stats for the modal.
- `GET /stream/<topic>/<file>` — the bytes: proxied to rqbit, `Range` forwarded,
  `Content-Range`/`Content-Length`/`Accept-Ranges` and status (200/206/416) passed back,
  `Content-Type` set from the extension.
- `DELETE /stream/<topic>` — stop now and delete the data.

### Tailnet node `plab-stream.bat-boa.ts.net`

plab opens a second listener, `127.0.0.1:8578` (`serve --stream-port`), whose router has
exactly one route: `GET /stream/<topic>/<file>`. Every other path is `404` and every other
method `405`. A tsnsrv service forwards to it with `prefixes = ["/stream/"]`,
`stripPrefix = false` and no forward auth: tailnet membership is the authentication. The
VLC URL uses this host. Because the restriction is which routes the listener has, not a
header plab inspects, nothing reachable without Authelia can start, switch or stop a
download — only read a stream already started on the gated host.

### Page

A **Stream** button beside Add to Vault on weekly and search cards. It opens a modal:
`<video controls>` on the stream path, a file picker for multi-file releases, a
"Copy URL for VLC" button (the tailnet URL), and a readout of downloaded/total, rate and
peers, polled from `GET /stream/<topic>` every 2 s while the modal is open. A "Stop"
button sends `DELETE`. Closing the modal does not stop the stream, so a VLC playback
keeps working until the idle reaper takes it.

## Data flow

1. **Start.** Take the `.torrent` from `torrent_file`, or on a miss fetch it through the
   tracker client (the path Add to Vault uses, captcha handling included) and store it.
   Evict if at the concurrency limit. `list` it, pick the default file,
   `add` with `only_files` set to it, record the stream.
2. **Play.** Each `GET` of the bytes is proxied to rqbit, which fetches the requested
   range's pieces first and fills in the rest of the file in the background. The stream's
   last-read time is refreshed as response chunks flow, not only when the request starts,
   so a long single-connection playback is never reaped mid-film.
3. **Switch file.** `select` replaces `only_files`; the old file's partial data stays
   until teardown.
4. **Teardown.** `DELETE`, the idle reaper, eviction: `delete(id)` with its files, and the
   table entry goes. Restart of either service: the scratch folder is emptied on start.
5. **Keep it.** Add to Vault sends the torrent to Transmission as today. The two engines
   never share files, at the cost of a second download.

## Error handling

Errors reach the modal as the toast Add to Vault already uses.

| Case | Response |
|---|---|
| rqbit unreachable | `503 stream engine down` |
| Tracker login needs a captcha | same message as Add to Vault |
| Tracker grab limit, torrent not stored | `429` with the tracker's message; nothing queued |
| No video file in the torrent | `400 no video file` |
| Unknown topic on stats/bytes/delete | `404` |
| Non-GET on the tailnet listener | `405` |
| No peers after 60 s | modal shows "no peers yet" and keeps polling; the reaper cleans up |
| Client disconnects mid-body | upstream request dropped, logged at debug, not as an error |
| rqbit lost a torrent plab still lists (e.g. engine restarted alone) | stats/bytes return 404 from rqbit → plab drops the entry and returns `410`; the modal offers to start again |

## Testing

`cargo test`, run by the package build:

- `rqbit.rs` against a stub HTTP server (the `transmission.rs` pattern): `list_only`
  decoding, `only_files` on add, `update_only_files` body, stats decoding, delete.
- `db`: `torrent_file` round-trips bytes; replace overwrites.
- Stream start with a stub tracker: a stored torrent makes no tracker call; a miss
  fetches once and stores before the rqbit add (stored even when the add fails); `Limit`
  with nothing stored yields `429` and queues nothing.
- `stream.rs` with an injected clock: idle streams reaped and active ones kept; a third
  stream evicts the least recently read; starting the same topic twice is idempotent;
  default file is the largest video; no-video torrents refused.
- `web_tests.rs`: `Range` forwarded and `206`/`Content-Range` passed back; tailnet
  listener gives `405` for `POST`/`DELETE` and `404` for the stats and page routes; unknown topic `404`; lost torrent `410`.
- `page_tests.rs`: the Stream button renders on weekly and search cards.

Manual, after deploy: stream a well-seeded mp4 and seek to the middle within seconds;
play the copied URL in VLC on raider; stop it and confirm `.plab-stream` is empty;
restart `plab` and confirm the same.

## Out of scope

Transcoding or remuxing, HEVC/mkv in-browser, seeding, a public (non-tailnet) stream URL,
handing a stream's data over to Vault, streaming a release that is already in
Transmission, and Add to Vault or the queue reading `torrent_file` (a later change; the
stored files are what it will use).
