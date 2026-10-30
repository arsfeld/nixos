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
# Each class as the page shows it: its name (badge and Production filter) and daisyUI color.
LABEL = {"amateur": ("amateur", "badge-success"), "pro_artistic": ("artistic", "badge-info"),
         "industrial": ("industrial", "badge-neutral")}


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
    if t["images"] is None:
        # A live search result: plab fetches the topic page when the thumbnail scrolls into view.
        thumb = (f'<img class="thumb w-full h-full object-cover cursor-zoom-in" loading="lazy" '
                 f'src="thumb/{t["id"]}" x-show="!thumbFailed" @error="thumbFailed = true" '
                 f'@click="openTopicGallery({t["id"]})" alt="">'
                 '<div class="thumb none w-full h-full" x-show="thumbFailed" x-cloak></div>')
    elif t["images"]:
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
    prod, color = LABEL.get(_production(t), ("", ""))
    production = (f'<span class="production badge {color} font-bold absolute bottom-2 right-2 z-[1]">{prod}</span>'
                  if prod else "")
    fresh = now - t["added"] < 86400
    if fresh:
        date = f'<span class="fresh text-warning font-bold">uploaded {age(t["added"], now)}</span>'
        badge = f'<span class="fresh-badge badge badge-warning font-bold absolute top-2 right-2 z-[1]">{_fresh_short(t["added"], now)}</span>'
    else:
        date = time.strftime("%Y-%m-%d", time.gmtime(t["added"]))
        badge = ""
    filters = t.get("filters") or []
    # The title in its parts: studio and quality above the release's own name, tags as pills
    # that filter by that tag (the full title stays as the link's tooltip).
    head = "".join((
        f'<span class="studio font-semibold uppercase tracking-wide text-primary">{e(lab["studio"])}</span>'
        if lab["studio"] else "",
        f'<span class="quality badge badge-xs badge-outline">{e(lab["quality"])}</span>' if lab["quality"] else ""))
    head = f'<div class="flex flex-wrap items-center gap-2 text-xs">{head}</div>' if head else ""
    pills = "".join(
        f'<button type="button" class="badge badge-sm badge-outline cursor-pointer" '
        f':class="{{ \'badge-primary\': st.tags.includes({e(json.dumps(tag))}) }}" '
        f'@click="toggleTag({e(json.dumps(tag))})">{e(tag)}</button>' for tag in lab["tags"])
    pills = f'<div class="tags flex flex-wrap gap-1">{pills}</div>' if pills else ""
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
            f'<figure class="relative aspect-[16/10] bg-black"><span x-show="isNew" class="new badge badge-accent badge-lg font-bold absolute top-2 left-2 z-[1]">NEW</span>{badge}{production}{thumb}</figure>'
            '<div class="card-body p-3 gap-2">'
            f'{head}<a class="title link link-hover font-semibold break-words" href="{TOPIC_URL % t["id"]}" '
            f'target="_blank" rel="noreferrer" title="{e(t["title"])}">{e(lab["name"])}</a>{pills}'
            f'<div class="meta text-xs text-base-content/60">{size(t["size"])} · ▲ {t["seeders"]} ▼ {t["leechers"]} · {date}</div>'
            f'<div class="card-actions mt-auto items-center">{button}</div></div></div>')


def _options(counter):
    """<option>s for a select: "All", then values by count descending (ties alphabetical)."""
    e = html.escape
    rows = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    return '<option value="">All</option>' + "".join(
        f'<option value="{e(v)}">{e(v)} ({n})</option>' for v, n in rows)


def _select(key_, name, options):
    """A daisyUI select carrying its name, so a closed dropdown still says what it filters."""
    return (f'<label class="select select-sm w-auto max-w-full"><span class="label">{name}</span>'
            f'<select data-key="{key_}" aria-label="{name}" x-model="st.{key_}">{options}</select></label>')


def _search_form(query):
    """The live search box; a results page shows its query in it."""
    return ('<form method="get" action="search" class="join" role="search">'
            '<input class="input input-sm join-item w-48" type="search" name="q" '
            f'value="{html.escape(query)}" placeholder="Search the tracker" required>'
            '<button class="btn btn-sm join-item">Search</button></form>')


