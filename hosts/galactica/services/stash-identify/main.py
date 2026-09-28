"""stash-identify: scan, generate and identify new Stash files, then fill bare scenes
from an LLM filename parse, confirmed against stash-box where possible.

Design: docs/superpowers/specs/2026-09-27-stash-llm-identify-design.md
"""
import argparse
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time

import match
from llm import OpenRouter
from stash import JobFailed, Stash

BOXES = ["https://theporndb.net/graphql", "https://stashdb.org/graphql"]  # preference order
PER_BOX = 6
LLM_TAG = "llm-identified"
LIBRARY_HOST = "/mnt/storage/media/Vault"
LIBRARY_CONTAINER = "/media/Vault"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def rel_path(container_path):
    return container_path.removeprefix(LIBRARY_CONTAINER + "/")


def identify_scene(stash, llm, scene):
    """Propose metadata for one bare scene. Raises if the parse, a stash-box search, or
    the Jev call fails: those are transient failures, and run_pass must retry the scene
    next pass rather than record a downgraded llm-only guess that would lose a possible
    scrape for good. Only downgrades to llm-only when every search succeeded and turned
    up nothing usable (or Jev affirmatively picked none)."""
    f = scene["files"][0]
    path, duration = rel_path(f["path"]), f["duration"]
    parse = llm.parse(path)
    prop = {"kind": "none", "rule": None, "parse": parse, "primary": None,
            "primary_endpoint": None, "stash_ids": [], "confidence": None, "delta": None}
    if parse.get("title") or parse.get("studio") or parse.get("performers"):
        prop["kind"] = "llm"

    everything = []
    if parse.get("query"):
        for ep in BOXES:
            try:
                hits = stash.search(ep, parse["query"])[:PER_BOX]
            except Exception as e:
                raise RuntimeError(f"scene {scene['id']}: search {ep} failed: {e}") from e
            everything += [(ep, c) for c in hits]
    cands = match.dedupe([t for t in everything if match.duration_ok(t[1], duration)])
    if not cands:
        return prop

    chosen, rule = match.deterministic_match(cands, parse), "date"
    if chosen is None:
        rule = "jev"
        try:
            answer = llm.choose(path, duration, parse, cands)
        except Exception as e:
            raise RuntimeError(f"scene {scene['id']}: jev failed: {e}") from e
        chosen, prop["confidence"] = match.jev_pick(answer, cands), answer.get("confidence")
    if chosen is None:
        return prop

    group = match.twins(chosen, everything, duration)
    primary_ep, primary = min(group, key=lambda t: BOXES.index(t[0]))
    ids, seen = [], set()
    for ep, c in sorted(group, key=lambda t: BOXES.index(t[0])):
        if ep not in seen and c.get("remote_site_id"):
            seen.add(ep)
            ids += match.stash_ids_for(ep, c["remote_site_id"])
    prop.update(kind="scrape", rule=rule, primary=primary, primary_endpoint=primary_ep,
                stash_ids=ids, delta=round(primary["duration"] - duration))
    return prop


def resolve_studio(stash, name, create_input=None, endpoint=None, remote_id=None, create=True):
    if endpoint and remote_id:
        hit = stash.studio_by_stash_id(endpoint, remote_id)
        if hit:
            return hit
    hit = match.pick_by_name(stash.studios_like(name), name, "aliases", allow_alias=True)
    if hit or not create:
        return hit
    return stash.create_studio(create_input or {"name": name})


def resolve_performer(stash, name, create_input=None, endpoint=None, remote_id=None):
    if endpoint and remote_id:
        hit = stash.performer_by_stash_id(endpoint, remote_id)
        if hit:
            return hit
    hit = match.pick_by_name(stash.performers_like(name), name, "alias_list",
                             allow_alias=match.alias_ok(name))
    return hit or stash.create_performer(create_input or {"name": name})


