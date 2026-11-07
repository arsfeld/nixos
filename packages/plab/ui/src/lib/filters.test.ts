import { describe, expect, it } from 'vitest';
import { empty, fromHash, isVisible, mostCommon, offered, prune, toHash } from './filters';
import type { List, Topic } from './types';

const topic = (over: Partial<Topic> = {}): Topic => ({
  id: 1, title: 't', name: 'n', studio: 'Studio', quality: '1080p', category: 'Couples',
  production: 'amateur', tags: ['a', 'b'], filters: ['couples'], size: 1, seeders: 1,
  leechers: 0, added: 0, images: [], state: '', status: null, source: null, link: null, kind: 'tracker', files: null, also: [], ownedBy: null, ...over,
});

describe('hash', () => {
  it('reads the format the old page wrote', () => {
    const s = fromHash('#h24=1&cat=Foo%20Bar&f=couples&tags=a,b%20c');
    expect(s).toEqual({ ...empty(), h24: true, cat: 'Foo Bar', f: 'couples', tags: ['a', 'b c'] });
  });
  it('round-trips, in the old key order', () => {
    const s = { ...empty(), new: true, hide: true, q: '4K', prod: 'amateur', tags: ['x,y'] };
    expect(toHash(s)).toBe('new=1&hide=1&q=4K&prod=amateur&tags=x%2Cy');
    expect(fromHash(toHash(s))).toEqual(s);
    expect(toHash(empty())).toBe('');
  });
  it('ignores junk', () => {
    expect(fromHash('#zzz=1&cat=%E0%A4%A&&tags=,,')).toEqual(empty());
  });
});

describe('isVisible', () => {
  it('passes everything with no filters', () => {
    expect(isVisible(empty(), topic(), false, false)).toBe(true);
  });
  it('applies each filter', () => {
    const t = topic();
    expect(isVisible({ ...empty(), h24: true }, t, false, false)).toBe(false);
    expect(isVisible({ ...empty(), h24: true }, t, true, false)).toBe(true);
    expect(isVisible({ ...empty(), new: true }, t, false, false)).toBe(false);
    expect(isVisible({ ...empty(), hide: true }, topic({ state: 'queued' }), false, false)).toBe(false);
    expect(isVisible({ ...empty(), f: 'other' }, t, false, false)).toBe(false);
    expect(isVisible({ ...empty(), cat: 'Couples', q: '1080p', studio: 'Studio', prod: 'amateur' }, t, false, false)).toBe(true);
    expect(isVisible({ ...empty(), studio: 'Studio' }, topic({ studio: null }), false, false)).toBe(false);
  });
  it('ANDs tags', () => {
    expect(isVisible({ ...empty(), tags: ['a', 'b'] }, topic(), false, false)).toBe(true);
    expect(isVisible({ ...empty(), tags: ['a', 'c'] }, topic(), false, false)).toBe(false);
  });
});

describe('facets', () => {
  it('counts by frequency, ties alphabetical, blanks dropped', () => {
    expect(mostCommon(['b', 'a', 'b', '', 'c', 'a'])).toEqual([['a', 2], ['b', 2], ['c', 1]]);
  });
  it('drops a saved value no longer offered, and keeps the object when nothing changes', () => {
    const list = { curatedFilters: ['couples'], topics: [topic()] } as List;
    const o = offered(list);
    const ok = { ...empty(), studio: 'Studio', f: 'couples' };
    expect(prune(ok, o)).toBe(ok);
    expect(prune({ ...ok, studio: 'Gone', f: 'renamed' }, o)).toEqual({ ...empty() });
  });
});
