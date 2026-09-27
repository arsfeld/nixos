import os
import sys
import types
import unittest
from datetime import datetime, timezone, timedelta

# Support running tests both as a package and directly from repo root
pkg_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if pkg_dir not in sys.path:
    sys.path.insert(0, pkg_dir)

try:
    import backup_summary
    if "packages" not in sys.modules:
        sys.modules["packages"] = types.ModuleType("packages")
    if "packages.backup_summary" not in sys.modules:
        pkg_mod = types.ModuleType("packages.backup_summary")
        sys.modules["packages.backup_summary"] = pkg_mod
        setattr(sys.modules["packages"], "backup_summary", pkg_mod)
    sys.modules["packages.backup_summary.backup_summary"] = backup_summary
    setattr(sys.modules["packages.backup_summary"], "backup_summary", backup_summary)
except ImportError:
    pass

from packages.backup_summary.backup_summary import (
    evaluate_target_status,
    partition_snapshots_by_host,
    parse_iso_timestamp,
)

class TestCollector(unittest.TestCase):
    def test_parse_iso_timestamp(self):
        ts_str = "2026-09-27T03:30:00.123456-04:00"
        dt = parse_iso_timestamp(ts_str)
        self.assertIsNotNone(dt)
        self.assertEqual(dt.tzinfo, timezone(timedelta(hours=-4)))

    def test_partition_snapshots_by_host(self):
        snapshots = [
            {"time": "2026-09-27T03:30:00Z", "hostname": "basestar", "paths": ["/home"]},
            {"time": "2026-09-27T04:00:00Z", "hostname": "pegasus", "paths": ["/var/lib"]},
            {"time": "2026-09-25T14:00:00Z", "hostname": "raider", "paths": ["/home"]},
        ]
        partitions = partition_snapshots_by_host(snapshots)
        self.assertIn("basestar", partitions)
        self.assertIn("pegasus", partitions)
        self.assertIn("raider", partitions)
        self.assertEqual(len(partitions["basestar"]), 1)

    def test_evaluate_target_status_ok(self):
        now = datetime(2026, 9, 27, 20, 0, 0, tzinfo=timezone.utc)
        latest_dt = now - timedelta(hours=12)
        status, badge, text = evaluate_target_status(
            latest_dt=latest_dt,
            max_age_hours=48,
            is_laptop=False,
            now=now,
        )
        self.assertEqual(status, "OK")
        self.assertEqual(badge, "badge-ok")
        self.assertEqual(text, "OK")

    def test_evaluate_target_status_laptop_warn(self):
        now = datetime(2026, 9, 27, 20, 0, 0, tzinfo=timezone.utc)
        latest_dt = now - timedelta(hours=96) # 4 days
        status, badge, text = evaluate_target_status(
            latest_dt=latest_dt,
            max_age_hours=168,
            is_laptop=True,
            now=now,
        )
        self.assertEqual(status, "WARN")
        self.assertEqual(badge, "badge-warn")
        self.assertEqual(text, "WARN")

    def test_evaluate_target_status_stale(self):
        now = datetime(2026, 9, 27, 20, 0, 0, tzinfo=timezone.utc)
        latest_dt = now - timedelta(hours=55) # > 48h
        status, badge, text = evaluate_target_status(
            latest_dt=latest_dt,
            max_age_hours=48,
            is_laptop=False,
            now=now,
        )
        self.assertEqual(status, "STALE")
        self.assertEqual(badge, "badge-stale")
        self.assertEqual(text, "STALE")

    def test_evaluate_target_status_none(self):
        now = datetime(2026, 9, 27, 20, 0, 0, tzinfo=timezone.utc)
        status, badge, text = evaluate_target_status(
            latest_dt=None,
            max_age_hours=48,
            is_laptop=False,
            now=now,
        )
        self.assertEqual(status, "STALE")
        self.assertEqual(badge, "badge-stale")
        self.assertEqual(text, "NO DATA")

if __name__ == "__main__":
    unittest.main()
