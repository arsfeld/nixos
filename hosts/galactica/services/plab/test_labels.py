import unittest

from labels import labels


class Labels(unittest.TestCase):
    def test_onlyfans(self):
        r = labels("[OnlyFans.com] Lola Grant, Girthmasterr [2026, Anal, Big Cock, Rimming, Redhead, 1080p, SiteRip]", 1875)
        self.assertEqual(r["tags"], ["anal", "big cock", "rimming", "redhead", "siterip"])
        self.assertEqual(r["quality"], "1080p")
        self.assertEqual(r["studio"], "OnlyFans.com")
        self.assertEqual(r["category"], "Clips and siterips")

    def test_multi_studio_with_date(self):
        r = labels("[HerLimit.com / LetsDoeIt.com] Hazel Moore - She Wants Moore Anal [05.10.2026, Anal, Ass To Mouth, Brunette]", 1875)
        self.assertEqual(r["tags"], ["anal", "ass to mouth", "brunette"])
        self.assertIsNone(r["quality"])
        self.assertEqual(r["studio"], "HerLimit.com")

    def test_last_comma_group_wins(self):
        r = labels("[LegalPorno.com / AnalVids.com / PornBox.com / Whitehard Industry] Marla Mur - ... (5321022) [2026-10-02, Anal, Gape, 1080p]", 1823)
        self.assertEqual(r["tags"], ["anal", "gape"])
        self.assertEqual(r["quality"], "1080p")
        self.assertEqual(r["studio"], "LegalPorno.com")
        self.assertEqual(r["category"], "VR")

    def test_no_bracket_studio(self):
        r = labels("Performer C - It's A Test [ABC-123] [2026 г., 1080p]", 424242)
        self.assertEqual(r["tags"], [])
        self.assertEqual(r["quality"], "1080p")
        self.assertIsNone(r["studio"])
        self.assertEqual(r["category"], "Other")

    def test_plain_title(self):
        r = labels("Just a title", 1670)
        self.assertEqual(r, {"tags": [], "quality": None, "studio": None, "category": "Erotic & softcore"})

    def test_date_shapes_dropped(self):
        r = labels("x [2026, 2025 г., 05.10.2026, 2026-10-02, 5.1.2026, 2026.10.02, Foo]", 1)
        self.assertEqual(r["tags"], ["foo"])

    def test_4k_and_uhd(self):
        self.assertEqual(labels("[S] a [2026, 4K, Anal]", 1)["quality"], "2160p")
        self.assertEqual(labels("[S] a [2026, UHD, Anal]", 1)["quality"], "2160p")
        self.assertEqual(labels("[S] a [2026, 4K, Anal]", 1)["tags"], ["anal"])

    def test_first_quality_wins_and_all_removed_from_tags(self):
        r = labels("a [Anal, 720p, 1080p]", 1)
        self.assertEqual(r["quality"], "720p")
        self.assertEqual(r["tags"], ["anal"])

    def test_dedupe_and_order(self):
        r = labels("a [Anal, anal , Gape, ANAL, Bbw]", 1)
        self.assertEqual(r["tags"], ["anal", "gape", "bbw"])

    def test_studio_only_if_title_starts_with_bracket(self):
        self.assertIsNone(labels("x [Studio.com] y [a, b]", 1)["studio"])

    def test_bracket_without_comma_ignored_for_tags(self):
        self.assertEqual(labels("[Studio] y [solo]", 1)["tags"], [])


if __name__ == "__main__":
    unittest.main()