def _filter_bar(labs, filters, query="", search=False):
    e = html.escape
    tags = Counter(tag for lab in labs for tag in lab["tags"])
    top = sorted(tags.items(), key=lambda kv: (-kv[1], kv[0]))[:20]
    toggles = (("h24", "Last 24h"), ("hide", "Hide added")) if search else \
        (("h24", "Last 24h"), ("new", "New"), ("hide", "Hide added"))
    toggle_bar = ('<div class="join">' + "".join(
        f'<button type="button" class="btn btn-sm join-item" data-toggle="{k}" '
        f':class="{{ \'btn-primary\': st.{k} }}" @click="toggle(\'{k}\')">{name}</button>'
        for k, name in toggles) + '</div>')
    fields = (("prod", "production", "Production"), ("cat", "category", "Category"),
              ("studio", "studio", "Studio"), ("q", "quality", "Quality"))
    if search:  # search results are not classified by production
        fields = fields[1:]
    selects = [_select(k, name, _options(Counter(lab[field] for lab in labs if lab[field])))
               for k, field, name in fields]
    # The curated filters, named in the filter file, in file order; at most one is active.
    if filters:
        counts = Counter(n for lab in labs for n in lab["filters"])
        selects.insert(1, _select("f", "Curated", '<option value="">All</option>' + "".join(
            f'<option value="{e(n)}">{e(n)} ({counts[n]})</option>' for n in filters)))
    # Tags are the least used filter, so they live behind a dropdown.
    chips = "".join(f'<button type="button" class="btn btn-xs" data-tag="{e(t)}" '
                    f':class="{{ \'btn-primary\': st.tags.includes(\'{e(t)}\') }}" '
                    f'@click="toggleTag(\'{e(t)}\')">{e(t)}'
                    f'<span class="badge badge-xs">{n}</span></button>' for t, n in top)
    datalist = "".join(f'<option value="{e(t)}">' for t in sorted(tags))
    tag_menu = ('<details class="dropdown">'
                '<summary class="btn btn-sm">Tags<span class="badge badge-sm badge-primary" '
                'x-show="st.tags.length" x-text="st.tags.length"></span></summary>'
                '<div class="dropdown-content z-20 mt-1 w-80 max-w-[90vw] rounded-box bg-base-200 p-3 shadow-lg '
                'flex flex-col gap-2">'
                '<input id="tagin" class="input input-sm w-full" list="taglist" placeholder="type a tag" '
                'autocomplete="off" @keydown.enter.prevent="addTyped($el)" @input="onTagInput($el)">'
                f'<datalist id="taglist">{datalist}</datalist>'
                f'<div id="chips" class="flex flex-wrap gap-1 max-h-48 overflow-y-auto">{chips}</div>'
                '</div></details>')
    selected_tags = ('<span id="seltags" class="flex flex-wrap gap-1">'
                     '<template x-for="t in st.tags" :key="t">'
                     '<button type="button" class="badge badge-primary cursor-pointer" @click="toggleTag(t)" '
                     'x-text="t + \' ×\'"></button></template></span>')
    return ('<div id="filters" class="sm:sticky top-0 z-10 bg-base-100 py-2 mb-4 border-b border-base-300 '
            'flex flex-wrap items-center gap-2">'
            f'{_search_form(query)}{toggle_bar}{"".join(selects)}{tag_menu}{selected_tags}'
            '<button type="button" id="clear" class="btn btn-ghost btn-sm" @click="clearFilters()">Clear</button>'
            f'<span id="count" class="ml-auto text-sm text-base-content/60" '
            f'x-text="\'Showing \' + shownCount + \' of \' + cards.length">Showing {len(labs)} of {len(labs)}</span>'
            '</div>')


def render(cache, added, queued, now, search=None):
    pending = len(queued - added)
    # sorted() is stable with reverse=True too: equal scores keep the tracker's order.
    topics = sorted(cache["topics"], key=score, reverse=True)
    labs = [{**labels(t["title"], t["forum"]), "production": LABEL.get(_production(t), ("",))[0],
             "filters": t.get("filters") or []} for t in topics]
    curated_n = sum(1 for t in topics if t.get("filters"))
    curated_sub = f" · {curated_n} curated" if curated_n else ""
    if search:
        n = len(topics)
        status = (f'<span class="text-error">{html.escape(search["error"])}</span>' if search.get("error")
                  else f'{n} result{"" if n == 1 else "s"} for “{html.escape(search["query"])}” · all time')
        summary = f'<a class="link link-hover" href="./">← weekly list</a> · {status}'
    else:
        summary = (f"{len(topics)} releases · last 7 days · updated {age(cache['updated'], now)}"
                   f"{curated_sub}{f' · {pending} queued' if pending else ''}"
                   "<span id=\"newcount\" x-show=\"newCount > 0\" x-text=\"' · ' + newCount + ' new'\"></span>")
    search_attr = ' data-search="1"' if search else ""
    cards = "".join(_card(t, lab, added, queued, now) for t, lab in zip(topics, labs))
    # The stylesheets and the Tailwind runtime are served by plab itself from
    # PLAB_STATIC_DIR (vendored at build time); without them the page still works, unstyled.
    return ("<!doctype html><html data-theme=\"luxury\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<meta name=\"referrer\" content=\"no-referrer\">"
            "<title>plab</title>"
            "<link rel=\"stylesheet\" href=\"static/daisyui.css\">"
            "<link rel=\"stylesheet\" href=\"static/themes.css\">"
            "<script src=\"static/tailwind.js\"></script>"
            "<script defer src=\"static/alpine.js\"></script>"
            f"<style>{CSS}</style></head>"
            "<body class=\"min-h-screen bg-base-100 text-base-content p-4 overflow-x-hidden\" x-data=\"plabApp\""
            f"{search_attr}>"
            "<header class=\"navbar min-h-0 p-0 mb-2 flex-wrap items-baseline gap-x-4 gap-y-1\">"
            "<h1 class=\"text-xl font-bold\">plab</h1>"
            f"<span class=\"text-sm text-base-content/60\">{summary}</span></header>"
            f"{_filter_bar(labs, cache.get('filters') or [], search['query'] if search else '', bool(search))}"
            "<div id=\"grid\" class=\"grid gap-4 grid-cols-[repeat(auto-fill,minmax(min(280px,100%),1fr))]\">"
            f"{cards}</div>"
            "<dialog id=\"ov\" x-ref=\"modal\" class=\"modal\" @click=\"closeGallery()\">"
            "<div class=\"modal-box w-11/12 max-w-5xl p-2 cursor-zoom-out\" @click.stop=\"closeGallery()\">"
            "<template x-for=\"img in modalImages\" :key=\"img\">"
            "<img class=\"block mx-auto mb-3 max-w-full\" loading=\"lazy\" :src=\"'img/' + img\">"
            "</template></div><form method=\"dialog\" class=\"modal-backdrop\"><button>close</button></form></dialog>"
            f"<script>{JS}{FILTER_JS}</script></body></html>")
