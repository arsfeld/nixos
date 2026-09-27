import os
import unittest
from jinja2 import Environment, FileSystemLoader

class TestSummaryEmailTemplate(unittest.TestCase):
    def setUp(self):
        template_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self.env = Environment(loader=FileSystemLoader(template_dir))

    def test_render_template_healthy(self):
        template = self.env.get_template("summary-email.html.j2")
        context = {
            "hostname": "galactica",
            "current_date": "Sunday, Sep 27, 2026 • 20:00 UTC",
            "overall_status": "HEALTHY",
            "status_summary": "All 6 backup targets healthy",
            "metrics": {
                "total_targets": 6,
                "healthy_targets": 6,
                "attention_targets": 0,
                "pool_used_gib": 12400.0,
                "pool_total_gib": 28000.0,
                "pool_percent": 44,
            },
            "targets": [
                {
                    "host": "basestar",
                    "name": "system",
                    "destination": "storage REST",
                    "last_snapshot_str": "2026-09-27 03:30 EDT",
                    "age_hours": 16.5,
                    "max_age_hours": 48,
                    "status": "OK",
                    "status_badge_class": "badge-ok",
                    "status_text": "OK",
                    "details": "/var/lib, /home, /root",
                }
            ],
            "storage_breakdown": [
                {"name": "Multi-client repo", "path": "/mnt/storage/backups/restic-server", "size_gib": 450.0}
            ],
            "backrest_portal_url": "https://backrest.arsfeld.one/",
        }
        html = template.render(**context)
        self.assertIn("galactica", html)
        self.assertIn("All 6 backup targets healthy", html)
        self.assertIn("basestar", html)
        self.assertIn("https://backrest.arsfeld.one/", html)
        self.assertIn("12.1", html)

    def test_render_template_attention_needed(self):
        template = self.env.get_template("summary-email.html.j2")
        context = {
            "hostname": "galactica",
            "current_date": "Sunday, Sep 27, 2026 • 20:00 UTC",
            "overall_status": "ATTENTION_NEEDED",
            "status_summary": "1 target stale, 1 target warning",
            "metrics": {
                "total_targets": 6,
                "healthy_targets": 4,
                "attention_targets": 2,
                "pool_used_gib": 12400.0,
                "pool_total_gib": 28000.0,
                "pool_percent": 44,
            },
            "targets": [
                {
                    "host": "raider",
                    "name": "system",
                    "destination": "storage REST",
                    "last_snapshot_str": "2026-09-23 10:00 EDT",
                    "age_hours": 98.0,
                    "max_age_hours": 168,
                    "status": "WARN",
                    "status_badge_class": "badge-warn",
                    "status_text": "WARN",
                    "details": "/var/lib, /home, /root",
                }
            ],
            "storage_breakdown": [],
            "backrest_portal_url": "https://backrest.arsfeld.one/",
        }
        html = template.render(**context)
        self.assertIn("Attention Needed", html)
        self.assertIn("raider", html)
        self.assertIn("badge-warn", html)

if __name__ == "__main__":
    unittest.main()
