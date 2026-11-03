import { expect, test } from 'vitest';
import { Latest } from './latest';

test('only the latest request per key is current', () => {
  const l = new Latest<'a' | 'b'>();
  const first = l.next('a');
  const second = l.next('a');
  expect(l.current('a', first)).toBe(false);
  expect(l.current('a', second)).toBe(true);
  const other = l.next('b');
  expect(l.current('a', second)).toBe(true);
  expect(l.current('b', other)).toBe(true);
});
