import { afterEach, expect, test, vi } from 'vitest';
import { fetchJobs, postTopic } from './api';

afterEach(() => vi.unstubAllGlobals());

const stub = (f: () => Promise<Response>) => vi.stubGlobal('fetch', vi.fn(f));

test('a plain-text error body is the message', async () => {
  stub(async () => new Response('db locked', { status: 500, headers: { 'content-type': 'text/plain; charset=utf-8' } }));
  await expect(fetchJobs()).rejects.toThrow('db locked');
});

test('a gateway html error page becomes HTTP <status>', async () => {
  stub(async () => new Response('<html>oops</html>', { status: 503, headers: { 'content-type': 'text/html' } }));
  await expect(fetchJobs()).rejects.toThrow('HTTP 503');
});

test('a network TypeError asks for a reload', async () => {
  stub(async () => {
    throw new TypeError('Failed to fetch');
  });
  await expect(fetchJobs()).rejects.toThrow('plab not reachable — reload the page');
  await expect(postTopic('add', 1)).rejects.toThrow('plab not reachable — reload the page');
});
