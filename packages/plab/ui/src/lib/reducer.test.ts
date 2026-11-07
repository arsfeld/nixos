import { expect, it } from 'vitest';
import { applyTopic } from './reducer';
import type { List, Topic } from './types';

const t = (id: number): Topic => ({
  id, title: '', name: '', studio: null, quality: null, category: '', production: null, tags: [],
  filters: [], size: 0, seeders: 0, leechers: 0, added: 0, images: [], state: '', status: null, source: null, link: null, kind: 'tracker', files: null, also: [], ownedBy: null,
});
const list = (...ids: number[]) => ({ topics: ids.map(t) }) as List;

it('patches the topic in every list that holds it', () => {
  const a = list(1, 2);
  const b = list(2, 3);
  applyTopic([a, b], { type: 'topicState', id: 2, state: 'added' });
  expect([a.topics[1].state, b.topics[0].state, b.topics[1].state]).toEqual(['added', 'added', '']);
  applyTopic([a, b], { type: 'topicStatus', id: 2, status: { kind: 'downloading', percent: 5 } });
  expect(a.topics[1].status).toEqual({ kind: 'downloading', percent: 5 });
  expect(a.topics[1].state).toBe('added');
});

it('ignores other events', () => {
  const a = list(1);
  applyTopic([a], { type: 'listing', section: 'video' });
  expect(a.topics[0]).toEqual(t(1));
});

it('updates a matching also entry and leaves its card alone', () => {
  const a = list(1);
  a.topics[0].also = [{ id: 2, source: 'Indexer A', seeders: 4, size: 0, quality: null, link: null, state: '' }];
  applyTopic([a], { type: 'topicState', id: 2, state: 'added' });
  expect(a.topics[0].also[0].state).toBe('added');
  expect(a.topics[0].state).toBe('');
});
