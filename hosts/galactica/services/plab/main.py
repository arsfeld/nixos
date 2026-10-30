"""plab: the tracker's most-seeded video releases of the last week, one click into Vault.

  refresh     send adds queued by the daily download limit, then scrape the list and
              each new topic's images into the state dir (timer)
  serve       the page, its vendored /static assets, the image proxy, POST /add/<topic> (queues past the daily limit)
              and POST /unqueue/<topic>; GET /search?q= searches the tracker live, all time
  set-cookie  seed the session cookie by hand when a login hits a captcha
  prune       take finished Vault torrents out of Transmission per prune.decide (timer);
              --dry-run only says what it would remove

Design: docs/superpowers/specs/2026-10-09-plab-design.md
Production ranking: docs/superpowers/specs/2026-10-30-plab-production-ranking-design.md
Live search: docs/superpowers/specs/2026-10-30-plab-live-search-design.md
Unit tests: `python3 -m unittest -v` in this directory.
"""
import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import page
import parse
import prune
import transmission
from classify import MODEL, Classifier
from forums import FORUMS, category
from lab import Lab, LimitError, LoginError, TrackerError
from labels import match_term, term_label
from store import Store, key

DAYS = 7
LIMIT = 100
DELAY = 1.0  # seconds between topic fetches; be gentle with the tracker
# Consecutive classifier failures after which one refresh stops asking; the next refresh retries.
CLASSIFY_FAILURE_LIMIT = 3
# One results page per live search: a single tracker request.
SEARCH_LIMIT = 50
# Topic pages fetched at once for search thumbnails; one results page must not burst the tracker.
FETCH_SLOTS = threading.BoundedSemaphore(2)


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


def load_filters(path=None, state_dir=None):
    """The curated filters as [(name, [search terms])], in file order.

    Read from `path` (or PLAB_FILTER_FILE), falling back to `filter.txt` in `state_dir`;
    neither means no curated filters. A `[Name]` line starts a filter, each line under it
    is a tracker search term, and terms before any header belong to "Curated". Blank lines
    and `#` comments are ignored. On galactica the file is the plab-filter sops secret:
    the names and terms are kept out of this repository on purpose.
    """
    if path is None:
        path = os.environ.get("PLAB_FILTER_FILE")
    if not path and state_dir:
        candidate = os.path.join(state_dir, "filter.txt")
        if os.path.isfile(candidate):
            path = candidate
    if not path or not os.path.isfile(path):
        return []
    filters = {}
    name = "Curated"
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                name = line[1:-1].strip() or "Curated"
            else:
                filters.setdefault(name, []).append(line)
    return list(filters.items())


def load_excludes(path=None, state_dir=None):
    """Load regex exclusion patterns from file.

    Checks `path` (or PLAB_EXCLUDE_FILE), falling back to `exclude.txt` in `state_dir`.
    Returns a list of compiled re.Pattern objects.
    """
    if path is None:
        path = os.environ.get("PLAB_EXCLUDE_FILE")
    if not path and state_dir:
        candidate = os.path.join(state_dir, "exclude.txt")
        if os.path.isfile(candidate):
            path = candidate
    if not path or not os.path.isfile(path):
        return []
    patterns = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                patterns.append(re.compile(line, re.IGNORECASE))
    return patterns


def exclude_predicate(patterns):
    """A row predicate that rejects titles matching any exclusion pattern."""
    if not patterns:
        return lambda row: True
    return lambda row: not any(p.search(row.get("title", "")) for p in patterns)


def match_filters(filters, title, found=None):
    """The curated filters a release belongs to, in file order, and the badge of the first.

    `found` holds {filter name: badge} for filters whose search returned it; any other
    filter claims it when the title names one of its terms."""
    matched = dict(found or {})
    for name, terms in filters:
        term = name not in matched and next((t for t in terms if match_term(t, title)), None)
        if term:
            matched[name] = term_label(term)
    names = [name for name, _ in filters if name in matched]
    return names, matched[names[0]] if names else None


