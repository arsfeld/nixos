import {
  deleteConversation,
  fetchConversation,
  fetchConversations,
  postChat,
  postMessage,
  postRecommend,
  postRetry,
} from './api';
import { upsertSummary } from './assistant';
import { applyTopic } from './reducer';
import { router } from './router.svelte';
import type { Conversation, ConversationSummary, ServerEvent } from './types';

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

class AssistantStore {
  list = $state<ConversationSummary[]>([]);
  current = $state<Conversation | null>(null);
  busy = $state(false);
  error = $state<string | null>(null);

  private async run(f: () => Promise<Conversation>) {
    this.busy = true;
    this.error = null;
    try {
      const c = await f();
      this.current = c;
      this.list = upsertSummary(this.list, c);
      if (router.route.view !== 'assistant' || router.route.id !== c.id) router.go(`/assistant/${c.id}`);
    } catch (e) {
      this.error = message(e);
    } finally {
      this.busy = false;
    }
  }

  async load() {
    try {
      this.list = await fetchConversations();
      this.error = null;
    } catch (e) {
      this.error = message(e);
    }
  }

  async open(id: number | null) {
    if (id === null) {
      this.current = null;
      return;
    }
    if (this.current?.id === id) return;
    try {
      this.current = await fetchConversation(id);
      this.error = null;
    } catch (e) {
      this.error = message(e);
    }
  }

  recommend = () => this.run(postRecommend);
  newChat = (text: string) => this.run(() => postChat(text));
  send = (text: string) => {
    const c = this.current;
    return c ? this.run(() => postMessage(c.id, text)) : this.newChat(text);
  };
  retry = () => {
    const c = this.current;
    return c ? this.run(() => postRetry(c.id)) : Promise.resolve();
  };

  async remove(id: number) {
    try {
      await deleteConversation(id);
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
