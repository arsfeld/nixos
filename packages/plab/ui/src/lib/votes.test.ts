import { expect, it } from 'vitest';
import { nextVotes, unvotedFirst, voteAction, voteOf } from './votes';

it('reads a vote only when every scene agrees', () => {
  expect(voteOf({ a: 1, b: 1 }, ['a', 'b'])).toBe(1);
  expect(voteOf({ a: -1 }, ['a'])).toBe(-1);
  expect(voteOf({ a: 1 }, ['a', 'b'])).toBe(0);
  expect(voteOf({ a: 1, b: -1 }, ['a', 'b'])).toBe(0);
  expect(voteOf({}, [])).toBe(0);
});

it('toggles the pressed thumb and switches to the other', () => {
  expect(voteAction(0, 1)).toBe(1);
  expect(voteAction(1, 1)).toBe(0);
  expect(voteAction(1, -1)).toBe(-1);
  expect(voteAction(-1, -1)).toBe(0);
});

it('takes the map from a votes event and ignores others', () => {
  const now = { a: 1 as const };
  expect(nextVotes(now, { type: 'votes', votes: { b: -1 } })).toEqual({ b: -1 });
  expect(nextVotes(now, { type: 'watchlist', ids: [] })).toBe(now);
});

it('puts unvoted scenes first and keeps order within each group', () => {
  const s = ['a', 'b', 'c', 'd'].map((id) => ({ id }));
  expect(unvotedFirst(s, { a: 1, c: -1 }).map((x) => x.id)).toEqual(['b', 'd', 'a', 'c']);
});
