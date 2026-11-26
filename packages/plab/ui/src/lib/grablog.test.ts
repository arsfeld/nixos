import { expect, it } from 'vitest';
import { keyLabels, pickLabel, runtime, studios } from './grablog';

it('prints running times like Stash', () => {
  expect(runtime(59.6)).toBe('1:00');
  expect(runtime(1800)).toBe('30:00');
  expect(runtime(3725)).toBe('1:02:05');
});

it('orders studios by grabs, then name', () => {
  expect(studios([{ studio: 'B' }, { studio: 'A' }, { studio: 'C' }, { studio: 'C' }])).toEqual([
    ['C', 2],
    ['A', 1],
    ['B', 1],
  ]);
});

it('describes the winning copy', () => {
  const r = { query: 'q', indexer: '1337x', seeders: 42, size: 1024 * 1024 * 1024, published: null, copies: 3 };
  expect(pickLabel(r)).toBe('1337x · 42 seeders · 1.0 GB · best of 3 copies');
  expect(pickLabel({ ...r, indexer: null, seeders: null, size: null, copies: 1 })).toBe('unknown indexer · only copy');
});

it('reads scene keys', () => {
  expect(keyLabels(['dated:2026-11-03:ann-ben', 'ep:2283', 'name:annandben', 'words:ann-ben'])).toEqual([
    'released 2026-11-03',
    'episode 2283',
  ]);
  expect(keyLabels(['name:annandben', 'words:ann-ben'])).toEqual(['title “annandben”']);
  expect(keyLabels(['words:ann-ben'])).toEqual(['title “ann ben”']);
  expect(keyLabels(['odd'])).toEqual(['odd']);
});
