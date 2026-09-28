"""Unit tests for stash-identify's per-scene flow, with fake Stash and LLM."""
import unittest

import main

TPDB, STASHDB = main.BOXES


def scene(id="5", path="/media/Vault/dir/file.mp4", duration=600.0, **kw):
    base = {"id": id, "title": "", "code": "", "details": "", "director": "", "date": None,
            "urls": [], "studio": None, "performers": [], "tags": [], "stash_ids": [],
            "files": [{"path": path, "duration": duration}]}
    return {**base, **kw}


class FakeStash:
    def __init__(self, results=None, performers=(), studios=(), tags=None):
        self.results = results or {}      # endpoint -> list of scraped scenes
        self.performers = list(performers)
        self.studios = list(studios)
        self.tags = dict(tags or {})      # name -> id
        self.updates, self.created = [], []

    def search(self, endpoint, query):
        return self.results.get(endpoint, [])

    def performer_by_stash_id(self, endpoint, sid):
        return next((p["id"] for p in self.performers if sid in p.get("sids", [])), None)

    def studio_by_stash_id(self, endpoint, sid):
        return next((s["id"] for s in self.studios if sid in s.get("sids", [])), None)

    def performers_like(self, name):
        return self.performers

    def studios_like(self, name):
        return self.studios

    def tag_id(self, name, create=False):
        if name not in self.tags and create:
            self.tags[name] = f"t-{name}"
        return self.tags.get(name)

    def create_performer(self, inp):
        self.created.append(("performer", inp))
        return f"p-{inp['name']}"

    def create_studio(self, inp):
        self.created.append(("studio", inp))
        return f"s-{inp['name']}"

    def update_scene(self, inp):
        self.updates.append(inp)


class FakeLLM:
    def __init__(self, parse, choice="none"):
        self._parse, self._choice = parse, choice

    def parse(self, path):
        if isinstance(self._parse, Exception):
            raise self._parse
        return self._parse

    def choose(self, path, duration, parse, cands):
        return {"choice": self._choice, "confidence": 0.4}


def scraped(title, studio, date=None, duration=600, rid="r", **kw):
    return {"title": title, "date": date, "duration": duration, "remote_site_id": rid,
            "studio": {"name": studio, "remote_site_id": f"st-{studio}"}, "performers": [],
            "tags": [], "image": "data:img", **kw}


class RelPathTest(unittest.TestCase):
    def test_strips_library_root(self):
        self.assertEqual(main.rel_path("/media/Vault/a/b.mp4"), "a/b.mp4")


class IdentifyTest(unittest.TestCase):
    def test_date_rule_beats_jev(self):
        st = FakeStash({TPDB: [scraped("Cow", "Trip For Fuck", "2024-12-24", rid="t1")],
                        STASHDB: [scraped("cow", "TripForFuck", "2024-12-24", 601, rid="s1")]})
        llm = FakeLLM({"studio": "TripForFuck", "date": "2024-12-24", "query": "q"}, choice="none")
        p = main.identify_scene(st, llm, scene())
        self.assertEqual((p["kind"], p["rule"], p["primary_endpoint"]), ("scrape", "date", TPDB))
        self.assertEqual(p["stash_ids"], [{"endpoint": TPDB, "stash_id": "t1"},
                                          {"endpoint": STASHDB, "stash_id": "s1"}])

    def test_jev_pick_and_tpdb_twin_becomes_primary(self):
        st = FakeStash({TPDB: [scraped("Snowed In", "Frolic Me", rid="t1")],
                        STASHDB: [scraped("SNOWED IN", "Frolic Me", rid="s1")]})
        # After dedupe only the TPDB copy is offered to Jev, as c0.
        p = main.identify_scene(st, FakeLLM({"query": "q"}, choice="c0"), scene())
        self.assertEqual((p["kind"], p["rule"], p["primary_endpoint"]), ("scrape", "jev", TPDB))
        self.assertEqual(len(p["stash_ids"]), 2)

    def test_duration_filter_blocks_lookalikes(self):
        st = FakeStash({STASHDB: [scraped("Similar", "Other", duration=900)]})
        p = main.identify_scene(st, FakeLLM({"title": "T", "query": "q"}, choice="c0"), scene())
        self.assertEqual(p["kind"], "llm")

    def test_empty_parse_is_none(self):
        p = main.identify_scene(FakeStash(), FakeLLM({"query": ""}), scene())
        self.assertEqual(p["kind"], "none")

    def test_parse_failure_propagates(self):
        with self.assertRaises(ValueError):
            main.identify_scene(FakeStash(), FakeLLM(ValueError("bad")), scene())


class ApplyTest(unittest.TestCase):
    def test_scrape_resolves_by_stash_id_then_creates(self):
        known = {"id": "1019", "name": "Kattie Gold", "alias_list": ["Vivian"], "sids": []}
        st = FakeStash(performers=[known], studios=[{"id": "161", "name": "Lustery", "aliases": []}])
        primary = scraped("Big Boobs", "Lustery", performers=[
            {"name": "Vivian", "remote_site_id": "v1", "images": ["https://i"]}],
            tags=[{"name": "Blowjob", "stored_id": "20"}, {"name": "Unknown", "stored_id": None}])
        prop = {"kind": "scrape", "primary": primary, "primary_endpoint": TPDB,
                "stash_ids": [{"endpoint": TPDB, "stash_id": "r"}]}
        main.apply(st, scene(tags=[{"id": "1398"}]), prop, skip_tag_ids={"1398"})
        # "Vivian" must NOT resolve to Kattie Gold through her alias.
        self.assertEqual(st.created, [("performer", {
            "name": "Vivian", "image": "https://i",
            "stash_ids": [{"endpoint": TPDB, "stash_id": "v1"}]})])
        up = st.updates[0]
        self.assertEqual(up["studio_id"], "161")
        self.assertEqual(up["performer_ids"], ["p-Vivian"])
        self.assertEqual(up["tag_ids"], ["20"])
        self.assertEqual(up["cover_image"], "data:img")

    def test_llm_guess_creates_by_name_and_tags(self):
        st = FakeStash()
        prop = {"kind": "llm", "parse": {"title": "Guess", "studio": "yoursofia",
                                         "performers": ["Sofia Young"]}}
        main.apply(st, scene(), prop, skip_tag_ids=set())
        self.assertEqual(st.created, [("studio", {"name": "yoursofia"}),
                                      ("performer", {"name": "Sofia Young"})])
        self.assertEqual(st.updates[0], {"id": "5", "title": "Guess", "studio_id": "s-yoursofia",
                                         "performer_ids": ["p-Sofia Young"],
                                         "tag_ids": ["t-llm-identified"]})

    def test_none_writes_nothing(self):
        st = FakeStash()
        main.apply(st, scene(), {"kind": "none"}, skip_tag_ids=set())
        self.assertEqual((st.updates, st.created), ([], []))


if __name__ == "__main__":
    unittest.main()
