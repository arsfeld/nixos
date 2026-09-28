"""ThePornDB's JAV database. Its stash-box endpoint doesn't expose JAV, and Stash's
ThePornDBJAV community scraper would need a key hand-edited into a file the scraper
manager overwrites, so stash-identify calls the REST API itself."""
import urllib.parse

from net import get_json

JAV_URL = "https://api.theporndb.net/jav"


class TPDBJav:
    def __init__(self, api_key):
        # Without a User-Agent, urllib's default is refused at the edge.
        self.headers = {"Authorization": f"Bearer {api_key}", "Accept": "application/json",
                        "User-Agent": "stash-identify"}

    def jav_search(self, code):
        return get_json(f"{JAV_URL}?q={urllib.parse.quote(code)}&per_page=10",
                        self.headers)["data"]
