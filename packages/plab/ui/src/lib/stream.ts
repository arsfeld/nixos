import type { Stats, StreamFile } from './types';

/** The player's progress line for a live stream. */
export function streamProgress(s: Stats, files: StreamFile[], selected: number | null, elapsedMs: number): string {
  if (s.peers === 0 && elapsedMs > 60000) return 'no peers yet';
  const gib = (b: number) => (b / 1073741824).toFixed(2) + ' GiB';
  const f = files.find((x) => x.index === selected);
  const name = f ? f.name.split('/').pop() + ' · ' : '';
  const pct = s.total > 0 ? ((s.progress / s.total) * 100).toFixed(1) : '0.0';
  const state = s.state !== 'live' ? ' · ' + s.state : '';
  return `${name}${pct}% of ${gib(s.total)} · ${s.mbps.toFixed(1)} MiB/s · ${s.peers} peers${state}`;
}
