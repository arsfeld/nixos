"""Unit tests for stash-identify's per-scene flow, with fake Stash and LLM."""
import json
import os
import tempfile
import unittest
import urllib.error

import main
import stash as stash_mod
import tpdb

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
        self.tagged = []                  # scenes returned by scenes_with_tag
        self.fc2 = {}                     # article URL -> scraped scene, None or Exception
        self.scraped_urls = []

    def scrape_url(self, url):
        self.scraped_urls.append(url)
        r = self.fc2.get(url)
        if isinstance(r, Exception):
            raise r
        return r

    def scenes_with_tag(self, tag_id):
        return self.tagged

    def search(self, endpoint, query):
        r = self.results.get(endpoint, [])
        if isinstance(r, Exception):
            raise r
        return r

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
    def __init__(self, parse, choice="none", translation="English Title"):
        self._parse, self._choice, self._translation = parse, choice, translation
        self.translated = []

    def translate_title(self, title):
        self.translated.append(title)
        if isinstance(self._translation, Exception):
            raise self._translation
        return self._translation

    def parse(self, path):
        if isinstance(self._parse, Exception):
            raise self._parse
        return self._parse

    def choose(self, path, duration, parse, cands):
        if isinstance(self._choice, Exception):
            raise self._choice
        return {"choice": self._choice, "confidence": 0.4}


def scraped(title, studio, date=None, duration=600, rid="r", **kw):
    return {"title": title, "date": date, "duration": duration, "remote_site_id": rid,
            "studio": {"name": studio, "remote_site_id": f"st-{studio}"}, "performers": [],
            "tags": [], "image": "data:img", **kw}


class FakeTPDB:
    def __init__(self, hits):
        self.hits, self.calls = hits, []

    def jav_search(self, code):
        self.calls.append(code)
        if isinstance(self.hits, Exception):
            raise self.hits
        return self.hits


def jav_hit(code, title=None, site="Kawaii", duration=7800, performers=("Kurea Hasumi",)):
    return {"external_id": code.lower(), "slug": f"x-{code.lower()}",
            "title": title or f"{code} - Some Title", "date": "2026-03-03", "description": "d",
            "duration": duration, "url": "https://r18.dev/x", "background": {"full": "https://img"},
            "site": {"name": site},
            "performers": [{"name": n, "image": None, "parent": {"name": n}} for n in performers]}


NO_LLM = FakeLLM(AssertionError("LLM must not be called for a JAV code hit"))


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

    def test_series_and_date_without_studio_or_title_is_llm(self):
        # No title, studio or performers, but display_title can still build a fallback
        # name from series + date -- that must count as a proposal, not "none".
        parse = {"series": "College Fun 2004", "date": "2025-01-01", "query": ""}
        p = main.identify_scene(FakeStash(), FakeLLM(parse), scene())
        self.assertEqual(p["kind"], "llm")

    def test_parse_failure_propagates(self):
        with self.assertRaises(ValueError):
            main.identify_scene(FakeStash(), FakeLLM(ValueError("bad")), scene())

    def test_search_failure_raises_instead_of_downgrading(self):
        st = FakeStash({TPDB: RuntimeError("timeout")})
        with self.assertRaises(RuntimeError):
            main.identify_scene(st, FakeLLM({"title": "T", "query": "q"}), scene())

    def test_jev_failure_raises_instead_of_downgrading(self):
        st = FakeStash({TPDB: [scraped("Snowed In", "Frolic Me", rid="t1")],
                        STASHDB: [scraped("SNOWED IN", "Frolic Me", rid="s1")]})
        llm = FakeLLM({"title": "T", "query": "q"}, choice=RuntimeError("jev down"))
        with self.assertRaises(RuntimeError):
            main.identify_scene(st, llm, scene())

    def test_duration_filter_runs_before_dedupe(self):
        # The TPDB copy sorts first into dedupe but has no usable duration; without
        # filtering first it would win dedupe and the whole match would be lost.
        st = FakeStash({TPDB: [scraped("Cow", "Trip", duration=None, rid="t1")],
                        STASHDB: [scraped("Cow", "Trip", duration=600, rid="s1")]})
        p = main.identify_scene(st, FakeLLM({"query": "q"}, choice="c0"), scene())
        self.assertEqual(p["kind"], "scrape")
        self.assertEqual(p["primary_endpoint"], STASHDB)


