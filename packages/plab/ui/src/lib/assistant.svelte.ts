import {
  deleteConversation,
  fetchConversation,
  fetchConversations,
  postChat,
  postMessage,
  postRetry,
} from './api';
import { openTarget, shouldNavigate, upsertSummary } from './assistant';
import { Latest } from './latest';
import { applyTopic } from './reducer';
import { router } from './router.svelte';
import type { Conversation, ConversationSummary, ServerEvent } from './types';

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

class AssistantStore {
  list = $state<ConversationSummary[]>([]);
  current = $state<Conversation | null>(null);
  busy = $state(false);
  private latest = new Latest<'open'>();
  error = $state<string | null>(null);

  /** Whether the request succeeded. */
  private async run(f: () => Promise<Conversation>): Promise<boolean> {
    this.busy = true;
    this.error = null;
    const start = $state.snapshot(router.route);
    try {
      const c = await f();
      this.list = upsertSummary(this.list, c);
      // The user may have opened something else while this ran: do not yank them back.
      if (shouldNavigate(start, router.route)) {
        this.latest.next('open'); // an in-flight open() must not overwrite this result
        this.current = c;
        if (router.route.view !== 'assistant' || router.route.id !== c.id) router.go(`/assistant/${c.id}`);
      }
      return true;
    } catch (e) {
      this.error = message(e);
      // The turn runs on in the server after a dropped request: show what it stored.
      await Promise.all([this.load(), this.refresh()]);
      return false;
    } finally {
      this.busy = false;
    }
  }

  async load() {
    try {
      this.list = await fetchConversations();
    } catch (e) {
      this.error = message(e);
    }
  }

  /** Re-fetch the open conversation, keeping any error on screen. */
  private async refresh() {
    const id = this.current?.id;
    if (id == null) return;
    const token = this.latest.next('open');
    try {
      const c = await fetchConversation(id);
      if (this.latest.current('open', token) && this.current?.id === id) this.current = c;
    } catch {
      // The error from the request that failed is the one worth showing.
    }
  }

  async open(id: number | null) {
    const target = openTarget(this.current?.id ?? null, id);
    if (target === 'keep') return;
    const token = this.latest.next('open');
    this.error = null;
    this.current = null;
    if (target === 'clear' || id === null) return;
    try {
      const c = await fetchConversation(id);
      if (this.latest.current('open', token)) this.current = c;
    } catch (e) {
      if (this.latest.current('open', token)) this.error = message(e);
    }
  }

  newChat = (text: string) => this.run(() => postChat(text));
  send = (text: string) => {
    const c = this.current;
    return c ? this.run(() => postMessage(c.id, text)) : this.newChat(text);
  };
  retry = () => {
    const c = this.current;
    return c ? this.run(() => postRetry(c.id)) : Promise.resolve(false);
  };

  async remove(id: number) {
    try {
      await deleteConversation(id);
      this.error = null;
      this.list = this.list.filter((c) => c.id !== id);
      if (this.current?.id === id) router.go('/assistant');
    } catch (e) {
      this.error = message(e);
    }
  }

  apply(ev: ServerEvent) {
    if (this.current) applyTopic([this.current], ev);
  }
}

export const assistant = new AssistantStore();
