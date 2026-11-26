// Votes' pure logic: what a card's thumbs show, what pressing one does, and the order of
// Recently watched. Design: docs/superpowers/specs/2026-11-26-plab-taste-feedback-design.md.
import type { ServerEvent, Votes } from './types';

export type Vote = 1 | -1 | 0;

/** ±1 only when there are scenes and every one has that vote. */
export function voteOf(votes: Votes, scenes: string[]): Vote {
  if (!scenes.length) return 0;
  const first = votes[scenes[0]] ?? 0;
  return scenes.every((id) => (votes[id] ?? 0) === first) ? first : 0;
}

/** Pressing the lit thumb clears it; any other press sets the pressed vote. */
export function voteAction(current: Vote, pressed: 1 | -1): Vote {
  return current === pressed ? 0 : pressed;
}

/** The votes after an event: a `votes` event carries all of them. */
export function nextVotes(current: Votes, ev: ServerEvent): Votes {
  return ev.type === 'votes' ? ev.votes : current;
}

/** Scenes not yet voted on first, each group in its given order. */
export function unvotedFirst<T extends { id: string }>(scenes: T[], votes: Votes): T[] {
  return [...scenes.filter((s) => !(s.id in votes)), ...scenes.filter((s) => s.id in votes)];
}
