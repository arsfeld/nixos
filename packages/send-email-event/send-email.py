#! /usr/bin/env -S uv run --no-project --python 3.12 --with jinja2 python

import subprocess
import datetime
import os
import socket
from jinja2 import Template
import logging
import argparse
from textwrap import dedent


def _read_proc_uptime():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return 0.0


def _read_meminfo():
    info = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                info[k.strip()] = int(v.strip().split()[0])  # kB
    except Exception:
        pass
    return info


def _format_uptime(secs):
    days = int(secs // 86400)
    hours = int((secs % 86400) // 3600)
    mins = int((secs % 3600) // 60)
    if days >= 1:
        return f"{days}d {hours}h", f"{mins}m"
    if hours >= 1:
        return f"{hours}h {mins}m", "since boot"
    return f"{mins}m", "since boot"


def _bar_color(percent):
    return "#ef4444" if percent >= 85 else "#4f46e5"


def collect_stats():
    stats = {}

    cpu = (
        get_command_output("lscpu | grep 'Model name' | cut -f 2 -d ':'")
        .strip()
        or "Unknown"
    )
    stats["cpu"] = {"label": "Processor", "value": cpu}

    uptime_value, uptime_sub = _format_uptime(_read_proc_uptime())
    stats["uptime"] = {"label": "Uptime", "value": uptime_value, "sub": uptime_sub}

    stats["kernel"] = {
        "label": "Kernel",
        "value": get_command_output("uname -r") or "?",
        "sub": get_command_output("uname -s") or "",
    }

    mem = _read_meminfo()
    total_kb = mem.get("MemTotal", 0)
    avail_kb = mem.get("MemAvailable", mem.get("MemFree", 0))
    if total_kb:
        used_kb = max(total_kb - avail_kb, 0)
        pct = round(used_kb / total_kb * 100)
        stats["memory"] = {
            "label": "Memory",
            "value": f"{used_kb / 1024 / 1024:.1f} / {total_kb / 1024 / 1024:.1f} GiB",
            "percent": pct,
            "color": _bar_color(pct),
        }

    try:
        s = os.statvfs("/")
        total = s.f_blocks * s.f_frsize
        free = s.f_bavail * s.f_frsize
        used = max(total - free, 0)
        pct = round(used / total * 100) if total else 0
        stats["disk"] = {
            "label": "Disk /",
            "value": f"{used / 1024**3:.0f} / {total / 1024**3:.0f} GiB",
            "percent": pct,
            "color": _bar_color(pct),
        }
    except OSError:
        pass

    return stats

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

EMAIL_TEMPLATE = os.environ.get(
    "EMAIL_TEMPLATE",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "event-notification.html"),
)


def get_command_output(command):
    try:
        return (
            subprocess.check_output(command, shell=True, stderr=subprocess.STDOUT)
            .decode("utf-8")
            .strip()
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"Error executing command: {e.output.decode('utf-8').strip()}")
        return f"Error executing command: {e.output.decode('utf-8').strip()}"
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}")
        return f"Unexpected error: {str(e)}"


def send_email_event(event, extra_content="", email_from=None, email_to=None):
    hostname = socket.gethostname()
    current_date = datetime.datetime.now().isoformat()
    stats = collect_stats()

    subject = f"[{hostname}] {event} {current_date}"

    with open(EMAIL_TEMPLATE, "r") as f:
        html_template = f.read()

    try:
        template = Template(html_template)
        html_content = template.render(
            EVENT=event,
            HOSTNAME=hostname,
            CURRENT_DATE=current_date,
            STATS=stats,
            EXTRA_CONTENT=extra_content,
        )
    except Exception as e:
        logger.error(f"Error generating HTML content: {e}")
        html_content = f"""
        <html>
        <body>
            <h1>System Event Notification</h1>
            <h2>{event}</h2>
            <p>Hostname: {hostname}</p>
            <p>Date: {current_date}</p>
            <h3>System Information:</h3>
            <pre>{stats}</pre>
            {'<h3>Extra Content:</h3><p>' + extra_content + '</p>' if extra_content else ''}
        </body>
        </html>
        """

    # Determine email addresses by overriding with arguments if provided
    if email_from is None:
        email_from = os.environ.get("EMAIL_FROM", "admin@rosenfeld.one")
    if email_to is None:
        email_to = os.environ.get("EMAIL_TO", "alex@rosenfeld.one")

    # Construct email content
    email_content = f"""
From: {email_from}
To: {email_to}
Subject: {subject}
Content-Type: text/html; charset="utf-8"

{html_content}
        """.strip(
        "\n"
    )

    logger.info(f"Email content: {email_content}")

    # Queue the email via msmtpq (never fails – mail lands on disk).
    subprocess.run(
        ["msmtpq"],
        input=email_content,
        text=True,
        check=True,
    )
    logger.info("Email queued successfully")

    # Best-effort immediate flush.  If the network isn't ready the queue
    # timer will pick it up on the next tick.
    try:
        subprocess.run(
            ["msmtp-queue", "-r"],
            capture_output=True,
            text=True,
            check=True,
        )
        logger.info("Queue flushed after queuing")
    except subprocess.CalledProcessError as e:
        logger.warning(f"Queue flush deferred (network not ready?): {e.stderr.strip()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Send email event notifications")
    parser.add_argument(
        "event", type=str, nargs="?", default="Unknown Event", help="Event description"
    )
    parser.add_argument(
        "extra_content",
        type=str,
        nargs="?",
        default="",
        help="Extra content for the email",
    )
    parser.add_argument(
        "--email-from", dest="email_from", type=str, help="Sender email address"
    )
    parser.add_argument(
        "--email-to", dest="email_to", type=str, help="Recipient email address"
    )

    args = parser.parse_args()

    send_email_event(
        args.event,
        args.extra_content,
        email_from=args.email_from,
        email_to=args.email_to,
    )