class JavIdentifyTest(unittest.TestCase):
    path = "/media/Vault/CAWD-910.mp4"

    def test_stashdb_exact_code_wins_without_llm(self):
        st = FakeStash({STASHDB: [scraped("IPZZ-795", "Idea Pocket", duration=9499, rid="s1",
                                          code="IPZZ-795"),
                                  scraped("DVDES-795", "Deep’s", rid="s2", code="DVDES-795")]})
        tp = FakeTPDB([])
        p = main.identify_scene(st, NO_LLM, scene(path="/media/Vault/IPZZ-795.mp4", duration=9500), tp)
        self.assertEqual((p["kind"], p["rule"], p["source"]), ("scrape", "code", "stashdb"))
        self.assertEqual(p["primary_endpoint"], STASHDB)
        self.assertEqual(p["stash_ids"], [{"endpoint": STASHDB, "stash_id": "s1"}])
        self.assertEqual(p["delta"], -1)
        self.assertEqual(tp.calls, [])  # StashDB hit: TPDB never asked

    def test_tpdb_jav_hit_ignores_duration(self):
        # StashDB only has same-number neighbours; TPDB's nominal 7800 s is 281 s off.
        st = FakeStash({STASHDB: [scraped("PPPD-910", "Oppai", code="PPPD-910")]})
        p = main.identify_scene(st, NO_LLM, scene(path=self.path, duration=7519.0),
                                FakeTPDB([jav_hit("CAWD-910")]))
        self.assertEqual((p["kind"], p["rule"], p["source"]), ("scrape", "code", "tpdb-jav"))
        self.assertEqual(p["primary_endpoint"], main.TPDB_JAV)
        self.assertEqual(p["primary"]["code"], "CAWD-910")
        self.assertEqual((p["stash_ids"], p["delta"]), ([], 281))

    def test_both_miss_falls_back_to_llm(self):
        p = main.identify_scene(FakeStash(), FakeLLM({"title": "T", "query": ""}),
                                scene(path=self.path), FakeTPDB([jav_hit("CAWD-190")]))
        self.assertEqual(p["kind"], "llm")

    def test_no_tpdb_client_uses_stashdb_only(self):
        p = main.identify_scene(FakeStash(), FakeLLM({"title": "T", "query": ""}),
                                scene(path=self.path), None)
        self.assertEqual(p["kind"], "llm")

    def test_ambiguous_exact_hits_fall_back(self):
        tp = FakeTPDB([jav_hit("CAWD-910", title="One"), jav_hit("CAWD-910", title="Two")])
        p = main.identify_scene(FakeStash(), FakeLLM({"title": "T", "query": ""}),
                                scene(path=self.path), tp)
        self.assertEqual(p["kind"], "llm")

    def test_tpdb_failure_is_transient(self):
        with self.assertRaises(main.TransientError):
            main.identify_scene(FakeStash(), NO_LLM, scene(path=self.path),
                                FakeTPDB(urllib.error.URLError("down")))

    def test_stashdb_failure_is_transient(self):
        with self.assertRaises(main.TransientError):
            main.identify_scene(FakeStash({STASHDB: RuntimeError("down")}), NO_LLM,
                                scene(path=self.path), FakeTPDB([]))

    def test_tpdb_auth_failure_is_a_miss_not_transient(self):
        logs = []
        orig_log = main.log
        main.log = lambda *a: logs.append(" ".join(str(x) for x in a))
        try:
            tp = FakeTPDB(urllib.error.HTTPError("url", 401, "Unauthorized", None, None))
            p = main.identify_scene(FakeStash(), FakeLLM({"title": "T", "query": ""}),
                                    scene(path=self.path), tp)
        finally:
            main.log = orig_log
        self.assertEqual(p["kind"], "llm")
        self.assertEqual(len(logs), 1)
        self.assertIn("ThePornDB", logs[0])

    def test_tpdb_server_error_is_still_transient(self):
        tp = FakeTPDB(urllib.error.HTTPError("url", 500, "Server Error", None, None))
        with self.assertRaises(main.TransientError):
            main.identify_scene(FakeStash(), NO_LLM, scene(path=self.path), tp)

    def test_tpdb_jav_apply_resolves_by_name(self):
        st = FakeStash()
        p = main.identify_scene(st, NO_LLM, scene(path=self.path, duration=7519.0),
                                FakeTPDB([jav_hit("CAWD-910")]))
        main.apply(st, scene(path=self.path), p, skip_tag_ids=set())
        self.assertEqual(st.created, [("studio", {"name": "Kawaii"}),
                                      ("performer", {"name": "Kurea Hasumi"})])
        up = st.updates[0]
        self.assertEqual((up["title"], up["code"]), ("CAWD-910 - Some Title", "CAWD-910"))
        self.assertEqual((up["studio_id"], up["performer_ids"]), ("s-Kawaii", ["p-Kurea Hasumi"]))
        self.assertEqual(up["stash_ids"], [])


