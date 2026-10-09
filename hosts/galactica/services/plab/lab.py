"""The tracker client: one logged-in session, persisted as a cookie jar on disk.

Logging in is the risky part: repeated logins make the form demand a captcha, which
plab cannot solve. So the jar is reused across runs and a login happens only when a
page comes back logged out, at most once per request. On a captcha it gives up and says
so; `plab set-cookie` is the way back in (see the design doc).
"""
import http.cookiejar
import os
import time
import urllib.parse
import urllib.request

import parse

BASE = "https://pornolab.net/forum/"
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"


class LoginError(Exception):
    pass


class Lab:
    def __init__(self, username, password, jar_path, opener=None):
        self.username = username
        self.password = password
        self.jar = http.cookiejar.MozillaCookieJar(jar_path)
        if os.path.exists(jar_path):
            self.jar.load(ignore_discard=True)
        self.opener = opener or urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.opener.addheaders = [("User-Agent", UA)]

    def _open(self, url, data=None):
        with self.opener.open(url, data, timeout=60) as response:
            return response.read()

    def _save(self):
        tmp = self.jar.filename + ".tmp"
        self.jar.save(tmp, ignore_discard=True)
        os.replace(tmp, self.jar.filename)

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
        for attempt in range(2):
            page = self._open(BASE + path).decode("cp1251", "replace")
            if parse.logged_in(page):
                return page
            if attempt == 0:
                self.login()
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
        for attempt in range(2):
            data = self._open(f"{BASE}dl.php?t={topic_id}")
            if data.startswith(b"d"):  # bencoded dictionary, not a login page
                return data
            if attempt == 0:
                self.login()
        raise LoginError(f"no torrent for topic {topic_id}")

    def fetch(self, url):
        return self._open(url)

    def set_cookie(self, value):
        self.jar.set_cookie(http.cookiejar.Cookie(
            0, "bb_data", value, None, False, ".pornolab.net", True, True, "/forum/", True,
            False, int(time.time()) + 365 * 86400, False, None, None, {},
        ))
        self._save()
