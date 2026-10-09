"""The page's static CSS and JS, kept apart from the renderer in page.py.

Styling is daisyUI plus the Tailwind browser runtime (both served from /static); the CSS
here is only what no component class expresses."""

CSS = """
[hidden] { display: none !important; }
.add.queued:not(:disabled):hover { --btn-color: var(--color-error); --btn-fg: var(--color-error-content); }
"""

JS = """
const ADD = 'btn-primary', QUEUED = 'btn-warning';
const queuedLabel = b => b.classList.contains('queued') && !b.disabled;
document.querySelectorAll('button.add').forEach(b => {
  b.onmouseenter = () => { if (queuedLabel(b)) b.textContent = 'Remove ✕'; };
  b.onmouseleave = () => { if (queuedLabel(b)) b.textContent = 'Queued ⏳'; };
  b.onclick = async () => {
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
        b.classList.remove('queued', QUEUED); b.classList.add(ADD); b.removeAttribute('title'); b.disabled = false;
        b.textContent = 'Add to Vault'; err.textContent = ''; card.dataset.state = '';
      } else if (j.queued) {
        b.classList.remove(ADD); b.classList.add('queued', QUEUED); b.title = 'Click to remove from queue'; b.disabled = false;
        b.textContent = 'Queued ⏳'; err.textContent = j.message; card.dataset.state = 'queued';
      } else { b.textContent = 'Added ✓'; card.dataset.state = 'added'; }
    } catch (e) {
      b.disabled = false; b.textContent = unq ? 'Queued ⏳' : 'Retry'; err.textContent = e.message;
    }
  };
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
      s.className = 'new badge badge-accent badge-lg font-bold absolute top-2 left-2 z-[1]'; s.textContent = 'NEW';
      (c.querySelector('figure') || c).prepend(s);
      // ring-accent does not exist: Tailwind's runtime knows no daisyUI colours, so name the variable.
      c.classList.add('is-new', 'ring-2', 'ring-(--color-accent)'); n++;
    });
    if (n) document.getElementById('newcount').textContent = ' · ' + n + ' new';
  }
  try { localStorage.setItem('plab.seen', JSON.stringify(next)); } catch (_) {}
} catch (_) {}
const ov = document.getElementById('ov'), ovbox = ov.querySelector('.modal-box');
document.querySelectorAll('img.thumb[data-images]').forEach(i => i.onclick = () => {
  ovbox.innerHTML = JSON.parse(i.dataset.images).map(k => '<img class="block mx-auto mb-3 max-w-full" loading="lazy" src="img/' + k + '">').join('');
  ov.showModal();
});
ov.onclick = () => ov.close();  // anywhere, images included, as before; Escape closes it natively
ov.onclose = () => { ovbox.innerHTML = ''; };
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
    bar.querySelectorAll('[data-toggle]').forEach(b => b.classList.toggle('btn-primary', st[b.dataset.toggle]));
    Object.keys(SELECTS).forEach(k => { const el = bar.querySelector('select[data-key="' + k + '"]'); if (el) el.value = st[k]; });
    bar.querySelectorAll('#chips [data-tag]').forEach(b => b.classList.toggle('btn-primary', st.tags.includes(b.dataset.tag)));
    const sel = document.getElementById('seltags');
    sel.replaceChildren(...st.tags.map(t => {
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'btn btn-xs btn-primary'; b.dataset.remove = t; b.textContent = t + ' ×';
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
