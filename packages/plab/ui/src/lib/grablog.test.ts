import { expect, it } from 'vitest';
import { keyLabels, pickLabel } from './grablog';

it('describes the winning copy', () => {
  const r = { query: 'q', indexer: '1337x', seeders: 42, size: 1024 * 1024 * 1024, published: null, copies: 3 };
  expect(pickLabel(r)).toBe('1337x · 42 seeders · 1.0 GB · best of 3 copies');
  expect(pickLabel({ ...r, indexer: null, seeders: null, size: null, copies: 1 })).toBe('unknown indexer · only copy');
});

it('reads scene keys', () => {
  expect(
    keyLabels(['dated:2026-11-03:ann-ben', 'ep:2283', 'name:annandben', 'words:ann-ben', 'odd']),
  ).toEqual(['released 2026-11-03', 'episode 2283', 'title “annandben”', 'title “ann ben”', 'odd']);
});
