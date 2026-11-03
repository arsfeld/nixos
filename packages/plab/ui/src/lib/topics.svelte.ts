import { fetchList, fetchSearch } from './api';
import { applyTopic } from './reducer';
import { Latest } from './latest';
import { nextSeen } from './seen';
import { readJson, writeStr } from './storage';
import type { List, Section, ServerEvent, TopicState } from './types';

type Key = Section | 'search';

/** The loaded lists, cached for the session: a tab switch shows its list at once. Events
 * patch topics in place; a `listing` event only marks the section stale (the reload pill). */
class Topics {
  lists = $state<Partial<Record<Key, List>>>({});
  stale = $state<Partial<Record<Section, boolean>>>({});
  errors = $state<Partial<Record<Key, string>>>({});
  /** Topic ids new since the last visit, per section. */
  newIds = $state.raw<Partial<Record<Section, Set<string>>>>({});
  private loading: Partial<Record<Key, boolean>> = {};
  private latest = new Latest<Key>();

  async load(key: Section) {
    this.loading[key] = true;
    const token = this.latest.next(key);
    try {
      const l = await fetchList(key);
      if (!this.latest.current(key, token)) return;
      const seenKey = 'plab.seen' + (key === 'video' ? '' : '.' + key);
      const r = nextSeen(readJson(seenKey), l.topics.map((t) => String(t.id)), Date.now());
      writeStr(seenKey, JSON.stringify(r.next));
      this.newIds = { ...this.newIds, [key]: r.newIds };
      this.lists[key] = l;
      this.stale[key] = false;
      delete this.errors[key];
    } catch (e) {
      if (this.latest.current(key, token)) {
        this.errors[key] = e instanceof Error ? e.message : String(e);
      }
    } finally {
      if (this.latest.current(key, token)) this.loading[key] = false;
    }
  }

  ensure(key: Section) {
    if (!this.lists[key] && !this.loading[key]) void this.load(key);
  }

  async search(q: string) {
    delete this.lists.search;
    const token = this.latest.next('search');
    try {
      const l = await fetchSearch(q);
      if (!this.latest.current('search', token)) return;
      this.lists.search = l;
      delete this.errors.search;
    } catch (e) {
      if (this.latest.current('search', token)) {
        this.errors.search = e instanceof Error ? e.message : String(e);
      }
    }
  }

  private all(): List[] {
    return Object.values(this.lists).filter((l): l is List => !!l);
  }

  apply(ev: ServerEvent) {
    applyTopic(this.all(), ev);
    if (ev.type === 'listing') this.stale[ev.section] = true;
  }

  /** After an add or unqueue reply, in every list holding the topic. */
  setState(id: number, state: TopicState) {
    applyTopic(this.all(), { type: 'topicState', id, state });
  }

  /** After a reconnect or a lag: refetch what is on screen, forget the rest. */
  resync(view: string) {
    for (const k of ['video', 'indexers', 'albums', 'games'] as const) {
      if (k === view) void this.load(k);
      else delete this.lists[k];
    }
    const q = this.lists.search?.query;
    if (view === 'search' && q) void this.search(q);
  }
}

export const topics = new Topics();
