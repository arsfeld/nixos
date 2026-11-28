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

/** How long a play lasted, for a card: "45 s", "12 min", "1 h 5 min"; null when untimed. */
export function playedFor(secs: number | null): string | null {
  if (secs === null) return null;
  if (secs < 60) return `${secs} s`;
  const m = Math.floor(secs / 60);
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`;
}

/** Liked and disliked scenes by their vote now, not the one they were loaded with, so a
 * changed thumb moves a card at once and a cleared one drops it. */
export function byVote<T extends { id: string }>(scenes: T[], votes: Votes): { liked: T[]; disliked: T[] } {
  return {
    liked: scenes.filter((s) => votes[s.id] === 1),
    disliked: scenes.filter((s) => votes[s.id] === -1),
  };
}

/** Scenes not yet voted on first, each group in its given order. */
export function unvotedFirst<T extends { id: string }>(scenes: T[], votes: Votes): T[] {
  return [...scenes.filter((s) => !(s.id in votes)), ...scenes.filter((s) => s.id in votes)];
}
