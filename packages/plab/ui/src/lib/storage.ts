// localStorage can be missing or throw (private windows, blocked storage): every read
// falls back to nothing, every write may silently fail.

export function readStr(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function writeStr(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* not persisted */
  }
}

export function readJson(key: string): unknown {
  const s = readStr(key);
  if (s === null) return null;
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}
