import { fetchWatchIds, postWatch } from './api';
import type { ServerEvent } from './types';
import { nextIds, toggleAction } from './watchlist';

/** Every queued Stash scene id, shared by every ☆ on the page. */
class WatchlistStore {
  ids = $state<ReadonlySet<string>>(new Set());

  async load() {
    try {
      this.ids = new Set(await fetchWatchIds());
    } catch {
      /* stars stay as they were; the next event or reconnect retries */
    }
  }

  apply(ev: ServerEvent) {
    this.ids = nextIds(this.ids, ev);
  }

  /** Queue `scenes`, or unqueue them when all are queued. Throws the server's error. */
  async toggle(scenes: string[]) {
    this.ids = new Set(await postWatch(toggleAction(this.ids, scenes), scenes));
  }
}

export const watchlist = new WatchlistStore();
