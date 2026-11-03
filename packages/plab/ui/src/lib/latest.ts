/** Per-key request tokens: only the latest request for a key may write its result. */
export class Latest<K extends string> {
  private n: Partial<Record<K, number>> = {};

  /** Start a request for `key`; any earlier one is stale from now on. */
  next(key: K): number {
    const t = (this.n[key] ?? 0) + 1;
    this.n[key] = t;
    return t;
  }

  current(key: K, token: number): boolean {
    return this.n[key] === token;
  }
}
