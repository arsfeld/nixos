# Vault Seed Pruning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An hourly `plab prune` that removes finished Vault torrents from Transmission:
non-PornoLab ones on completion, PornoLab ones at ratio 2.0 or after 7 days idle, with a
cap of 50 still seeding. Data is always kept.

**Architecture:** plab's `transmission.py` gains `torrents` and `remove` on a shared
`_call` handshake. A new pure `prune.decide` holds the policy. `main.py` gets a `prune`
subcommand, and `default.nix` gets a `plab-prune` oneshot service with an hourly timer.

**Tech Stack:** Python 3 stdlib (unittest, urllib), NixOS systemd units.

Spec: `docs/superpowers/specs/2026-10-30-vault-seed-prune-design.md`

## Global Constraints

- `torrent-remove` always sends `delete-local-data: false`.
- Only torrents whose `downloadDir` is the Vault dir or below it, and whose
  `percentDone == 1`, are ever removed.
- PornoLab = any tracker announce host containing `plab` or `pornolab`.
- `RATIO = 2.0`, `IDLE_DAYS = 7`, `MAX_SEEDING = 50`.
- Idle = `now - max(doneDate, activityDate)`.
- Tests: `python3 -m unittest -v` in `hosts/galactica/services/plab/`.
- Commits: `feat(galactica): plab …`; stage only the files named in the task.

---

### Task 1: Transmission `torrents` and `remove`

**Files:**
- Modify: `hosts/galactica/services/plab/transmission.py`
- Test: `hosts/galactica/services/plab/test_transmission.py`

**Interfaces:**
- Produces: `transmission.torrents(url) -> list[dict]` with the keys `id`, `name`,
  `downloadDir`, `percentDone`, `uploadRatio`, `doneDate`, `activityDate`, `trackers`.
  Also `transmission.remove(url, ids) -> None`.

- [ ] **Step 1: Write the failing tests.** Append these to the `Add` class:

```python
    def test_torrents_lists_with_fields(self):
        Stub.reply = {"result": "success", "arguments": {"torrents": [{"id": 1, "name": "A"}]}}
        self.assertEqual(transmission.torrents(self.url), [{"id": 1, "name": "A"}])
        body = Stub.requests[1][1]
        self.assertEqual(body["method"], "torrent-get")
        self.assertIn("trackers", body["arguments"]["fields"])

    def test_remove_keeps_data(self):
        Stub.reply = {"result": "success", "arguments": {}}
        transmission.remove(self.url, [3, 4])
        body = Stub.requests[1][1]
        self.assertEqual(body["method"], "torrent-remove")
        self.assertEqual(body["arguments"], {"ids": [3, 4], "delete-local-data": False})
```

- [ ] **Step 2: Run** `python3 -m unittest -v test_transmission`. Expect `AttributeError: … 'torrents'`.

- [ ] **Step 3: Implement.** Factor the handshake into `_call` and rewrite `add` on top of it:

```python
FIELDS = ["id", "name", "downloadDir", "percentDone", "uploadRatio", "doneDate", "activityDate", "trackers"]


def _call(url, method, arguments):
    """One RPC call; return its `arguments`. The first request is answered 409 with the
    session id to send on the second."""
    body = json.dumps({"method": method, "arguments": arguments}).encode()
    session = ""
    for _ in range(2):
        ...  # the existing loop body, returning reply.get("arguments", {})
    raise TransmissionError("no session id after 409")


def add(url, torrent, download_dir):
    source = ...
    args = _call(url, "torrent-add", {**source, "download-dir": download_dir})
    return (args.get("torrent-added") or args.get("torrent-duplicate") or {}).get("name", "")


def torrents(url):
    """Every torrent, with the fields `prune` reads."""
    return _call(url, "torrent-get", {"fields": FIELDS})["torrents"]


def remove(url, ids):
    """Remove torrents from Transmission, never their data."""
    _call(url, "torrent-remove", {"ids": ids, "delete-local-data": False})
```

Also update the module docstring.

- [ ] **Step 4: Run** `python3 -m unittest -v test_transmission`. All six tests should pass.

- [ ] **Step 5: Commit** `transmission.py` and `test_transmission.py`.

### Task 2: `prune.decide`

**Files:**
- Create: `hosts/galactica/services/plab/prune.py`
- Test: `hosts/galactica/services/plab/test_prune.py`

**Interfaces:**
- Consumes: the torrent dicts from `transmission.torrents`.
- Produces: `prune.decide(torrents, now, vault_dir) -> list[tuple[int, str, str]]`,
  returning `(id, name, reason)` tuples.

- [ ] **Step 1: Write the failing tests** (the full file is in the repo after this step). Cover:
  - non-PornoLab torrent removed when complete, kept while downloading
  - ratio 2.0 removed; ratio 1.9 active 1 day ago kept
  - idle 7 days removed; done 2 days ago with no uploads kept
  - a torrent outside Vault never removed, including a `/Vault2` prefix lookalike
  - the cap: 52 PornoLab torrents trims the 2 longest-idle
  - PornoLab matched on a non-first tracker

- [ ] **Step 2: Run** `python3 -m unittest -v test_prune`. Expect `ModuleNotFoundError`.

- [ ] **Step 3: Implement `prune.py`.** Constants, `_is_lab`, `_idle_days` and `decide`
  as specified in Global Constraints. The cap applies only to PornoLab torrents that
  survive the ratio and idle rules, and trims the longest-idle first.

- [ ] **Step 4: Run** `python3 -m unittest -v`. Every test should pass.

- [ ] **Step 5: Commit** `prune.py` and `test_prune.py`.

### Task 3: `plab prune` command and timer

**Files:**
- Modify: `hosts/galactica/services/plab/main.py` (docstring, `run_prune`, `main`)
- Modify: `hosts/galactica/services/plab/default.nix` (header comment, `plab-prune` service and timer)
- Test: `hosts/galactica/services/plab/test_main.py`

**Interfaces:**
- Consumes: `transmission.torrents`, `transmission.remove`, `prune.decide`.
- Produces: `main.run_prune(rpc_url, vault_dir, now, dry_run=False, list_=transmission.torrents, remove=transmission.remove) -> list`.

- [ ] **Step 1: Write the failing test** in `test_main.py`:
  - `run_prune` with a fake `list_` and `remove` removes the decided ids in one call
  - with `dry_run=True`, `remove` is never called

- [ ] **Step 2: Run it** and confirm it fails.

- [ ] **Step 3: Implement.**
  - `run_prune` logs `removed <name>: <reason>` (or `would remove …`).
  - In `main`, the `prune` subcommand is dispatched *before* the `Lab` and `Store` are
    built, so pruning never needs the tracker credentials.
  - In `default.nix`, `systemd.services.plab-prune` is a oneshot running
    `${plab}/bin/plab prune`. `systemd.timers.plab-prune` uses
    `OnCalendar = "hourly"` and `Persistent = true`.

- [ ] **Step 4: Run** `python3 -m unittest -v`, then
  `nix build .#nixosConfigurations.galactica.config.system.build.toplevel`.

- [ ] **Step 5: Commit** `main.py`, `test_main.py` and `default.nix`.

### Task 4: Deploy and verify

- [ ] `just deploy galactica`
- [ ] `ssh galactica.bat-boa.ts.net sudo -u media plab prune --dry-run`: the output
  matches the live torrents (the one PornoLab torrent is still downloading, so nothing
  is removed).
- [ ] `systemctl list-timers plab-prune` shows the next run, and
  `systemctl start plab-prune` exits successfully.
