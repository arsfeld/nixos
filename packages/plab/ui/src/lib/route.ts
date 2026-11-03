import type { Section } from './types';

export type Route =
  | { view: Section }
  | { view: 'search'; q: string }
  | { view: 'jobs' }
  | { view: 'assistant'; id: number | null };

/** The view for a URL; anything unknown is the video list. */
export function parse(path: string, search: string): Route {
  if (path === '/assistant' || path.startsWith('/assistant/')) {
    const n = Number(path.slice('/assistant/'.length));
    return { view: 'assistant', id: Number.isInteger(n) && n > 0 ? n : null };
  }
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
