// The watchlist's pure logic: which scenes a ☆ covers, and what clicking it does.
// Design: docs/superpowers/specs/2026-11-16-plab-watchlist-design.md.
import type { ServerEvent, Status } from './types';

/** True when there are scenes and every one is queued. */
export function watching(set: ReadonlySet<string>, ids: string[]): boolean {
  return ids.length > 0 && ids.every((id) => set.has(id));
}

/** A partly queued pack is added, so one click never drops the scenes already queued. */
export function toggleAction(set: ReadonlySet<string>, ids: string[]): 'add' | 'remove' {
  return watching(set, ids) ? 'remove' : 'add';
}

/** The queued ids after an event: a `watchlist` event carries all of them. */
export function nextIds(current: ReadonlySet<string>, ev: ServerEvent): ReadonlySet<string> {
  return ev.type === 'watchlist' ? new Set(ev.ids) : current;
}

/** The Stash scenes a download status points at; none until Stash has its files. */
export function statusScenes(status: Status | null): string[] {
  return status?.kind === 'inStash' || status?.kind === 'identified' ? status.scenes : [];
}
