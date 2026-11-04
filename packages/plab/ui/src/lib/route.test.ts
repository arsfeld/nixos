import { expect, it } from 'vitest';
import { parse } from './route';

it('maps paths to views', () => {
  expect(parse('/', '')).toEqual({ view: 'daily' });
  expect(parse('/tracker', '')).toEqual({ view: 'video' });
  expect(parse('/games', '')).toEqual({ view: 'games' });
  expect(parse('/indexers', '')).toEqual({ view: 'indexers' });
  expect(parse('/albums', '')).toEqual({ view: 'albums' });
  expect(parse('/jobs', '')).toEqual({ view: 'jobs' });
  expect(parse('/search', '?q=%20alpha%20')).toEqual({ view: 'search', q: 'alpha' });
  expect(parse('/search', '?q=')).toEqual({ view: 'video' });
  expect(parse('/nowhere', '')).toEqual({ view: 'daily' });
});

it('parses the assistant routes', () => {
  expect(parse('/assistant', '')).toEqual({ view: 'assistant', id: null });
  expect(parse('/assistant/12', '')).toEqual({ view: 'assistant', id: 12 });
  expect(parse('/assistant/x', '')).toEqual({ view: 'assistant', id: null });
});
