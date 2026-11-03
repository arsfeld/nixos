import { expect, it } from 'vitest';
import { jobWhen } from './jobtime';
import type { Job } from './types';

const job = (over: Partial<Job>): Job => ({
  name: 'grab', state: 'idle', since: null, pending: null, restart_at: null, next: null,
  step: null, progress: null, lines: [], runs: [], ...over,
});

it('says how long it has run, until it restarts, or until its next slot', () => {
  expect(jobWhen(job({ state: 'running', since: 100 }), 165)).toBe('running for 1m 5s');
  expect(jobWhen(job({ state: 'restarting', restart_at: 130 }), 100)).toBe('restarting in 30s');
  expect(jobWhen(job({ next: 100 + 3600 }), 100)).toBe('next in 1h 0m');
  expect(jobWhen(job({ state: 'watching' }), 100)).toBe('');
});
