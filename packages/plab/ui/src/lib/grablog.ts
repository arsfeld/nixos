import { size } from './format';
import type { GrabReason } from './types';

/** How the chosen copy won: where it came from, how well seeded, against how many others. */
export function pickLabel(r: GrabReason): string {
  const parts = [r.indexer ?? 'unknown indexer'];
  if (r.seeders !== null) parts.push(`${r.seeders} seeders`);
  if (r.size !== null) parts.push(size(r.size));
  parts.push(r.copies > 1 ? `best of ${r.copies} copies` : 'only copy');
  return parts.join(' · ');
}

/** A scene key as a person reads it: `ep:2283` is an episode, `dated:` a release date. */
export function keyLabel(k: string): string {
  const [kind, rest] = [k.slice(0, k.indexOf(':')), k.slice(k.indexOf(':') + 1)];
  switch (kind) {
    case 'ep':
      return `episode ${rest}`;
    case 'dated':
      return `released ${rest.slice(0, rest.indexOf(':'))}`;
    case 'name':
    case 'words':
      return `title “${rest.replaceAll('-', ' ')}”`;
    default:
      return k;
  }
}

/** A running time as Stash prints it: `m:ss`, or `h:mm:ss`. */
export function runtime(s: number): string {
  const t = Math.round(s);
  const ss = String(t % 60).padStart(2, '0');
  const m = Math.floor(t / 60);
  return m < 60 ? `${m}:${ss}` : `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}:${ss}`;
}

/** The studios on the page, by how many grabs each has, then by name. */
export function studios(grabs: { studio: string }[]): [string, number][] {
  const n = new Map<string, number>();
  for (const g of grabs) n.set(g.studio, (n.get(g.studio) ?? 0) + 1);
  return [...n].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

/** What made the scene new, briefly: its episode or release date when it has one, else its
 * title (the word-sorted form only when there is no other). */
export function keyLabels(keys: string[]): string[] {
  const strong = keys.filter((k) => k.startsWith('ep:') || k.startsWith('dated:'));
  const title = keys.find((k) => k.startsWith('name:')) ?? keys.find((k) => k.startsWith('words:'));
  const picked = strong.length ? strong : title ? [title] : keys;
  return [...new Set(picked.map(keyLabel))];
}
