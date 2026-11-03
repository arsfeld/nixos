// "New since your last visit", ported from page.js initSeen. The stored record holds the
// ids at the previous mark (prev) and now (cur); the mark moves once 30 minutes have
// passed, so a reload within a visit keeps showing the same cards as new.

export const WINDOW = 30 * 60 * 1000;

export interface SeenRecord {
  prev: string[];
  cur: string[];
  at: number;
}

export function nextSeen(raw: unknown, ids: string[], now: number): { next: SeenRecord; newIds: Set<string> } {
  let rec: SeenRecord | null = null;
  if (Array.isArray(raw)) rec = { prev: raw.map(String), cur: raw.map(String), at: now };
  else if (raw && typeof raw === 'object') {
    const r = raw as { prev?: unknown; cur?: unknown; at?: unknown };
    if (Array.isArray(r.prev) && Array.isArray(r.cur))
      rec = { prev: r.prev.map(String), cur: r.cur.map(String), at: Number(r.at) || 0 };
  }
  let next: SeenRecord;
  if (!rec) next = { prev: ids, cur: ids, at: now };
  else if (now - rec.at > WINDOW) next = { prev: rec.cur, cur: ids, at: now };
  else next = { prev: rec.prev, cur: ids, at: rec.at };
  const prev = new Set(next.prev);
  const newIds = rec ? new Set(ids.filter((id) => !prev.has(id))) : new Set<string>();
  return { next, newIds };
}
