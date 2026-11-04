import { fetchDaily, postDailyRefresh } from './api';
import { Latest } from './latest';
import { applyTopic } from './reducer';
import type { Daily, ServerEvent } from './types';

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** For you: the picks on show, refetched when a generation ends (`assistantDaily`). */
class DailyStore {
  data = $state<Daily | null>(null);
  /** A request failed (not today's picks: that is `data.error`). */
  error = $state<string | null>(null);
  busy = $state(false);
  private latest = new Latest<'load'>();

  /** Fetch the picks; on a new day this is also what starts today's. */
  async load() {
    const token = this.latest.next('load');
    try {
      const d = await fetchDaily();
      if (this.latest.current('load', token)) {
        this.data = d;
        this.error = null;
      }
    } catch (e) {
      if (this.latest.current('load', token)) this.error = message(e);
    }
  }

  async refresh() {
    if (this.busy || this.data?.refreshing) return;
    this.busy = true;
    // A load in flight must not overwrite this answer, nor this answer a later load (the
    // one the `assistantDaily` event starts, if the generation ends first).
    const token = this.latest.next('load');
    try {
      const d = await postDailyRefresh();
      if (this.latest.current('load', token)) {
        this.data = d;
        this.error = null;
      }
    } catch (e) {
      if (this.latest.current('load', token)) this.error = message(e);
    } finally {
      this.busy = false;
    }
  }

  apply(ev: ServerEvent) {
    if (ev.type === 'assistantDaily') void this.load();
    else if (this.data?.conversation) applyTopic([this.data.conversation], ev);
  }
}

export const daily = new DailyStore();
