import { expect, it } from 'vitest';
import { statusText } from './status';

it('reads each status as the page always has', () => {
  expect(statusText({ kind: 'queued' })).toBe('queued');
  expect(statusText({ kind: 'downloading', percent: 42 })).toBe('downloading 42%');
  expect(statusText({ kind: 'added' })).toBe('added');
  expect(statusText({ kind: 'inStash', link: null })).toBe('in Stash');
  expect(statusText({ kind: 'identified', label: 'S – T', more: 2, guess: true, link: null })).toBe('S – T +2 (guess)');
  expect(statusText({ kind: 'identified', label: 'S – T', more: 0, guess: false, link: null })).toBe('S – T');
  expect(statusText({ kind: 'failed', reason: 'lost', detail: 'x' })).toBe('failed: lost');
});
