import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import main
from lab import LimitError, LoginError, TrackerError
from store import Store, key

HERE = os.path.dirname(os.path.abspath(__file__))
JPEG = b"\xff\xd8\xff\xe0jpeg"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return f.read()


def row(topic_id, title=None):
    return {"id": topic_id, "title": title or f"t{topic_id}", "forum": 1875, "size": 1, "seeders": 9,
            "leechers": 0, "completed": 0, "added": 0}


class FakeLab:
    def __init__(self, rows, broken_topics=(), logged_out=(), errors=None):
        self.errors = errors or {}
        self.logged_out = set(logged_out)
        self.rows = rows
        self.broken = set(broken_topics)
        self.topics_fetched = []
        self.fetched = []
        self.torrents = []
        self.searches = []
        self.search_error = None

    def top(self, forums, days, limit, predicate=None):
        rows = self.rows
        if predicate:
            rows = [r for r in rows if predicate(r)]
        return rows

    def search(self, query, forums, days=32, limit=20, predicate=None, pages=None):
        self.searches.append((query, days, limit, pages))
        if self.search_error:
            raise self.search_error
        rows = getattr(self, "searched_rows", {}).get(query, [])
        if predicate:
            rows = [r for r in rows if predicate(r)]
        return rows

    def topic(self, topic_id):
        self.topics_fetched.append(topic_id)
        if topic_id in self.logged_out:
            raise LoginError("login needs captcha")
        if topic_id in self.broken:
            raise OSError("boom")
        return fixture("topic.html")

    def fetch(self, url):
        self.fetched.append(url)
        return JPEG

    def torrent(self, topic_id):
        self.torrents.append(topic_id)
        if topic_id in self.errors:
            raise self.errors[topic_id]
        return b"d4:infoe"


COVER = "https://i128.fastpic.org/big/2026/1004/19/cover.jpg"


