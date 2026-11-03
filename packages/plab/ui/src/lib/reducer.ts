import type { List, ServerEvent } from './types';

/** Apply a topic event to every loaded list holding that topic. A topic's state and its
 * status arrive as separate events, so neither overwrites the other. */
export function applyTopic(lists: Iterable<List>, ev: ServerEvent): void {
  if (ev.type !== 'topicState' && ev.type !== 'topicStatus') return;
  for (const l of lists)
    for (const t of l.topics)
      if (t.id === ev.id) {
        if (ev.type === 'topicState') t.state = ev.state;
        else t.status = ev.status;
      }
}
