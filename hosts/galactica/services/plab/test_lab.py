import io
import os
import tempfile
import unittest

from lab import BASE, Lab, LimitError, LoginError, TrackerError

HERE = os.path.dirname(os.path.abspath(__file__))
LOGGED_OUT = '<html><form action="/forum/login.php"></form></html>'.encode("cp1251")
LOGGED_IN = "<html>[ <a onclick=\"return post2url('login.php', {logout: 1});\">Выход</a> ]</html>".encode("cp1251")
CAPTCHA = b'<html><input type="hidden" name="cap_sid" value="x"></html>'


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return f.read().encode("cp1251")


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def open(self, url, data=None, timeout=None):
        self.calls.append((url, data))
        return io.BytesIO(self.responses.pop(0))


class LabTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.jar = os.path.join(self.dir.name, "cookies.txt")

    def tearDown(self):
        self.dir.cleanup()

    def lab(self, *responses):
        opener = FakeOpener(responses)
        return Lab("user", "pдssword", self.jar, opener=opener), opener

    def test_page_when_logged_in_does_not_log_in(self):
        lab, opener = self.lab(fixture("tracker.html"))
        self.assertIn("tor-tbl", lab.page("tracker.php"))
        self.assertEqual(len(opener.calls), 1)

    def test_page_logs_in_when_logged_out(self):
        lab, opener = self.lab(LOGGED_OUT, LOGGED_IN, fixture("tracker.html"))
        self.assertIn("tor-tbl", lab.page("tracker.php"))
        url, data = opener.calls[1]
        self.assertEqual(url, BASE + "login.php")
        self.assertIn(b"login_username=user", data)
        self.assertIn(b"login_password=p%E4ssword", data)  # cp1251, as the form expects

    def test_captcha_raises(self):
        lab, _ = self.lab(LOGGED_OUT, CAPTCHA)
        with self.assertRaisesRegex(LoginError, "captcha"):
            lab.page("tracker.php")

    def test_login_failed_without_captcha_raises(self):
        lab, opener = self.lab(LOGGED_OUT, b"<html>wrong password</html>")
        with self.assertRaisesRegex(LoginError, "^login failed$"):
            lab.page("tracker.php")
        self.assertEqual(len(opener.calls), 2)

    def test_still_logged_out_after_login_raises(self):
        lab, _ = self.lab(LOGGED_OUT, LOGGED_IN, LOGGED_OUT)
        with self.assertRaises(LoginError):
            lab.page("tracker.php")

    def test_top_query_and_second_page(self):
        lab, opener = self.lab(fixture("tracker.html"), fixture("tracker.html"))
        rows = lab.top([1875, 1818], 7, 3)
        self.assertEqual([r["id"] for r in rows], [3313754, 3314001, 3313754])
        first = opener.calls[0][0]
        for part in ("f%5B%5D=1875", "f%5B%5D=1818", "o=10", "s=2", "tm=7"):
            self.assertIn(part, first)
        self.assertEqual(opener.calls[1][0], BASE + "tracker.php?search_id=AbCdEf123&start=50")

    def test_top_stops_at_limit_without_second_page(self):
        lab, opener = self.lab(fixture("tracker.html"))
        self.assertEqual(len(lab.top([1875], 7, 2)), 2)
        self.assertEqual(len(opener.calls), 1)

    def test_torrent_logs_in_once(self):
        lab, opener = self.lab(LOGGED_OUT, LOGGED_IN, b"d8:announce1:xe")
        self.assertEqual(lab.torrent(3313754), b"d8:announce1:xe")
        self.assertEqual(opener.calls[0][0], BASE + "dl.php?t=3313754")

    def test_torrent_logged_in_non_torrent_raises_without_login(self):
        lab, opener = self.lab(LOGGED_IN)
        with self.assertRaisesRegex(TrackerError, "no torrent for topic 3313754"):
            lab.torrent(3313754)
        self.assertEqual(len(opener.calls), 1)

    def test_torrent_daily_limit_raises_without_login(self):
        lab, opener = self.lab(fixture("limit.html"))
        with self.assertRaisesRegex(LimitError, r"daily download limit reached \(10/day\)"):
            lab.torrent(1)
        self.assertEqual(len(opener.calls), 1)
        self.assertTrue(issubclass(LimitError, TrackerError))

    def test_torrent_other_info_page_carries_tracker_message(self):
        page = '<html>{logout: 1}<div class="mrg_16">Тема удалена</div></html>'.encode("cp1251")
        lab, _ = self.lab(page)
        with self.assertRaisesRegex(TrackerError, "Тема удалена"):
            lab.torrent(1)

    def test_torrent_still_logged_out_after_login_raises(self):
        lab, opener = self.lab(LOGGED_OUT, LOGGED_IN, LOGGED_OUT)
        with self.assertRaises(LoginError):
            lab.torrent(3313754)
        self.assertEqual(len(opener.calls), 3)

    def test_fetch_returns_bytes_for_any_url(self):
        lab, opener = self.lab(b"\x89PNG-bytes")
        self.assertEqual(lab.fetch("https://img.example.com/a.png"), b"\x89PNG-bytes")
        self.assertEqual(opener.calls[0][0], "https://img.example.com/a.png")

    def test_set_cookie_survives_a_new_lab(self):
        lab, _ = self.lab()
        lab.set_cookie("abc123")
        new_lab = Lab("user", "pдssword", self.jar, opener=FakeOpener([]))
        self.assertTrue(any(c.name == "bb_data" and c.value == "abc123" for c in new_lab.jar))

    def test_new_cookie_file_is_reloaded_without_login(self):
        lab, opener = self.lab(LOGGED_OUT, fixture("tracker.html"))
        other = Lab("user", "pдssword", self.jar, opener=FakeOpener([]))
        other.set_cookie("fresh")
        later = os.stat(self.jar).st_mtime + 10
        os.utime(self.jar, (later, later))
        self.assertIn("tor-tbl", lab.page("tracker.php"))
        self.assertEqual([url for url, _ in opener.calls], [BASE + "tracker.php"] * 2)
        self.assertTrue(any(c.name == "bb_data" and c.value == "fresh" for c in lab.jar))

    def test_new_cookie_file_still_logged_out_logs_in_once(self):
        lab, opener = self.lab(LOGGED_OUT, LOGGED_OUT, LOGGED_IN, fixture("tracker.html"))
        Lab("user", "pдssword", self.jar, opener=FakeOpener([])).set_cookie("dead")
        later = os.stat(self.jar).st_mtime + 10
        os.utime(self.jar, (later, later))
        lab.page("tracker.php")
        self.assertEqual([url for url, _ in opener.calls].count(BASE + "login.php"), 1)

    def test_torrent_reloads_new_cookie_file_without_login(self):
        lab, opener = self.lab(LOGGED_OUT, b"d8:announce1:xe")
        Lab("user", "pдssword", self.jar, opener=FakeOpener([])).set_cookie("fresh")
        later = os.stat(self.jar).st_mtime + 10
        os.utime(self.jar, (later, later))
        self.assertEqual(lab.torrent(1), b"d8:announce1:xe")
        self.assertEqual(len(opener.calls), 2)
        self.assertNotIn(BASE + "login.php", [url for url, _ in opener.calls])

    def test_own_save_is_not_reloaded(self):
        lab, opener = self.lab(LOGGED_OUT, LOGGED_IN, fixture("tracker.html"), LOGGED_OUT, LOGGED_IN, fixture("tracker.html"))
        lab.page("tracker.php")  # logs in and saves
        lab.page("tracker.php")
        # our own save is not "newer": a logged-out reply goes straight to login, no reload retry
        self.assertEqual(len(opener.calls), 6)

    def test_successful_page_saves_the_jar(self):
        lab, _ = self.lab(fixture("tracker.html"))
        lab.page("tracker.php")
        self.assertTrue(os.path.exists(self.jar))

    def test_corrupt_jar_is_an_empty_jar(self):
        with open(self.jar, "w") as f:
            f.write("garbage\nnot a cookie jar")
        lab, _ = self.lab()
        self.assertEqual(len(lab.jar), 0)

    def test_set_cookie(self):
        lab, _ = self.lab()
        lab.set_cookie("abc123")
        with open(self.jar) as f:
            saved = f.read()
        self.assertIn("bb_data\tabc123", saved)
        self.assertIn(".pornolab.net", saved)


if __name__ == "__main__":
    unittest.main()
