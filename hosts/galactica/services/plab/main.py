"""plab: the tracker's most-seeded video releases of the last week, one click into Vault.

  refresh     send adds queued by the daily download limit, then scrape the list and
              each new topic's images into the state dir (timer)
  serve       the page, its vendored /static assets, the image proxy, POST /add/<topic> (queues past the daily limit)
              and POST /unqueue/<topic>
  set-cookie  seed the session cookie by hand when a login hits a captcha

Design: docs/superpowers/specs/2026-10-09-plab-design.md
Unit tests: `python3 -m unittest -v` in this directory.
"""
import argparse
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import page
import parse
import transmission
from forums import FORUMS
from lab import Lab, LimitError, LoginError, TrackerError
from store import Store, key

DAYS = 7
LIMIT = 100
DELAY = 1.0  # seconds between topic fetches; be gentle with the tracker

def log(message):
    print(message, file=sys.stderr, flush=True)


def sniff(data):
    """The image type of `data` by its magic bytes, or None if it is not an image."""
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"GIF8":
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def _image_fetcher(lab):
    # An image host's error page must not be cached as the image.
    def fetch(url):
        data = lab.fetch(url)
        if sniff(data) is None:
            raise ValueError(f"not an image: {url}")
        return data
    return fetch


def refresh(lab, store, forums=FORUMS, days=DAYS, limit=LIMIT, sleep=time.sleep):
    """Rebuild cache.json. Raises, leaving the old cache in place, if the list fails."""
    rows = lab.top(forums, days, limit)
    if not rows:
        raise RuntimeError("tracker returned no rows")
    previous = {t["id"]: t for t in store.cache()["topics"]}
    fetch = _image_fetcher(lab)
    topics = []
    for row in rows:
        images = previous.get(row["id"], {}).get("images") or []
        if not images:
            sleep(DELAY)
            try:
                images = parse.images(lab.topic(row["id"]))
            except LoginError:
                raise  # the session is gone: stop, don't log in once per remaining topic
            except Exception as e:  # noqa: BLE001 -- one bad topic must not sink the refresh
                log(f"topic {row['id']}: {e}")
        if images:
            try:
                store.ensure_image(images[0], fetch)
            except Exception as e:  # noqa: BLE001
                log(f"image {images[0]}: {e}")
        topics.append({**row, "images": images})
    store.save_cache(topics)
    store.prune_images(u for t in topics for u in t["images"])
    log(f"refreshed: {len(topics)} topics")


def add_topic(lab, store, topic_id, rpc_url, download_dir, add=transmission.add):
    """Send a listed topic's torrent to Transmission.

    Returns {"name": ...}, or {"queued": True, "message": ...} when the tracker's daily
    download limit is reached: the topic waits in the queue for `drain_queue`."""
    if topic_id in store.added():
        return {"name": "already added"}  # a stale page must not burn a daily-quota slot
    if topic_id not in {t["id"] for t in store.cache()["topics"]}:
        raise ValueError(f"topic {topic_id} is not on the list")
    try:
        torrent = lab.torrent(topic_id)
    except LimitError as e:
        store.enqueue(topic_id)
        return {"queued": True, "message": str(e)}
    name = add(rpc_url, torrent, download_dir)
    store.mark_added(topic_id)
    return {"name": name}


def unqueue_topic(store, topic_id):
    """Take a topic off the queue. Idempotent: a topic that is not queued is fine."""
    store.dequeue(topic_id)
    return {}


def drain_queue(lab, store, rpc_url, download_dir, add=transmission.add):
    """Add queued topics, oldest first. Stops at the first limit reply: every further
    attempt would only fetch the limit page again."""
    for topic_id in store.queued():
        try:
            add(rpc_url, lab.torrent(topic_id), download_dir)
            store.dequeue(topic_id)  # first: a crash between the two must not re-download
            store.mark_added(topic_id)
            log(f"queued {topic_id}: added")
        except LimitError as e:
            log(f"queue: {e}; {len(store.queued())} still queued")
            return
        except LoginError:
            raise  # never loop logins
        except TrackerError as e:  # permanent (deleted topic, no access): drop it
            store.dequeue(topic_id)
            log(f"queued {topic_id} dropped: {e}")
        except Exception as e:  # noqa: BLE001 -- Transmission or network: retry next time
            log(f"queued {topic_id} kept: {e}")


