import { expect, it } from 'vitest';
import { sceneTaken, statusText } from './status';
import type { Topic } from './types';

it('reads each status as the page always has', () => {
  expect(statusText({ kind: 'queued' })).toBe('queued');
  expect(statusText({ kind: 'downloading', percent: 42 })).toBe('downloading 42%');
  expect(statusText({ kind: 'added' })).toBe('added');
  expect(statusText({ kind: 'inStash', link: null })).toBe('in Stash');
  expect(statusText({ kind: 'identified', label: 'S – T', more: 2, guess: true, link: null })).toBe('S – T +2 (guess)');
  expect(statusText({ kind: 'identified', label: 'S – T', more: 0, guess: false, link: null })).toBe('S – T');
  expect(statusText({ kind: 'failed', reason: 'lost', detail: 'x' })).toBe('failed: lost');
});

const card = (over: Partial<Topic> = {}): Topic => ({
  id: 1, title: '', name: '', studio: null, quality: null, category: '', production: null, tags: [],
  filters: [], size: 0, seeders: 0, leechers: 0, added: 0, images: [], state: '', status: null,
  source: null, link: null, kind: 'tracker', files: null, also: [], ownedBy: null, ...over,
});
const also = (state: Topic['state']) => ({ id: 2, source: 'Indexer A', seeders: 1, size: 0, quality: null, link: null, state });

it('a scene is taken once any of its releases is queued or added, or it is owned', () => {
  expect(sceneTaken(card())).toBe(false);
  expect(sceneTaken(card({ also: [also('')] }))).toBe(false);
  expect(sceneTaken(card({ state: 'queued' }))).toBe(true);
  expect(sceneTaken(card({ also: [also('added')] }))).toBe(true);
  expect(sceneTaken(card({ ownedBy: 4 }))).toBe(true);
});
