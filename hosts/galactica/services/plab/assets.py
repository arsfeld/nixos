"""The page's static CSS and JS, kept apart from the renderer in page.py.

Styling is daisyUI plus the Tailwind browser runtime (both served from /static); the CSS
here is only what no component class expresses.

Alpine.js components manage client-side filtering, persistence, image preview modal,
and async queue/vault actions."""

CSS = """
[x-cloak] { display: none !important; }
[hidden] { display: none !important; }
.add.queued:not(:disabled):hover { --btn-color: var(--color-error); --btn-fg: var(--color-error-content); }
"""

JS = """
(() => {
  const TOGGLES = ['h24', 'new', 'hide'];
  // f: the active curated filter's name
  const SELECTS = {cat: 'category', q: 'quality', studio: 'studio', prod: 'production', f: 'filters'};
  const STRINGS = Object.keys(SELECTS);
  const empty = () => ({h24: false, new: false, hide: false, f: '', cat: '', q: '', studio: '', prod: '', tags: []});

  function fromHash(h) {
    const o = empty();
    h.replace(/^#/, '').split('&').forEach(p => {
      if (!p) return;
      const i = p.indexOf('=');
      const k = i < 0 ? p : p.slice(0, i), v = i < 0 ? '' : p.slice(i + 1);
      try {
        if (TOGGLES.includes(k)) o[k] = v === '1';
        else if (STRINGS.includes(k)) o[k] = decodeURIComponent(v);
        else if (k === 'tags') v.split(',').filter(Boolean).forEach(t => { try { o.tags.push(decodeURIComponent(t)); } catch (_) {} });
      } catch (_) {}
    });
    return o;
  }

  function toHash(s) {
    const p = [];
    TOGGLES.forEach(k => { if (s[k]) p.push(k + '=1'); });
    STRINGS.forEach(k => { if (s[k]) p.push(k + '=' + encodeURIComponent(s[k])); });
    if (s.tags.length) p.push('tags=' + s.tags.map(encodeURIComponent).join(','));
    return p.join('&');
  }

  const isEmpty = s => toHash(s) === '';

  const register = () => {
    Alpine.data('plabApp', () => ({
      st: empty(),
      cards: [],
      newIds: new Set(),
      newCount: 0,
      modalImages: [],

      registerCard(card) {
        this.cards.push(card);
      },

      isVisible(card) {
        return (!this.st.h24 || card.fresh)
          && (!this.st.new || card.isNew)
          && (!this.st.hide || !card.state)
          && (!this.st.f || card.filters.includes(this.st.f))
          && (!this.st.cat || card.cat === this.st.cat)
          && (!this.st.q || card.q === this.st.q)
          && (!this.st.studio || card.studio === this.st.studio)
          && (!this.st.prod || card.prod === this.st.prod)
          && this.st.tags.every(t => card.tags.includes(t));
      },

      get shownCount() {
        return this.cards.filter(c => this.isVisible(c)).length;
      },

      init() {
        // A live search's results are not the weekly list: they must not move the "new
        // since your last visit" mark or overwrite the list's saved filters.
        if (document.body.dataset.search) {
          this.newIds = null;
          return;
        }
        this.initSeen();
        this.initFilters();
        if (this.$watch) {
          this.$watch('st', () => this.saveFilters());
        }
      },

      initSeen() {
        try {
          const ids = [...document.querySelectorAll('button.add[data-id]')].map(b => b.dataset.id);
          const now = Date.now(), WINDOW = 30 * 60 * 1000;
          let rec = null;
          try {
            const raw = JSON.parse(localStorage.getItem('plab.seen'));
            if (Array.isArray(raw)) rec = {prev: raw.map(String), cur: raw.map(String), at: now};
            else if (raw && Array.isArray(raw.prev) && Array.isArray(raw.cur)) rec = {prev: raw.prev.map(String), cur: raw.cur.map(String), at: Number(raw.at) || 0};
          } catch (_) {}
          let next;
          if (!rec) next = {prev: ids, cur: ids, at: now};
          else if (now - rec.at > WINDOW) next = {prev: rec.cur, cur: ids, at: now};
          else next = {prev: rec.prev, cur: ids, at: rec.at};
          this.newIds = new Set(next.prev);
          if (rec) {
            this.newCount = ids.filter(id => !this.newIds.has(String(id))).length;
            const el = document.getElementById('newcount');
            if (el && this.newCount) el.textContent = ' · ' + this.newCount + ' new';
          } else {
            this.newCount = 0;
          }
          try { localStorage.setItem('plab.seen', JSON.stringify(next)); } catch (_) {}
        } catch (_) {}
      },

      initFilters() {
        let initial = null;
        if (location.hash.length > 1) initial = fromHash(location.hash);
        else {
          try {
            const raw = localStorage.getItem('plab.filters');
            if (raw) initial = fromHash(raw);
          } catch (_) {}
        }
        if (initial) {
          Object.assign(this.st, initial);
        }
        // A value no longer offered (a renamed curated filter, a studio gone from the list) would hide every card.
        Object.keys(SELECTS).forEach(k => {
          const el = document.querySelector('select[data-key="' + k + '"]');
          if (this.st[k] && el && ![...el.options].some(o => o.value === this.st[k])) this.st[k] = '';
        });
        if (location.hash.length > 1 || !isEmpty(this.st)) this.saveFilters();
      },

      saveFilters() {
        const h = toHash(this.st);
        try { history.replaceState(null, '', h ? '#' + h : location.pathname + location.search); } catch (_) {}
        try { localStorage.setItem('plab.filters', h); } catch (_) {}
      },

      toggle(key) {
        this.st[key] = !this.st[key];
      },

      toggleTag(tag) {
        const i = this.st.tags.indexOf(tag);
        if (i < 0) this.st.tags.push(tag);
        else this.st.tags.splice(i, 1);
      },

      clearFilters() {
        this.st = empty();
      },

      addTyped(input) {
        const inp = input || document.getElementById('tagin');
        if (!inp) return;
        const t = inp.value.trim().toLowerCase();
        inp.value = '';
        if (t && !this.st.tags.includes(t)) this.st.tags.push(t);
      },

      onTagInput(e) {
        const inp = (e && e.target) || document.getElementById('tagin');
        if (!inp) return;
        const val = inp.value.trim().toLowerCase();
        const known = new Set([...document.querySelectorAll('#taglist option')].map(o => o.value));
        if (known.has(val)) {
          inp.value = '';
          if (!this.st.tags.includes(val)) this.st.tags.push(val);
        }
      },

      openGallery(images) {
        this.modalImages = images;
        const ov = (this.$refs && this.$refs.modal) || document.getElementById('ov');
        if (ov && ov.showModal) ov.showModal();
      },

      async openTopicGallery(id) {
        try {
          const r = await fetch('images/' + id);
          if (!r.ok) return;
          const j = await r.json();
          if (j.images && j.images.length) this.openGallery(j.images);
        } catch (_) {}
      },

      closeGallery() {
        const ov = (this.$refs && this.$refs.modal) || document.getElementById('ov');
        if (ov && ov.close) ov.close();
        this.modalImages = [];
      },
    }));

    Alpine.data('plabCard', (cfg = {}) => ({
      id: cfg.id,
      fresh: Boolean(cfg.fresh),
      filters: cfg.filters || [],
      cat: cfg.cat || '',
      q: cfg.q || '',
      studio: cfg.studio || '',
      prod: cfg.prod || '',
      tags: cfg.tags || [],
      state: cfg.initialState || '',
      loading: false,
      hoverQueued: false,
      error: '',
      thumbFailed: false,
      isNew: false,

      init() {
        if (this.registerCard) this.registerCard(this);
        if (this.newIds) this.isNew = !this.newIds.has(String(this.id));
      },

      get btnLabel() {
        if (this.loading) return this.state === 'queued' ? 'Removing…' : 'Adding…';
        if (this.state === 'added') return 'Added ✓';
        if (this.state === 'queued') return this.hoverQueued ? 'Remove ✕' : 'Queued ⏳';
        return this.error ? 'Retry' : 'Add to Vault';
      },

      get btnClass() {
        return this.state === 'queued' ? 'btn-warning queued' : 'btn-primary';
      },

      async toggleAdd() {
        if (this.loading || this.state === 'added') return;
        const unq = this.state === 'queued';
        this.loading = true;
        this.error = '';
        try {
          const r = await fetch((unq ? 'unqueue/' : 'add/') + this.id, {method: 'POST'});
          let j;
          try {
            j = await r.json();
          } catch (_) {
            throw new Error('HTTP ' + r.status + ' — reload the page');
          }
          if (!j.ok) throw new Error(j.error);
          if (unq) {
            this.state = '';
            this.error = '';
          } else if (j.queued) {
            this.state = 'queued';
            this.error = j.message || '';
          } else {
            this.state = 'added';
          }
        } catch (e) {
          this.error = e.message || String(e);
        } finally {
          this.loading = false;
          this.hoverQueued = false;
        }
      },
    }));
  };

  if (window.Alpine) register();
  else document.addEventListener('alpine:init', register);
})();
"""

FILTER_JS = ""
