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

/** Distinct readable keys, in the order given. */
export const keyLabels = (keys: string[]) => [...new Set(keys.map(keyLabel))];