def run_refresh(lab, store, rpc_url, download_dir):
    """The `refresh` subcommand: drain the queue, then rebuild the list."""
    try:
        drain_queue(lab, store, rpc_url, download_dir)
    except LoginError:
        raise  # the session is gone; the list refresh would only fail the same way
    except Exception as e:  # noqa: BLE001 -- the list refresh must still run
        log(f"queue drain failed: {e}")
    refresh(lab, store)


def image_for(lab, store, image_key):
    """(bytes, content type) for an image of a listed topic, fetching it on first use.

    Only URLs present in the cache resolve, so this is not an open proxy."""
    urls = {key(u): u for t in store.cache()["topics"] for u in t["images"]}
    url = urls.get(image_key)
    if url is None:
        return None
    with open(store.ensure_image(url, _image_fetcher(lab)), "rb") as f:
        data = f.read()
    return data, sniff(data)


# The vendored daisyUI and Tailwind files the page links (see default.nix). Exact names
# only: anything else under /static is a 404, so the directory is never browsed.
STATIC = {
    "daisyui.css": "text/css; charset=utf-8",
    "themes.css": "text/css; charset=utf-8",
    "tailwind.js": "text/javascript; charset=utf-8",
}


def static_file(static_dir, name):
    """(bytes, content type) of an allowlisted file in `static_dir`, or None."""
    ctype = STATIC.get(name)
    if ctype is None or not static_dir:
        return None
    try:
        with open(os.path.join(static_dir, name), "rb") as f:
            return f.read(), ctype
    except OSError:
        return None


def serve(lab, store, bind, port, rpc_url, download_dir, static_dir=None):
    lock = threading.Lock()  # one add at a time: added.json is read-modify-write

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype, cache="no-store"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                body = page.render(store.cache(), store.added(), set(store.queued()), time.time()).encode()
                return self._send(200, body, "text/html; charset=utf-8")
            m = re.fullmatch(r"/static/([^/]+)", self.path)
            if m:
                found = static_file(static_dir, m.group(1))
                if found:
                    # A day, not forever: the names carry no version, and a bump must arrive.
                    return self._send(200, found[0], found[1], "public, max-age=86400")
                return self._send(404, b"not found", "text/plain")
            m = re.fullmatch(r"/img/([0-9a-f]{40})", self.path)
            if m:
                try:
                    found = image_for(lab, store, m.group(1))
                except Exception as e:  # noqa: BLE001
                    log(f"image {m.group(1)}: {e}")
                    return self._send(502, b"image unavailable", "text/plain")
                if found:
                    return self._send(200, found[0], found[1], "private, max-age=604800")
            self._send(404, b"not found", "text/plain")

        def do_POST(self):
            m = re.fullmatch(r"/(add|unqueue)/(\d+)", self.path)
            if not m:
                return self._send(404, b"not found", "text/plain")
            action, topic_id = m.group(1), int(m.group(2))
            try:
                with lock:
                    if action == "unqueue":
                        result = unqueue_topic(store, topic_id)
                    else:
                        result = add_topic(lab, store, topic_id, rpc_url, download_dir)
                code, reply = 200, {"ok": True, **result}
                log(f"{action} {topic_id}: {result}")
            except Exception as e:  # noqa: BLE001 -- the reason goes back to the button
                code, reply = 502, {"ok": False, "error": str(e)}
                log(f"{action} {topic_id} failed: {e}")
            self._send(code, json.dumps(reply).encode(), "application/json")

    log(f"serving on {bind}:{port}")
    ThreadingHTTPServer((bind, port), Handler).serve_forever()


def _secret(env):
    with open(os.environ[env]) as f:
        return f.read().strip()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="plab")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("refresh")
    s = sub.add_parser("serve")
    s.add_argument("--bind", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8577)
    c = sub.add_parser("set-cookie")
    c.add_argument("value", help="the bb_data cookie from a logged-in browser")
    args = ap.parse_args(argv)

    state = os.environ.get("PLAB_STATE_DIR", "/var/lib/plab")
    store = Store(state)
    lab = Lab(_secret("PLAB_USERNAME_FILE"), _secret("PLAB_PASSWORD_FILE"), os.path.join(state, "cookies.txt"))
    if args.cmd == "refresh":
        run_refresh(lab, store, os.environ["PLAB_TRANSMISSION_URL"], os.environ["PLAB_DOWNLOAD_DIR"])
    elif args.cmd == "serve":
        serve(lab, store, args.bind, args.port, os.environ["PLAB_TRANSMISSION_URL"], os.environ["PLAB_DOWNLOAD_DIR"],
              os.environ.get("PLAB_STATIC_DIR"))
    else:
        lab.set_cookie(args.value)
        log("cookie saved")


if __name__ == "__main__":
    main()
