"""Unit tests for stash-identify's per-scene flow, with fake Stash and LLM."""
import json
import os
import tempfile
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
            self.assertEqual(json.load(open(path)), ["5"])


class SkipTagsTest(unittest.TestCase):
    def test_collects_identify_skip_tags(self):
        d = {"identify": {"options": {"skipMultipleMatchTag": "1398",
                                      "skipSingleNamePerformerTag": "1398"}}}
        self.assertEqual(main.skip_tags(d), {"1398"})
        self.assertEqual(main.skip_tags({"identify": {}}), set())


class PassTest(unittest.TestCase):
    class PassStash(FakeStash):
        def __init__(self, bare, scenes_dict=None):
            super().__init__()
            self.bare, self.jobs = bare, []
            self.scenes_dict = scenes_dict or {}

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
            return [self.scenes_dict[sid] for sid in ids if sid in self.scenes_dict]

    defaults = {"scan": {}, "generate": {}, "identify": {}}

    def state(self, d):
        return main.State(os.path.join(d, "s.json"))

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


if __name__ == "__main__":
    unittest.main()
