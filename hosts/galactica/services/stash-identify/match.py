"""Pure matching and payload-building logic for stash-identify. No I/O here."""
import re

# A candidate must be within this many seconds of the file. It is the gate that makes
# the looser checks (Jev, studio+date) safe: in testing every real match was within ~1 s.
DURATION_TOLERANCE = 10

GENDERS = {"MALE", "FEMALE", "TRANSGENDER_MALE", "TRANSGENDER_FEMALE", "INTERSEX", "NON_BINARY"}
CIRCUMCISED = {"CUT", "UNCUT"}

JEV_INSTRUCTIONS = (
    "All candidates already have a duration matching the file. Which one is the exact same "
    "scene as this file? The title or studio in the file path should correspond to the candidate. "
    "Performer names in file paths are often aliases, first names only, or folder names, so a "
    "performer mismatch alone does not rule a candidate out. Pick none if the title and studio "
    "don't correspond.")


def norm(s):
    """Lowercase alphanumerics only, so "TripForFuck" == "Trip For Fuck"."""
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def studio_name(c):
    return (c.get("studio") or {}).get("name")


def scene_key(c):
    return norm(c.get("title")), norm(studio_name(c))


def duration_ok(c, file_duration):
    d = c.get("duration")
    return bool(d) and abs(d - file_duration) <= DURATION_TOLERANCE


def dedupe(cands):
    """cands: [(endpoint, scraped)] in endpoint preference order; first per scene wins."""
    seen, out = set(), []
    for ep, c in cands:
        if scene_key(c) not in seen:
            seen.add(scene_key(c))
            out.append((ep, c))
    return out


def deterministic_match(cands, parse):
    """Studio and date agree with the filename parse. cands must be duration-filtered.

    Release-style names (TripForFuck.24.12.24.Peachy.Alice) carry a date but no title,
    which Jev reads as a mismatch; this rule catches them. Several hits must all be the
    same scene, else nothing fires."""
    studio, date = norm(parse.get("studio")), parse.get("date")
    if not studio or not date:
        return None
    hits = [(ep, c) for ep, c in cands
            if norm(studio_name(c)) == studio and c.get("date") == date]
    if hits and len({norm(c.get("title")) for _, c in hits}) == 1:
        return hits[0]
    return None


def twins(chosen, all_cands, file_duration):
    """All candidates, from any endpoint and including chosen, that are the same scene."""
    key = scene_key(chosen[1])
    return [(ep, c) for ep, c in all_cands
            if scene_key(c) == key and duration_ok(c, file_duration)]


def describe(c):
    d = c.get("duration")
    return (f"title={c.get('title')!r}; studio={studio_name(c)!r}; "
            f"performers={[p['name'] for p in c.get('performers') or []]}; "
            f"date={c.get('date')}; code={c.get('code')}; "
            f"duration={f'{d}s' if d else 'unknown'}")


def _compact(d):
    return {k: v for k, v in d.items() if v not in (None, "", [])}


