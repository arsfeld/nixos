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


# Button classes; the JS in assets.py swaps btn-primary and btn-warning on state changes.
ADD_BTN = "add btn btn-sm btn-primary"
QUEUED_BTN = "add queued btn btn-sm btn-warning"


def _card(t, lab, added, queued, now):
    e = html.escape
    if t["images"]:
        keys = [key(u) for u in t["images"]]
        thumb = (f'<img class="thumb w-full h-full object-cover cursor-zoom-in" loading="lazy" '
                 f'src="img/{keys[0]}" data-images="{e(json.dumps(keys))}" alt="">')
    else:
        thumb = '<div class="thumb none w-full h-full"></div>'
    if t["id"] in added:
        cls, attrs, label, state = ADD_BTN, " disabled", "Added ✓", "added"
    elif t["id"] in queued:
        cls, attrs, label, state = QUEUED_BTN, ' title="Click to remove from queue"', "Queued ⏳", "queued"
    else:
        cls, attrs, label, state = ADD_BTN, "", "Add to Vault", ""
    button = (f'<button class="{cls}" data-id="{t["id"]}"{attrs}>'
              f'{label}</button><span class="err text-xs text-error"></span>')
    fresh = now - t["added"] < 86400
    if fresh:
        date = f'<span class="fresh text-warning font-bold">uploaded {age(t["added"], now)}</span>'
        badge = f'<span class="fresh-badge badge badge-warning font-bold absolute top-2 right-2 z-[1]">{_fresh_short(t["added"], now)}</span>'
    else:
        date = time.strftime("%Y-%m-%d", time.gmtime(t["added"]))
        badge = ""
    data = {"tags": "|".join(lab["tags"]), "quality": lab["quality"] or "", "studio": lab["studio"] or "",
            "category": lab["category"], "fresh": "1" if fresh else "", "state": state}
    attrs_data = "".join(f' data-{k}="{e(v)}"' for k, v in data.items())
    return (f'<div class="card bg-base-200 shadow-sm overflow-hidden"{attrs_data}>'
            f'<figure class="relative aspect-[16/10] bg-black">{badge}{thumb}</figure>'
            '<div class="card-body p-3 gap-2">'
            f'<a class="title link link-hover break-words" href="{TOPIC_URL % t["id"]}" target="_blank" '
            f'rel="noreferrer">{e(t["title"])}</a>'
            f'<div class="meta text-xs text-base-content/60">{size(t["size"])} · ▲ {t["seeders"]} ▼ {t["leechers"]} · {date}</div>'
            f'<div class="card-actions mt-auto items-center">{button}</div></div></div>')


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
        f'<select class="select select-sm w-auto max-w-full" data-key="{key_}" aria-label="{name}" title="{name}">'
        f'{_options(Counter(lab[field] for lab in labs if lab[field]))}</select>'
        for key_, field, name in (("cat", "category", "Category"), ("q", "quality", "Quality"),
                                  ("studio", "studio", "Studio")))
    chips = "".join(f'<button type="button" class="btn btn-xs" data-tag="{e(t)}">{e(t)}'
                    f'<span class="badge badge-xs">{n}</span></button>' for t, n in top)
    datalist = "".join(f'<option value="{e(t)}">' for t in sorted(tags))
    toggles = "".join(f'<button type="button" class="btn btn-sm" data-toggle="{k}">{name}</button>'
                      for k, name in (("h24", "Last 24h"), ("new", "New only"), ("hide", "Hide added/queued")))
    row = "flex flex-wrap items-center gap-2"
    return ('<div id="filters" class="sm:sticky top-0 z-10 bg-base-100 py-2 mb-4 border-b border-base-300 '
            'flex flex-col gap-2">'
            f'<div class="{row}">{toggles}{selects}</div>'
            f'<div id="chips" class="{row} max-h-[5.5em] overflow-y-auto">{chips}</div>'
            f'<div class="{row}"><span id="seltags" class="{row}"></span>'
            '<input id="tagin" class="input input-sm w-40" list="taglist" placeholder="add tag" autocomplete="off">'
            f'<datalist id="taglist">{datalist}</datalist>'
            '<button type="button" id="clear" class="btn btn-ghost btn-sm">Clear</button>'
            f'<span id="count" class="ml-auto text-sm text-base-content/60">Showing {len(labs)} of {len(labs)}</span>'
            '</div></div>')


def render(cache, added, queued, now):
    pending = len(queued - added)
    topics = cache["topics"]
    labs = [labels(t["title"], t["forum"]) for t in topics]
    cards = "".join(_card(t, lab, added, queued, now) for t, lab in zip(topics, labs))
    # The stylesheets and the Tailwind runtime are served by plab itself from
    # PLAB_STATIC_DIR (vendored at build time); without them the page still works, unstyled.
    return ("<!doctype html><html data-theme=\"dim\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<meta name=\"referrer\" content=\"no-referrer\">"
            "<title>plab</title>"
            "<link rel=\"stylesheet\" href=\"static/daisyui.css\">"
            "<link rel=\"stylesheet\" href=\"static/themes.css\">"
            "<script src=\"static/tailwind.js\"></script>"
            f"<style>{CSS}</style></head>"
            "<body class=\"min-h-screen bg-base-100 text-base-content p-4 overflow-x-hidden\">"
            "<header class=\"navbar min-h-0 p-0 mb-2 flex-wrap items-baseline gap-x-4 gap-y-1\">"
            "<h1 class=\"text-xl font-bold\">plab</h1>"
            f"<span class=\"text-sm text-base-content/60\">{len(topics)} releases · last 7 days · "
            f"updated {age(cache['updated'], now)}{f' · {pending} queued' if pending else ''}"
            "<span id=\"newcount\"></span></span></header>"
            f"{_filter_bar(labs)}"
            "<div id=\"grid\" class=\"grid gap-4 grid-cols-[repeat(auto-fill,minmax(min(280px,100%),1fr))]\">"
            f"{cards}</div>"
            "<dialog id=\"ov\" class=\"modal\"><div class=\"modal-box w-11/12 max-w-5xl p-2 cursor-zoom-out\">"
            "</div><form method=\"dialog\" class=\"modal-backdrop\"><button>close</button></form></dialog>"
            f"<script>{JS}{FILTER_JS}</script></body></html>")
