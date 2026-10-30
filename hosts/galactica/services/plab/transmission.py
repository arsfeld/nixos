"""Transmission RPC: `torrent-add` (bytes or magnet), `torrent-get` and `torrent-remove`,
including its CSRF session-id handshake."""
import base64
import json
import urllib.error
import urllib.request

# What `torrents` asks for: the fields prune.decide reads.
FIELDS = ["id", "name", "downloadDir", "percentDone", "uploadRatio", "doneDate", "activityDate", "trackers"]


class TransmissionError(Exception):
    pass


def _call(url, method, arguments):
    """One RPC call; return its reply's `arguments`."""
    body = json.dumps({"method": method, "arguments": arguments}).encode()
    session = ""
    # The first request is answered 409 with the session id to send on the second.
    for _ in range(2):
        request = urllib.request.Request(url, body, {
            "Content-Type": "application/json",
            "X-Transmission-Session-Id": session,
        })
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                reply = json.load(response)
        except urllib.error.HTTPError as e:
            e.close()
            if e.code == 409:
                session = e.headers.get("X-Transmission-Session-Id", "")
                continue
            raise TransmissionError(f"HTTP {e.code}") from e
        if reply.get("result") != "success":
            raise TransmissionError(reply.get("result", "no result"))
        return reply.get("arguments", {})
    raise TransmissionError("no session id after 409")


def add(url, torrent, download_dir):
    """Add a torrent, as .torrent bytes or a magnet link (str); return its name. A duplicate
    is not an error."""
    source = ({"filename": torrent} if isinstance(torrent, str)
              else {"metainfo": base64.b64encode(torrent).decode()})
    args = _call(url, "torrent-add", {**source, "download-dir": download_dir})
    return (args.get("torrent-added") or args.get("torrent-duplicate") or {}).get("name", "")


def torrents(url):
    """Every torrent in the client, with FIELDS."""
    return _call(url, "torrent-get", {"fields": FIELDS})["torrents"]


def remove(url, ids):
    """Take torrents out of the client. Their data stays on disk."""
    _call(url, "torrent-remove", {"ids": ids, "delete-local-data": False})
