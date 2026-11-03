import { expect, it } from 'vitest';
import { streamProgress } from './stream';

const stats = { progress: 512 * 1024 ** 2, total: 1024 ** 3, finished: false, mbps: 3.25, peers: 4, state: 'live' };
const files = [{ index: 0, name: 'Rel/a.mp4', length: 1 }];

it('reads like the old player', () => {
  expect(streamProgress(stats, files, 0, 1000)).toBe('a.mp4 · 50.0% of 1.00 GiB · 3.3 MiB/s · 4 peers');
  expect(streamProgress({ ...stats, state: 'paused' }, [], null, 1000)).toBe('50.0% of 1.00 GiB · 3.3 MiB/s · 4 peers · paused');
  expect(streamProgress({ ...stats, peers: 0 }, files, 0, 61000)).toBe('no peers yet');
  expect(streamProgress({ ...stats, total: 0 }, [], null, 0)).toContain('0.0% of 0.00 GiB');
});
