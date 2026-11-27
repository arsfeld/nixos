import { expect, it } from 'vitest';
import { allDeleted, nextDeleted } from './deleted';

it('adds the ids a deleted event carries and ignores other events', () => {
  const s = nextDeleted(new Set(['a']), { type: 'deleted', ids: ['b'] });
  expect([...s].sort()).toEqual(['a', 'b']);
  const same = new Set(['a']);
  expect(nextDeleted(same, { type: 'resync' })).toBe(same);
});

it('counts a card deleted only when every scene is', () => {
  const s = new Set(['a', 'b']);
  expect(allDeleted(s, ['a', 'b'])).toBe(true);
  expect(allDeleted(s, ['a', 'c'])).toBe(false);
  expect(allDeleted(s, [])).toBe(false);
});
