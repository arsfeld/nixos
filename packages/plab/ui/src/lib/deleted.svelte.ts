import { deleteScenes } from './api';
import { allDeleted, nextDeleted } from './deleted';
import type { ServerEvent } from './types';

/** The scenes deleted while this page is open, so their cards go at once. Lists fetched
 * later already leave them out. */
class DeletedStore {
  ids = $state<ReadonlySet<string>>(new Set());

  apply(ev: ServerEvent) {
    this.ids = nextDeleted(this.ids, ev);
  }

  has(scenes: string[]): boolean {
    return allDeleted(this.ids, scenes);
  }

  /** Delete `scenes`. Throws the server's error. */
  async delete(scenes: string[]) {
    const ids = await deleteScenes(scenes);
    this.ids = new Set([...this.ids, ...ids]);
  }
}

export const deleted = new DeletedStore();