def refresh(lab, store, forums=FORUMS, days=DAYS, limit=LIMIT, sleep=time.sleep,
            exclude_file=None, filter_file=None, classify=None):
    """Rebuild cache.json. Raises, leaving the old cache in place, if the list fails."""
    patterns = load_excludes(exclude_file, state_dir=store.root)
    pred = exclude_predicate(patterns)
    rows = lab.top(forums, days, limit, predicate=pred)
    if not rows:
        raise RuntimeError("tracker returned no rows")

    # Each filter's terms are searched over a longer window: that content rarely makes the top list.
    filters = load_filters(filter_file, state_dir=store.root)
    found = {}  # topic id -> {filter name: badge of the first term that found it}
    extra_rows = []
    for name, terms in filters:
        for term in terms:
            sleep(DELAY)
            try:
                results = lab.search(term, forums, days=32, limit=20, predicate=pred)
            except LoginError:
                raise
            except Exception as err:  # noqa: BLE001 -- one failed search must not sink the refresh
                log(f"search failed for {term!r}: {err}")
                continue
            for r in results:
                found.setdefault(r["id"], {}).setdefault(name, term_label(term))
                extra_rows.append(r)

    # Combine & deduplicate rows by id
    seen = set()
    combined = []
    for r in rows + extra_rows:
        if r["id"] not in seen:
            seen.add(r["id"])
            combined.append(r)

    previous = {t["id"]: t for t in store.cache()["topics"]}
    fetch = _image_fetcher(lab)
    topics = []
    classify_failures = 0
    for row in combined:
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
        # A top-list release whose title names a term belongs to that filter too.
        names, reason = match_filters(filters, row["title"], found.get(row["id"]))
        topic = {**row, "images": images, "filters": names, "curated_reason": reason}
        # Judged once per release; an unclassified one ranks on seeders alone until retried.
        production = previous.get(row["id"], {}).get("production")
        if production is None and classify and classify_failures < CLASSIFY_FAILURE_LIMIT:
            try:
                production = classify(row["title"], category(row["forum"]))
                classify_failures = 0
            except Exception as e:  # noqa: BLE001 -- classification must never sink the refresh
                classify_failures += 1
                log(f"classify {row['id']}: {e!r}")
                if classify_failures == CLASSIFY_FAILURE_LIMIT:
                    log(f"classify: {CLASSIFY_FAILURE_LIMIT} failures in a row, "
                        "skipping the rest of this refresh")
        if production:
            topic["production"] = production
        topics.append(topic)
    store.save_cache(topics, [name for name, _ in filters])
    store.prune_images(_image_urls(store))  # after save_cache: the new list, plus searches
    log(f"refreshed: {len(topics)} topics ({sum(1 for t in topics if t['filters'])} curated, "
        f"{sum(1 for t in topics if 'production' in t)} classified)")


def _listed(store, topic_id):
    """A topic of the weekly list or of a recent live search, or None."""
    for t in store.cache()["topics"]:
        if t["id"] == topic_id:
            return t
    return store.search_topics().get(str(topic_id))


def _image_urls(store):
    """Every image URL plab may serve: the weekly list's and the recent searches'."""
    topics = store.cache()["topics"] + list(store.search_topics().values())
    return (u for t in topics for u in t.get("images") or [])


def add_topic(lab, store, topic_id, rpc_url, download_dir, add=transmission.add):
    """Send a listed topic's torrent to Transmission.

    Returns {"name": ...}, or {"queued": True, "message": ...} when the tracker's daily
    download limit is reached: the topic waits in the queue for `drain_queue`."""
    if topic_id in store.added():
        return {"name": "already added"}  # a stale page must not burn a daily-quota slot
    if _listed(store, topic_id) is None:
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


def run_refresh(lab, store, rpc_url, download_dir, exclude_file=None, filter_file=None, classify=None):
    """The `refresh` subcommand: drain the queue, then rebuild the list."""
    try:
        drain_queue(lab, store, rpc_url, download_dir)
    except LoginError:
        raise  # the session is gone; the list refresh would only fail the same way
    except Exception as e:  # noqa: BLE001 -- the list refresh must still run
        log(f"queue drain failed: {e}")
    refresh(lab, store, exclude_file=exclude_file, filter_file=filter_file, classify=classify)


def make_classifier(key_file=None, model=None):
    """The production classifier for `refresh`, or None without an OpenRouter key."""
    key_file = key_file or os.environ.get("PLAB_OPENROUTER_KEY_FILE")
    if not key_file or not os.path.isfile(key_file):
        return None
    with open(key_file) as f:
        api_key = f.read().strip()
    return Classifier(api_key, model or os.environ.get("PLAB_JEV_MODEL") or MODEL).classify


def image_for(lab, store, image_key):
    """(bytes, content type) for an image of a listed topic, fetching it on first use.

    Only URLs of listed or searched topics resolve, so this is not an open proxy."""
    urls = {key(u): u for u in _image_urls(store)}
    url = urls.get(image_key)
    if url is None:
        return None
    with open(store.ensure_image(url, _image_fetcher(lab)), "rb") as f:
        data = f.read()
    return data, sniff(data)


def run_search(lab, store, query, exclude_file=None, filter_file=None, now=None):
    """A live tracker search over all time, recorded in search.json; the entries in tracker
    order, with their curated filters. Never touches cache.json."""
    pred = exclude_predicate(load_excludes(exclude_file, state_dir=store.root))
    rows = lab.search(query, FORUMS, days=None, limit=SEARCH_LIMIT, predicate=pred, pages=1)
    now = time.time() if now is None else now
    store.save_search(rows, now)
    known = store.search_topics(now)
    filters = load_filters(filter_file, state_dir=store.root)
    topics = []
    for r in rows:
        names, reason = match_filters(filters, r["title"])
        topics.append({**known[str(r["id"])], "filters": names, "curated_reason": reason})
    return topics


def topic_images(lab, store, topic_id, slots=FETCH_SLOTS):
    """The image URLs of a listed or searched topic, fetching a searched one's on first use."""
    topic = _listed(store, topic_id)
    if topic is None:
        raise ValueError(f"topic {topic_id} is not on the list")
    if topic.get("images") is not None:
        return topic["images"]
    with slots:
        # Another request may have fetched them while this one waited.
        images = (_listed(store, topic_id) or {}).get("images")
        if images is None:
            images = parse.images(lab.topic(topic_id))
            store.set_search_images(topic_id, images)
    return images


