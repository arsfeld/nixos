"""Transmission RPC, just `torrent-add`, including its CSRF session-id handshake."""
import base64
import json
import urllib.error
import urllib.request


class TransmissionError(Exception):
    pass


def add(url, torrent, download_dir):
    """Add a .torrent's bytes; return the torrent's name. A duplicate is not an error."""
    body = json.dumps({
        "method": "torrent-add",
        "arguments": {"metainfo": base64.b64encode(torrent).decode(), "download-dir": download_dir},
    }).encode()
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
        args = reply.get("arguments", {})
        return (args.get("torrent-added") or args.get("torrent-duplicate") or {}).get("name", "")
    raise TransmissionError("no session id after 409")
