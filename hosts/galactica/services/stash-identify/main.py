"""stash-identify: scan, generate and identify new Stash files, then fill bare scenes
from an LLM filename parse, confirmed against stash-box where possible.

Design: docs/superpowers/specs/2026-09-27-stash-llm-identify-design.md
"""
import sys

import match

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
    """Propose metadata for one bare scene. Raises if the parse itself fails."""
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
                everything += [(ep, c) for c in stash.search(ep, parse["query"])[:PER_BOX]]
            except Exception as e:
                log(f"  [{scene['id']}] search {ep}: {e}")
    cands = [c for c in match.dedupe(everything) if match.duration_ok(c[1], duration)]
    if not cands:
        return prop

    chosen, rule = match.deterministic_match(cands, parse), "date"
    if chosen is None:
        rule = "jev"
        try:
            answer = llm.choose(path, duration, parse, cands)
            chosen, prop["confidence"] = match.jev_pick(answer, cands), answer.get("confidence")
        except Exception as e:
            log(f"  [{scene['id']}] jev: {e}")
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
