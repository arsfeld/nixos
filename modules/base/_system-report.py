"""One mail per settled change: the deploy, if there was one, and every unit
that failed since the last report and is still failed.

Fed by two producers. email@<unit> appends a line to /run/unit-failures/<unit>
each time that unit fails; the deploy activation snippet writes the generation
it replaced to /run/deploy-mail/from. Both then queue this service. Starting it
while it already runs merges into the running job, so it loops until both
spools are empty after a pass.
"""

import html
import os
import subprocess
import sys
import time
from pathlib import Path

SPOOL = Path("/run/unit-failures")
SENT = SPOOL / ".sent"
DEPLOY = Path("/run/deploy-mail/from")
COOLDOWN = 3600  # a unit is reported at most once an hour
LOG_LINES = 40
# send-email-event takes the body as one argv string, and Linux caps a single
# argument at 128 KiB.
BODY_MAX = 100_000

WAIT, SEND, EMAIL_FROM, EMAIL_TO = sys.argv[1:5]


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def failed_units():
    out = run("systemctl", "list-units", "--state=failed", "--plain",
              "--no-legend", "--no-pager")
    return [line.split()[0] for line in out.splitlines() if line.strip()]


def cooling(unit, now):
    try:
        return now - float((SENT / unit).read_text()) < COOLDOWN
    except (OSError, ValueError):
        return False


def take_deploy():
    try:
        old = DEPLOY.read_text().strip()
    except OSError:
        return None
    DEPLOY.unlink(missing_ok=True)
    return old or "unknown"


def take_failures(failed_now, now):
    """Spooled units still failed and out of cooldown, with their counts.

    A unit that recovered is dropped. One still cooling keeps its spool file,
    so its count carries into the next report.
    """
    report = {}
    if not SPOOL.is_dir():
        return report
    for f in SPOOL.iterdir():
        if not f.is_file():
            continue
        unit = f.name
        if unit not in failed_now:
            f.unlink(missing_ok=True)
        elif not cooling(unit, now):
            report[unit] = len(f.read_text().splitlines()) or 1
            f.unlink(missing_ok=True)
    return report


def pre(text):
    return "<pre>" + html.escape(text) + "</pre>"


def unit_section(unit, count):
    status = run("systemctl", "status", "--full", "--no-pager", "--lines=0",
                 unit)
    logs = run("journalctl", "-u", unit, "-b", "--no-pager", "-n",
               str(LOG_LINES))
    times = "once" if count == 1 else f"{count} times"
    return (f"<h3>{html.escape(unit)}</h3><p>Failed {times} since the last "
            f"report.</p>{pre(status)}{pre(logs)}")


def send(deploy_from, report, failed_now):
    n = len(report)
    noun = "unit" if n == 1 else "units"
    if deploy_from is not None:
        event = "deployed" + (f", {len(failed_now)} failed" if failed_now
                              else "")
    else:
        event = f"{n} {noun} failed"

    parts = []
    if deploy_from is not None:
        new = os.path.realpath("/run/current-system")
        try:
            version = Path(new, "nixos-version").read_text().strip()
        except OSError:
            version = "?"
        parts.append(pre(
            f"From: {deploy_from.removeprefix('/nix/store/')}\n"
            f"To:   {new.removeprefix('/nix/store/')}\n"
            f"NixOS {version}\n\n"
            "Failed units: " + (", ".join(failed_now) or "none")))
    elif set(failed_now) - set(report):
        others = sorted(set(failed_now) - set(report))
        parts.append(pre("Also failed now: "
                         + ", ".join(others)))

    body = "".join(parts)
    for unit in sorted(report):
        section = unit_section(unit, report[unit])
        if len(body) + len(section) > BODY_MAX:
            rest = sorted(report)[sorted(report).index(unit):]
            body += pre("Truncated; not shown: " + ", ".join(rest))
            break
        body += section

    subprocess.run([SEND, "--email-from", EMAIL_FROM, "--email-to", EMAIL_TO,
                    event, body], check=True)
    SENT.mkdir(parents=True, exist_ok=True)
    now = str(time.time())
    for unit in report:
        (SENT / unit).write_text(now)


def main():
    while True:
        subprocess.run([WAIT], check=True)
        now = time.time()
        failed_now = failed_units()
        deploy_from = take_deploy()
        report = take_failures(set(failed_now), now)
        if deploy_from is not None or report:
            send(deploy_from, report, failed_now)
        # Units still cooling stay spooled; do not spin on them.
        if not DEPLOY.exists() and not any(
            f.is_file() and not cooling(f.name, time.time())
            for f in (SPOOL.iterdir() if SPOOL.is_dir() else [])
        ):
            break


main()
