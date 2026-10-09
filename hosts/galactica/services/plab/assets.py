"""The page's static CSS and JS, kept apart from the renderer in page.py."""

CSS = """
:root { color-scheme: dark; --bg: #111; --card: #1c1c1c; --fg: #ddd; --dim: #888; --accent: #4a9; --fresh: #f90; }
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg); font: 14px/1.4 system-ui, sans-serif; overflow-x: hidden; }
header { display: flex; flex-wrap: wrap; gap: 4px 16px; justify-content: space-between; align-items: baseline; margin-bottom: 12px; }
h1 { font-size: 20px; margin: 0; }
.dim { color: var(--dim); }
#filters { position: sticky; top: 0; z-index: 5; background: var(--bg); padding: 8px 0; margin-bottom: 8px; border-bottom: 1px solid #2a2a2a; display: flex; flex-direction: column; gap: 8px; }
.frow { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
#filters select, #filters input { background: var(--card); color: var(--fg); border: 1px solid #333; border-radius: 4px; padding: 5px 8px; font: inherit; max-width: 100%; min-width: 0; }
#filters button { background: var(--card); color: var(--fg); border: 1px solid #333; border-radius: 14px; padding: 4px 10px; font: inherit; cursor: pointer; }
#filters button.on { background: var(--accent); color: #000; border-color: var(--accent); }
#filters button i { font-style: normal; color: var(--dim); margin-left: 4px; }
#filters button.on i { color: #024; }
#chips { max-height: 5.5em; overflow-y: auto; }
#count { margin-left: auto; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(280px, 100%), 1fr)); gap: 16px; }
.card { position: relative; background: var(--card); border-radius: 8px; overflow: hidden; display: flex; flex-direction: column; }
.card.is-new { outline: 2px solid var(--accent); }
.thumb { width: 100%; aspect-ratio: 16 / 10; object-fit: cover; cursor: zoom-in; background: #000; display: block; }
.thumb.none { cursor: default; }
.body { padding: 10px; display: flex; flex-direction: column; gap: 6px; flex: 1; }
.title { color: var(--fg); text-decoration: none; word-break: break-word; }
.title:hover { text-decoration: underline; }
.meta { color: var(--dim); font-size: 12px; }
.actions { margin-top: auto; display: flex; gap: 8px; align-items: center; }
button.add { background: var(--accent); color: #000; border: 0; border-radius: 4px; padding: 6px 12px; font-weight: 600; cursor: pointer; }
button.add:disabled { background: #333; color: var(--dim); cursor: default; }
button.add.queued:hover { background: #522; color: #fcc; }
.badge { position: absolute; z-index: 1; font-weight: 700; border-radius: 4px; }
.badge.new { top: 8px; left: 8px; background: var(--accent); color: #000; font-size: 15px; padding: 4px 10px; }
.badge.fresh-badge { top: 8px; right: 8px; background: var(--fresh); color: #000; font-size: 12px; padding: 3px 7px; }
.fresh { color: var(--fresh); font-weight: 700; }
.err { color: #e66; font-size: 12px; }
@media (max-width: 640px) { #filters { position: static; } }
#ov { position: fixed; inset: 0; background: rgba(0, 0, 0, .92); overflow-y: auto; padding: 16px; text-align: center; cursor: zoom-out; }
#ov img { max-width: 100%; margin: 0 auto 12px; display: block; }
"""

JS = """
document.querySelectorAll('button.add').forEach(b => b.onclick = async () => {
  const err = b.nextElementSibling;
  const card = b.closest('.card');
  const unq = b.classList.contains('queued');
  b.disabled = true; b.textContent = unq ? 'Removing…' : 'Adding…'; err.textContent = '';
  try {
    const r = await fetch((unq ? 'unqueue/' : 'add/') + b.dataset.id, {method: 'POST'});
    let j;
    try { j = await r.json(); } catch (_) { throw new Error('HTTP ' + r.status + ' — reload the page'); }
    if (!j.ok) throw new Error(j.error);
    if (unq) {
      b.classList.remove('queued'); b.removeAttribute('title'); b.disabled = false;
      b.textContent = 'Add to Vault'; err.textContent = ''; card.dataset.state = '';
    } else if (j.queued) {
      b.classList.add('queued'); b.title = 'Click to remove from queue'; b.disabled = false;
      b.textContent = 'Queued ⏳'; err.textContent = j.message; card.dataset.state = 'queued';
    } else { b.textContent = 'Added ✓'; card.dataset.state = 'added'; }
  } catch (e) {
    b.disabled = false; b.textContent = unq ? 'Queued ⏳' : 'Retry'; err.textContent = e.message;
  }
});
try {
  const ids = [...document.querySelectorAll('button.add[data-id]')].map(b => b.dataset.id);
  const now = Date.now(), WINDOW = 30 * 60 * 1000;
  let rec = null;
  try {
    const raw = JSON.parse(localStorage.getItem('plab.seen'));
    if (Array.isArray(raw)) rec = {prev: raw.map(String), cur: raw.map(String), at: now};  // old format
    else if (raw && Array.isArray(raw.prev) && Array.isArray(raw.cur)) rec = {prev: raw.prev.map(String), cur: raw.cur.map(String), at: Number(raw.at) || 0};
  } catch (_) {}
  let next;
  if (!rec) next = {prev: ids, cur: ids, at: now};
  else if (now - rec.at > WINDOW) next = {prev: rec.cur, cur: ids, at: now};
  else next = {prev: rec.prev, cur: ids, at: rec.at};
  if (rec) {
    const seen = new Set(next.prev);
    let n = 0;
    document.querySelectorAll('.card').forEach(c => {
      const b = c.querySelector('button.add[data-id]');
      if (!b || seen.has(b.dataset.id)) return;
      const s = document.createElement('span');
      s.className = 'badge new'; s.textContent = 'NEW'; c.prepend(s); c.classList.add('is-new'); n++;
    });
    if (n) document.getElementById('newcount').textContent = ' · ' + n + ' new';
  }
  try { localStorage.setItem('plab.seen', JSON.stringify(next)); } catch (_) {}
} catch (_) {}
const ov = document.getElementById('ov');
document.querySelectorAll('img.thumb[data-images]').forEach(i => i.onclick = () => {
  ov.innerHTML = JSON.parse(i.dataset.images).map(k => '<img loading="lazy" src="img/' + k + '">').join('');
  ov.hidden = false;
});
ov.onclick = () => { ov.hidden = true; ov.innerHTML = ''; };
"""

