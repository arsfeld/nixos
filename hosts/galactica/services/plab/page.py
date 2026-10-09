"""Renders the card grid from the cache. Pure: no I/O, all data passed in."""
import html
import json
import time
from collections import Counter

from assets import CSS, FILTER_JS, JS
from labels import labels
from store import key

TOPIC_URL = "https://pornolab.net/forum/viewtopic.php?t=%d"

def size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n} B" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def age(updated, now):
    if not updated:
        return "never"
    minutes = max(0, int((now - updated) // 60))
    return f"{minutes} min ago" if minutes < 60 else f"{minutes // 60} h ago"


def _fresh_short(updated, now):
    minutes = max(0, int((now - updated) // 60))
    return f"{minutes}m" if minutes < 60 else f"{minutes // 60}h"


def _card(t, lab, added, queued, now):
    e = html.escape
    if t["images"]:
        keys = [key(u) for u in t["images"]]
        thumb = f'<img class="thumb" loading="lazy" src="img/{keys[0]}" data-images="{e(json.dumps(keys))}" alt="">'
    else:
        thumb = '<div class="thumb none"></div>'
    if t["id"] in added:
        cls, attrs, label, state = "add", " disabled", "Added ✓", "added"
    elif t["id"] in queued:
        cls, attrs, label, state = "add queued", ' title="Click to remove from queue"', "Queued ⏳", "queued"
    else:
        cls, attrs, label, state = "add", "", "Add to Vault", ""
    button = (f'<button class="{cls}" data-id="{t["id"]}"{attrs}>'
              f'{label}</button><span class="err"></span>')
    fresh = now - t["added"] < 86400
    if fresh:
        date = f'<span class="fresh">uploaded {age(t["added"], now)}</span>'
        badge = f'<span class="badge fresh-badge">{_fresh_short(t["added"], now)}</span>'
    else:
        date = time.strftime("%Y-%m-%d", time.gmtime(t["added"]))
        badge = ""
    data = {"tags": "|".join(lab["tags"]), "quality": lab["quality"] or "", "studio": lab["studio"] or "",
            "category": lab["category"], "fresh": "1" if fresh else "", "state": state}
    attrs_data = "".join(f' data-{k}="{e(v)}"' for k, v in data.items())
    return (f'<div class="card"{attrs_data}>{badge}{thumb}<div class="body">'
            f'<a class="title" href="{TOPIC_URL % t["id"]}" target="_blank" rel="noreferrer">{e(t["title"])}</a>'
            f'<div class="meta">{size(t["size"])} · ▲ {t["seeders"]} ▼ {t["leechers"]} · {date}</div>'
            f'<div class="actions">{button}</div></div></div>')


def _options(counter):
    """<option>s for a select: "All", then values by count descending (ties alphabetical)."""
    e = html.escape
    rows = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    return '<option value="">All</option>' + "".join(
        f'<option value="{e(v)}">{e(v)} ({n})</option>' for v, n in rows)


def _filter_bar(labs):
    e = html.escape
    tags = Counter(tag for lab in labs for tag in lab["tags"])
    top = sorted(tags.items(), key=lambda kv: (-kv[1], kv[0]))[:20]
    selects = "".join(
        f'<select data-key="{key_}" aria-label="{name}" title="{name}">'
        f'{_options(Counter(lab[field] for lab in labs if lab[field]))}</select>'
        for key_, field, name in (("cat", "category", "Category"), ("q", "quality", "Quality"),
                                  ("studio", "studio", "Studio")))
    chips = "".join(f'<button type="button" data-tag="{e(t)}">{e(t)}<i>{n}</i></button>' for t, n in top)
    datalist = "".join(f'<option value="{e(t)}">' for t in sorted(tags))
    return ('<div id="filters">'
            '<div class="frow">'
            '<button type="button" data-toggle="h24">Last 24h</button>'
            '<button type="button" data-toggle="new">New only</button>'
            '<button type="button" data-toggle="hide">Hide added/queued</button>'
            f'{selects}</div>'
            f'<div class="frow" id="chips">{chips}</div>'
            '<div class="frow"><span id="seltags" class="frow"></span>'
            '<input id="tagin" list="taglist" placeholder="add tag" autocomplete="off">'
            f'<datalist id="taglist">{datalist}</datalist>'
            '<button type="button" id="clear">Clear</button>'
            f'<span id="count" class="dim">Showing {len(labs)} of {len(labs)}</span></div>'
            '</div>')


def render(cache, added, queued, now):
    pending = len(queued - added)
    topics = cache["topics"]
    labs = [labels(t["title"], t["forum"]) for t in topics]
    cards = "".join(_card(t, lab, added, queued, now) for t, lab in zip(topics, labs))
    return ("<!doctype html><html><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<meta name=\"referrer\" content=\"no-referrer\">"
            f"<title>plab</title><style>{CSS}</style></head><body>"
            f"<header><h1>plab</h1><span class=\"dim\">{len(topics)} releases · last 7 days · "
            f"updated {age(cache['updated'], now)}{f' · {pending} queued' if pending else ''}<span id=\"newcount\"></span></span></header>"
            f"{_filter_bar(labs)}"
            f"<div class=\"grid\">{cards}</div><div id=\"ov\" hidden></div>"
            f"<script>{JS}{FILTER_JS}</script></body></html>")
