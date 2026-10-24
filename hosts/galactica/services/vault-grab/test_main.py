import datetime
import os
import tempfile
import unittest

import main

NOW = datetime.datetime(2026, 10, 24, 12, tzinfo=datetime.timezone.utc)
A = main.Rule("Studio A", "studioa", main.re.compile(r"^(\[studioa\.com\]|studioa e\d+\b)", main.re.I))
B = main.Rule("Studio B", "studiob", main.re.compile(r"^(\[studiob\.com\]|studio b\s)", main.re.I))


def result(title, indexer="1337x", seeders=10, published="2026-10-17T20:00:00Z", url="http://p/1/download"):
    return {"title": title, "indexer": indexer, "seeders": seeders, "publishDate": published,
            "downloadUrl": url, "protocol": "torrent"}


def rules_file(text):
    f = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8")
    f.write(text)
    f.close()
    return f.name


class LoadRules(unittest.TestCase):
    def test_blocks_and_comments(self):
        path = rules_file("# c\n\n[Studio A]\nquery = studioa\nmatch = ^studioa e\\d+\n\n[Studio B]\n"
                          "query = studiob\nmatch = ^\\[studiob\\.com\\]\n")
        rules = main.load_rules(path)
        os.unlink(path)
        self.assertEqual([r.name for r in rules], ["Studio A", "Studio B"])
        self.assertEqual(rules[0].query, "studioa")
        self.assertTrue(rules[1].match.match("[StudioB.com] X - Y"))  # case-insensitive

    def test_missing_key(self):
        path = rules_file("[Studio A]\nquery = studioa\n")
        with self.assertRaisesRegex(ValueError, "missing match"):
            main.load_rules(path)
        os.unlink(path)

    def test_unknown_key_and_line_before_block(self):
        for text in ("[Studio A]\nquery = a\nmatch = a\nsave = x\n", "query = a\n"):
            path = rules_file(text)
            with self.assertRaisesRegex(ValueError, "unexpected line"):
                main.load_rules(path)
            os.unlink(path)

    def test_bad_regex(self):
        path = rules_file("[Studio A]\nquery = a\nmatch = ^(a\n")
        with self.assertRaisesRegex(ValueError, r"\[Studio A\] match"):
            main.load_rules(path)
        os.unlink(path)


class SkipReason(unittest.TestCase):
    def reason(self, title, rule=A, **kw):
        return main.skip_reason(rule, result(title, **kw), NOW)

    def test_candidates(self):
        self.assertIsNone(self.reason("StudioA E2283 Iris And Jase How We Deepthroat XXX 1080p MP4 FETiSH [XC]"))
        self.assertIsNone(self.reason("[StudioA.com] Johanna & Lars - Park & Ohhh (E2274) "
                                      "[2026-09-29, All sex, Outdoor, 1080p, SiteRip]"))
        self.assertIsNone(self.reason("[StudioB.com] Kitty Wild - Waking to Find You "
                                      "[2026, Blowjob, All Sex, 1088p, SiteRip]", rule=B))
        self.assertIsNone(self.reason("Studio B   Hailey White   An Evening of Romance (10.06.2026) 1080p",
                                      rule=B))

    def test_480p_twin(self):
        self.assertEqual(self.reason("StudioA E2283 Iris And Jase How We Deepthroat XXX 480p MP4 XXX [XC]"),
                         "not 1080p")

    def test_studio_must_lead_the_title(self):
        self.assertEqual(self.reason("Guess the Straight Girl (Other) [2026 г., BDRip, 1080p] "
                                     "(Jane(StudioA - Emanuel & Jane))"), "not this studio")

    def test_window(self):
        self.assertEqual(self.reason("StudioA E2100 Some Couple Some Title XXX 1080p", published="2026-09-20T00:00:00Z"),
                         "older than the window")

    def test_pack_and_imageset(self):
        self.assertEqual(self.reason("[StudioA.com] Mike & Vika (3 ролика) Pack [2025-2026, 1080p]"),
                         "pack or image set")
        self.assertEqual(self.reason("Studio B   Ashby Winter IMAGESET (30.04.2026) 1080p", rule=B),
                         "pack or image set")

    def test_old_scene_reuploaded(self):
        self.assertEqual(self.reason("[StudioA.com] Katya And Paul - Cabin Kink (E769) [2022 г., HDRip, 1080p]"),
                         "old scene re-uploaded")
        self.assertIsNone(self.reason("[StudioA.com] Ariel & Kirk - Pull Out Couch [2025-10-13, 1080p, SiteRip]"))

    def test_not_a_torrent(self):
        r = result("StudioA E1 Some Couple Some Title XXX 1080p")
        r["protocol"] = "usenet"
        self.assertEqual(main.skip_reason(A, r, NOW), "not a torrent")


class SceneKeys(unittest.TestCase):
    def test_both_namings_share_keys(self):
        lab = main.scene_keys(A, "[StudioA.com] Johanna & Lars - Park & Ohhh (E2274) [2026-09-29, 1080p, SiteRip]")
        x = main.scene_keys(A, "StudioA E2274 Johanna And Lars Park And Ohhh XXX 1080p MP4 FETiSH [XC]")
        self.assertEqual(lab, {"ep:2274", "name:johannaandlarsparkandohhh"})
        self.assertEqual(x, lab)

    def test_name_only(self):
        self.assertEqual(main.scene_keys(B, "[StudioB.com] Sofia Smith - Beauty In The Bath [2026-10-16, 1080p]"),
                         {"name:sofiasmithbeautyinthebath"})

    def test_short_name_is_not_a_key(self):
        self.assertEqual(main.scene_keys(A, "StudioA E0042 Ab XXX 1080p"), {"ep:42"})
        self.assertEqual(main.scene_keys(B, "[StudioB.com] Ab [2026, 1080p]"), set())


class Choose(unittest.TestCase):
    def test_non_quota_indexer_wins_then_seeders(self):
        lab = result("lab", indexer="PornoLab", seeders=99)
        weak = result("weak", seeders=5)
        strong = result("strong", seeders=40)
        scenes = main.choose([(lab, {"ep:1", "name:x"}), (weak, {"ep:1"}), (strong, {"name:x"})])
        self.assertEqual(len(scenes), 1)
        self.assertIs(scenes[0][0], strong)
        self.assertEqual(scenes[0][1], {"ep:1", "name:x"})

    def test_distinct_scenes_stay_apart(self):
        scenes = main.choose([(result("a"), {"ep:1"}), (result("b"), {"ep:2"})])
        self.assertEqual(len(scenes), 2)


if __name__ == "__main__":
    unittest.main()
