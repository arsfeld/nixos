"""Unit tests for stash-identify's pure matching logic."""
import unittest

import match

TPDB = "https://theporndb.net/graphql"
STASHDB = "https://stashdb.org/graphql"


def cand(title, studio, date=None, duration=None, **kw):
    return {"title": title, "studio": {"name": studio} if studio else None,
            "date": date, "duration": duration, **kw}


class NormTest(unittest.TestCase):
    def test_collapses_case_space_punctuation(self):
        self.assertEqual(match.norm("Trip For Fuck"), match.norm("TripForFuck"))
        self.assertEqual(match.norm("CAN'T WAIT"), "cantwait")
        self.assertEqual(match.norm(None), "")


class DurationTest(unittest.TestCase):
    def test_within_tolerance(self):
        self.assertTrue(match.duration_ok(cand("a", "s", duration=358), 348.0))
        self.assertFalse(match.duration_ok(cand("a", "s", duration=359), 348.0))

    def test_unknown_duration_never_qualifies(self):
        self.assertFalse(match.duration_ok(cand("a", "s"), 348.0))


class DedupeTest(unittest.TestCase):
    def test_first_endpoint_wins_per_scene(self):
        out = match.dedupe([(TPDB, cand("Snowed In", "Frolic Me")),
                            (STASHDB, cand("SNOWED IN", "FrolicMe")),
                            (STASHDB, cand("Other", "Frolic Me"))])
        self.assertEqual([ep for ep, _ in out], [TPDB, STASHDB])
        self.assertEqual(out[1][1]["title"], "Other")


class DeterministicTest(unittest.TestCase):
    parse = {"studio": "TripForFuck", "date": "2024-12-24"}

    def test_studio_and_date_fire(self):
        c = (TPDB, cand("She's A Breeding Cow", "Trip For Fuck", "2024-12-24", 1200))
        self.assertEqual(match.deterministic_match([c], self.parse), c)

    def test_twins_across_endpoints_still_fire(self):
        a = (TPDB, cand("She's A Breeding Cow", "Trip For Fuck", "2024-12-24"))
        b = (STASHDB, cand("She's a breeding cow", "TripForFuck", "2024-12-24"))
        self.assertEqual(match.deterministic_match([a, b], self.parse), a)

    def test_two_different_scenes_do_not_fire(self):
        a = (TPDB, cand("One", "Trip For Fuck", "2024-12-24"))
        b = (TPDB, cand("Two", "Trip For Fuck", "2024-12-24"))
        self.assertIsNone(match.deterministic_match([a, b], self.parse))

    def test_needs_both_studio_and_date(self):
        c = (TPDB, cand("x", "Trip For Fuck", "2024-12-24"))
        self.assertIsNone(match.deterministic_match([c], {"studio": "TripForFuck", "date": None}))
        self.assertIsNone(match.deterministic_match([c], {"studio": "Other", "date": "2024-12-24"}))


class TwinsTest(unittest.TestCase):
    def test_finds_same_scene_on_other_endpoint(self):
        a = (STASHDB, cand("SNOWED IN", "Frolic Me", duration=600))
        b = (TPDB, cand("Snowed In", "Frolic Me", duration=601))
        c = (TPDB, cand("Snowed In", "Frolic Me", duration=900))  # wrong duration
        self.assertEqual(match.twins(a, [b, a, c], 600.0), [b, a])


class CreateInputTest(unittest.TestCase):
    def test_performer_conversions(self):
        p = {"name": "Vivian", "gender": "female", "height": "170", "weight": "55",
             "penis_length": None, "circumcised": "nonsense", "aliases": "Viv, V. ",
             "images": ["https://img/1.jpg", "https://img/2.jpg"], "remote_site_id": "abc",
             "country": "", "urls": []}
        got = match.performer_create_input(p, TPDB)
        self.assertEqual(got, {
            "name": "Vivian", "gender": "FEMALE", "height_cm": 170, "weight": 55,
            "alias_list": ["Viv", "V."], "image": "https://img/1.jpg",
            "stash_ids": [{"endpoint": TPDB, "stash_id": "abc"}]})

    def test_studio_with_parent(self):
        s = {"name": "Lustery", "image": "https://logo", "aliases": None, "remote_site_id": "r1"}
        self.assertEqual(match.studio_create_input(s, STASHDB, parent_id="7"), {
            "name": "Lustery", "image": "https://logo", "parent_id": "7",
            "stash_ids": [{"endpoint": STASHDB, "stash_id": "r1"}]})


