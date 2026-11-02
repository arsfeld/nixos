import unittest

from rehost import apply_moves, decide, tuya_entries

HUB = ("e1", "Living room IR", "192.168.68.56", "dev1")
NOW = 100_000


def run(state, up=(), found=None, entries=(HUB,)):
    scanned = []

    def discover(device_id):
        scanned.append(device_id)
        return found

    moves, new, _ = decide(list(entries), lambda h: h in up, discover, state, NOW)
    return moves, new, scanned


class Decide(unittest.TestCase):
    def test_reachable_clears_failures(self):
        moves, state, scanned = run({"failures": {"e1": 1}}, up={"192.168.68.56"})
        self.assertEqual((moves, state["failures"], scanned), ({}, {}, []))

    def test_one_failure_does_not_scan(self):
        moves, state, scanned = run({})
        self.assertEqual((moves, state["failures"], scanned), ({}, {"e1": 1}, []))

    def test_two_failures_and_moved(self):
        moves, state, scanned = run({"failures": {"e1": 1}}, found="192.168.68.77")
        self.assertEqual(moves, {"e1": "192.168.68.77"})
        self.assertEqual((state["failures"], state["last_rewrite"], scanned), ({}, NOW, ["dev1"]))

    def test_two_failures_not_found(self):
        moves, state, _ = run({"failures": {"e1": 1}})
        self.assertEqual((moves, state["failures"]), ({}, {"e1": 2}))

    def test_same_ip_is_left_alone(self):
        moves, _, _ = run({"failures": {"e1": 1}}, found="192.168.68.56")
        self.assertEqual(moves, {})

    def test_rate_limited(self):
        moves, state, _ = run({"failures": {"e1": 3}, "last_rewrite": NOW - 600}, found="192.168.68.77")
        self.assertEqual((moves, state["last_rewrite"]), ({}, NOW - 600))
        moves, _, _ = run({"failures": {"e1": 3}, "last_rewrite": NOW - 3600}, found="192.168.68.77")
        self.assertEqual(moves, {"e1": "192.168.68.77"})


class Config(unittest.TestCase):
    CONFIG = {"data": {"entries": [
        {"entry_id": "e1", "domain": "tuya_local", "title": "Living room IR",
         "data": {"host": "192.168.68.56", "device_id": "dev1", "local_key": "k"}},
        {"entry_id": "e2", "domain": "hilo", "data": {"host": "x"}},
    ]}}

    def test_only_tuya_local_entries(self):
        self.assertEqual(tuya_entries(self.CONFIG), [HUB])

    def test_apply_changes_only_the_host(self):
        import copy

        config = copy.deepcopy(self.CONFIG)
        apply_moves(config, {"e1": "192.168.68.77"})
        self.assertEqual(config["data"]["entries"][0]["data"],
                         {"host": "192.168.68.77", "device_id": "dev1", "local_key": "k"})
        self.assertEqual(config["data"]["entries"][1], self.CONFIG["data"]["entries"][1])


if __name__ == "__main__":
    unittest.main()
