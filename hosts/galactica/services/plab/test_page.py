import unittest

import page
from store import key

TOPIC = {"id": 3313754, "title": "Studio <script>alert(1)</script> & Co", "forum": 1875,
         "size": 2254024095, "seeders": 310, "leechers": 4, "completed": 3189,
         "added": 1791117232, "images": ["https://x/cover.jpg", "https://x/shot.jpg"]}


class Render(unittest.TestCase):
    def render(self, topics, added=frozenset(), updated=1791117232, now=1791117232 + 7200):
        return page.render({"updated": updated, "topics": topics}, set(added), now)

    def test_card(self):
        out = self.render([TOPIC])
        self.assertIn('src="img/%s"' % key("https://x/cover.jpg"), out)
        self.assertIn(key("https://x/shot.jpg"), out)
        self.assertIn('data-id="3313754"', out)
        self.assertIn("2.1 GB", out)
        self.assertIn("310", out)
        self.assertIn("2026-10-04", out)  # UTC
        self.assertIn("https://pornolab.net/forum/viewtopic.php?t=3313754", out)
        self.assertIn("updated 2 h ago", out)

    def test_title_escaped(self):
        out = self.render([TOPIC])
        self.assertNotIn("<script>alert", out)
        self.assertIn("&lt;script&gt;", out)

    def test_added_topic(self):
        out = self.render([TOPIC], added={3313754})
        self.assertIn('<button class="add" data-id="3313754" disabled>Added ✓</button>', out)

    def test_not_added_topic(self):
        out = self.render([TOPIC], added=set())
        self.assertIn('<button class="add" data-id="3313754">Add to Vault</button>', out)
        self.assertNotIn('data-id="3313754" disabled', out)

    def test_no_images(self):
        out = self.render([dict(TOPIC, images=[])])
        self.assertIn('class="thumb none"', out)

    def test_size_and_age(self):
        self.assertEqual(page.size(2254024095), "2.1 GB")
        self.assertEqual(page.size(900), "900 B")
        self.assertEqual(page.age(0, 100), "never")
        self.assertEqual(page.age(100, 100 + 600), "10 min ago")
        self.assertEqual(page.age(100, 100 + 3 * 3600), "3 h ago")


if __name__ == "__main__":
    unittest.main()
