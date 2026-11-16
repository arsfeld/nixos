import { expect, it } from 'vitest';
import { nextIds, statusScenes, toggleAction, watching } from './watchlist';

it('is watching only when every scene is queued', () => {
  expect(watching(new Set(['1', '2']), ['1', '2'])).toBe(true);
  expect(watching(new Set(['1']), ['1', '2'])).toBe(false);
  expect(watching(new Set(), [])).toBe(false);
});

it('adds a partly queued pack rather than removing it', () => {
  expect(toggleAction(new Set(['1', '2']), ['1', '2', '3'])).toBe('add');
  expect(toggleAction(new Set(['1']), ['1'])).toBe('remove');
});

it('takes the ids from a watchlist event and ignores others', () => {
  const now = new Set(['1']);
  expect(nextIds(now, { type: 'watchlist', ids: ['9'] })).toEqual(new Set(['9']));
  expect(nextIds(now, { type: 'resync' })).toBe(now);
});

it('reads the scenes off a status', () => {
  expect(statusScenes({ kind: 'inStash', link: null, scenes: ['4', '5'] })).toEqual(['4', '5']);
  expect(statusScenes({ kind: 'identified', label: 'x', more: 0, guess: false, link: null, scenes: ['7'] })).toEqual(['7']);
  expect(statusScenes({ kind: 'added' })).toEqual([]);
  expect(statusScenes(null)).toEqual([]);
});
