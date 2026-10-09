"""The tracker client: one logged-in session, persisted as a cookie jar on disk.

Logging in is the risky part: repeated logins make the form demand a captcha, which
plab cannot solve. So the jar is reused across runs and a login happens only when a
page comes back logged out, at most once per request. On a captcha it gives up and says
so; `plab set-cookie` is the way back in (see the design doc).
"""
import http.cookiejar
import os
import re
import threading
import time
import urllib.parse
import urllib.request

import parse

BASE = "https://pornolab.net/forum/"
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"


class LoginError(Exception):
    pass


class TrackerError(Exception):
    pass


class LimitError(TrackerError):
    """The account's daily .torrent download quota is used up."""


class Lab:
    def __init__(self, username, password, jar_path, opener=None):
        self.username = username
        self.password = password
        self.jar = http.cookiejar.MozillaCookieJar(jar_path)
        self._mtime = 0
        self._load()
        self.opener = opener or urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.opener.addheaders = [("User-Agent", UA)]

    def _open(self, url, data=None):
        with self.opener.open(url, data, timeout=60) as response:
            return response.read()

    def _file_mtime(self):
        try:
            return os.stat(self.jar.filename).st_mtime_ns
        except OSError:
            return 0

    def _load(self):
        """(Re)read the jar file in place; a corrupt or missing file is an empty jar."""
        self._mtime = self._file_mtime()
        self.jar.clear()
        try:
            self.jar.load(ignore_discard=True)
        except (http.cookiejar.LoadError, OSError):
            self.jar.clear()

    def _reload_if_newer(self):
        """Pick up a cookie another process wrote (`plab set-cookie`); True if reloaded."""
        if self._file_mtime() > self._mtime:
            self._load()
            return True
        return False

    def _save(self):
        # Unique per writer: `serve` and `refresh` both save this file.
        tmp = f"{self.jar.filename}.{os.getpid()}.{threading.get_ident()}.tmp"
        self.jar.save(tmp, ignore_discard=True)
        os.replace(tmp, self.jar.filename)
        self._mtime = self._file_mtime()

    def _save_session(self):
        # The tracker rotates session cookies; keep them, unless a newer file is waiting.
        if self._file_mtime() <= self._mtime:
            self._save()

    def login(self):
        body = urllib.parse.urlencode({
            "login_username": self.username,
            "login_password": self.password,
            "login": "Вход",
        }, encoding="cp1251").encode()
        page = self._open(BASE + "login.php", body).decode("cp1251", "replace")
        if parse.needs_captcha(page):
            raise LoginError("login needs captcha")
        if not parse.logged_in(page):
            raise LoginError("login failed")
        self._save()

    def page(self, path):
        reloaded = logged_in = False
        while True:
            page = self._open(BASE + path).decode("cp1251", "replace")
            if parse.logged_in(page):
                self._save_session()
                return page
            # A newer cookie file is tried before any login; then at most one login.
            if not reloaded and self._reload_if_newer():
                reloaded = True
            elif not logged_in:
                self.login()
                logged_in = True
            else:
                raise LoginError(f"still logged out after login: {path}")

    def top(self, forums, days, limit):
        """The most-seeded releases uploaded in the last `days` days, best first."""
        query = urllib.parse.urlencode([("f[]", f) for f in forums] + [("o", 10), ("s", 2), ("tm", days)])
        page = self.page("tracker.php?" + query)
        rows = parse.rows(page)
        start = 50
        while len(rows) < limit:
            link = parse.page_link(page, start)
            if not link:
                break
            page = self.page(link)
            rows += parse.rows(page)
            start += 50
        return rows[:limit]

    def topic(self, topic_id):
        return self.page(f"viewtopic.php?t={topic_id}")

    def torrent(self, topic_id):
        reloaded = logged_in = False
        while True:
            data = self._open(f"{BASE}dl.php?t={topic_id}")
            if re.match(rb"d\d+:", data):  # bencoded dictionary, not a login page
                self._save_session()
                return data
            # Only a missing session earns a login; a logged-in reply that is not a torrent
            # (deleted topic, no access) is the tracker's answer, not a reason to log in again.
            text = data.decode("cp1251", "replace")
            if parse.logged_in(text):
                limit = parse.daily_limit(text)
                if limit is not None:
                    raise LimitError(f"daily download limit reached ({limit}/day)")
                raise TrackerError(parse.info_message(text) or f"no torrent for topic {topic_id}")
            if not reloaded and self._reload_if_newer():
                reloaded = True
            elif not logged_in:
                self.login()
                logged_in = True
            else:
                raise LoginError(f"still logged out after login: topic {topic_id}")

    def fetch(self, url):
        return self._open(url)

    def set_cookie(self, value):
        self.jar.set_cookie(http.cookiejar.Cookie(
            0, "bb_data", value, None, False, ".pornolab.net", True, True, "/forum/", True,
            False, int(time.time()) + 365 * 86400, False, None, None, {},
        ))
        self._save()