def _int(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def _float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _enum(v, allowed):
    v = (v or "").upper().replace(" ", "_").replace("-", "_")
    return v if v in allowed else None


def _aliases(v):
    return [a.strip() for a in (v or "").split(",") if a.strip()]


def stash_ids_for(endpoint, remote_id):
    return [{"endpoint": endpoint, "stash_id": remote_id}] if remote_id else []


def performer_create_input(p, endpoint):
    """ScrapedPerformer -> PerformerCreateInput, keeping every field stash-box returned."""
    images = p.get("images") or []
    return _compact({
        "name": p["name"], "disambiguation": p.get("disambiguation"),
        "gender": _enum(p.get("gender"), GENDERS), "urls": p.get("urls"),
        "birthdate": p.get("birthdate"), "death_date": p.get("death_date"),
        "ethnicity": p.get("ethnicity"), "country": p.get("country"),
        "eye_color": p.get("eye_color"), "hair_color": p.get("hair_color"),
        "height_cm": _int(p.get("height")), "weight": _int(p.get("weight")),
        "measurements": p.get("measurements"), "fake_tits": p.get("fake_tits"),
        "penis_length": _float(p.get("penis_length")),
        "circumcised": _enum(p.get("circumcised"), CIRCUMCISED),
        "career_start": p.get("career_start"), "career_end": p.get("career_end"),
        "tattoos": p.get("tattoos"), "piercings": p.get("piercings"),
        "alias_list": _aliases(p.get("aliases")), "details": p.get("details"),
        "image": images[0] if images else None,
        "stash_ids": stash_ids_for(endpoint, p.get("remote_site_id")),
    })


def studio_create_input(s, endpoint, parent_id=None):
    """ScrapedStudio -> StudioCreateInput."""
    return _compact({
        "name": s["name"], "urls": s.get("urls"), "image": s.get("image"),
        "details": s.get("details"), "aliases": _aliases(s.get("aliases")),
        "parent_id": parent_id,
        "stash_ids": stash_ids_for(endpoint, s.get("remote_site_id")),
    })


def alias_ok(name):
    """Single-word aliases are too ambiguous: "Vivian" is one of Kattie Gold's 34."""
    return len(name.split()) >= 2


def pick_by_name(records, name, alias_field, allow_alias):
    """records come from a q= search. Exact normalized name first; alias only if allowed."""
    n = norm(name)
    for r in records:
        if norm(r["name"]) == n:
            return r["id"]
    if allow_alias:
        for r in records:
            if any(norm(a) == n for a in r.get(alias_field) or []):
                return r["id"]
    return None


def _ids(objs):
    return [o["id"] for o in objs or []]


def _merge(existing, new):
    out = list(existing)
    for i in new:
        if i not in out:
            out.append(i)
    return out


def scrape_update(scene, primary, stash_ids, studio_id, performer_ids, tag_ids, drop_tag_ids):
    """SceneUpdateInput for a confirmed stash-box match. Fills empty fields only,
    except the cover, which replaces the generated screenshot."""
    up = {"id": scene["id"]}
    for k in ("title", "code", "details", "director", "date"):
        if primary.get(k) and not scene.get(k):
            up[k] = primary[k]
    if primary.get("urls") and not scene.get("urls"):
        up["urls"] = primary["urls"]
    if primary.get("image"):
        up["cover_image"] = primary["image"]
    if studio_id and not scene.get("studio"):
        up["studio_id"] = studio_id
    up["performer_ids"] = _merge(_ids(scene.get("performers")), performer_ids)
    up["tag_ids"] = [t for t in _merge(_ids(scene.get("tags")), tag_ids) if t not in drop_tag_ids]
    have = scene.get("stash_ids") or []
    seen = {(s["endpoint"], s["stash_id"]) for s in have}
    up["stash_ids"] = have + [s for s in stash_ids if (s["endpoint"], s["stash_id"]) not in seen]
    return up


def display_title(parse):
    """A scene title for an LLM parse, or None if there's nothing usable.

    Returns the parsed title unchanged when there is one. Otherwise, for a filename with
    no real title, builds a "Creator - date" style fallback: base is the series, studio,
    or first performer (in that order); suffix is date+time, date, a clip_id, or -- only
    when base came from a series -- the first performer's name. No suffix means no title:
    a bare creator name on its own isn't worth writing.
    """
    if parse.get("title"):
        return parse["title"]
    performers = parse.get("performers") or []
    series = parse.get("series")
    base = series or parse.get("studio") or (performers[0] if performers else None)
    if not base:
        return None
    date, time, clip_id = parse.get("date"), parse.get("time"), parse.get("clip_id")
    if date and time:
        suffix = f"{date} {time}"
    elif date:
        suffix = date
    elif clip_id:
        suffix = clip_id
    elif series and performers:
        suffix = performers[0]
    else:
        suffix = None
    return f"{base} – {suffix}" if suffix else None


def llm_update(scene, parse, studio_id, performer_ids, llm_tag_id):
    """SceneUpdateInput for an unconfirmed filename guess, tagged for later review."""
    up = {"id": scene["id"]}
    title = display_title(parse)
    if title and not scene.get("title"):
        up["title"] = title
    if parse.get("date") and not scene.get("date"):
        up["date"] = parse["date"]
    if studio_id and not scene.get("studio"):
        up["studio_id"] = studio_id
    up["performer_ids"] = _merge(_ids(scene.get("performers")), performer_ids)
    up["tag_ids"] = _merge(_ids(scene.get("tags")), [llm_tag_id])
    return up


def jev_request(path, duration, parse, cands):
    """(state, questions) for a Jev choice over duration-filtered candidates."""
    criteria = {f"c{i}": describe(c) for i, (_, c) in enumerate(cands)}
    criteria["none"] = "None of the candidates is this exact scene."
    state = {"file_path": path, "file_duration_seconds": round(duration), "filename_parse": parse}
    return state, {"match": {"type": "choice", "instructions": JEV_INSTRUCTIONS,
                             "criteria": criteria}}


def jev_pick(answer, cands):
    choice = answer["choice"]
    return None if choice == "none" else cands[int(choice[1:])]
