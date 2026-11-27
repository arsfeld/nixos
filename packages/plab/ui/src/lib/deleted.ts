// Deleted scenes' pure logic. A delete removes a scene and its files from Stash and hides
// it in plab for good; it is not a vote.
import type { ServerEvent } from './types';

/** The deleted ids after an event: a `deleted` event carries the newly deleted ones. */
export function nextDeleted(current: ReadonlySet<string>, ev: ServerEvent): ReadonlySet<string> {
  return ev.type === 'deleted' ? new Set([...current, ...ev.ids]) : current;
}

/** True when there are scenes and every one is deleted. */
export function allDeleted(set: ReadonlySet<string>, ids: string[]): boolean {
  return ids.length > 0 && ids.every((id) => set.has(id));
}
