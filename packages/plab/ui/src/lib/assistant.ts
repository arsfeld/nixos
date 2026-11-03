import type { Conversation, ConversationSummary, PickData, SceneCardData, Topic } from './types';

export type Resolved =
  | { kind: 'topic'; topic: Topic; pick: PickData }
  | { kind: 'scene'; scene: SceneCardData; pick: PickData };

/** A pick's card data, or null when the server could not resolve it. */
export function resolvePick(c: Conversation, pick: PickData): Resolved | null {
  if (pick.ref.startsWith('t:')) {
    const id = Number(pick.ref.slice(2));
    const topic = c.topics.find((t) => t.id === id);
    return topic ? { kind: 'topic', topic, pick } : null;
  }
  const scene = c.scenes.find((s) => s.ref === pick.ref);
  return scene ? { kind: 'scene', scene, pick } : null;
}

export function lastFailed(c: Conversation): boolean {
  return c.turns.at(-1)?.error != null;
}

export function upsertSummary(list: ConversationSummary[], c: Conversation): ConversationSummary[] {
  const s: ConversationSummary = { id: c.id, title: c.title, kind: c.kind, updatedAt: c.updatedAt };
  return [s, ...list.filter((x) => x.id !== c.id)];
}
