import datetime
import io
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

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


class ApiKey(unittest.TestCase):
    def test_reads_config_xml(self):
        path = rules_file("<Config>\n  <Port>9696</Port>\n  <ApiKey>abc123</ApiKey>\n</Config>\n")
        self.assertEqual(main.api_key(path), "abc123")
        os.unlink(path)

    def test_missing(self):
        path = rules_file("<Config></Config>")
        with self.assertRaisesRegex(ValueError, "no <ApiKey>"):
            main.api_key(path)
        os.unlink(path)


class Download(BaseHTTPRequestHandler):
    """Prowlarr's /download: a 301 to a magnet for one indexer, .torrent bytes for another."""
    def do_GET(self):
        if self.path == "/magnet":
            self.send_response(301)
            self.send_header("Location", "magnet:?xt=urn:btih:ABC&dn=x")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/torrent":
            self.send_response(200)
            self.send_header("Content-Type", "application/x-bittorrent")
            self.send_header("Content-Length", "8")
            self.end_headers()
            self.wfile.write(b"d4:infoe")
        elif self.path == "/html":
            self.send_response(200)
            self.send_header("Content-Length", "6")
            self.end_headers()
            self.wfile.write(b"<html>")
        elif self.path.startswith("/api/v1/search"):
            body = json.dumps([{"title": self.path, "key": self.headers.get("X-Api-Key")}]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, *args):
        pass


class Http(unittest.TestCase):
    def setUp(self):
        self.server = HTTPServer(("127.0.0.1", 0), Download)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_magnet_redirect_is_not_followed(self):
        self.assertEqual(main.fetch(self.base + "/magnet"), "magnet:?xt=urn:btih:ABC&dn=x")

    def test_torrent_bytes(self):
        self.assertEqual(main.fetch(self.base + "/torrent"), b"d4:infoe")

    def test_not_a_torrent(self):
        with self.assertRaisesRegex(ValueError, "not a .torrent"):
            main.fetch(self.base + "/html")

    def test_server_error(self):
        with self.assertRaises(main.urllib.error.HTTPError):
            main.fetch(self.base + "/boom")

    def test_search_sends_key_and_query(self):
        [item] = main.search(self.base, "k3y", "studio a")
        self.assertEqual(item["key"], "k3y")
        self.assertIn("query=studio+a", item["title"])
        self.assertIn("type=search", item["title"])


class StateFile(unittest.TestCase):
    def test_record_persists_and_matches_any_key(self):
        path = os.path.join(tempfile.mkdtemp(), "state.json")
        s = main.State(path)
        self.assertFalse(s.grabbed("Studio A", {"ep:1"}))
        s.record("Studio A", {"ep:1", "name:abcdefgh"}, "t", "2026-10-24T00:00:00+00:00")
        again = main.State(path)
        self.assertTrue(again.grabbed("Studio A", {"name:abcdefgh"}))
        self.assertFalse(again.grabbed("Studio B", {"ep:1"}))
        self.assertFalse(os.path.exists(path + ".tmp"))


class Run(unittest.TestCase):
    def setUp(self):
        self.state = main.State(os.path.join(tempfile.mkdtemp(), "state.json"))
        self.added = []
        self.fail_urls = set()

    def fetch(self, url):
        if url in self.fail_urls:
            raise main.urllib.error.HTTPError(url, 429, "daily limit", {}, io.BytesIO())
        return "magnet:" + url

    def add(self, torrent, download_dir):
        self.added.append((torrent, download_dir))
        return "name"

    def go(self, results, dry_run=False, search=None):
        return main.run([A], search or (lambda q: results), self.fetch, self.add, self.state,
                        "/vault", NOW, dry_run)

    def test_grabs_one_copy_per_scene_into_studio_dir(self):
        results = [
            result("StudioA E2283 Iris And Jase How We Deepthroat XXX 480p MP4 XXX [XC]", url="u480"),
            result("StudioA E2283 Iris And Jase How We Deepthroat XXX 1080p MP4 FETiSH [XC]", url="u1080"),
            result("[StudioA.com] Iris & Jase - How We Deepthroat (E2283) [2026-10-15, 1080p, SiteRip]",
                   indexer="PornoLab", seeders=90, url="ulab"),
            result("Unrelated Release 1080p", url="other"),
        ]
        self.assertEqual(self.go(results), 0)
        self.assertEqual(self.added, [("magnet:u1080", "/vault/Studio A")])
        self.assertTrue(self.state.grabbed("Studio A", {"name:irisandjasehowwedeepthroat"}))

    def test_already_grabbed_is_skipped(self):
        self.state.record("Studio A", {"ep:2283"}, "t", "x")
        self.go([result("StudioA E2283 Iris And Jase How We Deepthroat XXX 1080p MP4 [XC]")])
        self.assertEqual(self.added, [])

    def test_failed_grab_is_not_recorded_and_others_continue(self):
        self.fail_urls = {"bad"}
        status = self.go([result("StudioA E1001 Some Couple Some Title XXX 1080p", url="bad"),
                          result("StudioA E1002 Other Couple Other Title XXX 1080p", url="good")])
        self.assertEqual(status, 0)
        self.assertEqual(self.added, [("magnet:good", "/vault/Studio A")])
        self.assertFalse(self.state.grabbed("Studio A", {"ep:1001"}))
        self.assertTrue(self.state.grabbed("Studio A", {"ep:1002"}))

    def test_failed_search_exits_1(self):
        def broken(query):
            raise OSError("connection refused")
        self.assertEqual(self.go([], search=broken), 1)

    def test_malformed_result_is_skipped_and_run_continues(self):
        bad = result("StudioA E1001 Some Couple Some Title XXX 1080p", url="bad")
        del bad["publishDate"]
        naive = result("StudioA E1003 Third Couple Third Title XXX 1080p", url="naive",
                       published="2026-10-17T20:00:00")
        status = self.go([bad, naive, result("StudioA E1002 Other Couple Other Title XXX 1080p", url="good")])
        self.assertEqual(status, 0)
        self.assertEqual(self.added, [("magnet:good", "/vault/Studio A")])

    def test_failed_state_write_after_add_does_not_stop_the_run(self):
        class FailingOnce(main.State):
            calls = 0

            def record(self, *args):
                FailingOnce.calls += 1
                if FailingOnce.calls == 1:
                    raise OSError("disk full")
                super().record(*args)

        self.state = FailingOnce(os.path.join(tempfile.mkdtemp(), "state.json"))
        status = self.go([result("StudioA E1001 Some Couple Some Title XXX 1080p", url="first"),
                          result("StudioA E1002 Other Couple Other Title XXX 1080p", url="second")])
        self.assertEqual(status, 0)
        self.assertEqual(self.added, [("magnet:first", "/vault/Studio A"), ("magnet:second", "/vault/Studio A")])
        self.assertFalse(self.state.grabbed("Studio A", {"ep:1001"}))
        self.assertTrue(self.state.grabbed("Studio A", {"ep:1002"}))

    def test_dry_run_writes_nothing(self):
        self.go([result("StudioA E1001 Some Couple Some Title XXX 1080p")], dry_run=True)
        self.assertEqual(self.added, [])
        self.assertFalse(os.path.exists(self.state.path))


if __name__ == "__main__":
    unittest.main()