FC2_URL = "https://adult.contents.fc2.com/article/4987084/"


def fc2_hit(title="金欠スレンダー美女", seller="イカせげぇむ"):
    return {"title": title, "code": "FC2-PPV-4987084", "date": "2026-10-04", "details": None,
            "image": "data:img", "duration": None, "remote_site_id": None,
            "studio": {"name": "FC2"}, "performers": [{"name": seller}] if seller else [],
            "tags": [], "urls": [FC2_URL]}


class Fc2IdentifyTest(unittest.TestCase):
    path = "/media/Vault/FC2-PPV-4987084.mp4"
    PARSE_ONLY = FakeLLM({"title": "T", "query": ""}, translation=AssertionError("no hit"))

    def stash(self, result):
        st = FakeStash(studios=[{"id": "632", "name": "FC2-PPV", "aliases": []}])
        st.fc2[FC2_URL] = result
        return st

    def test_hit_is_translated_and_skips_stash_box_and_tpdb(self):
        st, tp = self.stash(fc2_hit()), FakeTPDB([])
        llm = FakeLLM(AssertionError("no parse"), translation="Slender Beauty")
        p = main.identify_scene(st, llm, scene(path=self.path), tp)
        self.assertEqual((p["kind"], p["rule"], p["source"]), ("scrape", "code", "fc2"))
        self.assertEqual((p["primary"]["title"], p["primary"]["details"]),
                         ("Slender Beauty", "金欠スレンダー美女"))
        self.assertEqual((p["stash_ids"], p["delta"]), ([], None))
        self.assertEqual(llm.translated, ["金欠スレンダー美女"])
        self.assertEqual((st.scraped_urls, tp.calls), ([FC2_URL], []))

    def test_removed_listing_falls_back_to_llm(self):
        # Stash's fc2 scraper nil-derefs on FC2's "product not found" page.
        st = self.stash(RuntimeError([{"message": "nil pointer dereference"}]))
        p = main.identify_scene(st, self.PARSE_ONLY, scene(path=self.path))
        self.assertEqual(p["kind"], "llm")

    def test_empty_scrape_falls_back_to_llm(self):
        p = main.identify_scene(self.stash(None), self.PARSE_ONLY, scene(path=self.path))
        self.assertEqual(p["kind"], "llm")

    def test_stash_unreachable_is_transient(self):
        with self.assertRaises(main.TransientError):
            main.identify_scene(self.stash(urllib.error.URLError("down")), NO_LLM,
                                scene(path=self.path))

    def test_translation_failure_is_transient(self):
        llm = FakeLLM(AssertionError("no parse"), translation=ValueError("malformed"))
        with self.assertRaises(main.TransientError):
            main.identify_scene(self.stash(fc2_hit()), llm, scene(path=self.path))

    def test_apply_puts_seller_under_existing_fc2_ppv(self):
        st = self.stash(fc2_hit())
        p = main.identify_scene(st, FakeLLM(None, translation="Slender Beauty"),
                                scene(path=self.path))
        main.apply(st, scene(path=self.path), p, skip_tag_ids=set())
        self.assertEqual(st.created, [("studio", {"name": "イカせげぇむ", "parent_id": "632"})])
        up = st.updates[0]
        self.assertEqual((up["title"], up["code"], up["studio_id"], up["performer_ids"]),
                         ("Slender Beauty", "FC2-PPV-4987084", "s-イカせげぇむ", []))
        self.assertEqual(up["urls"], [FC2_URL])


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


