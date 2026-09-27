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
