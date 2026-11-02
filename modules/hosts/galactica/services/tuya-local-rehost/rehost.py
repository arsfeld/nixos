"""Point tuya_local entries at their device's current IP.

tuya_local reaches each device at the fixed `host` saved in its config entry
and cannot follow a DHCP move: on 2026-10-26 the living room IR hub moved
from .56 to .77 and every heat pump command was dropped for six days. Run
from a timer, this checks each entry's host; after FAILURES_BEFORE_SCAN
failed checks in a row it listens for the device's own UDP broadcast (which
carries its id and IP), and if the device is somewhere else it stops Home
Assistant, rewrites the host and starts it again. The restart is what makes
tuya_local reconnect, and the heat pump automation re-sends its state on
start.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import time

STORAGE = "/var/lib/hass/.storage/core.config_entries"
STATE = os.path.join(os.environ.get("STATE_DIRECTORY", "/var/lib/tuya-local-rehost"), "state.json")
PORT = 6668
FAILURES_BEFORE_SCAN = 2
REWRITE_INTERVAL = 3600


def tuya_entries(config):
    """(entry_id, title, host, device_id) of every tuya_local entry."""
    return [
        (e["entry_id"], e.get("title", ""), e["data"].get("host"), e["data"].get("device_id"))
        for e in config["data"]["entries"]
        if e.get("domain") == "tuya_local" and e.get("data", {}).get("host") and e["data"].get("device_id")
    ]


def decide(entries, reachable, discover, state, now):
    """Pure decision: returns (moves, new_state, log lines).

    moves maps entry_id to the new host. `reachable(host)` and
    `discover(device_id)` (an IP or None) are injected so this can be tested.
    """
    failures = dict(state.get("failures", {}))
    last_rewrite = state.get("last_rewrite", 0)
    moves, log = {}, []
    for entry_id, title, host, device_id in entries:
        if reachable(host):
            failures.pop(entry_id, None)
            continue
        failures[entry_id] = failures.get(entry_id, 0) + 1
        log.append(f"{title}: {host}:{PORT} unreachable ({failures[entry_id]} in a row)")
        if failures[entry_id] < FAILURES_BEFORE_SCAN:
            continue
        found = discover(device_id)
        if found is None:
            log.append(f"{title}: no broadcast from {device_id}; leaving it")
        elif found == host:
            log.append(f"{title}: still broadcasting from {host}; leaving it")
        elif now - last_rewrite < REWRITE_INTERVAL:
            log.append(f"{title}: moved to {found}, but rewrote less than an hour ago; waiting")
        else:
            log.append(f"{title}: moved {host} -> {found}")
            moves[entry_id] = found
    if moves:
        last_rewrite = now
        for entry_id in moves:
            failures.pop(entry_id, None)
    return moves, {"failures": failures, "last_rewrite": last_rewrite}, log


def apply_moves(config, moves):
    for entry in config["data"]["entries"]:
        if entry["entry_id"] in moves:
            entry["data"]["host"] = moves[entry["entry_id"]]


def reachable(host):
    try:
        with socket.create_connection((host, PORT), timeout=3):
            return True
    except OSError:
        return False


def discover(device_id):
    import tinytuya

    return tinytuya.find_device(dev_id=device_id)["ip"]


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_atomic(path, data, like=None):
    """Write via rename; `like` lends its owner and mode (HA's file is hass's)."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    if like:
        st = os.stat(like)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)


def main():
    state = load(STATE, {})
    config = load(STORAGE, None)
    if config is None:
        print(f"{STORAGE} missing; nothing to do")
        return
    now = time.time()
    moves, state, log = decide(tuya_entries(config), reachable, discover, state, now)
    for line in log:
        print(line)
    if moves:
        subprocess.run(["systemctl", "stop", "home-assistant.service"], check=True)
        try:
            # Re-read: HA may have written the file while it stopped.
            config = load(STORAGE, None)
            shutil.copy2(STORAGE, STORAGE + time.strftime(".bak-%Y%m%dT%H%M%SZ", time.gmtime(now)))
            apply_moves(config, moves)
            write_atomic(STORAGE, config, STORAGE)
        finally:
            subprocess.run(["systemctl", "start", "home-assistant.service"], check=True)
        print("home-assistant restarted with the new host(s)")
    write_atomic(STATE, state)


if __name__ == "__main__":
    sys.exit(main())