class FormatLineTest(unittest.TestCase):
    def test_llm_only_shows_display_title_fallback(self):
        prop = {"kind": "llm", "parse": {"title": None, "studio": "RealCollegeGirls",
                                         "date": "2025-10-11"}, "confidence": None}
        line = main.format_line(scene(), prop)
        self.assertIn("RealCollegeGirls – 2025-10-11", line)

    def test_llm_only_shows_real_title_unchanged(self):
        prop = {"kind": "llm", "parse": {"title": "Guess", "studio": "S"}, "confidence": None}
        line = main.format_line(scene(), prop)
        self.assertIn("'Guess'", line)

    def test_tpdb_jav_line_shows_source_and_delta(self):
        prop = main.identify_scene(FakeStash(), NO_LLM,
                                   scene(path="/media/Vault/CAWD-910.mp4", duration=7519.0),
                                   FakeTPDB([jav_hit("CAWD-910")]))
        line = main.format_line(scene(path="/media/Vault/CAWD-910.mp4"), prop)
        self.assertIn("tpdb-jav (code)", line)
        self.assertIn("Δ+281s", line)

    def test_unknown_delta_does_not_crash(self):
        prop = main.identify_scene(FakeStash({STASHDB: [scraped("IPZZ-795", "Idea Pocket",
                                                                duration=None, code="IPZZ-795")]}),
                                   NO_LLM, scene(path="/media/Vault/IPZZ-795.mp4"), None)
        self.assertIn("Δ?", main.format_line(scene(), prop))


class StashLookupTest(unittest.TestCase):
    """Real Stash: the q= fuzzy search is capped at 50 hits and not relevance-ordered, so
    it can miss a performer/studio's own exact name (seen live for "Be", "Ro", ...).
    performers_like/studios_like must also run an exact-name lookup and union the results."""

    def test_performers_like_unions_exact_and_fuzzy_by_id(self):
        s = stash_mod.Stash("http://x/graphql")
        calls = []

        def fake_gql(query, **variables):
            calls.append((query, variables))
            if "performer_filter" in query:
                return {"findPerformers": {"performers": [{"id": "1", "name": "Be", "alias_list": []}]}}
            return {"findPerformers": {"performers": [
                {"id": "1", "name": "Be", "alias_list": []},
                {"id": "2", "name": "Bee", "alias_list": []}]}}
        s.gql = fake_gql
        result = s.performers_like("Be")
        self.assertEqual([r["id"] for r in result], ["1", "2"])
        self.assertEqual(len(calls), 2)
        exact_call = next(q for q, v in calls if "performer_filter" in q)
        self.assertIn("modifier: EQUALS", exact_call)
        self.assertIn("per_page: -1", exact_call)

    def test_studios_like_unions_exact_and_fuzzy_by_id(self):
        s = stash_mod.Stash("http://x/graphql")
        calls = []

        def fake_gql(query, **variables):
            calls.append((query, variables))
            if "studio_filter" in query:
                # The exact-name query finds "Ro", which the capped/unordered q= search
                # below misses entirely.
                return {"findStudios": {"studios": [{"id": "9", "name": "Ro", "aliases": []}]}}
            return {"findStudios": {"studios": [{"id": "10", "name": "Robot", "aliases": []}]}}
        s.gql = fake_gql
        result = s.studios_like("Ro")
        self.assertEqual([r["id"] for r in result], ["9", "10"])
        self.assertEqual(len(calls), 2)
        exact_call = next(q for q, v in calls if "studio_filter" in q)
        self.assertIn("modifier: EQUALS", exact_call)
        self.assertIn("per_page: -1", exact_call)


