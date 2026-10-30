"""Renders the card grid from the cache. Pure: no I/O, all data passed in."""
import html
import json
import time
from collections import Counter

from assets import CSS, FILTER_JS, JS
from labels import labels
from store import key

TOPIC_URL = "https://pornolab.net/forum/viewtopic.php?t=%d"

# Seeders count for more or less by how the release was produced (classify.py), so
# gonzo-factory releases sink below amateur and artistic ones. Unclassified counts as 1.0.
WEIGHT = {"amateur": 1.5, "pro_artistic": 1.0, "industrial": 0.25}
# Each class as the page shows it: its name (badge and Production filter), icon and daisyUI color.
LABEL = {"amateur": ("amateur", "🏠", "badge-success"), "pro_artistic": ("artistic", "🎨", "badge-info"),
         "industrial": ("industrial", "🏭", "badge-neutral")}


def _production(t):
    return (t.get("production") or {}).get("class")


def score(t):
    return t["seeders"] * WEIGHT.get(_production(t), 1.0)


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
        keys_json = e(json.dumps(keys))
        thumb = (f'<img class="thumb w-full h-full object-cover cursor-zoom-in" loading="lazy" '
                 f'src="img/{keys[0]}" data-images="{keys_json}" @click="openGallery({keys_json})" alt="">')
    else:
        thumb = '<div class="thumb none w-full h-full"></div>'
    if t["id"] in added:
        cls, attrs, label, state = ADD_BTN, " disabled", "Added ✓", "added"
    elif t["id"] in queued:
        cls, attrs, label, state = QUEUED_BTN, ' title="Click to remove from queue"', "Queued ⏳", "queued"
    else:
        cls, attrs, label, state = ADD_BTN, "", "Add to Vault", ""
    button = (f'<button class="{cls}" data-id="{t["id"]}"{attrs} :class="btnClass" '
              ':disabled="loading || state === \'added\'" '
              ':title="state === \'queued\' ? \'Click to remove from queue\' : \'\'" '
              '@mouseenter="hoverQueued = (state === \'queued\' && !loading)" '
              '@mouseleave="hoverQueued = false" '
              '@click="toggleAdd()">'
              f'<span x-text="btnLabel">{label}</span></button>'
              '<span class="err text-xs text-error" x-text="error"></span>')
    name, icon, color = LABEL.get(_production(t), ("", "", ""))
    production = (f'<span class="production badge {color} font-bold absolute bottom-2 right-2 z-[1]">{icon} {name}</span>'
                  if name else "")
    fresh = now - t["added"] < 86400
    if fresh:
        date = f'<span class="fresh text-warning font-bold">uploaded {age(t["added"], now)}</span>'
        badge = f'<span class="fresh-badge badge badge-warning font-bold absolute top-2 right-2 z-[1]">{_fresh_short(t["added"], now)}</span>'
    else:
        date = time.strftime("%Y-%m-%d", time.gmtime(t["added"]))
        badge = ""
    filters = t.get("filters") or []
    reason = t.get("curated_reason")
    curated_badge = (f'<span class="badge badge-secondary font-bold absolute bottom-2 left-2 z-[1]">{e(reason)}</span>'
                     if filters and reason else "")
    data = {"tags": "|".join(lab["tags"]), "quality": lab["quality"] or "", "studio": lab["studio"] or "",
            "category": lab["category"], "production": lab["production"], "fresh": "1" if fresh else "", "state": state,
            "curated": "1" if filters else ""}
    attrs_data = "".join(f' data-{k}="{e(v)}"' for k, v in data.items())
    cfg = json.dumps({
        "id": t["id"],
        "fresh": fresh,
        "filters": filters,
        "cat": lab["category"],
        "q": lab["quality"] or "",
        "studio": lab["studio"] or "",
        "prod": lab["production"],
        "tags": lab["tags"],
        "initialState": state,
    })
    return (f'<div class="card bg-base-200 shadow-sm overflow-hidden"{attrs_data} '
            f'x-data="plabCard({e(cfg)})" x-show="isVisible($data)" '
            ':class="{ \'is-new ring-2 ring-(--color-accent)\': isNew }">'
            f'<figure class="relative aspect-[16/10] bg-black"><span x-show="isNew" class="new badge badge-accent badge-lg font-bold absolute top-2 left-2 z-[1]">NEW</span>{badge}{curated_badge}{production}{thumb}</figure>'
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


def _filter_bar(labs, filters):
    e = html.escape
    tags = Counter(tag for lab in labs for tag in lab["tags"])
    top = sorted(tags.items(), key=lambda kv: (-kv[1], kv[0]))[:20]
    selects = "".join(
        f'<select class="select select-sm w-auto max-w-full" data-key="{key_}" aria-label="{name}" title="{name}" '
        f'x-model="st.{key_}">'
        f'{_options(Counter(lab[field] for lab in labs if lab[field]))}</select>'
        for key_, field, name in (("cat", "category", "Category"), ("q", "quality", "Quality"),
                                  ("studio", "studio", "Studio"), ("prod", "production", "Production")))
    chips = "".join(f'<button type="button" class="btn btn-xs" data-tag="{e(t)}" '
                    f':class="{{ \'btn-primary\': st.tags.includes(\'{e(t)}\') }}" '
                    f'@click="toggleTag(\'{e(t)}\')">{e(t)}'
                    f'<span class="badge badge-xs">{n}</span></button>' for t, n in top)
    datalist = "".join(f'<option value="{e(t)}">' for t in sorted(tags))
    toggles = "".join(f'<button type="button" class="btn btn-sm" data-toggle="{k}" '
                      f':class="{{ \'btn-primary\': st.{k} }}" '
                      f'@click="toggle(\'{k}\')">{name}</button>'
                      for k, name in (("h24", "Last 24h"), ("new", "New only"), ("hide", "Hide added/queued")))
    # One button per curated filter, named in the filter file; at most one is active.
    toggles += "".join(f'<button type="button" class="btn btn-sm" data-filter="{e(n)}" '
                       f':class="{{ \'btn-secondary\': st.f === {e(json.dumps(n))} }}" '
                       f'@click="pick({e(json.dumps(n))})">{e(n)}</button>' for n in filters)
    row = "flex flex-wrap items-center gap-2"
    selected_tags = (
        '<template x-for="t in st.tags" :key="t">'
        '<button type="button" class="btn btn-xs btn-primary" @click="toggleTag(t)" x-text="t + \' ×\'"></button>'
        '</template>'
    )
    return ('<div id="filters" class="sm:sticky top-0 z-10 bg-base-100 py-2 mb-4 border-b border-base-300 '
            'flex flex-col gap-2">'
            f'<div class="{row}">{toggles}{selects}</div>'
            f'<div id="chips" class="{row} max-h-[5.5em] overflow-y-auto">{chips}</div>'
            f'<div class="{row}"><span id="seltags" class="{row}">{selected_tags}</span>'
            '<input id="tagin" class="input input-sm w-40" list="taglist" placeholder="add tag" autocomplete="off" '
            '@keydown.enter.prevent="addTyped($el)" @input="onTagInput($el)">'
            f'<datalist id="taglist">{datalist}</datalist>'
            '<button type="button" id="clear" class="btn btn-ghost btn-sm" @click="clearFilters()">Clear</button>'
            f'<span id="count" class="ml-auto text-sm text-base-content/60" x-text="\'Showing \' + shownCount + \' of \' + cards.length">Showing {len(labs)} of {len(labs)}</span>'
            '</div></div>')


def render(cache, added, queued, now):
    pending = len(queued - added)
    # sorted() is stable with reverse=True too: equal scores keep the tracker's order.
    topics = sorted(cache["topics"], key=score, reverse=True)
    labs = [{**labels(t["title"], t["forum"]), "production": LABEL.get(_production(t), ("",))[0]}
            for t in topics]
    curated_n = sum(1 for t in topics if t.get("filters"))
    curated_sub = f" · {curated_n} curated" if curated_n else ""
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
            "<script defer src=\"static/alpine.js\"></script>"
            f"<style>{CSS}</style></head>"
            "<body class=\"min-h-screen bg-base-100 text-base-content p-4 overflow-x-hidden\" x-data=\"plabApp\">"
            "<header class=\"navbar min-h-0 p-0 mb-2 flex-wrap items-baseline gap-x-4 gap-y-1\">"
            "<h1 class=\"text-xl font-bold\">plab</h1>"
            f"<span class=\"text-sm text-base-content/60\">{len(topics)} releases · last 7 days · "
            f"updated {age(cache['updated'], now)}{curated_sub}{f' · {pending} queued' if pending else ''}"
            "<span id=\"newcount\" x-show=\"newCount > 0\" x-text=\"' · ' + newCount + ' new'\"></span></span></header>"
            f"{_filter_bar(labs, cache.get('filters') or [])}"
            "<div id=\"grid\" class=\"grid gap-4 grid-cols-[repeat(auto-fill,minmax(min(280px,100%),1fr))]\">"
            f"{cards}</div>"
            "<dialog id=\"ov\" x-ref=\"modal\" class=\"modal\" @click=\"closeGallery()\">"
            "<div class=\"modal-box w-11/12 max-w-5xl p-2 cursor-zoom-out\" @click.stop=\"closeGallery()\">"
            "<template x-for=\"img in modalImages\" :key=\"img\">"
            "<img class=\"block mx-auto mb-3 max-w-full\" loading=\"lazy\" :src=\"'img/' + img\">"
            "</template></div><form method=\"dialog\" class=\"modal-backdrop\"><button>close</button></form></dialog>"
            f"<script>{JS}{FILTER_JS}</script></body></html>")