def apply(stash, scene, prop, skip_tag_ids):
    if prop["kind"] == "scrape":
        p, ep = prop["primary"], prop["primary_endpoint"]
        studio_id = None
        if p.get("studio"):
            s = p["studio"]
            parent = s.get("parent")
            parent_id = parent and resolve_studio(stash, parent["name"], endpoint=ep,
                                                  remote_id=parent.get("remote_site_id"),
                                                  create=False)
            studio_id = resolve_studio(stash, s["name"], match.studio_create_input(s, ep, parent_id),
                                       ep, s.get("remote_site_id"))
        performer_ids = [resolve_performer(stash, x["name"], match.performer_create_input(x, ep),
                                           ep, x.get("remote_site_id"))
                         for x in p.get("performers") or [] if x.get("name")]
        tag_ids = [t["stored_id"] for t in p.get("tags") or [] if t.get("stored_id")]
        stash.update_scene(match.scrape_update(scene, p, prop["stash_ids"], studio_id,
                                               performer_ids, tag_ids, skip_tag_ids))
    elif prop["kind"] == "llm":
        parse = prop["parse"]
        studio_id = parse.get("studio") and resolve_studio(stash, parse["studio"])
        performer_ids = [resolve_performer(stash, n) for n in parse.get("performers") or [] if n]
        stash.update_scene(match.llm_update(scene, parse, studio_id, performer_ids,
                                            stash.tag_id(LLM_TAG, create=True)))


def format_line(scene, prop):
    head = f"[{scene['id']}] {rel_path(scene['files'][0]['path'])}"
    if prop["kind"] == "scrape":
        p = prop["primary"]
        src = "+".join(sorted({s["endpoint"].split("/")[2].split(".")[-2] for s in prop["stash_ids"]}))
        conf = f" conf={prop['confidence']:.2f}" if prop["confidence"] is not None else ""
        perf = ", ".join(x["name"] for x in p.get("performers") or [])
        body = (f"{src} ({prop['rule']}{conf}) | {p.get('title')!r} | {match.studio_name(p)} | "
                f"{perf or '-'} | Δ{prop['delta']:+d}s")
    elif prop["kind"] == "llm":
        q = prop["parse"]
        body = (f"llm-only | {q.get('title')!r} | {q.get('studio') or '-'} | "
                f"{', '.join(q.get('performers') or []) or '-'}")
    else:
        body = "nothing found"
    return f"{head}\n    {body}"


def to_container(host_path):
    return LIBRARY_CONTAINER + host_path.removeprefix(LIBRARY_HOST)


class State:
    """Scene IDs the LLM step has finished with, so hopeless files aren't re-billed."""

    def __init__(self, path):
        self.path = path
        try:
            with open(path) as f:
                self.ids = set(json.load(f))
        except FileNotFoundError:
            self.ids = set()

    def __contains__(self, scene_id):
        return scene_id in self.ids

    def add(self, scene_id):
        self.ids.add(scene_id)
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path))
        with os.fdopen(fd, "w") as f:
            json.dump(sorted(self.ids, key=int), f)
        os.replace(tmp, self.path)


def skip_tags(defaults):
    opts = defaults.get("identify", {}).get("options", {})
    return {t for t in (opts.get("skipMultipleMatchTag"), opts.get("skipSingleNamePerformerTag")) if t}


def run_pass(stash, llm, state, defaults, paths, *, jobs=True, dry_run=False, limit=None,
             scene_ids=None):
    """One pass. paths=None means the whole library (the sweep). jobs=False skips Stash's
    scan/generate/identify; scene_ids processes exactly those scenes, ignoring state."""
    if jobs and not dry_run:
        try:
            before = stash.max_scene_id()
            log(f"scan {paths or 'library'}")
            stash.scan([to_container(p) for p in paths] if paths else None, defaults["scan"])
            new = stash.scene_ids_after(before)
            log(f"{len(new)} new scene(s)")
            if new or paths is None:
                # The sweep generates library-wide (overwrite is always off, so only
                # missing files are made); a watched pass only touches its new scenes.
                stash.generate(new if paths else None, defaults["generate"])
            if new:
                stash.identify(new, defaults["identify"])
        except Exception as e:
            log(f"stash jobs failed, continuing to the LLM step: {e}")

    todo = stash.scenes(scene_ids) if scene_ids else \
        [s for s in stash.bare_scenes() if s["id"] not in state]
    if limit:
        todo = todo[:limit]
    log(f"llm step: {len(todo)} scene(s)")
    drop = skip_tags(defaults)
    for scene in todo:
        try:
            prop = identify_scene(stash, llm, scene)
            print(format_line(scene, prop), flush=True)
            if dry_run:
                continue
            apply(stash, scene, prop, drop)
            state.add(scene["id"])
        except Exception as e:
            log(f"  [{scene['id']}] failed, will retry next pass: {e}")