# The vendored daisyUI and Tailwind files the page links (see default.nix). Exact names
# only: anything else under /static is a 404, so the directory is never browsed.
STATIC = {
    "daisyui.css": "text/css; charset=utf-8",
    "themes.css": "text/css; charset=utf-8",
    "tailwind.js": "text/javascript; charset=utf-8",
    "alpine.js": "text/javascript; charset=utf-8",
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


def make_handler(lab, store, rpc_url, download_dir, static_dir=None, exclude_file=None, filter_file=None):
    lock = threading.Lock()  # one add at a time: added.json is read-modify-write

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype, cache="no-store"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            self.end_headers()
            self.wfile.write(body)

        def _redirect(self, location):
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _search(self, query):
            if not query:
                return self._redirect("./")
            try:
                topics, error = run_search(lab, store, query, exclude_file, filter_file), None
            except Exception as e:  # noqa: BLE001 -- the reason goes on the page, next to the box
                topics, error = [], str(e)
                log(f"search {query!r} failed: {e}")
            cache = {**store.cache(), "topics": topics}
            body = page.render(cache, store.added(), set(store.queued()), time.time(),
                               search={"query": query, "error": error}).encode()
            self._send(200, body, "text/html; charset=utf-8")

        def _topic_images(self, kind, topic_id):
            try:
                images = topic_images(lab, store, topic_id)
                if kind == "images":
                    body = json.dumps({"images": [key(u) for u in images]}).encode()
                    return self._send(200, body, "application/json")
                if not images:
                    return self._send(404, b"no images", "text/plain")
                store.ensure_image(images[0], _image_fetcher(lab))
            except ValueError as e:  # not listed or searched, or not an image
                return self._send(404, str(e).encode(), "text/plain")
            except Exception as e:  # noqa: BLE001 -- the card keeps its placeholder
                log(f"{kind} {topic_id}: {e}")
                return self._send(502, b"images unavailable", "text/plain")
            self._redirect(f"../img/{key(images[0])}")

        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            if url.path == "/search":
                return self._search(urllib.parse.parse_qs(url.query).get("q", [""])[0].strip())
            m = re.fullmatch(r"/(thumb|images)/(\d+)", self.path)
            if m:
                return self._topic_images(m.group(1), int(m.group(2)))
            if self.path == "/":
                cache = store.cache()
                patterns = load_excludes(exclude_file, state_dir=store.root)
                if patterns:
                    pred = exclude_predicate(patterns)
                    cache = {**cache, "topics": [t for t in cache.get("topics", []) if pred(t)]}
                body = page.render(cache, store.added(), set(store.queued()), time.time()).encode()
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

    return Handler


def serve(lab, store, bind, port, rpc_url, download_dir, static_dir=None, exclude_file=None, filter_file=None):
    handler = make_handler(lab, store, rpc_url, download_dir, static_dir, exclude_file, filter_file)
    log(f"serving on {bind}:{port}")
    ThreadingHTTPServer((bind, port), handler).serve_forever()


def run_prune(rpc_url, vault_dir, now, dry_run=False, list_=transmission.torrents, remove=transmission.remove):
    """Remove the torrents prune.decide picks, in one call; return them."""
    chosen = prune.decide(list_(rpc_url), now, vault_dir)
    for _, name, reason in chosen:
        log(f"{'would remove' if dry_run else 'removed'} {name}: {reason}")
    if chosen and not dry_run:
        remove(rpc_url, [i for i, _, _ in chosen])
    return chosen


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
    sub.add_parser("prune").add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    if args.cmd == "prune":  # Transmission only: no tracker login, no state
        run_prune(os.environ["PLAB_TRANSMISSION_URL"], os.environ["PLAB_DOWNLOAD_DIR"], time.time(), args.dry_run)
        return

    state = os.environ.get("PLAB_STATE_DIR", "/var/lib/plab")
    store = Store(state)
    lab = Lab(_secret("PLAB_USERNAME_FILE"), _secret("PLAB_PASSWORD_FILE"), os.path.join(state, "cookies.txt"))
    if args.cmd == "refresh":
        run_refresh(lab, store, os.environ["PLAB_TRANSMISSION_URL"], os.environ["PLAB_DOWNLOAD_DIR"],
                    os.environ.get("PLAB_EXCLUDE_FILE"), os.environ.get("PLAB_FILTER_FILE"),
                    make_classifier())
    elif args.cmd == "serve":
        serve(lab, store, args.bind, args.port, os.environ["PLAB_TRANSMISSION_URL"], os.environ["PLAB_DOWNLOAD_DIR"],
              os.environ.get("PLAB_STATIC_DIR"), os.environ.get("PLAB_EXCLUDE_FILE"),
              os.environ.get("PLAB_FILTER_FILE"))
    else:
        lab.set_cookie(args.value)
        log("cookie saved")


if __name__ == "__main__":
    main()
