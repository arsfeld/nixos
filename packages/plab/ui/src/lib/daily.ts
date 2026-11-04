import { resolvePick, type Resolved } from './assistant';
import type { Conversation, Daily, TurnData } from './types';

/** The daily's answer: its first assistant turn, the one that answers the canned ask. */
export function dailyAnswer(c: Conversation): TurnData | null {
  return c.turns.find((t) => t.role === 'assistant') ?? null;
}

/** A turn's resolvable picks: scenes to watch, and releases to stream or download. */
export function groupPicks(c: Conversation, t: TurnData): { watch: Resolved[]; get: Resolved[] } {
  const out: { watch: Resolved[]; get: Resolved[] } = { watch: [], get: [] };
  for (const p of t.picks) {
    const r = resolvePick(c, p);
    if (r) (r.kind === 'scene' ? out.watch : out.get).push(r);
  }
  return out;
}

/** What For you shows: nothing loaded yet, the very first picks being made, picks, or none. */
export function show(d: Daily | null): 'loading' | 'first' | 'picks' | 'empty' {
  if (d === null) return 'loading';
  if (d.conversation) return 'picks';
  return d.refreshing ? 'first' : 'empty';
}
