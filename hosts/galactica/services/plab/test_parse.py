import os
import unittest

import parse

HERE = os.path.dirname(os.path.abspath(__file__))


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return f.read()


class Markers(unittest.TestCase):
    def test_logged_in(self):
        self.assertTrue(parse.logged_in(fixture("tracker.html")))
        self.assertFalse(parse.logged_in("<html><form action=\"/forum/login.php\"></html>"))

    def test_needs_captcha(self):
        self.assertTrue(parse.needs_captcha('<input type="hidden" name="cap_sid" value="x">'))
        self.assertFalse(parse.needs_captcha(fixture("tracker.html")))


class Rows(unittest.TestCase):
    def test_rows(self):
        rows = parse.rows(fixture("tracker.html"))
        self.assertEqual(rows, [
            {"id": 3313754, "title": "[Studio.com] Performer A, Performer B [2026, Rock & Roll, 1080p, SiteRip]",
             "forum": 1875, "size": 2254024095, "seeders": 310, "leechers": 4, "completed": 3189,
             "added": 1791117232},
            {"id": 3314001, "title": "Performer C - It's A Test [ABC-123] [2026 г., 1080p]",
             "forum": 1818, "size": 5000000000, "seeders": 12, "leechers": 0, "completed": 40,
             "added": 1791200000},
        ])

    def test_no_table(self):
        self.assertEqual(parse.rows("<html>nothing</html>"), [])

    def test_page_link(self):
        page = fixture("tracker.html")
        self.assertEqual(parse.page_link(page, 50), "tracker.php?search_id=AbCdEf123&start=50")
        self.assertEqual(parse.page_link(page, 100), "tracker.php?search_id=AbCdEf123&start=100")
        self.assertIsNone(parse.page_link(page, 150))


class Images(unittest.TestCase):
    def test_first_post_only_in_order_deduplicated(self):
        self.assertEqual(parse.images(fixture("topic.html")), [
            "https://i128.fastpic.org/big/2026/1004/19/cover.jpg",
            "https://i128.fastpic.org/thumb/2026/1004/a1/_a.jpeg",
            "https://i128.fastpic.org/thumb/2026/1004/04/_b.jpeg?x=1&y=2",
        ])

    def test_no_post(self):
        self.assertEqual(parse.images("<html></html>"), [])


if __name__ == "__main__":
    unittest.main()