class ClientTest(unittest.TestCase):
    def test_tpdb_jav_search_sends_key_and_returns_data(self):
        seen = {}

        def fake_get_json(url, headers=None, timeout=120):
            seen.update(url=url, headers=headers)
            return {"data": [{"external_id": "cawd-910"}]}
        orig = tpdb.get_json
        tpdb.get_json = fake_get_json
        try:
            hits = tpdb.TPDBJav("k").jav_search("CAWD-910")
        finally:
            tpdb.get_json = orig
        self.assertEqual(hits, [{"external_id": "cawd-910"}])
        self.assertEqual(seen["url"], "https://api.theporndb.net/jav?q=CAWD-910&per_page=10")
        self.assertEqual(seen["headers"]["Authorization"], "Bearer k")
        self.assertIn("User-Agent", seen["headers"])

    def test_tpdb_api_key_from_stash_box_config(self):
        s = stash_mod.Stash("http://x/graphql")
        s.gql = lambda q, **v: {"configuration": {"general": {"stashBoxes": [
            {"endpoint": "https://stashdb.org/graphql", "api_key": "sdb"},
            {"endpoint": "https://theporndb.net/graphql", "api_key": "tp"}]}}}
        self.assertEqual(s.tpdb_api_key(), "tp")
        s.gql = lambda q, **v: {"configuration": {"general": {"stashBoxes": []}}}
        self.assertIsNone(s.tpdb_api_key())

    def test_scenes_with_tag_filters_by_tag(self):
        s = stash_mod.Stash("http://x/graphql")
        calls = []

        def fake_gql(query, **variables):
            calls.append((query, variables))
            return {"findScenes": {"scenes": [{"id": "20"}]}}
        s.gql = fake_gql
        self.assertEqual(s.scenes_with_tag("77"), [{"id": "20"}])
        query, variables = calls[0]
        self.assertIn("tags:", query)
        self.assertIn("INCLUDES", query)
        self.assertEqual(variables, {"t": ["77"]})


class PathTest(unittest.TestCase):
    def test_host_to_container(self):
        self.assertEqual(main.to_container("/mnt/storage/media/Vault/a b/c"), "/media/Vault/a b/c")


class StateTest(unittest.TestCase):
    def test_persists_ids(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "sub", "attempted.json")
            s = main.State(path)
            self.assertNotIn("5", s)
            s.add("5")
            self.assertIn("5", main.State(path))
            with open(path) as f:
                self.assertEqual(json.load(f), ["5"])


class SkipTagsTest(unittest.TestCase):
    def test_collects_identify_skip_tags(self):
        d = {"identify": {"options": {"skipMultipleMatchTag": "1398",
                                      "skipSingleNamePerformerTag": "1398"}}}
        self.assertEqual(main.skip_tags(d), {"1398"})
        self.assertEqual(main.skip_tags({"identify": {}}), set())


class IsUpgradeTest(unittest.TestCase):
    def test_tagged_scene_with_no_files_is_not_an_upgrade(self):
        s = scene(tags=[{"id": "t-llm-identified"}], files=[])
        self.assertFalse(main.is_upgrade(s, "t-llm-identified"))


