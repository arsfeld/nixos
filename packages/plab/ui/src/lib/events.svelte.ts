import type { ServerEvent } from './types';

/** The one SSE connection. EventSource retries a dropped connection itself; a refused one
 * (the gateway's 502 while plab restarts) closes it for good, so that is retried here. */
class Live {
  connected = $state(false);
  private handlers: ((e: ServerEvent) => void)[] = [];
  private reconnects: (() => void)[] = [];
  private es: EventSource | null = null;
  private lost = false;

  on(h: (e: ServerEvent) => void) {
    this.handlers.push(h);
  }

  /** Called after a reconnect and on `resync`: the client may have missed events. */
  onReconnect(h: () => void) {
    this.reconnects.push(h);
  }

  start() {
    if (this.es) return;
    const es = new EventSource('/api/events');
    this.es = es;
    es.onopen = () => {
      this.connected = true;
      if (this.lost) {
        this.lost = false;
        this.reconnects.forEach((f) => f());
      }
    };
    es.onerror = () => {
      this.connected = false;
      this.lost = true;
      if (es.readyState === EventSource.CLOSED) {
        this.es = null;
        setTimeout(() => this.start(), 5000);
      }
    };
    es.onmessage = (m) => {
      let ev: ServerEvent;
      try {
        ev = JSON.parse(m.data) as ServerEvent;
      } catch {
        return;
      }
      if (ev.type === 'resync') this.reconnects.forEach((f) => f());
      else this.handlers.forEach((h) => h(ev));
    };
  }
}

export const live = new Live();
