// The page's number and time formats, ported from page.rs.

export function size(n: number): string {
  if (n < 1024) return `${n} B`;
  let x = n / 1024;
  for (const unit of ['KB', 'MB']) {
    if (x < 1024) return `${x.toFixed(1)} ${unit}`;
    x /= 1024;
  }
  return `${x.toFixed(1)} GB`;
}

const minutes = (t: number, now: number) => Math.max(0, Math.floor((now - t) / 60));

export function age(t: number, now: number): string {
  if (t === 0) return 'never';
  const m = minutes(t, now);
  return m < 60 ? `${m} min ago` : `${Math.floor(m / 60)} h ago`;
}

export function freshShort(t: number, now: number): string {
  const m = minutes(t, now);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h`;
}

/** Uploaded within the last day. */
export const isFresh = (added: number, now: number) => now - added < 86400;

/** YYYY-MM-DD in UTC, as the server rendered it. */
export const day = (t: number) => new Date(t * 1000).toISOString().slice(0, 10);

export function duration(s: number): string {
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}
