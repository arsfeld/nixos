import type { ServerEvent, Topic } from './types';

/** Apply a topic event to every loaded list holding that topic. A topic's state and its
 * status arrive as separate events, so neither overwrites the other. A release listed as
 * another card's `also` takes its state too. */
export function applyTopic(lists: Iterable<{ topics: Topic[] }>, ev: ServerEvent): void {
  if (ev.type !== 'topicState' && ev.type !== 'topicStatus') return;
  for (const l of lists)
    for (const t of l.topics) {
      if (t.id === ev.id) {
        if (ev.type === 'topicState') t.state = ev.state;
        else t.status = ev.status;
      }
      if (ev.type === 'topicState') for (const a of t.also ?? []) if (a.id === ev.id) a.state = ev.state;
    }
}
