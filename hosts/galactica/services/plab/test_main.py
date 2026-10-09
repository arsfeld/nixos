import os
import tempfile
import unittest

import main
from lab import LoginError
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
    def __init__(self, rows, broken_topics=(), logged_out=()):
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
        name = main.add_topic(self.lab, self.store, 1, "http://rpc", "/vault", add=add)
        self.assertEqual(name, "Release")
        self.assertEqual(calls, [("http://rpc", b"d4:infoe", "/vault")])
        self.assertEqual(self.store.added(), {1})

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
