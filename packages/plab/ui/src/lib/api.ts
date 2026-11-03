import type { AddReply, Grab, Job, List, Section } from './types';

export class HttpError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
  }
}

/** A network failure (an expired session redirecting cross-origin, say) rejects with a TypeError. */
async function reach(f: () => Promise<Response>): Promise<Response> {
  try {
    return await f();
  } catch (e) {
    if (e instanceof TypeError) throw new Error('plab not reachable — reload the page');
    throw e;
  }
}

async function getJson<T>(url: string): Promise<T> {
  const r = await reach(() => fetch(url));
  if (!r.ok) {
    // Only plab's own plain-text errors are worth showing; a gateway answers with HTML.
    const plain = r.headers.get('content-type')?.startsWith('text/plain');
    throw new HttpError((plain && (await r.text())) || `HTTP ${r.status}`, r.status);
  }
  return (await r.json()) as T;
}

export const fetchList = (section: Section) => getJson<List>(`/api/list?section=${section}`);
export const fetchSearch = (q: string) => getJson<List>(`/api/search?q=${encodeURIComponent(q)}`);
export const fetchGrabs = () => getJson<{ now: number; grabs: Grab[] }>('/api/grabs');
export const fetchJobs = () => getJson<{ now: number; jobs: Job[] }>('/api/jobs');
export const fetchImages = (id: number) => getJson<{ images: string[] }>(`/api/images/${id}`);
export const imgUrl = (key: string) => `/api/img/${key}`;
export const thumbUrl = (id: number) => `/api/thumb/${id}`;

/** Add or unqueue. A reply that is not JSON (a gateway's error page) asks for a reload. */
export async function postTopic(action: 'add' | 'unqueue', id: number): Promise<AddReply> {
  const r = await reach(() => fetch(`/api/${action}/${id}`, { method: 'POST' }));
  let j: AddReply;
  try {
    j = (await r.json()) as AddReply;
  } catch {
    throw new Error(`HTTP ${r.status} — reload the page`);
  }
  if (!j.ok) throw new Error(j.error ?? `HTTP ${r.status}`);
  return j;
}

/** A call under /api/stream/: its JSON when ok, else an HttpError with its reason. */
export async function streamCall<T>(path: string, method = 'GET'): Promise<T> {
  const r = await fetch(`/api/stream/${path}`, { method });
  let j: { ok: boolean; error?: string } & T;
  try {
    j = await r.json();
  } catch {
    throw new HttpError(`HTTP ${r.status}`, r.status);
  }
  if (!j.ok) throw new HttpError(j.error ?? `HTTP ${r.status}`, r.status);
  return j;
}
