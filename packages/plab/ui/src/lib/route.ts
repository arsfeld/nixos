import type { Section } from './types';

export type Route = { view: Section } | { view: 'search'; q: string } | { view: 'jobs' };

/** The view for a URL; anything unknown is the video list. */
export function parse(path: string, search: string): Route {
  switch (path) {
    case '/indexers':
      return { view: 'indexers' };
    case '/albums':
      return { view: 'albums' };
    case '/games':
      return { view: 'games' };
    case '/jobs':
      return { view: 'jobs' };
    case '/search': {
      const q = new URLSearchParams(search).get('q')?.trim() ?? '';
      return q ? { view: 'search', q } : { view: 'video' };
    }
    default:
      return { view: 'video' };
  }
}