SETTLE = 120            # seconds without events before a pass runs
SWEEP_EVERY = 24 * 3600


class Debouncer:
    def __init__(self, quiet):
        self.quiet, self.pending, self.last = quiet, set(), 0.0

    def add(self, path, now):
        self.pending.add(path)
        self.last = now

    def ready(self, now):
        if self.pending and now - self.last >= self.quiet:
            out, self.pending = self.pending, set()
            return out
        return None


def changed_dir(line, video_exts):
    """One `inotifywait --format '%e|%w%f'` line -> the folder Stash should scan."""
    events, sep, path = line.rstrip("\n").partition("|")
    if not sep:
        return None
    if "ISDIR" in events.split(","):
        return path
    if path.rsplit(".", 1)[-1].lower() in video_exts:
        return os.path.dirname(path)
    return None


def next_action(debouncer, last_sweep, now):
    """Decide what to do: ("pass", dirs), ("sweep", None), or None."""
    dirs = debouncer.ready(now)
    if dirs:
        return ("pass", dirs)
    if last_sweep == 0.0 or now - last_sweep >= SWEEP_EVERY:
        return ("sweep", None)
    return None


def watch(stash, llm, state):
    exts = {e.lower() for e in stash.video_extensions()}
    proc = subprocess.Popen(
        ["inotifywait", "-m", "-r", "-q", "-e", "close_write,moved_to",
         "--format", "%e|%w%f", LIBRARY_HOST],
        stdout=subprocess.PIPE, text=True)
    events = queue.Queue()

    def reader():
        for line in proc.stdout:
            d = changed_dir(line, exts)
            if d:
                events.put(d)
    threading.Thread(target=reader, daemon=True).start()

    def safe_pass(paths):
        try:
            run_pass(stash, llm, state, stash.defaults(), paths)
        except Exception as e:
            log(f"pass failed: {e}")

    debouncer, last_sweep = Debouncer(SETTLE), 0.0   # 0 => sweep at startup (backfill)
    while True:
        if proc.poll() is not None:
            raise RuntimeError(f"inotifywait exited with {proc.returncode}")
        try:
            debouncer.add(events.get(timeout=10), time.monotonic())
        except queue.Empty:
            pass
        now = time.monotonic()
        action = next_action(debouncer, last_sweep, now)
        if action:
            action_type, data = action
            if action_type == "pass":
                log(f"changed: {sorted(data)}")
                safe_pass(sorted(data))
            elif action_type == "sweep":
                log("sweep")
                safe_pass(None)
                last_sweep = time.monotonic()


def openrouter_key():
    if os.environ.get("OPENROUTER_API_KEY"):
        return os.environ["OPENROUTER_API_KEY"]
    with open(os.environ["OPENROUTER_API_KEY_FILE"]) as f:
        return f.read().strip()


def clients():
    stash = Stash(os.environ.get("STASH_URL", "http://localhost:9999/graphql"),
                  os.environ.get("STASH_API_KEY"))
    llm = OpenRouter(openrouter_key(),
                     os.environ.get("PARSE_MODEL", "~deepseek/deepseek-flash-latest"),
                     os.environ.get("JEV_MODEL", "typesafe/jev-1.13"))
    state = State(os.environ.get("STATE_FILE", "/var/lib/stash-identify/attempted.json"))
    return stash, llm, state


def main(argv):
    ap = argparse.ArgumentParser(prog="stash-identify")
    sub = ap.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run", help="one pass, by hand")
    run.add_argument("--dry-run", action="store_true", help="print proposals; write nothing")
    run.add_argument("--limit", type=int)
    run.add_argument("--scene", action="append", dest="scenes",
                     help="only this scene ID (repeatable); ignores the state file")
    sub.add_parser("watch", help="the service: watch the library, sweep daily")
    args = ap.parse_args(argv)
    stash, llm, state = clients()
    if args.cmd == "run":
        # A manual run never scans; it only does the LLM step.
        run_pass(stash, llm, state, stash.defaults(), None, jobs=False, dry_run=args.dry_run,
                 limit=args.limit, scene_ids=args.scenes)
    if args.cmd == "watch":
        watch(stash, llm, state)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
