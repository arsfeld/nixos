import os
import tempfile
import unittest

import main
from lab import LimitError, LoginError, TrackerError
from store import Store, key

HERE = os.path.dirname(os.path.abspath(__file__))
JPEG = b"\xff\xd8\xff\xe0jpeg"


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return f.read()


def row(topic_id):
    return {"id": topic_id, "title": f"t{topic_id}", "forum": 1875, "size": 1, "seeders": 9,
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

    def top(self, forums, days, limit):
        return self.rows

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
        self.assertEqual(self.sleeps, [main.DELAY, main.DELAY])

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
        main.drain_queue, main.refresh = drain, lambda lab, store: calls.append("refresh")
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


if __name__ == "__main__":
    unittest.main()
