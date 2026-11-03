import { empty, fromHash, toHash, type Filters, type Toggle } from './filters';
import { readStr, writeStr } from './storage';

/** One view's filters. The lists keep theirs in the URL hash and localStorage (the old
 * page's keys); a search's are in memory only, so they never overwrite the list's. */
export class FilterState {
  st = $state<Filters>(empty());

  constructor(private key: string | null) {}

  /** On entering the view: the hash wins, then the saved filters. */
  activate() {
    if (this.key === null) return;
    const raw = location.hash.length > 1 ? location.hash : readStr(this.key);
    this.st = raw ? fromHash(raw) : empty();
  }

  save() {
    if (this.key === null) return;
    const h = toHash(this.st);
    try {
      history.replaceState(history.state, '', h ? '#' + h : location.pathname + location.search);
    } catch {
      /* not reflected in the URL */
    }
    writeStr(this.key, h);
  }

  toggle(k: Toggle) {
    this.st[k] = !this.st[k];
  }

  toggleTag(t: string) {
    const i = this.st.tags.indexOf(t);
    if (i < 0) this.st.tags.push(t);
    else this.st.tags.splice(i, 1);
  }

  addTag(t: string) {
    if (t && !this.st.tags.includes(t)) this.st.tags.push(t);
  }

  clear() {
    this.st = empty();
  }
}

export const filters = {
  video: new FilterState('plab.filters'),
  games: new FilterState('plab.filters.games'),
  search: new FilterState(null),
};
