import { describe, expect, it } from 'vitest';
import { age, day, duration, freshShort, isFresh, size } from './format';

describe('format', () => {
  it('sizes in binary units', () => {
    expect(size(512)).toBe('512 B');
    expect(size(2048)).toBe('2.0 KB');
    expect(size(5 * 1024 * 1024)).toBe('5.0 MB');
    expect(size(3.5 * 1024 ** 3)).toBe('3.5 GB');
  });
  it('ages in minutes then hours', () => {
    expect(age(0, 100)).toBe('never');
    expect(age(1000, 1000 + 59 * 60)).toBe('59 min ago');
    expect(age(1000, 1000 + 125 * 60)).toBe('2 h ago');
    expect(age(2000, 1000)).toBe('0 min ago');
    expect(freshShort(1000, 1000 + 5 * 60)).toBe('5m');
    expect(freshShort(1000, 1000 + 3 * 3600)).toBe('3h');
  });
  it('is fresh under a day', () => {
    expect(isFresh(1000, 1000 + 86399)).toBe(true);
    expect(isFresh(1000, 1000 + 86400)).toBe(false);
  });
  it('dates in UTC', () => {
    expect(day(1793501999)).toBe('2026-11-01');
  });
  it('durations', () => {
    expect(duration(42)).toBe('42s');
    expect(duration(125)).toBe('2m 5s');
    expect(duration(3 * 3600 + 7 * 60)).toBe('3h 7m');
  });
});
