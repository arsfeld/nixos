import os
import tempfile
import time
import unittest

from store import SEARCH_TTL, Store, key

T = time.time()  # entries are read against the real clock


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def test_empty_defaults(self):
        self.assertEqual(self.store.cache(), {"updated": 0, "topics": []})
        self.assertEqual(self.store.added(), set())

    def test_cache_roundtrip(self):
        self.store.save_cache([{"id": 1, "images": []}])
        cache = self.store.cache()
        self.assertEqual(cache["topics"], [{"id": 1, "images": []}])
        self.assertGreater(cache["updated"], 0)

    def test_mark_added_persists(self):
        self.store.mark_added(5)
        self.store.mark_added(3)
        self.assertEqual(Store(self.dir.name).added(), {3, 5})

    def test_queue(self):
        self.assertEqual(self.store.queued(), [])
        self.store.enqueue(5)
        self.store.enqueue(3)
        self.store.enqueue(5)  # no duplicates
        self.assertEqual(Store(self.dir.name).queued(), [5, 3])  # oldest first
        self.store.dequeue(5)
        self.store.dequeue(99)  # unknown: no-op
        self.assertEqual(self.store.queued(), [3])

    def test_enqueue_skips_added(self):
        self.store.mark_added(4)
        self.store.enqueue(4)
        self.assertEqual(self.store.queued(), [])

    def test_ensure_image_fetches_once(self):
        calls = []

        def fetch(url):
            calls.append(url)
            return b"\xff\xd8\xffdata"

        path = self.store.ensure_image("https://x/a.jpg", fetch)
        self.store.ensure_image("https://x/a.jpg", fetch)
        self.assertEqual(calls, ["https://x/a.jpg"])
        self.assertEqual(os.path.basename(path), key("https://x/a.jpg"))
        with open(path, "rb") as f:
            self.assertEqual(f.read(), b"\xff\xd8\xffdata")

    def test_prune_images(self):
        fetch = lambda url: b"x"  # noqa: E731
        keep = self.store.ensure_image("https://x/keep.jpg", fetch)
        drop = self.store.ensure_image("https://x/drop.jpg", fetch)
        self.store.prune_images(["https://x/keep.jpg"])
        self.assertTrue(os.path.exists(keep))
        self.assertFalse(os.path.exists(drop))

    def test_search_empty_default(self):
        self.assertEqual(self.store.search_topics(), {})

    def test_save_search_records_rows_without_images(self):
        self.store.save_search([{"id": 5, "title": "a"}], now=T)
        self.assertEqual(Store(self.dir.name).search_topics(),
                         {"5": {"id": 5, "title": "a", "images": None, "at": T}})

    def test_save_search_keeps_known_images_and_refreshes_at(self):
        self.store.save_search([{"id": 5, "title": "a"}], now=T)
        self.store.set_search_images(5, ["https://x/1.jpg"])
        self.store.save_search([{"id": 5, "title": "a2"}], now=T + 1000)
        self.assertEqual(self.store.search_topics()["5"],
                         {"id": 5, "title": "a2", "images": ["https://x/1.jpg"], "at": T + 1000})

    def test_save_search_drops_entries_older_than_a_day(self):
        self.store.save_search([{"id": 5}], now=T)
        self.store.save_search([{"id": 6}], now=T + SEARCH_TTL)
        self.assertEqual(set(self.store.search_topics()), {"5", "6"})  # exactly a day: kept
        self.store.save_search([{"id": 7}], now=T + 1 + SEARCH_TTL)
        self.assertEqual(set(self.store.search_topics()), {"6", "7"})

    def test_search_topics_hides_expired_entries_without_writing(self):
        self.store.save_search([{"id": 5}], now=T)
        path = os.path.join(self.dir.name, "search.json")
        with open(path, "rb") as f:
            before = f.read()
        self.assertEqual(set(self.store.search_topics(now=T + SEARCH_TTL)), {"5"})
        self.assertEqual(self.store.search_topics(now=T + 1 + SEARCH_TTL), {})
        self.assertEqual(set(self.store.search_topics()), {"5"})  # fresh by the real clock
        self.assertEqual(self.store.search_topics(now=T + SEARCH_TTL + 5), {})
        with open(path, "rb") as f:
            self.assertEqual(f.read(), before)

    def test_set_search_images_unknown_topic_is_a_no_op(self):
        self.store.set_search_images(9, ["https://x/1.jpg"])
        self.assertEqual(self.store.search_topics(), {})

    def test_prune_keeps_in_flight_temp_files(self):
        keep = self.store.ensure_image("https://x/keep.jpg", lambda url: b"x")
        tmp = os.path.join(self.store.img, key("https://x/other.jpg") + ".123.456.tmp")
        with open(tmp, "wb") as f:
            f.write(b"partial")
        self.store.prune_images(["https://x/keep.jpg"])
        self.assertTrue(os.path.exists(keep))
        self.assertTrue(os.path.exists(tmp))

    def test_corrupt_json_reads_as_defaults(self):
        with open(os.path.join(self.dir.name, "cache.json"), "w") as f:
            f.write("")
        with open(os.path.join(self.dir.name, "added.json"), "w") as f:
            f.write("not json{")
        self.assertEqual(self.store.cache(), {"updated": 0, "topics": []})
        self.assertEqual(self.store.added(), set())
        with open(os.path.join(self.dir.name, "queued.json"), "w") as f:
            f.write("[1,")
        self.assertEqual(self.store.queued(), [])


if __name__ == "__main__":
    unittest.main()