class PassTest(unittest.TestCase):
    class PassStash(FakeStash):
        def __init__(self, bare, scenes_dict=None, missing=()):
            super().__init__()
            self.bare, self.jobs = bare, []
            self.scenes_dict = scenes_dict or {}
            self.missing = set(missing)

        def max_scene_id(self):
            return 10

        def scan(self, paths, options):
            self.jobs.append(("scan", paths))

        def scene_ids_after(self, sid):
            return ["11"]

        def generate(self, ids, options):
            self.jobs.append(("generate", ids))

        def identify(self, ids, options):
            self.jobs.append(("identify", ids))

        def bare_scenes(self):
            return self.bare

        def scenes(self, ids):
            # Real Stash still returns a scene's current data on a plain re-fetch; only an
            # id in `missing` simulates one deleted mid-run. `scenes_dict` overrides a bare
            # entry to stage a "fresh copy differs from the stale one" case.
            by_id = {**{s["id"]: s for s in self.bare}, **self.scenes_dict}
            return [by_id[sid] for sid in ids if sid in by_id and sid not in self.missing]

    defaults = {"scan": {}, "generate": {}, "identify": {}}

    def state(self, d):
        return main.State(os.path.join(d, "s.json"))

    def guessed(self, id="20", path="/media/Vault/CAWD-910.mp4", tags=("t-llm-identified",)):
        return scene(id, path=path, duration=7519.0, title="Kawaii* – CAWD-910",
                     studio={"id": "s9"}, performers=[{"id": "p9"}],
                     tags=[{"id": t} for t in tags])

    def upgrade_stash(self, stale, fresh=None):
        st = self.PassStash([], scenes_dict={stale["id"]: fresh or stale})
        st.tags = {"llm-identified": "t-llm-identified"}
        st.tagged = [stale]
        return st

    def test_steps_in_order_and_state_recorded(self):
        st = self.PassStash([scene("11"), scene("12")])
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            state.add("12")
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                          ["/mnt/storage/media/Vault/new"])
            self.assertEqual(st.jobs, [("scan", ["/media/Vault/new"]),
                                       ("generate", ["11"]), ("identify", ["11"])])
            self.assertEqual([u["id"] for u in st.updates], ["11"])  # 12 was already attempted
            self.assertIn("11", state)

    def test_dry_run_skips_jobs_writes_and_state(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                          None, dry_run=True)
            self.assertEqual((st.jobs, st.updates), ([], []))
            self.assertNotIn("11", state)

    def test_manual_run_skips_jobs_but_applies(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), self.state(d), self.defaults,
                          None, jobs=False)
            self.assertEqual(st.jobs, [])
            self.assertEqual([u["id"] for u in st.updates], ["11"])

    def test_parse_failure_is_not_recorded(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            main.run_pass(st, FakeLLM(ValueError("bad")), state, self.defaults, None)
            self.assertNotIn("11", state)

    def test_job_failure_still_reaches_llm_step(self):
        st = self.PassStash([scene("11")])

        def boom(paths, options):
            raise main.JobFailed("scan failed")
        st.scan = boom
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), self.state(d), self.defaults, None)
            self.assertEqual([u["id"] for u in st.updates], ["11"])

    def test_failure_cap_gives_up_after_three_failures(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.json")
            for _ in range(main.State.FAILURE_LIMIT - 1):
                main.run_pass(st, FakeLLM(ValueError("bad")), main.State(path), self.defaults,
                              None, jobs=False)
                self.assertNotIn("11", main.State(path))
            main.run_pass(st, FakeLLM(ValueError("bad")), main.State(path), self.defaults,
                          None, jobs=False)
            self.assertIn("11", main.State(path))

    def test_failure_cap_not_counted_in_dry_run(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.json")
            for _ in range(main.State.FAILURE_LIMIT + 2):
                main.run_pass(st, FakeLLM(ValueError("bad")), main.State(path), self.defaults,
                              None, jobs=False, dry_run=True)
            state = main.State(path)
            self.assertEqual(state.failures, {})
            self.assertNotIn("11", state)

    def test_success_clears_failure_count(self):
        st = self.PassStash([scene("11")])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.json")
            main.run_pass(st, FakeLLM(ValueError("bad")), main.State(path), self.defaults,
                          None, jobs=False)
            main.run_pass(st, FakeLLM(ValueError("bad")), main.State(path), self.defaults,
                          None, jobs=False)
            self.assertEqual(main.State(path).failures.get("11"), 2)
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), main.State(path), self.defaults,
                          None, jobs=False)
            state = main.State(path)
            self.assertIsNone(state.failures.get("11"))
            self.assertIn("11", state)

    def test_transient_search_failure_never_counted(self):
        # A stash-box outage: search raises on every pass. The scene must never be
        # recorded and the failure count must never move, however many passes run.
        st = self.PassStash([scene("11")])
        st.results = {TPDB: RuntimeError("stash-box down")}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.json")
            for _ in range(main.State.FAILURE_LIMIT + 2):
                main.run_pass(st, FakeLLM({"title": "T", "query": "q"}), main.State(path),
                              self.defaults, None, jobs=False)
            state = main.State(path)
            self.assertNotIn("11", state)
            self.assertEqual(state.failures, {})

    def test_transient_network_error_never_counted(self):
        # An OpenRouter outage surfacing as a raw urllib error, not a TransientError:
        # still must not count, however many passes run.
        st = self.PassStash([scene("11")])
        llm = FakeLLM(urllib.error.URLError("timed out"))
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.json")
            for _ in range(main.State.FAILURE_LIMIT + 2):
                main.run_pass(st, llm, main.State(path), self.defaults, None, jobs=False)
            state = main.State(path)
            self.assertNotIn("11", state)
            self.assertEqual(state.failures, {})

    def test_scene_specific_failure_gives_up_with_error_in_log(self):
        # A Stash-side mutation error (not transient) must still count, and the give-up
        # line must carry the error that caused the final failure.
        st = self.PassStash([scene("11")])

        def boom(inp):
            raise RuntimeError("sceneUpdate: bad studio_id")
        st.update_scene = boom
        logs = []
        orig_log = main.log
        main.log = lambda *a: logs.append(" ".join(str(x) for x in a))
        try:
            with tempfile.TemporaryDirectory() as d:
                path = os.path.join(d, "s.json")
                for _ in range(main.State.FAILURE_LIMIT):
                    main.run_pass(st, FakeLLM({"title": "T", "query": ""}), main.State(path),
                                  self.defaults, None, jobs=False)
                state = main.State(path)
                self.assertIn("11", state)
        finally:
            main.log = orig_log
        giveup = [l for l in logs if "giving up on [11]" in l]
        self.assertEqual(len(giveup), 1)
        self.assertIn("bad studio_id", giveup[0])

    def test_scene_ids_ignore_state_and_bare_filter(self):
        st = self.PassStash([], scenes_dict={"11": scene("11"), "12": scene("12")})

        def boom(*args):
            raise AssertionError("bare_scenes should not be called")
        st.bare_scenes = boom
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            state.add("12")
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                          None, jobs=False, scene_ids=["12"])
            self.assertEqual(st.jobs, [])
            self.assertEqual([u["id"] for u in st.updates], ["12"])
            self.assertIn("12", state)  # updated even though already in state

    def test_edited_meanwhile_not_applied(self):
        # Listed bare, but a fresh re-fetch shows the scene picked up a title by other
        # means (UI edit, a concurrent identify) while the LLM step was running.
        st = self.PassStash([scene("11")], scenes_dict={"11": scene("11", title="Already Titled")})
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                          None, jobs=False)
            self.assertEqual(st.updates, [])
            self.assertIn("11", state)

    def test_gone_mid_run_is_skipped(self):
        # The re-fetch finds nothing: the scene was deleted while the LLM step ran.
        # Nothing should be created or updated, and it must not be recorded as done.
        st = self.PassStash([scene("11")], missing={"11"})
        logs = []
        orig_log = main.log
        main.log = lambda *a: logs.append(" ".join(str(x) for x in a))
        try:
            with tempfile.TemporaryDirectory() as d:
                state = self.state(d)
                main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                              None, jobs=False)
                self.assertEqual((st.updates, st.created), ([], []))
                self.assertNotIn("11", state)
        finally:
            main.log = orig_log
        self.assertTrue(any("[11] gone, skipped" in l for l in logs))

    def test_apply_uses_freshly_refetched_scene(self):
        stale = scene("11", tags=[{"id": "stale-tag"}])
        fresh = scene("11", tags=[{"id": "fresh-tag"}])
        st = self.PassStash([stale], scenes_dict={"11": fresh})
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                          None, jobs=False)
            self.assertEqual(len(st.updates), 1)
            self.assertEqual(st.updates[0]["tag_ids"], ["fresh-tag", "t-llm-identified"])
            self.assertIn("11", state)

    def test_explicit_scene_run_applies_even_if_edited_meanwhile(self):
        # --scene ID is an explicit ask; it should not be silently skipped.
        edited = scene("11", title="Existing Title")
        st = self.PassStash([], scenes_dict={"11": edited})
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            main.run_pass(st, FakeLLM({"title": "T", "query": ""}), state, self.defaults,
                          None, jobs=False, scene_ids=["11"])
            self.assertEqual(len(st.updates), 1)
            self.assertIn("11", state)

    def test_llm_guess_with_jav_code_is_upgraded(self):
        st = self.upgrade_stash(self.guessed())
        with tempfile.TemporaryDirectory() as d:
            state = self.state(d)
            state.add("20")  # done long ago; upgrades ignore the state file
            main.run_pass(st, NO_LLM, state, self.defaults, None, jobs=False,
                          tpdb=FakeTPDB([jav_hit("CAWD-910")]))
        up = st.updates[0]
        self.assertEqual(up["title"], "CAWD-910 - Some Title")
        self.assertEqual(up["studio_id"], "s-Kawaii")
        self.assertEqual(up["performer_ids"], ["p-Kurea Hasumi"])
        self.assertEqual(up["tag_ids"], [])  # llm-identified dropped

    def test_upgrade_miss_writes_nothing_and_leaves_state(self):
        st = self.upgrade_stash(self.guessed())
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.json")
            main.run_pass(st, NO_LLM, main.State(path), self.defaults, None, jobs=False,
                          tpdb=FakeTPDB([]))
            state = main.State(path)
            self.assertEqual((st.updates, st.created), ([], []))
            self.assertNotIn("20", state)
            self.assertEqual(state.failures, {})

    def test_llm_guess_without_code_is_not_revisited(self):
        tp = FakeTPDB([jav_hit("CAWD-910")])
        st = self.upgrade_stash(self.guessed(path="/media/Vault/Some Title.mp4"))
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, NO_LLM, self.state(d), self.defaults, None, jobs=False, tpdb=tp)
        self.assertEqual((st.updates, tp.calls), ([], []))

    def test_upgrade_skipped_once_tag_removed_meanwhile(self):
        st = self.upgrade_stash(self.guessed(), fresh=self.guessed(tags=()))
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, NO_LLM, self.state(d), self.defaults, None, jobs=False,
                          tpdb=FakeTPDB([jav_hit("CAWD-910")]))
        self.assertEqual(st.updates, [])

    def test_explicit_scene_run_upgrades_too(self):
        st = self.upgrade_stash(self.guessed())
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, NO_LLM, self.state(d), self.defaults, None, jobs=False,
                          scene_ids=["20"], tpdb=FakeTPDB([jav_hit("CAWD-910")]))
        self.assertEqual(st.updates[0]["title"], "CAWD-910 - Some Title")

    def test_fc2_llm_guess_is_upgraded_with_translation(self):
        st = self.upgrade_stash(self.guessed(path="/media/Vault/FC2-PPV-4987084.mp4"))
        st.fc2[FC2_URL] = fc2_hit()
        with tempfile.TemporaryDirectory() as d:
            main.run_pass(st, FakeLLM(AssertionError("no parse"), translation="Slender Beauty"),
                          self.state(d), self.defaults, None, jobs=False)
        up = st.updates[0]
        self.assertEqual((up["title"], up["details"]), ("Slender Beauty", "金欠スレンダー美女"))
        self.assertEqual((up["performer_ids"], up["tag_ids"]), ([], []))


