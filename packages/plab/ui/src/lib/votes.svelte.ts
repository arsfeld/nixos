import { fetchVotes, postVotes } from './api';
import type { ServerEvent, Votes } from './types';
import { nextVotes, type Vote } from './votes';

/** Every vote, shared by every pair of thumbs on the page. */
class VotesStore {
  map = $state<Votes>({});

  async load() {
    try {
      this.map = await fetchVotes();
    } catch {
      /* thumbs stay as they were; the next event or reconnect retries */
    }
  }

  apply(ev: ServerEvent) {
    this.map = nextVotes(this.map, ev);
  }

  /** Set `scenes` to `vote` (0 clears). Throws the server's error. */
  async set(scenes: string[], vote: Vote) {
    this.map = await postVotes(scenes, vote);
  }
}

export const votes = new VotesStore();
