import os
import tempfile
import unittest

from store import Store, key


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


if __name__ == "__main__":
    unittest.main()
