import { duration } from './format';
import type { Job } from './types';

/** A job card's header time: how long it has run, until it restarts, or until its next slot. */
export function jobWhen(j: Job, now: number): string {
  switch (j.state) {
    case 'running':
      return j.since !== null ? `running for ${duration(now - j.since)}` : 'running';
    case 'restarting':
      return j.restart_at !== null ? `restarting in ${duration(Math.max(0, j.restart_at - now))}` : 'restarting';
    default:
      return j.next !== null ? `next in ${duration(Math.max(0, j.next - now))}` : '';
  }
}
