"""Unit tests for the Immich → Pixel stager.

Deliberately hermetic: no database, no exiftool, no Immich library. Everything
tested here is a pure function or a tmpdir operation, so the whole file runs
inside a Nix build.
"""

import unittest
import tempfile
from pathlib import Path

import sync


def row(**overrides):
    """One row as the selector query returns it."""
    asset = {
        "id": "a1b2c3d4-1111-2222-3333-444455556666",
        "originalPath": "/mnt/storage/files/Immich/library/admin/2026/2026-07/IMG_2145.heic",
        "originalFileName": "IMG_2145.HEIC",
        "ts": "20260724_143022",
        "live_video": None,
    }
    asset.update(overrides)
    return asset


class IsMotionTest(unittest.TestCase):
    def test_an_asset_with_no_video_half_is_not_a_motion_photo(self):
        self.assertFalse(sync.is_motion(row()))

    def test_heic_plus_mov_is_a_motion_photo(self):
        self.assertTrue(sync.is_motion(row(live_video="/immich/IMG_2145.mov")))

    def test_a_primary_format_google_does_not_accept_is_not_muxed(self):
        asset = row(originalFileName="IMG_2145.PNG", live_video="/immich/IMG_2145.mov")
        self.assertFalse(sync.is_motion(asset))

    def test_a_video_format_the_spec_does_not_allow_is_not_muxed(self):
        asset = row(live_video="/immich/IMG_2145.avi")
        self.assertFalse(sync.is_motion(asset))


class StagedNameTest(unittest.TestCase):
    def test_a_plain_image_gets_a_sortable_prefix_and_a_lowercase_extension(self):
        self.assertEqual(
            sync.staged_name(row()),
            "20260724_143022_a1b2c3d4_IMG_2145.heic",
        )

    def test_a_live_pair_gets_the_MP_suffix_google_requires(self):
        self.assertEqual(
            sync.staged_name(row(live_video="/immich/IMG_2145.mov")),
            "20260724_143022_a1b2c3d4_IMG_2145.MP.heic",
        )

    def test_duplicate_basenames_do_not_collide(self):
        first = sync.staged_name(row())
        second = sync.staged_name(row(id="99998888-0000-0000-0000-000000000000"))
        self.assertNotEqual(first, second)

    def test_characters_android_rejects_are_replaced(self):
        self.assertEqual(
            sync.staged_name(row(originalFileName='we:ird?  name.heic')),
            "20260724_143022_a1b2c3d4_we_ird__name.heic",
        )

    def test_a_stem_that_sanitizes_away_to_nothing_still_produces_a_filename(self):
        self.assertEqual(
            sync.staged_name(row(originalFileName=":::.heic")),
            "20260724_143022_a1b2c3d4_photo.heic",
        )


class PlanActionsTest(unittest.TestCase):
    def test_stages_what_is_missing_and_reaps_what_fell_out_of_the_window(self):
        desired = {"new.heic": row(), "kept.heic": row()}
        current = {"kept.heic", "old.heic"}
        to_add, to_delete = sync.plan_actions(desired, current, 50)
        self.assertEqual(set(to_add), {"new.heic"})
        self.assertEqual(to_delete, ["old.heic"])

    def test_an_empty_result_set_aborts_rather_than_deleting_everything(self):
        with self.assertRaises(sync.Abort):
            sync.plan_actions({}, {"kept.heic"}, 50)

    def test_the_shrink_guard_stops_a_mass_delete(self):
        desired = {"a.heic": row()}
        current = {f"{index}.heic" for index in range(10)}
        with self.assertRaises(sync.Abort):
            sync.plan_actions(desired, current, 50)

    def test_force_overrides_the_shrink_guard(self):
        desired = {"a.heic": row()}
        current = {f"{index}.heic" for index in range(10)}
        _, to_delete = sync.plan_actions(desired, current, 50, force=True)
        self.assertEqual(len(to_delete), 10)

    def test_the_shrink_guard_does_not_block_a_first_run(self):
        desired = {"a.heic": row()}
        to_add, to_delete = sync.plan_actions(desired, set(), 50)
        self.assertEqual(set(to_add), {"a.heic"})
        self.assertEqual(to_delete, [])

    def test_a_shrink_inside_the_threshold_is_allowed(self):
        desired = {f"{index}.heic": row() for index in range(7)}
        current = {f"{index}.heic" for index in range(10)}
        _, to_delete = sync.plan_actions(desired, current, 50)
        self.assertEqual(len(to_delete), 3)


class MpvdBoxTest(unittest.TestCase):
    def test_the_box_declares_its_own_size_including_the_eight_byte_header(self):
        box = sync.mpvd_box(b"V" * 512)
        self.assertEqual(len(box), 520)
        self.assertEqual(box[0:4], (520).to_bytes(4, "big"))
        self.assertEqual(box[4:8], b"mpvd")
        self.assertEqual(box[8:], b"V" * 512)

    def test_an_empty_video_still_produces_a_well_formed_header(self):
        self.assertEqual(sync.mpvd_box(b""), (8).to_bytes(4, "big") + b"mpvd")


class StagePlainTest(unittest.TestCase):
    """Staging must never be able to alter Immich's original — content or metadata.

    A hardlink would share the original's inode, so making the staged copy
    group-readable for Syncthing would also relax the permissions on Immich's
    file. These assertions are what stop someone reintroducing os.link here.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()
        self.original = self.root / "IMG_2145.heic"
        self.original.write_bytes(b"pixels")
        self.original.chmod(0o600)
        self.dest = self.root / "20260724_143022_a1b2c3d4_IMG_2145.heic"
        self.addCleanup(self._tmp.cleanup)

    def test_the_staged_copy_is_a_separate_inode_with_the_same_bytes(self):
        sync.stage_plain(row(originalPath=str(self.original)), self.dest, self.scratch)
        self.assertNotEqual(self.original.stat().st_ino, self.dest.stat().st_ino)
        self.assertEqual(self.dest.read_bytes(), b"pixels")

    def test_the_staged_copy_is_group_readable_so_syncthing_can_scan_it(self):
        sync.stage_plain(row(originalPath=str(self.original)), self.dest, self.scratch)
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o640)

    def test_immich_keeps_its_restrictive_mode(self):
        sync.stage_plain(row(originalPath=str(self.original)), self.dest, self.scratch)
        self.assertEqual(self.original.stat().st_mode & 0o777, 0o600)

    def test_reaping_the_staged_copy_leaves_the_original_intact(self):
        sync.stage_plain(row(originalPath=str(self.original)), self.dest, self.scratch)
        self.dest.unlink()
        self.assertEqual(self.original.read_bytes(), b"pixels")
        self.assertEqual(self.original.stat().st_mode & 0o777, 0o600)

    def test_no_scratch_file_is_left_behind(self):
        sync.stage_plain(row(originalPath=str(self.original)), self.dest, self.scratch)
        self.assertEqual(list(self.scratch.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
