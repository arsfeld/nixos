import { parse, type Route } from './route';

class Router {
  route = $state<Route>(parse(location.pathname, location.search));

  constructor() {
    addEventListener('popstate', () => {
      this.route = parse(location.pathname, location.search);
    });
  }

  go(url: string) {
    const u = new URL(url, location.href);
    history.pushState(null, '', u.pathname + u.search + u.hash);
    this.route = parse(u.pathname, u.search);
  }
}

export const router = new Router();

/** `use:link` on an <a>: a plain left click navigates in the app. */
export function link(node: HTMLAnchorElement) {
  const on = (e: MouseEvent) => {
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    router.go(node.href);
  };
  node.addEventListener('click', on);
  return { destroy: () => node.removeEventListener('click', on) };
}
