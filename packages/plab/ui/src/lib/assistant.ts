import type { Route } from './route';
import type { Conversation, ConversationSummary, PickData, PickedTopic, SceneCardData } from './types';

export type Resolved =
  | { kind: 'topic'; topic: PickedTopic; pick: PickData }
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

/** The last turn needs a Retry: it is an error, or a user turn that never got a reply. */
export function lastFailed(c: Conversation): boolean {
  const last = c.turns.at(-1);
  return last != null && (last.error != null || last.role === 'user');
}

export function upsertSummary(list: ConversationSummary[], c: Conversation): ConversationSummary[] {
  const s: ConversationSummary = { id: c.id, title: c.title, kind: c.kind, updatedAt: c.updatedAt };
  return [s, ...list.filter((x) => x.id !== c.id)];
}

const sameRoute = (a: Route, b: Route) => a.view === b.view && (a.view !== 'assistant' || (b.view === 'assistant' && a.id === b.id));

/** A finished request may navigate or show its result only if the user is still where it started. */
export function shouldNavigate(start: Route, now: Route): boolean {
  return sameRoute(start, now);
}

/** What `open(routeId)` must do given the conversation on screen. */
export function openTarget(currentId: number | null, routeId: number | null): 'clear' | 'keep' | 'fetch' {
  if (routeId === null) return 'clear';
  return currentId === routeId ? 'keep' : 'fetch';
}