# Client-side filtering. Runs after the NEW pass above, so "New only" sees .is-new.
FILTER_JS = """
(() => {
  const bar = document.getElementById('filters');
  if (!bar) return;
  const cards = [...document.querySelectorAll('.card')];
  const TOGGLES = ['h24', 'new', 'hide'];
  const SELECTS = {cat: 'category', q: 'quality', studio: 'studio'};
  const empty = () => ({h24: false, new: false, hide: false, cat: '', q: '', studio: '', tags: []});
  let st = empty();

  function fromHash(h) {
    const o = empty();
    h.replace(/^#/, '').split('&').forEach(p => {
      if (!p) return;
      const i = p.indexOf('=');
      const k = i < 0 ? p : p.slice(0, i), v = i < 0 ? '' : p.slice(i + 1);
      try {
        if (TOGGLES.includes(k)) o[k] = v === '1';
        else if (Object.hasOwn(SELECTS, k)) o[k] = decodeURIComponent(v);
        else if (k === 'tags') v.split(',').filter(Boolean).forEach(t => { try { o.tags.push(decodeURIComponent(t)); } catch (_) {} });
      } catch (_) {}
    });
    return o;
  }
  function toHash(s) {
    const p = [];
    TOGGLES.forEach(k => { if (s[k]) p.push(k + '=1'); });
    Object.keys(SELECTS).forEach(k => { if (s[k]) p.push(k + '=' + encodeURIComponent(s[k])); });
    if (s.tags.length) p.push('tags=' + s.tags.map(encodeURIComponent).join(','));
    return p.join('&');
  }
  const isEmpty = s => toHash(s) === '';

  function load() {
    if (location.hash.length > 1) return fromHash(location.hash);
    try { const raw = localStorage.getItem('plab.filters'); if (raw) return fromHash(raw); } catch (_) {}
    return empty();
  }
  function save() {
    const h = toHash(st);
    try { history.replaceState(null, '', h ? '#' + h : location.pathname + location.search); } catch (_) {}
    try { localStorage.setItem('plab.filters', h); } catch (_) {}
  }

  function render() {
    bar.querySelectorAll('[data-toggle]').forEach(b => b.classList.toggle('on', st[b.dataset.toggle]));
    Object.keys(SELECTS).forEach(k => { const el = bar.querySelector('select[data-key="' + k + '"]'); if (el) el.value = st[k]; });
    bar.querySelectorAll('#chips [data-tag]').forEach(b => b.classList.toggle('on', st.tags.includes(b.dataset.tag)));
    const sel = document.getElementById('seltags');
    sel.replaceChildren(...st.tags.map(t => {
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'on'; b.dataset.remove = t; b.textContent = t + ' ×';
      return b;
    }));
    let shown = 0;
    cards.forEach(c => {
      const d = c.dataset;
      const tags = d.tags ? d.tags.split('|') : [];
      const ok = (!st.h24 || d.fresh === '1')
        && (!st.new || c.classList.contains('is-new'))
        && (!st.hide || !d.state)
        && (!st.cat || d.category === st.cat)
        && (!st.q || d.quality === st.q)
        && (!st.studio || d.studio === st.studio)
        && st.tags.every(t => tags.includes(t));
      c.hidden = !ok;
      if (ok) shown++;
    });
    document.getElementById('count').textContent = 'Showing ' + shown + ' of ' + cards.length;
  }
  function change() { save(); render(); }

  bar.querySelectorAll('[data-toggle]').forEach(b => b.onclick = () => { st[b.dataset.toggle] = !st[b.dataset.toggle]; change(); });
  bar.querySelectorAll('select[data-key]').forEach(el => el.onchange = () => { st[el.dataset.key] = el.value; change(); });
  const toggleTag = t => { const i = st.tags.indexOf(t); if (i < 0) st.tags.push(t); else st.tags.splice(i, 1); change(); };
  bar.querySelectorAll('#chips [data-tag]').forEach(b => b.onclick = () => toggleTag(b.dataset.tag));
  document.getElementById('seltags').onclick = e => {
    const t = e.target.dataset && e.target.dataset.remove;
    if (t) toggleTag(t);
  };
  const input = document.getElementById('tagin');
  function addTyped() {
    const t = input.value.trim().toLowerCase();
    input.value = '';
    if (t && !st.tags.includes(t)) { st.tags.push(t); change(); }
  }
  input.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); addTyped(); } };
  const known = new Set([...document.querySelectorAll('#taglist option')].map(o => o.value));
  input.oninput = () => { if (known.has(input.value.trim().toLowerCase())) addTyped(); };  // chose a datalist value
  document.getElementById('clear').onclick = () => { st = empty(); change(); };

  st = load();
  Object.keys(SELECTS).forEach(k => {
    const el = bar.querySelector('select[data-key="' + k + '"]');
    if (st[k] && !(el && [...el.options].some(o => o.value === st[k]))) st[k] = '';
  });
  render();
  if (location.hash.length > 1 || !isEmpty(st)) save();
})();
"""