class DebouncerTest(unittest.TestCase):
    def test_fires_once_after_quiet(self):
        d = main.Debouncer(quiet=120)
        self.assertIsNone(d.ready(0))
        d.add("/v/a", 0)
        d.add("/v/b", 100)
        self.assertIsNone(d.ready(219))           # 119 s since the last event
        self.assertEqual(d.ready(220), {"/v/a", "/v/b"})
        self.assertIsNone(d.ready(1000))          # drained


class ChangedDirTest(unittest.TestCase):
    exts = {"mp4", "mkv"}

    def test_video_file_gives_its_folder(self):
        self.assertEqual(main.changed_dir("CLOSE_WRITE,CLOSE|/v/a b/x.MP4", self.exts), "/v/a b")

    def test_moved_in_folder_gives_itself(self):
        self.assertEqual(main.changed_dir("MOVED_TO,ISDIR|/v/New Folder", self.exts), "/v/New Folder")

    def test_other_files_ignored(self):
        self.assertIsNone(main.changed_dir("CLOSE_WRITE,CLOSE|/v/x.nfo", self.exts))
        self.assertIsNone(main.changed_dir("garbage", self.exts))


class NextActionTest(unittest.TestCase):
    def test_startup_triggers_sweep(self):
        # Startup with last_sweep == 0.0 should trigger sweep immediately
        d = main.Debouncer(quiet=120)
        action = main.next_action(d, 0.0, 100.0)
        self.assertEqual(action, ("sweep", None))

    def test_pending_dirs_after_quiet_triggers_pass(self):
        # After quiet period, pending dirs should trigger a pass
        d = main.Debouncer(quiet=120)
        d.add("/dir/a", 0.0)
        d.add("/dir/b", 50.0)
        action = main.next_action(d, 50.0, 170.1)  # 120.1s after last event
        self.assertEqual(action[0], "pass")
        self.assertEqual(action[1], {"/dir/a", "/dir/b"})

    def test_nothing_due_returns_none(self):
        # No events and no sweep due = None
        d = main.Debouncer(quiet=120)
        action = main.next_action(d, 100.0, 200.0)  # 100s after last sweep, no pending
        self.assertIsNone(action)

    def test_sweep_not_starved_by_pending_events(self):
        # Even if debouncer has pending dirs that aren't quiet yet,
        # sweep should fire if SWEEP_EVERY has passed
        d = main.Debouncer(quiet=120)
        now = 100000.0
        last_sweep = now - main.SWEEP_EVERY - 1  # sweep is due
        d.add("/dir/a", now - 10.0)  # event 10s ago, not quiet yet
        action = main.next_action(d, last_sweep, now)
        self.assertEqual(action, ("sweep", None))


if __name__ == "__main__":
    unittest.main()