class Refresh(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.sleeps = []

    def tearDown(self):
        self.dir.cleanup()

    def refresh(self, lab):
        main.refresh(lab, self.store, sleep=self.sleeps.append)

    def test_fetches_topics_and_first_image(self):
        lab = FakeLab([row(1), row(2)])
        self.refresh(lab)
        topics = self.store.cache()["topics"]
        self.assertEqual([t["id"] for t in topics], [1, 2])
        self.assertEqual(topics[0]["images"][0], COVER)
        self.assertEqual(lab.fetched, [COVER])  # same cover for both; fetched once
        self.assertEqual(self.sleeps, [main.DELAY] * 2)  # no filter file: no searches

    def test_reuses_cached_images(self):
        self.refresh(FakeLab([row(1)]))
        lab = FakeLab([row(1)])
        self.refresh(lab)
        self.assertEqual(lab.topics_fetched, [])

    def test_broken_topic_is_kept_without_images_and_retried(self):
        self.refresh(FakeLab([row(1)], broken_topics={1}))
        self.assertEqual(self.store.cache()["topics"][0]["images"], [])
        lab = FakeLab([row(1)])
        self.refresh(lab)
        self.assertEqual(lab.topics_fetched, [1])

    def test_no_rows_keeps_old_cache(self):
        self.refresh(FakeLab([row(1)]))
        with self.assertRaises(RuntimeError):
            self.refresh(FakeLab([]))
        self.assertEqual([t["id"] for t in self.store.cache()["topics"]], [1])

    def test_login_error_aborts_refresh_and_keeps_cache(self):
        self.refresh(FakeLab([row(1)]))
        lab = FakeLab([row(2), row(3), row(4)], logged_out={2})
        with self.assertRaises(LoginError):
            self.refresh(lab)
        self.assertEqual(lab.topics_fetched, [2])
        self.assertEqual([t["id"] for t in self.store.cache()["topics"]], [1])

    def test_prunes_images_of_dropped_topics(self):
        self.store.ensure_image("https://old/gone.jpg", lambda url: JPEG)
        self.refresh(FakeLab([row(1)]))
        self.assertFalse(os.path.exists(self.store.image_path("https://old/gone.jpg")))
        self.assertTrue(os.path.exists(self.store.image_path(COVER)))

    def write_filters(self, text):
        path = os.path.join(self.dir.name, "filters.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def test_refresh_assigns_top_list_rows_to_filters_by_title(self):
        path = self.write_filters("[Group A]\nAlpha Studio\n[Group B]\n\"beta word\"\n")
        lab = FakeLab([
            row(1, "[AlphaStudio.com] Movie [1080p]"),
            row(2, "Regular Movie [1080p]"),
            row(3, "Alpha Studio - Beta Word Scene"),
        ])
        main.refresh(lab, self.store, filter_file=path, sleep=lambda _: None)
        cache = self.store.cache()
        by_id = {t["id"]: t for t in cache["topics"]}
        self.assertEqual(cache["filters"], ["Group A", "Group B"])
        self.assertEqual(by_id[1]["filters"], ["Group A"])
        self.assertEqual(by_id[1]["curated_reason"], "Alpha Studio")
        self.assertEqual(by_id[2]["filters"], [])
        self.assertIsNone(by_id[2]["curated_reason"])
        self.assertEqual(by_id[3]["filters"], ["Group A", "Group B"])

    def test_refresh_merges_search_results_into_their_filter(self):
        path = self.write_filters("[Group A]\nAlpha\n[Group B]\nBeta\n")
        lab = FakeLab([row(1, "Mainstream Top 100")])
        lab.searched_rows = {"Alpha": [row(2, "Unrelated Title")],
                             "Beta": [row(1, "Mainstream Top 100"), row(2, "Unrelated Title")]}
        main.refresh(lab, self.store, filter_file=path, sleep=lambda _: None)
        by_id = {t["id"]: t for t in self.store.cache()["topics"]}
        self.assertEqual(list(by_id), [1, 2])
        self.assertEqual(by_id[1]["filters"], ["Group B"])
        self.assertEqual(by_id[1]["curated_reason"], "Beta")
        self.assertEqual(by_id[2]["filters"], ["Group A", "Group B"])
        self.assertEqual(by_id[2]["curated_reason"], "Alpha")

    def test_search_failure_continues_refresh(self):
        lab = FakeLab([row(1, "Top 1")])
        lab.search = lambda *args, **kwargs: (_ for _ in ()).throw(OSError("tracker timed out"))
        main.refresh(lab, self.store, filter_file=self.write_filters("Alpha\n"), sleep=lambda _: None)
        self.assertEqual([t["id"] for t in self.store.cache()["topics"]], [1])

    def test_search_login_error_aborts_refresh(self):
        lab = FakeLab([row(1, "Top 1")])
        lab.search = lambda *args, **kwargs: (_ for _ in ()).throw(LoginError("captcha"))
        with self.assertRaises(LoginError):
            main.refresh(lab, self.store, filter_file=self.write_filters("Alpha\n"), sleep=lambda _: None)

    def test_classifies_new_topics(self):
        calls = []

        def classify(title, category):
            calls.append((title, category))
            return {"class": "amateur", "confidence": 0.8}

        main.refresh(FakeLab([row(1, "[OnlyFans.com] A")]), self.store, sleep=self.sleeps.append,
                     classify=classify)
        self.assertEqual(calls, [("[OnlyFans.com] A", "Clips and siterips")])
        self.assertEqual(self.store.cache()["topics"][0]["production"],
                         {"class": "amateur", "confidence": 0.8})

    def test_reuses_stored_production(self):
        main.refresh(FakeLab([row(1)]), self.store, sleep=self.sleeps.append,
                     classify=lambda t, c: {"class": "industrial", "confidence": None})
        calls = []
        main.refresh(FakeLab([row(1), row(2)]), self.store, sleep=self.sleeps.append,
                     classify=lambda t, c: calls.append(t) or {"class": "amateur", "confidence": None})
        self.assertEqual(calls, ["t2"])
        topics = {t["id"]: t for t in self.store.cache()["topics"]}
        self.assertEqual(topics[1]["production"]["class"], "industrial")
        self.assertEqual(topics[2]["production"]["class"], "amateur")

    def test_repeated_classifier_failures_stop_the_refresh_classifying(self):
        calls = []

        def classify(title, category):
            calls.append(title)
            raise OSError("openrouter hung")

        main.refresh(FakeLab([row(i) for i in range(1, 6)]), self.store, sleep=self.sleeps.append,
                     classify=classify)
        self.assertEqual(len(calls), main.CLASSIFY_FAILURE_LIMIT)
        topics = self.store.cache()["topics"]
        self.assertEqual([t["id"] for t in topics], [1, 2, 3, 4, 5])
        self.assertFalse(any("production" in t for t in topics))

    def test_classifier_failure_leaves_topic_unclassified(self):
        def classify(title, category):
            raise OSError("openrouter down")

        main.refresh(FakeLab([row(1)]), self.store, sleep=self.sleeps.append, classify=classify)
        topics = self.store.cache()["topics"]
        self.assertEqual([t["id"] for t in topics], [1])
        self.assertNotIn("production", topics[0])

    def test_without_classifier_no_production(self):
        self.refresh(FakeLab([row(1)]))
        self.assertNotIn("production", self.store.cache()["topics"][0])


class Drain(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.calls = []

    def tearDown(self):
        self.dir.cleanup()

    def add(self, url, torrent, ddir):
        self.calls.append((url, torrent, ddir))
        return "n"

    def drain(self, lab, add=None):
        main.drain_queue(lab, self.store, "http://rpc", "/vault", add=add or self.add)

    def queue(self, *ids):
        for i in ids:
            self.store.enqueue(i)

    def test_drains_oldest_first_without_cache(self):
        self.queue(3, 1, 2)
        lab = FakeLab([])
        self.drain(lab)
        self.assertEqual(lab.torrents, [3, 1, 2])
        self.assertEqual(self.store.queued(), [])
        self.assertEqual(self.store.added(), {1, 2, 3})
        self.assertEqual(self.calls[0], ("http://rpc", b"d4:infoe", "/vault"))

    def test_stops_at_limit_and_keeps_the_rest(self):
        self.queue(1, 2, 3)
        lab = FakeLab([], errors={2: LimitError("limit")})
        self.drain(lab)
        self.assertEqual(lab.torrents, [1, 2])
        self.assertEqual(self.store.queued(), [2, 3])
        self.assertEqual(self.store.added(), {1})

    def test_tracker_error_dequeues_and_continues(self):
        self.queue(1, 2)
        lab = FakeLab([], errors={1: TrackerError("gone")})
        self.drain(lab)
        self.assertEqual(self.store.queued(), [])
        self.assertEqual(self.store.added(), {2})

    def test_other_errors_keep_queued_and_continue(self):
        self.queue(1, 2)

        def add(url, torrent, ddir):
            if not self.calls:
                self.calls.append(1)
                raise OSError("transmission down")
            return "n"

        lab = FakeLab([])
        self.drain(lab, add=add)
        self.assertEqual(lab.torrents, [1, 2])
        self.assertEqual(self.store.queued(), [1])
        self.assertEqual(self.store.added(), {2})

    def test_network_error_fetching_keeps_queued(self):
        self.queue(1)
        self.drain(FakeLab([], errors={1: OSError("net")}))
        self.assertEqual(self.store.queued(), [1])

    def test_login_error_propagates(self):
        self.queue(1, 2)
        lab = FakeLab([], errors={1: LoginError("captcha")})
        with self.assertRaises(LoginError):
            self.drain(lab)
        self.assertEqual(lab.torrents, [1])
        self.assertEqual(self.store.queued(), [1, 2])


class RunRefresh(unittest.TestCase):
    def run_it(self, drain_error):
        calls = self.calls = []

        def drain(*args):
            calls.append("drain")
            raise drain_error

        saved = main.drain_queue, main.refresh
        main.drain_queue, main.refresh = drain, lambda lab, store, **kw: calls.append("refresh")
        try:
            main.run_refresh(None, None, "http://rpc", "/vault")
        finally:
            main.drain_queue, main.refresh = saved
        return calls

    def test_drain_failure_does_not_stop_refresh(self):
        self.assertEqual(self.run_it(RuntimeError("boom")), ["drain", "refresh"])

    def test_login_error_aborts_before_refresh(self):
        with self.assertRaises(LoginError):
            self.run_it(LoginError("captcha"))
        self.assertEqual(self.calls, ["drain"])  # refresh never ran

    def test_run_refresh_passes_filter_file(self):
        calls = []
        saved = main.drain_queue, main.refresh
        main.drain_queue = lambda *args: None
        main.refresh = lambda lab, store, exclude_file=None, filter_file=None, **kw: calls.append(filter_file)
        try:
            main.run_refresh(None, None, "http://rpc", "/vault", filter_file="/path/filter.txt")
        finally:
            main.drain_queue, main.refresh = saved
        self.assertEqual(calls, ["/path/filter.txt"])

    def test_run_refresh_passes_classifier(self):
        calls = []
        saved = main.drain_queue, main.refresh
        main.drain_queue = lambda *args: None
        main.refresh = lambda lab, store, classify=None, **kw: calls.append(classify)
        classify = object()
        try:
            main.run_refresh(None, None, "http://rpc", "/vault", classify=classify)
        finally:
            main.drain_queue, main.refresh = saved
        self.assertEqual(calls, [classify])


class Routes(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.save_cache([dict(row(1), images=[COVER, "https://x/b.jpg"])])
        self.lab = FakeLab([])

    def tearDown(self):
        self.dir.cleanup()

    def test_add_known_topic(self):
        calls = []
        add = lambda url, torrent, ddir: calls.append((url, torrent, ddir)) or "Release"  # noqa: E731
        result = main.add_topic(self.lab, self.store, 1, "http://rpc", "/vault", add=add)
        self.assertEqual(result, {"name": "Release"})
        self.assertEqual(calls, [("http://rpc", b"d4:infoe", "/vault")])
        self.assertEqual(self.store.added(), {1})

    def test_add_over_the_limit_is_queued(self):
        lab = FakeLab([], errors={1: LimitError("daily download limit reached (10/day)")})
        result = main.add_topic(lab, self.store, 1, "http://rpc", "/vault", add=None)
        self.assertEqual(result, {"queued": True, "message": "daily download limit reached (10/day)"})
        self.assertEqual(self.store.queued(), [1])
        self.assertEqual(self.store.added(), set())

    def test_add_already_added_topic_skips_fetch(self):
        self.store.mark_added(1)
        result = main.add_topic(self.lab, self.store, 1, "http://rpc", "/vault", add=None)
        self.assertEqual(result, {"name": "already added"})
        self.assertEqual(self.lab.torrents, [])

    def test_unqueue_removes_from_queue(self):
        self.store.enqueue(1)
        self.store.enqueue(2)
        self.assertEqual(main.unqueue_topic(self.store, 1), {})
        self.assertEqual(self.store.queued(), [2])

    def test_unqueue_is_idempotent(self):
        self.assertEqual(main.unqueue_topic(self.store, 1), {})
        self.assertEqual(self.store.queued(), [])

    def test_add_unknown_topic_rejected(self):
        with self.assertRaises(ValueError):
            main.add_topic(self.lab, self.store, 99, "http://rpc", "/vault", add=None)
        self.assertEqual(self.lab.torrents, [])

    def test_image_for_listed_url_is_fetched_lazily(self):
        data, ctype = main.image_for(self.lab, self.store, key("https://x/b.jpg"))
        self.assertEqual((data, ctype), (JPEG, "image/jpeg"))
        self.assertEqual(self.lab.fetched, ["https://x/b.jpg"])

    def test_image_for_unlisted_key(self):
        self.assertIsNone(main.image_for(self.lab, self.store, key("https://evil/x")))

    def test_image_that_is_not_an_image_is_refused(self):
        self.lab.fetch = lambda url: b"<html>"
        with self.assertRaises(ValueError):
            main.image_for(self.lab, self.store, key("https://x/b.jpg"))
        self.assertFalse(os.path.exists(self.store.image_path("https://x/b.jpg")))

    def test_sniff(self):
        self.assertEqual(main.sniff(b"\x89PNG\r\n\x1a\nxx"), "image/png")
        self.assertEqual(main.sniff(b"GIF89a"), "image/gif")
        self.assertEqual(main.sniff(b"RIFF\0\0\0\0WEBPVP8"), "image/webp")
        self.assertIsNone(main.sniff(b"<html>"))


class Search(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.save_cache([dict(row(1), images=[COVER])])
        self.lab = FakeLab([])
        self.lab.searched_rows = {"alpha": [row(5, "Alpha One"), row(6, "Ripe Cherry")]}

    def tearDown(self):
        self.dir.cleanup()

    def write(self, name, text):
        path = os.path.join(self.dir.name, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def test_run_search_all_time_excludes_and_records(self):
        exclude = self.write("ex.txt", "cherry\n")
        topics = main.run_search(self.lab, self.store, "alpha", exclude_file=exclude, now=1000)
        self.assertEqual([t["id"] for t in topics], [5])
        self.assertEqual(self.lab.searches, [("alpha", None, main.SEARCH_LIMIT, 1)])
        self.assertIsNone(topics[0]["images"])
        self.assertEqual(set(self.store.search_topics()), {"5"})
        self.assertEqual(self.store.cache()["topics"][0]["id"], 1)  # the weekly list is untouched

    def test_run_search_marks_curated_by_title(self):
        filters = self.write("f.txt", "[Fav]\nalpha\n[Other]\nzulu\n")
        topics = main.run_search(self.lab, self.store, "alpha", filter_file=filters, now=1000)
        self.assertEqual(topics[0]["filters"], ["Fav"])
        self.assertEqual(topics[0]["curated_reason"], "Alpha")
        self.assertEqual(topics[1]["filters"], [])

    def test_match_filters_prefers_found_badges(self):
        filters = [("A", ["alpha"]), ("B", ["one"])]
        self.assertEqual(main.match_filters(filters, "Alpha One", {"B": "Searched"}), (["A", "B"], "Alpha"))
        self.assertEqual(main.match_filters(filters, "nothing"), ([], None))

    def test_topic_images_fetches_a_searched_topic_once(self):
        main.run_search(self.lab, self.store, "alpha", now=1000)
        self.assertEqual(main.topic_images(self.lab, self.store, 5)[0], COVER)
        self.assertEqual(main.topic_images(self.lab, self.store, 5)[0], COVER)
        self.assertEqual(self.lab.topics_fetched, [5])
        self.assertEqual(self.store.search_topics()["5"]["images"][0], COVER)

    def test_topic_images_of_a_listed_topic_needs_no_fetch(self):
        self.assertEqual(main.topic_images(self.lab, self.store, 1), [COVER])
        self.assertEqual(self.lab.topics_fetched, [])

    def test_topic_images_unknown_topic_rejected(self):
        with self.assertRaises(ValueError):
            main.topic_images(self.lab, self.store, 99)
        self.assertEqual(self.lab.topics_fetched, [])

    def test_add_accepts_a_searched_topic(self):
        main.run_search(self.lab, self.store, "alpha", now=1000)
        result = main.add_topic(self.lab, self.store, 5, "http://rpc", "/vault", add=lambda *a: "Release")
        self.assertEqual(result, {"name": "Release"})
        self.assertEqual(self.store.added(), {5})

    def test_image_for_accepts_a_searched_topics_image(self):
        main.run_search(self.lab, self.store, "alpha", now=1000)
        self.store.set_search_images(5, ["https://s/only.jpg"])
        data, ctype = main.image_for(self.lab, self.store, key("https://s/only.jpg"))
        self.assertEqual((data, ctype), (JPEG, "image/jpeg"))

    def test_refresh_keeps_images_of_searched_topics(self):
        main.run_search(self.lab, self.store, "alpha", now=1000)
        self.store.set_search_images(5, ["https://s/only.jpg"])
        path = self.store.ensure_image("https://s/only.jpg", lambda url: JPEG)
        main.refresh(FakeLab([row(1)]), self.store, sleep=lambda s: None)
        self.assertTrue(os.path.exists(path))


class SearchRoutes(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.lab = FakeLab([])
        self.lab.searched_rows = {"alpha": [row(5, "Alpha One")]}
        handler = main.make_handler(self.lab, self.store, "http://rpc", "/vault")
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.opener = urllib.request.build_opener(NoRedirect)

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.dir.cleanup()

    def get(self, path):
        """(status, headers, body) without following redirects."""
        url = f"http://127.0.0.1:{self.httpd.server_address[1]}{path}"
        try:
            with self.opener.open(url) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            with e:
                return e.code, e.headers, e.read()

    def test_blank_query_redirects_to_the_list(self):
        status, headers, _ = self.get("/search?q=+")
        self.assertEqual((status, headers["Location"]), (302, "./"))

    def test_results_page(self):
        status, _, body = self.get("/search?q=alpha")
        self.assertEqual(status, 200)
        self.assertIn(b"Alpha One", body)
        self.assertIn(b'src="thumb/5"', body)
        self.assertEqual(self.lab.searches, [("alpha", None, main.SEARCH_LIMIT, 1)])

    def test_search_failure_is_shown_on_the_page(self):
        self.lab.search_error = LoginError("login needs captcha")
        status, _, body = self.get("/search?q=alpha")
        self.assertEqual(status, 200)
        self.assertIn(b"login needs captcha", body)

    def test_thumb_redirects_to_the_cached_image(self):
        self.get("/search?q=alpha")
        status, headers, _ = self.get("/thumb/5")
        self.assertEqual((status, headers["Location"]), (302, f"../img/{key(COVER)}"))
        self.assertTrue(os.path.exists(self.store.image_path(COVER)))

    def test_thumb_unknown_topic_is_404(self):
        self.assertEqual(self.get("/thumb/99")[0], 404)
        self.assertEqual(self.lab.topics_fetched, [])

    def test_thumb_topic_without_images_is_404(self):
        self.get("/search?q=alpha")
        self.store.set_search_images(5, [])
        self.assertEqual(self.get("/thumb/5")[0], 404)

    def test_thumb_fetch_failure_is_502(self):
        self.get("/search?q=alpha")
        self.lab.broken.add(5)
        self.assertEqual(self.get("/thumb/5")[0], 502)

    def test_images_lists_keys(self):
        self.get("/search?q=alpha")
        status, _, body = self.get("/images/5")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["images"][0], key(COVER))


class Static(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        for name in ("daisyui.css", "themes.css", "tailwind.js", "alpine.js", "secret.txt"):
            with open(os.path.join(self.dir.name, name), "w") as f:
                f.write(name)

    def tearDown(self):
        self.dir.cleanup()

    def test_allowed_names_with_types(self):
        self.assertEqual(main.static_file(self.dir.name, "daisyui.css"), (b"daisyui.css", "text/css; charset=utf-8"))
        self.assertEqual(main.static_file(self.dir.name, "themes.css")[1], "text/css; charset=utf-8")
        self.assertEqual(main.static_file(self.dir.name, "tailwind.js"),
                         (b"tailwind.js", "text/javascript; charset=utf-8"))
        self.assertEqual(main.static_file(self.dir.name, "alpine.js"),
                         (b"alpine.js", "text/javascript; charset=utf-8"))

    def test_unknown_name(self):
        self.assertIsNone(main.static_file(self.dir.name, "secret.txt"))
        self.assertIsNone(main.static_file(self.dir.name, ""))

    def test_traversal(self):
        for name in ("../main.py", "%2e%2e/main.py", "%2e%2e%2fmain.py", "/etc/passwd", "./daisyui.css",
                     "daisyui.css/", "sub/../daisyui.css"):
            self.assertIsNone(main.static_file(HERE, name), name)

    def test_no_static_dir(self):
        self.assertIsNone(main.static_file(None, "daisyui.css"))
        self.assertIsNone(main.static_file("", "daisyui.css"))

    def test_missing_file(self):
        os.remove(os.path.join(self.dir.name, "themes.css"))
        self.assertIsNone(main.static_file(self.dir.name, "themes.css"))


class ExcludeTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def test_load_excludes_from_file(self):
        path = os.path.join(self.dir.name, "terms.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("# comment line\n\n  apple  \n\\bbanana\\w*  \n")
        patterns = main.load_excludes(path)
        self.assertEqual(len(patterns), 2)
        pred = main.exclude_predicate(patterns)
        self.assertFalse(pred({"title": "A big red apple pie"}))
        self.assertFalse(pred({"title": "Sweet bananas for sale"}))
        self.assertTrue(pred({"title": "Fresh orange juice"}))

    def test_load_excludes_fallback_to_state_dir(self):
        candidate = os.path.join(self.dir.name, "exclude.txt")
        with open(candidate, "w", encoding="utf-8") as f:
            f.write("pear\n")
        patterns = main.load_excludes(state_dir=self.dir.name)
        self.assertEqual(len(patterns), 1)
        pred = main.exclude_predicate(patterns)
        self.assertFalse(pred({"title": "A sweet pear"}))
        self.assertTrue(pred({"title": "An orange"}))

    def test_load_excludes_missing_file_returns_empty(self):
        patterns = main.load_excludes("/nonexistent/file/path", state_dir=self.dir.name)
        self.assertEqual(patterns, [])
        pred = main.exclude_predicate(patterns)
        self.assertTrue(pred({"title": "anything"}))

    def test_refresh_filters_releases_with_exclude_file(self):
        exclude_path = os.path.join(self.dir.name, "exclude.txt")
        with open(exclude_path, "w", encoding="utf-8") as f:
            f.write("cherry\n")
        lab = FakeLab([
            row(1, "Fresh Apple"),
            row(2, "Ripe Cherry"),
            row(3, "Sweet Banana"),
        ])
        main.refresh(lab, self.store, exclude_file=exclude_path, sleep=lambda _: None)
        cached = self.store.cache()["topics"]
        self.assertEqual([t["id"] for t in cached], [1, 3])

    def test_serve_filters_cached_topics(self):
        exclude_path = os.path.join(self.dir.name, "exclude.txt")
        with open(exclude_path, "w", encoding="utf-8") as f:
            f.write("cherry\n")
        self.store.save_cache([
            dict(row(1, "Fresh Apple"), images=[]),
            dict(row(2, "Ripe Cherry"), images=[]),
        ])
        handler = main.make_handler(FakeLab([]), self.store, "http://rpc", "/vault", exclude_file=exclude_path)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        port = httpd.server_address[1]
        t = threading.Thread(target=httpd.serve_forever)
        t.daemon = True
        t.start()
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/") as resp:
                body = resp.read().decode()
                self.assertIn("Fresh Apple", body)
                self.assertNotIn("Ripe Cherry", body)
        finally:
            httpd.shutdown()
            httpd.server_close()


class FiltersTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def write(self, name, text):
        path = os.path.join(self.dir.name, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def test_no_file_means_no_filters(self):
        self.assertEqual(main.load_filters("/nonexistent/file", state_dir=self.dir.name), [])

    def test_sections_comments_and_whitespace(self):
        path = self.write("f.txt", "# comment\n\n[Group A]\n  Alpha  \n# more\n\"two words\"\n\n"
                                   "[ Group B ]\nBeta\n[Empty]\n")
        self.assertEqual(main.load_filters(path),
                         [("Group A", ["Alpha", "\"two words\""]), ("Group B", ["Beta"])])

    def test_terms_before_any_header_are_curated(self):
        path = self.write("f.txt", "Alpha\n[Group B]\nBeta\n")
        self.assertEqual(main.load_filters(path), [("Curated", ["Alpha"]), ("Group B", ["Beta"])])

    def test_repeated_header_extends_the_filter(self):
        path = self.write("f.txt", "[A]\nx\n[B]\ny\n[A]\nz\n")
        self.assertEqual(main.load_filters(path), [("A", ["x", "z"]), ("B", ["y"])])

    def test_from_state_dir(self):
        self.write("filter.txt", "[Group A]\nAlpha\n")
        self.assertEqual(main.load_filters(state_dir=self.dir.name), [("Group A", ["Alpha"])])

    def test_from_env(self):
        path = self.write("custom.txt", "Alpha\n")
        old_env = os.environ.get("PLAB_FILTER_FILE")
        os.environ["PLAB_FILTER_FILE"] = path
        try:
            self.assertEqual(main.load_filters(), [("Curated", ["Alpha"])])
        finally:
            if old_env is None:
                os.environ.pop("PLAB_FILTER_FILE", None)
            else:
                os.environ["PLAB_FILTER_FILE"] = old_env


class MakeClassifier(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def test_no_key_file_means_none(self):
        self.assertIsNone(main.make_classifier(os.path.join(self.dir.name, "missing")))

    def test_key_file_builds_classifier(self):
        path = os.path.join(self.dir.name, "key")
        with open(path, "w") as f:
            f.write("sk-key\n")
        fn = main.make_classifier(path, "other/model")
        self.assertEqual(fn.__self__.headers, {"Authorization": "Bearer sk-key"})
        self.assertEqual(fn.__self__.model, "other/model")


class RunPrune(unittest.TestCase):
    VAULT = "/v/Vault"
    TORRENTS = [
        {"id": 1, "name": "public", "downloadDir": "/v/Vault", "percentDone": 1.0, "uploadRatio": 0.0,
         "doneDate": 100, "activityDate": 100, "trackers": [{"announce": "udp://open.example:1337"}]},
        {"id": 2, "name": "lab", "downloadDir": "/v/Vault", "percentDone": 1.0, "uploadRatio": 0.1,
         "doneDate": 100, "activityDate": 100, "trackers": [{"announce": "http://bt.plab.site/ann"}]},
    ]

    def test_removes_chosen_in_one_call(self):
        calls = []
        chosen = main.run_prune("rpc", self.VAULT, 200, list_=lambda url: self.TORRENTS,
                                remove=lambda url, ids: calls.append((url, ids)))
        self.assertEqual([i for i, _, _ in chosen], [1])
        self.assertEqual(calls, [("rpc", [1])])

    def test_dry_run_removes_nothing(self):
        calls = []
        main.run_prune("rpc", self.VAULT, 200, dry_run=True, list_=lambda url: self.TORRENTS,
                       remove=lambda url, ids: calls.append(ids))
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()

