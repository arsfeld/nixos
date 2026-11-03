import type { List, Topic } from './types';

// The filter state and its URL-hash form, ported unchanged from the old page.js so saved
// filters (localStorage and bookmarked hashes) keep working.

export const TOGGLES = ['h24', 'new', 'hide'] as const;
/** In the old page's key order, which toHash keeps. f: the active curated filter. */
export const SELECTS = ['cat', 'q', 'studio', 'prod', 'f'] as const;
export type Toggle = (typeof TOGGLES)[number];
export type Select = (typeof SELECTS)[number];

export interface Filters {
  h24: boolean;
  new: boolean;
  hide: boolean;
  f: string;
  cat: string;
  q: string;
  studio: string;
  prod: string;
  tags: string[];
}

export const empty = (): Filters => ({ h24: false, new: false, hide: false, f: '', cat: '', q: '', studio: '', prod: '', tags: [] });

export function fromHash(h: string): Filters {
  const o = empty();
  for (const p of h.replace(/^#/, '').split('&')) {
    if (!p) continue;
    const i = p.indexOf('=');
    const k = i < 0 ? p : p.slice(0, i);
    const v = i < 0 ? '' : p.slice(i + 1);
    try {
      if ((TOGGLES as readonly string[]).includes(k)) o[k as Toggle] = v === '1';
      else if ((SELECTS as readonly string[]).includes(k)) o[k as Select] = decodeURIComponent(v);
      else if (k === 'tags')
        for (const t of v.split(',').filter(Boolean)) {
          try {
            o.tags.push(decodeURIComponent(t));
          } catch {
            /* skip a malformed tag */
          }
        }
    } catch {
      /* skip a malformed value */
    }
  }
  return o;
}

export function toHash(s: Filters): string {
  const p: string[] = [];
  for (const k of TOGGLES) if (s[k]) p.push(k + '=1');
  for (const k of SELECTS) if (s[k]) p.push(k + '=' + encodeURIComponent(s[k]));
  if (s.tags.length) p.push('tags=' + s.tags.map(encodeURIComponent).join(','));
  return p.join('&');
}

/** The value a select filters a topic on. */
export function valueOf(t: Topic, k: Exclude<Select, 'f'>): string {
  switch (k) {
    case 'cat':
      return t.category;
    case 'q':
      return t.quality ?? '';
    case 'studio':
      return t.studio ?? '';
    case 'prod':
      return t.production ?? '';
  }
}

export function isVisible(s: Filters, t: Topic, fresh: boolean, isNew: boolean): boolean {
  return (
    (!s.h24 || fresh) &&
    (!s.new || isNew) &&
    (!s.hide || !t.state) &&
    (!s.f || t.filters.includes(s.f)) &&
    (!s.cat || valueOf(t, 'cat') === s.cat) &&
    (!s.q || valueOf(t, 'q') === s.q) &&
    (!s.studio || valueOf(t, 'studio') === s.studio) &&
    (!s.prod || valueOf(t, 'prod') === s.prod) &&
    s.tags.every((x) => t.tags.includes(x))
  );
}

/** Values by count descending, ties alphabetical; empty values are not counted. */
export function mostCommon(values: Iterable<string>): [string, number][] {
  const c = new Map<string, number>();
  for (const v of values) if (v) c.set(v, (c.get(v) ?? 0) + 1);
  return [...c].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
}

/** Each select's offered values for a list. */
export function offered(l: List): Record<Select, Set<string>> {
  const vals = (k: Exclude<Select, 'f'>) => new Set(l.topics.map((t) => valueOf(t, k)).filter(Boolean));
  return { cat: vals('cat'), q: vals('q'), studio: vals('studio'), prod: vals('prod'), f: new Set(l.curatedFilters) };
}

/** Clear any select whose saved value is no longer offered: it would hide every card. The
 * same object comes back when nothing changes, so an effect can compare by identity. */
export function prune(s: Filters, o: Record<Select, Set<string>>): Filters {
  const drop = SELECTS.filter((k) => s[k] && !o[k].has(s[k]));
  if (!drop.length) return s;
  const n = { ...s, tags: [...s.tags] };
  for (const k of drop) n[k] = '';
  return n;
}