class PickByNameTest(unittest.TestCase):
    records = [{"id": "1019", "name": "Kattie Gold", "alias_list": ["Vivian", "Katie Gold"]},
               {"id": "842", "name": "Vivian Grace", "alias_list": []}]

    def test_exact_name(self):
        self.assertEqual(match.pick_by_name(self.records, "vivian grace", "alias_list", True), "842")

    def test_single_name_alias_is_refused(self):
        self.assertFalse(match.alias_ok("Vivian"))
        self.assertIsNone(match.pick_by_name(self.records, "Vivian", "alias_list",
                                             match.alias_ok("Vivian")))

    def test_multi_word_alias_is_allowed(self):
        self.assertEqual(match.pick_by_name(self.records, "Katie Gold", "alias_list",
                                            match.alias_ok("Katie Gold")), "1019")


class UpdateTest(unittest.TestCase):
    scene = {"id": "5", "title": "", "code": "", "details": "", "director": "",
             "date": None, "urls": [], "studio": None, "performers": [],
             "tags": [{"id": "1398"}, {"id": "9"}],
             "stash_ids": [{"endpoint": STASHDB, "stash_id": "old"}]}

    def test_scrape_update_fills_empty_and_sets_cover(self):
        primary = {"title": "T", "code": "C", "date": "2026-07-23", "urls": ["u"],
                   "image": "data:image/jpeg;base64,xx", "details": None}
        up = match.scrape_update(
            self.scene, primary,
            stash_ids=[{"endpoint": TPDB, "stash_id": "new"}, {"endpoint": STASHDB, "stash_id": "old"}],
            studio_id="161", performer_ids=["1", "2"], tag_ids=["9", "20"], drop_tag_ids={"1398"})
        self.assertEqual(up, {
            "id": "5", "title": "T", "code": "C", "date": "2026-07-23", "urls": ["u"],
            "cover_image": "data:image/jpeg;base64,xx", "studio_id": "161",
            "performer_ids": ["1", "2"], "tag_ids": ["9", "20"],
            "stash_ids": [{"endpoint": STASHDB, "stash_id": "old"}, {"endpoint": TPDB, "stash_id": "new"}]})

    def test_scrape_update_never_overwrites(self):
        scene = {**self.scene, "title": "Mine", "studio": {"id": "3"}}
        up = match.scrape_update(scene, {"title": "T"}, [], "161", [], [], set())
        self.assertNotIn("title", up)
        self.assertNotIn("studio_id", up)

    def test_llm_update_tags_guess(self):
        up = match.llm_update(self.scene, {"title": "Guess"}, "3", ["4"], "77")
        self.assertEqual(up, {"id": "5", "title": "Guess", "studio_id": "3",
                              "performer_ids": ["4"], "tag_ids": ["1398", "9", "77"]})


class JevTest(unittest.TestCase):
    def test_request_and_pick(self):
        cands = [(TPDB, cand("A", "S", duration=100)), (STASHDB, cand("B", "S", duration=101))]
        state, q = match.jev_request("dir/file.mp4", 100.4, {"studio": "S"}, cands)
        self.assertEqual(state["file_duration_seconds"], 100)
        self.assertEqual(sorted(q["match"]["criteria"]), ["c0", "c1", "none"])
        self.assertEqual(match.jev_pick({"choice": "c1"}, cands), cands[1])
        self.assertIsNone(match.jev_pick({"choice": "none"}, cands))


if __name__ == "__main__":
    unittest.main()
