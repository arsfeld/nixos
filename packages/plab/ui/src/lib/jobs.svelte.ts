import { fetchJobs } from './api';
import { clock } from './clock.svelte';
import type { Job, ServerEvent } from './types';

class Jobs {
  list = $state<Job[]>([]);
  error = $state('');

  async load() {
    try {
      const r = await fetchJobs();
      this.list = r.jobs;
      clock.sync(r.now);
      this.error = '';
    } catch {
      this.error = 'plab not responding';
    }
  }

  apply(ev: ServerEvent) {
    if (ev.type !== 'job') return;
    const { type: _type, ...job } = ev;
    const i = this.list.findIndex((j) => j.name === job.name);
    if (i >= 0) this.list[i] = job;
  }
}

export const jobs = new Jobs();
