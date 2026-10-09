"""Renders the card grid from the cache. Pure: no I/O, all data passed in."""
import html
import json
import time

from store import key

TOPIC_URL = "https://pornolab.net/forum/viewtopic.php?t=%d"

CSS = """
:root { color-scheme: dark; --bg: #111; --card: #1c1c1c; --fg: #ddd; --dim: #888; --accent: #4a9; }
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg); font: 14px/1.4 system-ui, sans-serif; }
header { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 16px; }
h1 { font-size: 20px; margin: 0; }
.dim { color: var(--dim); }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }
.card { background: var(--card); border-radius: 8px; overflow: hidden; display: flex; flex-direction: column; }
.thumb { width: 100%; aspect-ratio: 16 / 10; object-fit: cover; cursor: zoom-in; background: #000; display: block; }
.thumb.none { cursor: default; }
.body { padding: 10px; display: flex; flex-direction: column; gap: 6px; flex: 1; }
.title { color: var(--fg); text-decoration: none; word-break: break-word; }
.title:hover { text-decoration: underline; }
.meta { color: var(--dim); font-size: 12px; }
.actions { margin-top: auto; display: flex; gap: 8px; align-items: center; }
button.add { background: var(--accent); color: #000; border: 0; border-radius: 4px; padding: 6px 12px; font-weight: 600; cursor: pointer; }
button.add:disabled { background: #333; color: var(--dim); cursor: default; }
.err { color: #e66; font-size: 12px; }
#ov { position: fixed; inset: 0; background: rgba(0, 0, 0, .92); overflow-y: auto; padding: 16px; text-align: center; cursor: zoom-out; }
#ov img { max-width: 100%; margin: 0 auto 12px; display: block; }
"""

JS = """
document.querySelectorAll('button.add').forEach(b => b.onclick = async () => {
  const err = b.nextElementSibling;
  b.disabled = true; b.textContent = 'Adding…'; err.textContent = '';
  try {
    const r = await fetch('add/' + b.dataset.id, {method: 'POST'});
    let j;
    try { j = await r.json(); } catch (_) { throw new Error('HTTP ' + r.status + ' — reload the page'); }
    if (!j.ok) throw new Error(j.error);
    if (j.queued) { b.textContent = 'Queued ⏳'; err.textContent = j.message; b.disabled = true; return; }
    b.textContent = 'Added ✓';
  } catch (e) {
    b.disabled = false; b.textContent = 'Retry'; err.textContent = e.message;
  }
});
const ov = document.getElementById('ov');
document.querySelectorAll('img.thumb[data-images]').forEach(i => i.onclick = () => {
  ov.innerHTML = JSON.parse(i.dataset.images).map(k => '<img loading="lazy" src="img/' + k + '">').join('');
  ov.hidden = false;
});
ov.onclick = () => { ov.hidden = true; ov.innerHTML = ''; };
"""


def size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n} B" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def age(updated, now):
    if not updated:
        return "never"
    minutes = int((now - updated) // 60)
    return f"{minutes} min ago" if minutes < 60 else f"{minutes // 60} h ago"


def _card(t, added, queued):
    e = html.escape
    if t["images"]:
        keys = [key(u) for u in t["images"]]
        thumb = f'<img class="thumb" loading="lazy" src="img/{keys[0]}" data-images="{e(json.dumps(keys))}" alt="">'
    else:
        thumb = '<div class="thumb none"></div>'
    label = "Added ✓" if t["id"] in added else "Queued ⏳" if t["id"] in queued else None
    button = (f'<button class="add" data-id="{t["id"]}"{" disabled" if label else ""}>'
              f'{label or "Add to Vault"}</button><span class="err"></span>')
    date = time.strftime("%Y-%m-%d", time.gmtime(t["added"]))
    return (f'<div class="card">{thumb}<div class="body">'
            f'<a class="title" href="{TOPIC_URL % t["id"]}" target="_blank" rel="noreferrer">{e(t["title"])}</a>'
            f'<div class="meta">{size(t["size"])} · ▲ {t["seeders"]} ▼ {t["leechers"]} · {date}</div>'
            f'<div class="actions">{button}</div></div></div>')


def render(cache, added, queued, now):
    pending = len(queued - added)
    cards = "".join(_card(t, added, queued) for t in cache["topics"])
    return ("<!doctype html><html><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<meta name=\"referrer\" content=\"no-referrer\">"
            f"<title>plab</title><style>{CSS}</style></head><body>"
            f"<header><h1>plab</h1><span class=\"dim\">{len(cache['topics'])} releases · last 7 days · "
            f"updated {age(cache['updated'], now)}{f' · {pending} queued' if pending else ''}</span></header>"
            f"<div class=\"grid\">{cards}</div><div id=\"ov\" hidden></div>"
            f"<script>{JS}</script></body></html>")
