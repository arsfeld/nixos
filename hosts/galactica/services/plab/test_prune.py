import unittest

from prune import decide

VAULT = "/mnt/storage/media/Downloads/Vault"
NOW = 1_800_000_000
DAY = 86400
LAB = [{"announce": "http://bt.plab.site/ann?uk=x"}]
PUBLIC = [{"announce": "udp://tracker.opentrackr.org:1337/announce"}]


def t(id, trackers=LAB, done=1.0, ratio=0.0, done_ago=1, active_ago=None, dir=VAULT):
    return {
        "id": id, "name": f"t{id}", "downloadDir": dir, "percentDone": done, "uploadRatio": ratio,
        "doneDate": NOW - done_ago * DAY if done == 1.0 else 0,
        "activityDate": NOW - (done_ago if active_ago is None else active_ago) * DAY,
        "trackers": trackers,
    }


def ids(torrents):
    return [i for i, _, _ in decide(torrents, NOW, VAULT)]


class Decide(unittest.TestCase):
    def test_public_removed_once_complete(self):
        self.assertEqual(ids([t(1, PUBLIC), t(2, PUBLIC, done=0.5)]), [1])

    def test_lab_ratio(self):
        self.assertEqual(ids([t(1, ratio=2.0), t(2, ratio=1.9, done_ago=10, active_ago=1)]), [1])

    def test_lab_idle_counts_from_completion(self):
        # done 8 days ago, last upload 7 days ago: idle. Done 2 days ago, nothing since: not yet.
        self.assertEqual(ids([t(1, done_ago=8, active_ago=7), t(2, done_ago=2, active_ago=20)]), [1])

    def test_lab_still_downloading_kept(self):
        self.assertEqual(ids([t(1, done=0.4, ratio=5.0, active_ago=30)]), [])

    def test_outside_vault_never_removed(self):
        others = [t(1, PUBLIC, dir="/mnt/storage/media/Downloads"),
                  t(2, PUBLIC, dir=VAULT + "2"),
                  t(3, ratio=9.0, dir="/mnt/storage/media/Downloads/radarr")]
        self.assertEqual(ids(others), [])

    def test_studio_subdirectory_is_vault(self):
        self.assertEqual(ids([t(1, PUBLIC, dir=VAULT + "/Some Studio")]), [1])

    def test_cap_trims_longest_idle(self):
        seeding = [t(i, done_ago=1, active_ago=0) for i in range(50)]
        seeding += [t(100, done_ago=6), t(101, done_ago=5)]
        self.assertEqual(sorted(ids(seeding)), [100, 101])

    def test_lab_on_any_tracker(self):
        mixed = PUBLIC + [{"announce": "http://pornolab.net/ann"}]
        self.assertEqual(ids([t(1, mixed, done_ago=1)]), [])

    def test_reasons(self):
        reasons = {i: r for i, _, r in decide([t(1, PUBLIC), t(2, ratio=3.0), t(3, done_ago=9)], NOW, VAULT)}
        self.assertEqual(reasons[1], "complete, not PornoLab")
        self.assertIn("ratio", reasons[2])
        self.assertIn("idle", reasons[3])


if __name__ == "__main__":
    unittest.main()
