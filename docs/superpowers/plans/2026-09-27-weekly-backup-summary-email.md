# Weekly Fleet Backup Summary Email Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide an automated, centralized weekly email digest on `galactica` that audits the backup freshness, snapshot recency, and storage footprint of all fleet hosts and cold targets (`galactica`, `basestar`, `pegasus`, `raider`, and OVH Cold Archive).

**Architecture:** A standalone Python package (`backup-summary`) with a Jinja2 HTML email template queries local restic repositories, the central restic REST server, pegasus REST server, and rustic OVH targets on `galactica`, partitions snapshots by host, calculates staleness against differentiated thresholds (48h daily, 72h laptop, 192h weekly), and sends a rich HTML status report via `msmtp` on Sunday evenings. A new Constellation NixOS module (`modules/constellation/backup-summary.nix`) manages the systemd service, timer, failure alerting via `backup-notify`, and deduplicates heartbeat mail by disabling `galactica`'s generic `weekly-mail-alert.timer`.

**Tech Stack:** NixOS, Python 3 (Jinja2, unittest), restic, rustic, msmtp, systemd, HTML/CSS email formatting.

**Spec:** [`docs/superpowers/specs/2026-09-27-weekly-backup-summary-email-design.md`](file:///home/arosenfeld/Code/nixos/docs/superpowers/specs/2026-09-27-weekly-backup-summary-email-design.md)

## Global Constraints

- Never mutate or alter existing restic / rustic backup repositories or snapshot data.
- Query failures on remote or secondary endpoints (e.g. pegasus offline over Tailscale) must report as `UNREACHABLE` without aborting the overall report.
- Laptop (`raider`) receives a differentiated threshold: warning badge between 72h and 168h, stale only after 168h (7 days).
- Systemd timer runs on `galactica` at `"Sun *-*-* 20:00:00 UTC"`.
- Suppress generic `systemd.timers."weekly-mail-alert"` on `galactica` when `constellation.backupSummary.enable = true`.
- Pass evaluation on `.#nixosConfigurations.galactica.config.system.build.toplevel`.

---

### Task 1: Create Jinja2 HTML Email Template

**Files:**
- Create: `packages/backup-summary/summary-email.html.j2`
- Test: `packages/backup-summary/tests/test_template.py`

**Interfaces:**
- Consumes: Template context dictionary:
  ```python
  {
      "hostname": "galactica",
      "current_date": "Sunday, Sep 27, 2026 • 20:00 UTC",
      "overall_status": "HEALTHY", # or "ATTENTION_NEEDED"
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
              "host": "galactica",
              "name": "local-system",
              "destination": "Local NAS (/mnt/storage)",
              "last_snapshot_str": "2026-09-27 02:30 EDT",
              "age_hours": 17.5,
              "max_age_hours": 48,
              "status": "OK", # "OK", "WARN", "STALE", "UNREACHABLE"
              "status_badge_class": "badge-ok",
              "status_text": "OK",
              "details": "/",
          }
      ],
      "storage_breakdown": [
          {"name": "Multi-client REST server", "path": "/mnt/storage/backups/restic-server", "size_gib": 450.2},
          {"name": "Local system repo", "path": "/mnt/storage/backups/restic", "size_gib": 182.5},
      ],
      "backrest_portal_url": "https://backrest.arsfeld.one/",
  }
  ```
- Produces: Rendered HTML string compatible with major email clients.

- [ ] **Step 1: Write the template rendering test**

Create `packages/backup-summary/tests/test_template.py`:
```python
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
        self.assertIn("12400.0", html)

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest packages/backup-summary/tests/test_template.py`
Expected: FAIL with `TemplateNotFound: summary-email.html.j2`

- [ ] **Step 3: Implement `summary-email.html.j2`**

Create `packages/backup-summary/summary-email.html.j2`:
```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>[{{ hostname }}] Weekly Backup Summary</title>
  <style>
    body, table, td { -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; }
    table, td { mso-table-lspace: 0pt; mso-table-rspace: 0pt; }
    table { border-collapse: collapse !important; }
    body { margin: 0 !important; padding: 0 !important; width: 100% !important; }

    @media screen and (max-width: 640px) {
      .container { width: 100% !important; }
      .px { padding-left: 16px !important; padding-right: 16px !important; }
      .tile-cell { display: block !important; width: 100% !important; padding: 0 0 10px 0 !important; }
      .table-cell { display: block !important; width: 100% !important; }
    }

    @media (prefers-color-scheme: dark) {
      .body-bg { background-color: #0b0b0d !important; }
      .card-bg { background-color: #18181b !important; border-color: #27272a !important; }
      .text-primary { color: #f4f4f5 !important; }
      .text-secondary { color: #a1a1aa !important; }
      .text-muted { color: #71717a !important; }
      .divider { border-color: #27272a !important; }
      .tile-bg { background-color: #27272a !important; }
      .bar-track { background-color: #3f3f46 !important; }
      .row-alt { background-color: #1f1f23 !important; }
    }

    .badge-ok { background-color: #059669; color: #ffffff; }
    .badge-warn { background-color: #d97706; color: #ffffff; }
    .badge-stale { background-color: #dc2626; color: #ffffff; }
    .badge-unreachable { background-color: #6b7280; color: #ffffff; }
  </style>
</head>
<body class="body-bg" style="margin:0;padding:0;background-color:#f5f5f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;">

  <div style="display:none;font-size:1px;color:#fefefe;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;">
    [{{ hostname }}] Backup Summary: {{ status_summary }}
  </div>

  <table class="body-bg" border="0" cellpadding="0" cellspacing="0" width="100%" style="background-color:#f5f5f7;">
    <tr>
      <td align="center" style="padding:32px 16px;">

        <table class="container card-bg" align="center" border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width:680px;background-color:#ffffff;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;">

          <!-- Header -->
          <tr>
            <td class="px divider" style="padding:22px 28px;border-bottom:1px solid #f3f4f6;">
              <table border="0" cellpadding="0" cellspacing="0" width="100%">
                <tr>
                  <td style="vertical-align:middle;">
                    <p class="text-secondary" style="margin:0 0 4px 0;font-size:11px;font-weight:600;letter-spacing:0.6px;text-transform:uppercase;color:#6b7280;">
                      {{ hostname }} • BACKUP AUDIT
                    </p>
                    <h1 class="text-primary" style="margin:0;font-size:20px;font-weight:600;line-height:1.3;color:#111827;">
                      Weekly Fleet Backup Summary
                    </h1>
                  </td>
                  <td align="right" style="vertical-align:middle;white-space:nowrap;font-size:12px;color:#6b7280;padding-left:16px;">
                    {{ current_date }}
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Hero Status Banner -->
          <tr>
            <td style="padding:16px 28px 8px 28px;">
              {% if overall_status == "HEALTHY" %}
              <div style="background-color:#ecfdf5;border:1px solid #a7f3d0;border-radius:8px;padding:12px 16px;color:#065f46;font-size:14px;font-weight:600;">
                ✓ {{ status_summary }}
              </div>
              {% else %}
              <div style="background-color:#fffbeb;border:1px solid #fde68a;border-radius:8px;padding:12px 16px;color:#92400e;font-size:14px;font-weight:600;">
                ⚠ Attention Needed: {{ status_summary }}
              </div>
              {% endif %}
            </td>
          </tr>

          <!-- Summary Metric Tiles -->
          <tr>
            <td style="padding:12px 28px;">
              <table border="0" cellpadding="0" cellspacing="0" width="100%">
                <tr>
                  <td class="tile-cell" width="25%" style="padding:0 6px 0 0;">
                    <div class="tile-bg" style="background-color:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;padding:12px;text-align:center;">
                      <p class="text-secondary" style="margin:0;font-size:10px;font-weight:600;text-transform:uppercase;color:#6b7280;">Monitored</p>
                      <p class="text-primary" style="margin:6px 0 0 0;font-size:18px;font-weight:700;color:#111827;">{{ metrics.total_targets }}</p>
                    </div>
                  </td>
                  <td class="tile-cell" width="25%" style="padding:0 3px 0 3px;">
                    <div class="tile-bg" style="background-color:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;padding:12px;text-align:center;">
                      <p class="text-secondary" style="margin:0;font-size:10px;font-weight:600;text-transform:uppercase;color:#6b7280;">Healthy</p>
                      <p style="margin:6px 0 0 0;font-size:18px;font-weight:700;color:#059669;">{{ metrics.healthy_targets }}</p>
                    </div>
                  </td>
                  <td class="tile-cell" width="25%" style="padding:0 3px 0 3px;">
                    <div class="tile-bg" style="background-color:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;padding:12px;text-align:center;">
                      <p class="text-secondary" style="margin:0;font-size:10px;font-weight:600;text-transform:uppercase;color:#6b7280;">Issues</p>
                      <p style="margin:6px 0 0 0;font-size:18px;font-weight:700;color:{% if metrics.attention_targets > 0 %}#dc2626{% else %}#6b7280{% endif %};">{{ metrics.attention_targets }}</p>
                    </div>
                  </td>
                  <td class="tile-cell" width="25%" style="padding:0 0 0 6px;">
                    <div class="tile-bg" style="background-color:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;padding:12px;text-align:center;">
                      <p class="text-secondary" style="margin:0;font-size:10px;font-weight:600;text-transform:uppercase;color:#6b7280;">Pool Used</p>
                      <p class="text-primary" style="margin:6px 0 0 0;font-size:18px;font-weight:700;color:#111827;">{{ metrics.pool_percent }}%</p>
                    </div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Targets Table -->
          <tr>
            <td style="padding:16px 28px 8px 28px;">
              <p class="text-secondary" style="margin:0 0 10px 0;font-size:11px;font-weight:600;letter-spacing:0.6px;text-transform:uppercase;color:#6b7280;">
                Target Status Details
              </p>
              <table border="0" cellpadding="0" cellspacing="0" width="100%" style="font-size:12px;border:1px solid #e5e7eb;border-radius:8px;overflow:hidden;">
                <thead>
                  <tr style="background-color:#f9fafb;border-bottom:1px solid #e5e7eb;text-align:left;">
                    <th style="padding:10px 12px;font-weight:600;color:#4b5563;">Target</th>
                    <th style="padding:10px 12px;font-weight:600;color:#4b5563;">Destination</th>
                    <th style="padding:10px 12px;font-weight:600;color:#4b5563;">Last Snapshot</th>
                    <th style="padding:10px 12px;font-weight:600;color:#4b5563;">Age</th>
                    <th style="padding:10px 12px;font-weight:600;color:#4b5563;text-align:center;">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {% for t in targets %}
                  <tr style="border-bottom:1px solid #f3f4f6;" class="{% if loop.index is even %}row-alt{% endif %}">
                    <td style="padding:10px 12px;">
                      <strong class="text-primary" style="color:#111827;">{{ t.host }}</strong><br/>
                      <span class="text-muted" style="font-size:11px;color:#6b7280;">{{ t.name }}</span>
                    </td>
                    <td style="padding:10px 12px;" class="text-secondary">
                      {{ t.destination }}
                    </td>
                    <td style="padding:10px 12px;" class="text-primary">
                      {{ t.last_snapshot_str }}
                    </td>
                    <td style="padding:10px 12px;" class="text-secondary">
                      {{ "%.1f"|format(t.age_hours) }}h <span class="text-muted" style="font-size:10px;">(max {{ t.max_age_hours }}h)</span>
                    </td>
                    <td style="padding:10px 12px;text-align:center;">
                      <span class="{{ t.status_badge_class }}" style="display:inline-block;padding:3px 8px;border-radius:999px;font-size:10px;font-weight:700;letter-spacing:0.5px;">
                        {{ t.status_text }}
                      </span>
                    </td>
                  </tr>
                  {% endfor %}
                </tbody>
              </table>
            </td>
          </tr>

          <!-- Storage Pool & Breakdown -->
          {% if storage_breakdown %}
          <tr>
            <td style="padding:16px 28px;">
              <p class="text-secondary" style="margin:0 0 10px 0;font-size:11px;font-weight:600;letter-spacing:0.6px;text-transform:uppercase;color:#6b7280;">
                Storage Pool & Repo Footprint (/mnt/storage)
              </p>
              <div class="tile-bg" style="background-color:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;padding:14px 16px;">
                <table border="0" cellpadding="0" cellspacing="0" width="100%">
                  <tr>
                    <td class="text-secondary" style="font-size:11px;font-weight:600;color:#4b5563;">Pool Capacity: {{ "%.1f"|format(metrics.pool_used_gib / 1024.0) }} / {{ "%.1f"|format(metrics.pool_total_gib / 1024.0) }} TiB</td>
                    <td class="text-primary" align="right" style="font-size:12px;font-weight:600;color:#111827;">{{ metrics.pool_percent }}%</td>
                  </tr>
                </table>
                <table class="bar-track" border="0" cellpadding="0" cellspacing="0" width="100%" style="background-color:#e5e7eb;border-radius:999px;margin:8px 0 12px 0;">
                  <tr>
                    <td height="6" width="{{ metrics.pool_percent }}%" bgcolor="#4f46e5" style="background-color:#4f46e5;line-height:6px;font-size:0;border-radius:999px;">&nbsp;</td>
                    <td height="6" width="{{ 100 - metrics.pool_percent }}%" style="line-height:6px;font-size:0;">&nbsp;</td>
                  </tr>
                </table>

                <table border="0" cellpadding="0" cellspacing="0" width="100%" style="font-size:11px;color:#6b7280;">
                  {% for s in storage_breakdown %}
                  <tr>
                    <td style="padding:2px 0;">{{ s.name }} (<code>{{ s.path }}</code>)</td>
                    <td align="right" style="padding:2px 0;font-weight:600;color:#111827;">{{ "%.1f"|format(s.size_gib) }} GiB</td>
                  </tr>
                  {% endfor %}
                </table>
              </div>
            </td>
          </tr>
          {% endif %}

          <!-- Action Portal Button -->
          <tr>
            <td align="center" style="padding:8px 28px 24px 28px;">
              <a href="{{ backrest_portal_url }}" target="_blank" style="display:inline-block;background-color:#4f46e5;color:#ffffff;text-decoration:none;font-size:13px;font-weight:600;padding:10px 20px;border-radius:6px;">
                Open Backrest Portal →
              </a>
            </td>
          </tr>

        </table>

        <!-- Footer -->
        <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width:680px;">
          <tr>
            <td class="text-muted" align="center" style="padding:14px 8px 0 8px;font-size:11px;color:#9ca3af;line-height:1.5;">
              Automated weekly summary from {{ hostname }}. Diagnostic command: <code>ssh galactica backup-status</code>
            </td>
          </tr>
        </table>

      </td>
    </tr>
  </table>

</body>
</html>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest packages/backup-summary/tests/test_template.py`
Expected: `Ran 2 tests in ...s OK`

- [ ] **Step 5: Commit**

Run:
```bash
git add packages/backup-summary/summary-email.html.j2 packages/backup-summary/tests/test_template.py
git commit -m "feat(backup-summary): add responsive html email template and rendering tests"
```

---

### Task 2: Implement `backup-summary` Python CLI and Unit Tests

**Files:**
- Create: `packages/backup-summary/backup_summary.py`
- Create: `packages/backup-summary/tests/test_collector.py`

**Interfaces:**
- Consumes:
  - CLI flags: `--dry-run`, `--stdout`, `--send`, `--to <email>`, `--from <email>`, `--config <json-path>`
  - Environment variables: `RESTIC_PASSWORD_FILE`, `RUSTIC_PASSWORD_FILE`, `EMAIL_TEMPLATE`
- Produces:
  - Formatted status dictionary for template rendering
  - Sends email via `msmtp` when invoked with `--send` (or default run mode)
  - Exit code 0 on success; exit code 1 if persistent SMTP failure occurs

- [ ] **Step 1: Write unit tests for status classification and snapshot parsing**

Create `packages/backup-summary/tests/test_collector.py`:
```python
import unittest
from datetime import datetime, timezone, timedelta
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest packages/backup-summary/tests/test_collector.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'packages.backup_summary.backup_summary'`

- [ ] **Step 3: Implement `backup_summary.py`**

Create `packages/backup-summary/backup_summary.py`:
```python
#!/usr/bin/env python3
import argparse
import datetime
import json
import logging
import os
import socket
import subprocess
import sys
import time
from typing import Dict, List, Optional, Tuple
from jinja2 import Environment, FileSystemLoader

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger("backup-summary")


def parse_iso_timestamp(ts_str: str) -> Optional[datetime.datetime]:
    if not ts_str:
        return None
    try:
        # Standard fromisoformat handles +00:00 or -04:00, but strip nanoseconds if needed
        clean_str = ts_str.strip()
        if "." in clean_str:
            base, sep, tail = clean_str.partition(".")
            tz_part = ""
            for i, c in enumerate(tail):
                if c in ("+", "-", "Z"):
                    tz_part = tail[i:]
                    tail = tail[:i]
                    break
            # Truncate microsecond portion to 6 digits max for python <3.11 compatibility
            clean_str = f"{base}.{tail[:6]}{tz_part}"
        if clean_str.endswith("Z"):
            clean_str = clean_str[:-1] + "+00:00"
        return datetime.datetime.fromisoformat(clean_str)
    except Exception as e:
        logger.warning(f"Failed to parse timestamp {ts_str}: {e}")
        return None


def partition_snapshots_by_host(snapshots: List[dict]) -> Dict[str, List[dict]]:
    hosts: Dict[str, List[dict]] = {}
    for s in snapshots:
        h = s.get("hostname", "unknown")
        hosts.setdefault(h, []).append(s)
    return hosts


def evaluate_target_status(
    latest_dt: Optional[datetime.datetime],
    max_age_hours: float,
    is_laptop: bool,
    now: datetime.datetime,
) -> Tuple[str, str, str]:
    """Returns (status, badge_class, status_text)"""
    if latest_dt is None:
        return "STALE", "badge-stale", "NO DATA"

    age_hours = (now - latest_dt).total_seconds() / 3600.0
    if is_laptop:
        if age_hours <= 72.0:
            return "OK", "badge-ok", "OK"
        elif age_hours <= max_age_hours: # 72h - 168h
            return "WARN", "badge-warn", "WARN"
        else:
            return "STALE", "badge-stale", "STALE"
    else:
        if age_hours <= max_age_hours:
            return "OK", "badge-ok", "OK"
        else:
            return "STALE", "badge-stale", "STALE"


def query_restic_snapshots(uri: str, password_file: str, timeout_sec: int = 60) -> Tuple[List[dict], Optional[str]]:
    cmd = ["restic", "-r", uri, "snapshots", "--json"]
    env = os.environ.copy()
    env["RESTIC_PASSWORD_FILE"] = password_file
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_sec,
            env=env,
        )
        if proc.returncode != 0:
            return [], proc.stderr.strip()
        return json.loads(proc.stdout), None
    except subprocess.TimeoutExpired:
        return [], f"Timed out after {timeout_sec}s"
    except Exception as e:
        return [], str(e)


def query_rustic_snapshots(profile: str = "ovh", timeout_sec: int = 60) -> Tuple[List[dict], Optional[str]]:
    cmd = ["rustic", "-P", profile, "snapshots", "--json"]
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_sec,
        )
        if proc.returncode != 0:
            return [], proc.stderr.strip()
        data = json.loads(proc.stdout)
        # rustic can emit group-based snapshots: [{"group_key": ..., "snapshots": [...]}]
        if isinstance(data, list) and len(data) > 0 and "snapshots" in data[0]:
            flattened = []
            for g in data:
                flattened.extend(g.get("snapshots", []))
            return flattened, None
        return data, None
    except subprocess.TimeoutExpired:
        return [], f"Timed out after {timeout_sec}s"
    except Exception as e:
        return [], str(e)


def get_dir_size_gib(path: str, timeout_sec: int = 15) -> float:
    if not os.path.exists(path):
        return 0.0
    try:
        proc = subprocess.run(
            ["du", "-sb", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_sec,
        )
        if proc.returncode == 0:
            bytes_val = int(proc.stdout.split()[0])
            return bytes_val / (1024.0**3)
    except Exception:
        pass
    return 0.0


def get_filesystem_stats(mount_point: str = "/mnt/storage") -> Dict[str, float]:
    try:
        s = os.statvfs(mount_point)
        total = s.f_blocks * s.f_frsize
        avail = s.f_bavail * s.f_frsize
        used = max(total - avail, 0)
        pct = round((used / total) * 100) if total else 0
        return {
            "total_gib": total / (1024.0**3),
            "used_gib": used / (1024.0**3),
            "free_gib": avail / (1024.0**3),
            "percent": pct,
        }
    except Exception as e:
        logger.warning(f"Could not statvfs {mount_point}: {e}")
        return {"total_gib": 0.0, "used_gib": 0.0, "free_gib": 0.0, "percent": 0}


def build_report_data(
    now: datetime.datetime,
    restic_pw_file: str,
    backrest_url: str = "https://backrest.arsfeld.one/",
) -> dict:
    targets_data = []

    # 1. Central shared repo: rest:http://127.0.0.1:8000/
    shared_snaps, shared_err = query_restic_snapshots("rest:http://127.0.0.1:8000/", restic_pw_file)
    shared_partition = partition_snapshots_by_host(shared_snaps) if not shared_err else {}

    # Define targets on the shared repo
    shared_targets = [
        ("basestar", "system", "storage REST", 48.0, False),
        ("pegasus", "system", "storage REST", 192.0, False),
        ("raider", "system", "storage REST", 168.0, True),
    ]

    for host, name, dest, max_age, is_laptop in shared_targets:
        if shared_err:
            targets_data.append({
                "host": host,
                "name": name,
                "destination": dest,
                "last_snapshot_str": "Query Error",
                "age_hours": 999.0,
                "max_age_hours": int(max_age),
                "status": "STALE",
                "status_badge_class": "badge-stale",
                "status_text": "ERROR",
                "details": shared_err,
            })
            continue

        host_snaps = shared_partition.get(host, [])
        latest_dt = None
        best_iso = ""
        for s in host_snaps:
            dt = parse_iso_timestamp(s.get("time"))
            if dt and (latest_dt is None or dt > latest_dt):
                latest_dt = dt
                best_iso = s.get("time")

        status, badge, text = evaluate_target_status(latest_dt, max_age, is_laptop, now)
        age_hours = (now - latest_dt).total_seconds() / 3600.0 if latest_dt else 999.0
        last_str = latest_dt.strftime("%Y-%m-%d %H:%M %Z") if latest_dt else "None"

        targets_data.append({
            "host": host,
            "name": name,
            "destination": dest,
            "last_snapshot_str": last_str,
            "age_hours": age_hours,
            "max_age_hours": int(max_age),
            "status": status,
            "status_badge_class": badge,
            "status_text": text,
            "details": f"Snapshots: {len(host_snaps)}",
        })

    # 2. Local system backup on galactica: /mnt/storage/backups/restic
    local_snaps, local_err = query_restic_snapshots("/mnt/storage/backups/restic", restic_pw_file)
    latest_dt = None
    if not local_err:
        for s in local_snaps:
            dt = parse_iso_timestamp(s.get("time"))
            if dt and (latest_dt is None or dt > latest_dt):
                latest_dt = dt

    status, badge, text = evaluate_target_status(latest_dt, 48.0, False, now)
    age_hours = (now - latest_dt).total_seconds() / 3600.0 if latest_dt else 999.0
    last_str = latest_dt.strftime("%Y-%m-%d %H:%M %Z") if latest_dt else ("Query Error" if local_err else "None")
    targets_data.append({
        "host": "galactica",
        "name": "local-system",
        "destination": "Local NAS (/mnt/storage)",
        "last_snapshot_str": last_str,
        "age_hours": age_hours,
        "max_age_hours": 48,
        "status": status if not local_err else "STALE",
        "status_badge_class": badge if not local_err else "badge-stale",
        "status_text": text if not local_err else "ERROR",
        "details": f"Snapshots: {len(local_snaps)}" if not local_err else local_err,
    })

    # 3. Pegasus REST offsite: rest:http://pegasus.bat-boa.ts.net:8000/
    peg_snaps, peg_err = query_restic_snapshots("rest:http://pegasus.bat-boa.ts.net:8000/", restic_pw_file, timeout_sec=30)
    latest_dt = None
    if not peg_err:
        for s in peg_snaps:
            dt = parse_iso_timestamp(s.get("time"))
            if dt and (latest_dt is None or dt > latest_dt):
                latest_dt = dt
        status, badge, text = evaluate_target_status(latest_dt, 192.0, False, now)
    else:
        status, badge, text = "WARN", "badge-unreachable", "UNREACHABLE"

    age_hours = (now - latest_dt).total_seconds() / 3600.0 if latest_dt else 999.0
    last_str = latest_dt.strftime("%Y-%m-%d %H:%M %Z") if latest_dt else ("Unreachable" if peg_err else "None")
    targets_data.append({
        "host": "galactica",
        "name": "pegasus (offsite)",
        "destination": "Pegasus REST server",
        "last_snapshot_str": last_str,
        "age_hours": age_hours,
        "max_age_hours": 192,
        "status": status,
        "status_badge_class": badge,
        "status_text": text,
        "details": peg_err or f"Snapshots: {len(peg_snaps)}",
    })

    # 4. OVH Cold Archive: rustic profile ovh
    ovh_snaps, ovh_err = query_rustic_snapshots("ovh", timeout_sec=45)
    latest_dt = None
    if not ovh_err:
        for s in ovh_snaps:
            dt = parse_iso_timestamp(s.get("time"))
            if dt and (latest_dt is None or dt > latest_dt):
                latest_dt = dt
        status, badge, text = evaluate_target_status(latest_dt, 192.0, False, now)
    else:
        status, badge, text = "WARN", "badge-unreachable", "UNREACHABLE"

    age_hours = (now - latest_dt).total_seconds() / 3600.0 if latest_dt else 999.0
    last_str = latest_dt.strftime("%Y-%m-%d %H:%M %Z") if latest_dt else ("Query Failed" if ovh_err else "None")
    targets_data.append({
        "host": "galactica",
        "name": "ovh (cold archive)",
        "destination": "OVHcloud S3 Cold",
        "last_snapshot_str": last_str,
        "age_hours": age_hours,
        "max_age_hours": 192,
        "status": status,
        "status_badge_class": badge,
        "status_text": text,
        "details": ovh_err or f"Snapshots: {len(ovh_snaps)}",
    })

    # Metrics Rollup
    total = len(targets_data)
    healthy = sum(1 for t in targets_data if t["status"] == "OK")
    attention = total - healthy
    overall_status = "HEALTHY" if attention == 0 else "ATTENTION_NEEDED"

    summary_msg = f"All {total} backup targets healthy" if attention == 0 else f"{attention} target(s) require attention"

    pool_stats = get_filesystem_stats("/mnt/storage")
    storage_breakdown = [
        {"name": "Multi-client REST server", "path": "/mnt/storage/backups/restic-server", "size_gib": get_dir_size_gib("/mnt/storage/backups/restic-server")},
        {"name": "Local system repo", "path": "/mnt/storage/backups/restic", "size_gib": get_dir_size_gib("/mnt/storage/backups/restic")},
    ]

    return {
        "hostname": socket.gethostname(),
        "current_date": now.strftime("%A, %b %d, %Y • %H:%M %Z"),
        "overall_status": overall_status,
        "status_summary": summary_msg,
        "metrics": {
            "total_targets": total,
            "healthy_targets": healthy,
            "attention_targets": attention,
            "pool_used_gib": pool_stats["used_gib"],
            "pool_total_gib": pool_stats["total_gib"],
            "pool_percent": pool_stats["percent"],
        },
        "targets": targets_data,
        "storage_breakdown": storage_breakdown,
        "backrest_portal_url": backrest_url,
    }


def send_email(subject: str, html_body: str, email_from: str, email_to: str) -> None:
    msg = f"""From: {email_from}
To: {email_to}
Subject: {subject}
Content-Type: text/html; charset="utf-8"

{html_body}
""".strip("\n")

    attempts = 8
    for attempt in range(1, attempts + 1):
        proc = subprocess.run(
            ["msmtp", email_to],
            input=msg,
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            logger.info(f"Summary email successfully sent to {email_to}")
            return
        if attempt == attempts:
            logger.error(f"Giving up after {attempts} attempts: {proc.stderr.strip()}")
            sys.exit(1)
        delay = min(2**attempt, 30)
        logger.warning(f"Send attempt {attempt}/{attempts} failed ({proc.stderr.strip()}); retrying in {delay}s")
        time.sleep(delay)


def main():
    parser = argparse.ArgumentParser(description="Weekly fleet backup summary auditor and email reporter")
    parser.add_argument("--dry-run", action="store_true", help="Print summary table to stdout without sending email")
    parser.add_argument("--stdout", action="store_true", help="Render HTML to stdout without sending email")
    parser.add_argument("--send", action="store_true", help="Send email report (default behavior if no flag specified)")
    parser.add_argument("--email-to", default=os.environ.get("EMAIL_TO", "alex@rosenfeld.one"), help="Recipient email")
    parser.add_argument("--email-from", default=os.environ.get("EMAIL_FROM", "admin@rosenfeld.one"), help="Sender email")
    parser.add_argument("--template", default=os.environ.get("EMAIL_TEMPLATE"), help="Path to jinja2 template")
    parser.add_argument("--password-file", default=os.environ.get("RESTIC_PASSWORD_FILE", "/run/secrets/restic-password"), help="Path to restic password file")

    args = parser.parse_args()

    now = datetime.datetime.now(datetime.timezone.utc).astimezone()
    data = build_report_data(now=now, restic_pw_file=args.password_file)

    template_path = args.template
    if not template_path:
        template_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "summary-email.html.j2")

    env = Environment(loader=FileSystemLoader(os.path.dirname(template_path)))
    template = env.get_template(os.path.basename(template_path))
    html_output = template.render(**data)

    if args.stdout:
        print(html_output)
        return

    if args.dry_run:
        print(f"\n=== BACKUP SUMMARY AUDIT ({data['current_date']}) ===")
        print(f"Overall Status: {data['overall_status']} ({data['status_summary']})")
        print(f"Monitored Targets: {data['metrics']['total_targets']} | Healthy: {data['metrics']['healthy_targets']} | Issues: {data['metrics']['attention_targets']}")
        print(f"Pool Usage: {data['metrics']['pool_used_gib']:.1f}/{data['metrics']['pool_total_gib']:.1f} GiB ({data['metrics']['pool_percent']}%)")
        print("-" * 80)
        for t in data["targets"]:
            print(f"{t['host']:<12} {t['name']:<18} {t['destination']:<22} {t['status']:<8} (Age: {t['age_hours']:.1f}h / max {t['max_age_hours']}h)")
        print("-" * 80)
        return

    # Default action: send email
    subject = f"[{data['hostname']}] Backup Summary: {data['status_summary']} ({now.strftime('%Y-%m-%d')})"
    send_email(subject, html_output, args.email_from, args.email_to)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest packages/backup-summary/tests/test_collector.py`
Expected: `Ran 6 tests in ...s OK`

- [ ] **Step 5: Commit**

Run:
```bash
git add packages/backup-summary/backup_summary.py packages/backup-summary/tests/test_collector.py
git commit -m "feat(backup-summary): implement backup auditor cli and status evaluation logic"
```

---

### Task 3: Package `backup-summary` in Nix

**Files:**
- Create: `packages/backup-summary/default.nix`
- Test: Build package derivation via Nix

**Interfaces:**
- Consumes: `pkgs` (with python3, jinja2, restic, rustic, msmtp, coreutils, util-linux)
- Produces: Executable `bin/backup-summary` exposed to `pkgs.backup-summary`

- [ ] **Step 1: Write `packages/backup-summary/default.nix`**

Create `packages/backup-summary/default.nix`:
```nix
{pkgs, ...}: let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.jinja2
  ]);
in
  pkgs.writeShellApplication {
    name = "backup-summary";
    runtimeInputs = [
      pythonEnv
      pkgs.restic
      pkgs.rustic
      pkgs.msmtp
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      export EMAIL_TEMPLATE=${./summary-email.html.j2}
      exec ${pythonEnv}/bin/python ${./backup_summary.py} "$@"
    '';
  }
```

- [ ] **Step 2: Build the package to verify derivation evaluates and compiles**

Run: `nix build .#backup-summary --no-link`
Expected: Derivation builds successfully without error.

- [ ] **Step 3: Run `--help` on the built wrapper to verify runtime environment**

Run: `$(nix build .#backup-summary --print-out-paths --no-link)/bin/backup-summary --help`
Expected: Shows argument parser help with `--dry-run`, `--stdout`, `--send`.

- [ ] **Step 4: Commit**

Run:
```bash
git add packages/backup-summary/default.nix
git commit -m "feat(backup-summary): add nix package derivation for backup-summary"
```

---

### Task 4: Create NixOS Module `modules/constellation/backup-summary.nix`

**Files:**
- Create: `modules/constellation/backup-summary.nix`
- Test: Nix evaluation of the module options

**Interfaces:**
- Consumes:
  - `config.constellation.backupSummary.enable`
  - `config.constellation.backupSummary.schedule`
  - `config.constellation.backupSummary.toEmail`
  - `config.constellation.backupSummary.fromEmail`
  - `config.sops.secrets."restic-password".path`
- Produces:
  - `environment.systemPackages = [ pkgs.backup-summary ]`
  - `systemd.services.backup-summary`
  - `systemd.timers.backup-summary`
  - `systemd.timers."weekly-mail-alert".enable = false;` (heartbeat deduplication)

- [ ] **Step 1: Write `modules/constellation/backup-summary.nix`**

Create `modules/constellation/backup-summary.nix`:
```nix
# Constellation backup-summary module
#
# Generates and sends a weekly fleet-wide backup summary email on Sunday
# evening. Audits local and multi-client restic repos, rustic cold archives,
# and storage pool capacity, alerting operators to stale backups or
# unreachable remote targets.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.backupSummary;
in {
  options.constellation.backupSummary = {
    enable = mkEnableOption "weekly fleet backup summary email digest";

    schedule = mkOption {
      type = types.str;
      default = "Sun *-*-* 20:00:00 UTC";
      description = "systemd OnCalendar schedule for the weekly summary email.";
    };

    toEmail = mkOption {
      type = types.str;
      default = config.constellation.email.toEmail;
      description = "Recipient email address.";
    };

    fromEmail = mkOption {
      type = types.str;
      default = config.constellation.email.fromEmail;
      description = "Sender email address.";
    };

    backrestPortalUrl = mkOption {
      type = types.str;
      default = "https://backrest.arsfeld.one/";
      description = "URL for the central Backrest web portal.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [pkgs.backup-summary];

    # Deduplicate: Suppress the generic "is still alive" heartbeat timer on
    # hosts running the comprehensive backup digest.
    systemd.timers."weekly-mail-alert".enable = false;

    systemd.services.backup-summary = {
      description = "Weekly fleet backup summary email";
      after = ["network-online.target" "restic-rest-server.service"];
      wants = ["network-online.target"];
      unitConfig.RequiresMountsFor = "/mnt/storage";
      onFailure = ["backup-notify@backup-summary.service"];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        TimeoutStartSec = "10m";
        Restart = "no";
        Environment = [
          "EMAIL_TO=${cfg.toEmail}"
          "EMAIL_FROM=${cfg.fromEmail}"
          "RESTIC_PASSWORD_FILE=${config.sops.secrets."restic-password".path}"
        ];
        ExecStart = "${pkgs.backup-summary}/bin/backup-summary --send";
      };
    };

    systemd.timers.backup-summary = {
      description = "Weekly fleet backup summary timer";
      wantedBy = ["timers.target"];
      partOf = ["backup-summary.service"];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
      };
    };
  };
}
```

- [ ] **Step 2: Verify NixOS evaluation with module present**

Run: `nix eval .#nixosConfigurations.galactica.config.system.build.toplevel --apply 'x: "ok"'`
Expected: `"ok"` (module loads via haumea in `modules/`).

- [ ] **Step 3: Commit**

Run:
```bash
git add modules/constellation/backup-summary.nix
git commit -m "feat(modules): add constellation.backupSummary module"
```

---

### Task 5: Enable `backupSummary` on `galactica`

**Files:**
- Modify: `hosts/galactica/backup/default.nix:1-9`
- Test: Full nixosConfiguration evaluation of `galactica`

**Interfaces:**
- Consumes: `constellation.backupSummary` from Task 4
- Produces: `config.constellation.backupSummary.enable = true` on `galactica`

- [ ] **Step 1: Enable `constellation.backupSummary` on `galactica`**

Modify `hosts/galactica/backup/default.nix`:
```nix
{
  imports = [
    ./backup-server.nix
    ./backrest-client.nix
    ./rustic-ovh.nix
    ./rustic.nix
  ];

  constellation.backupSummary.enable = true;
}
```

- [ ] **Step 2: Verify full configuration evaluation on `galactica`**

Run: `nix eval .#nixosConfigurations.galactica.config.system.build.toplevel --apply 'x: "ok"'`
Expected: `"ok"`

- [ ] **Step 3: Verify systemd service and timer are configured on `galactica`**

Run: `nix eval .#nixosConfigurations.galactica.config.systemd.services.backup-summary.description`
Expected: `"Weekly fleet backup summary email"`

Run: `nix eval .#nixosConfigurations.galactica.config.systemd.timers.weekly-mail-alert.enable`
Expected: `false`

- [ ] **Step 4: Commit**

Run:
```bash
git add hosts/galactica/backup/default.nix
git commit -m "feat(galactica): enable weekly fleet backup summary email digest"
```

---

### Task 6: Documentation and Fleet Verification

**Files:**
- Modify: `docs/architecture/backup.md:154-167`
- Test: Fleet-wide Nix evaluation check across all tier 1 and tier 2 hosts

**Interfaces:**
- Consumes: Architecture documentation
- Produces: Updated `docs/architecture/backup.md` documenting the weekly summary digest and heartbeat deduplication

- [ ] **Step 1: Update `docs/architecture/backup.md`**

In `docs/architecture/backup.md`, update the `## Notifications` section to document the weekly summary digest:
```markdown
## Notifications

Every plan fires a shell hook on `CONDITION_ANY_ERROR` and
`CONDITION_SNAPSHOT_ERROR`. The hook POSTs to
`https://ntfy.arsfeld.one/backups` with an `Authorization: Basic`
header built from `NTFY_BASIC_AUTH_B64` (loaded from the
`ntfy-publisher-env` sops secret). Body includes hostname, repo id,
plan id, and the restic error.

### Weekly Backup Summary Digest

Every Sunday evening at 20:00 UTC (16:00 EDT), `galactica` runs
`backup-summary.service` (managed by `constellation.backupSummary`).
The service:
- Inspects `/mnt/storage/backups/restic` (galactica local-system).
- Inspects `/mnt/storage/backups/restic-server` partitioned by `--host`
  (`basestar`, `pegasus`, `raider`).
- Inspects the pegasus REST server and OVH Cold Archive rustic repo.
- Measures `/mnt/storage` filesystem pool capacity and repository sizes.
- Generates a responsive HTML email dashboard sent to `alex@rosenfeld.one`
  via `msmtp`.

When enabled, `galactica`'s generic `systemd.timers."weekly-mail-alert"`
is disabled, replacing redundant heartbeats with an actionable audit.
If the summary service encounters a fatal execution error, it notifies
`ntfy.arsfeld.one/backups` via `OnFailure=backup-notify@backup-summary.service`.
```

- [ ] **Step 2: Run fleet evaluation check**

Run:
```bash
nix eval .#nixosConfigurations.basestar.config.system.build.toplevel --apply 'x: "basestar ok"'
nix eval .#nixosConfigurations.galactica.config.system.build.toplevel --apply 'x: "galactica ok"'
nix eval .#nixosConfigurations.pegasus.config.system.build.toplevel --apply 'x: "pegasus ok"'
nix eval .#nixosConfigurations.raider.config.system.build.toplevel --apply 'x: "raider ok"'
```
Expected: All hosts return `"host ok"`.

- [ ] **Step 3: Commit**

Run:
```bash
git add docs/architecture/backup.md
git commit -m "docs(backup): document weekly fleet backup summary email service"
```
