"""plab: the tracker's most-seeded video releases of the last week, one click into Vault.

  refresh     send adds queued by the daily download limit, then scrape the list and
              each new topic's images into the state dir (timer)
  serve       the page, the image proxy and POST /add/<topic> (queues past the daily limit)
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
from lab import Lab, LimitError, LoginError, TrackerError
from store import Store, key

DAYS = 7
LIMIT = 100
DELAY = 1.0  # seconds between topic fetches; be gentle with the tracker

# Forums holding video releases. Left out on purpose: photos and magazines
# (1723 1726 883 1728 1729 38 1757 1735 1731 1802), manga/art/comics (1745 1760 1781
# 1296), games (1838 1750 1756 1869 1785 1790 1827 1870 1828 1829 1865), and rules,
# discussion and archive forums (1817 1863 1864 1683 1720 1815 1692).
FORUMS = (
    # Erotic & softcore
    1670, 1768, 60, 1671, 1644,
    # Full-length movies
    1672, 1111, 508, 555, 1845, 1673, 1112, 1718, 553, 1143, 1646,
    1717, 1851, 1713, 512, 1712, 1775, 1450,
    # Russian
    1674, 902, 1675, 36, 1830, 1803, 1831, 1877, 1878, 1741, 1676,
    # Clips and siterips
    1677, 1780, 1110, 1678, 1124, 1784, 1769, 1793, 1797, 1804, 1819, 1825, 1836, 1842,
    1846, 1857, 1861, 1867, 1872, 1875, 1451, 1788, 1789, 1792, 1798, 1805, 1820, 1826,
    1837, 1843, 1847, 1856, 1862, 1868, 1873, 1876, 1707, 1874, 284, 1853, 1823,
    # JAV
    1800, 1801, 1719, 997, 1818, 1849,
    # Hentai and cartoon video
    1679, 1740, 1834, 1752, 1711,
    # Special interest
    11, 1715, 1680, 1758, 1682, 1733, 1754, 1734, 1791, 509, 1859, 1685, 1762, 1881, 1681,
    # Gay
    1688, 903, 1765, 1767, 1755, 1787, 1763, 1777, 1691,
)


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


def drain_queue(lab, store, rpc_url, download_dir, add=transmission.add):
    """Add queued topics, oldest first. Stops at the first limit reply: every further
    attempt would only fetch the limit page again."""
    for topic_id in store.queued():
        try:
            add(rpc_url, lab.torrent(topic_id), download_dir)
            store.mark_added(topic_id)
            store.dequeue(topic_id)
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


def serve(lab, store, bind, port, rpc_url, download_dir):
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
            m = re.fullmatch(r"/add/(\d+)", self.path)
            if not m:
                return self._send(404, b"not found", "text/plain")
            try:
                with lock:
                    result = add_topic(lab, store, int(m.group(1)), rpc_url, download_dir)
                code, reply = 200, {"ok": True, **result}
                log(f"added {m.group(1)}: {result}")
            except Exception as e:  # noqa: BLE001 -- the reason goes back to the button
                code, reply = 502, {"ok": False, "error": str(e)}
                log(f"add {m.group(1)} failed: {e}")
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
        try:
            drain_queue(lab, store, os.environ["PLAB_TRANSMISSION_URL"], os.environ["PLAB_DOWNLOAD_DIR"])
        except LoginError:
            raise
        except Exception as e:  # noqa: BLE001 -- the list refresh must still run
            log(f"queue drain failed: {e}")
        refresh(lab, store)
    elif args.cmd == "serve":
        serve(lab, store, args.bind, args.port, os.environ["PLAB_TRANSMISSION_URL"], os.environ["PLAB_DOWNLOAD_DIR"])
    else:
        lab.set_cookie(args.value)
        log("cookie saved")


if __name__ == "__main__":
    main()
