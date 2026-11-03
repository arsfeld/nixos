import { expect, it } from 'vitest';
import { nextSeen, WINDOW } from './seen';

it('marks nothing new on the first visit', () => {
  const r = nextSeen(null, ['1', '2'], 1000);
  expect(r.newIds.size).toBe(0);
  expect(r.next).toEqual({ prev: ['1', '2'], cur: ['1', '2'], at: 1000 });
});

it('keeps the previous mark inside the window', () => {
  const r = nextSeen({ prev: ['1'], cur: ['1', '2'], at: 1000 }, ['1', '2', '3'], 1000 + WINDOW);
  expect([...r.newIds]).toEqual(['2', '3']);
  expect(r.next).toEqual({ prev: ['1'], cur: ['1', '2', '3'], at: 1000 });
});

it('moves the mark after the window', () => {
  const r = nextSeen({ prev: ['1'], cur: ['1', '2'], at: 1000 }, ['1', '2', '3'], 1001 + WINDOW);
  expect([...r.newIds]).toEqual(['3']);
  expect(r.next).toEqual({ prev: ['1', '2'], cur: ['1', '2', '3'], at: 1001 + WINDOW });
});

it('reads the oldest format, a bare array', () => {
  const r = nextSeen([1, 2], ['1', '2', '3'], 5);
  expect([...r.newIds]).toEqual(['3']);
});
