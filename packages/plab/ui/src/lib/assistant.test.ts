import { describe, expect, it } from 'vitest';
import { Latest } from './latest';
import { resolvePick, lastFailed, upsertSummary, shouldNavigate, openTarget, pickNote } from './assistant';
import type { Conversation, PickedTopic } from './types';

const topic = { id: 5, title: 'Alpha One', section: 'video' } as PickedTopic;
const conv: Conversation = {
  id: 1, title: 't', kind: 'chat', updatedAt: 2, now: 3, topicUrl: 'u', degraded: [], scenesUnavailable: false,
  turns: [
    { seq: 1, role: 'user', text: 'hi', picks: [], error: null },
    { seq: 2, role: 'assistant', text: 'x', picks: [
      { ref: 't:5', action: 'download', reason: 'r' },
      { ref: 's:4', action: 'watch', reason: 'w' },
      { ref: 't:9', action: 'stream', reason: 'missing' },
    ], error: null },
  ],
  topics: [topic],
  scenes: [{ ref: 's:4', id: '4', title: 'S', studio: null, performers: [], screenshot: null, link: null }],
};

describe('resolvePick', () => {
  it('finds topics and scenes by ref', () => {
    const [a, b, c] = conv.turns[1].picks.map((p) => resolvePick(conv, p));
    expect(a).toEqual({ kind: 'topic', topic, pick: conv.turns[1].picks[0] });
    expect(b?.kind).toBe('scene');
    expect(c).toBeNull();
  });
});

describe('lastFailed', () => {
  it('is true when the last turn is an error or an unanswered user turn', () => {
    expect(lastFailed(conv)).toBe(false);
    const failed = { ...conv, turns: [...conv.turns, { seq: 3, role: 'assistant' as const, text: '', picks: [], error: 'boom' }] };
    expect(lastFailed(failed)).toBe(true);
    const unanswered = { ...conv, turns: [...conv.turns, { seq: 3, role: 'user' as const, text: 'more', picks: [], error: null }] };
    expect(lastFailed(unanswered)).toBe(true);
    expect(lastFailed({ ...conv, turns: [] })).toBe(false);
  });
});

describe('upsertSummary', () => {
  it('moves the conversation to the top', () => {
    const list = [{ id: 2, title: 'b', kind: 'chat' as const, updatedAt: 1 }, { id: 1, title: 'old', kind: 'chat' as const, updatedAt: 0 }];
    expect(upsertSummary(list, conv).map((c) => [c.id, c.title])).toEqual([[1, 't'], [2, 'b']]);
  });
});

describe('shouldNavigate', () => {
  it('only when the route is unchanged since the request began', () => {
    expect(shouldNavigate({ view: 'assistant', id: null }, { view: 'assistant', id: null })).toBe(true);
    expect(shouldNavigate({ view: 'assistant', id: 3 }, { view: 'assistant', id: 3 })).toBe(true);
    expect(shouldNavigate({ view: 'assistant', id: 3 }, { view: 'assistant', id: 4 })).toBe(false);
    expect(shouldNavigate({ view: 'assistant', id: null }, { view: 'jobs' })).toBe(false);
  });
});

describe('openTarget', () => {
  it('clears, keeps or fetches', () => {
    expect(openTarget(5, null)).toBe('clear');
    expect(openTarget(null, null)).toBe('clear');
    expect(openTarget(5, 5)).toBe('keep');
    expect(openTarget(5, 6)).toBe('fetch');
    expect(openTarget(null, 6)).toBe('fetch');
  });
});

describe('Latest guarding open()', () => {
  it('lets only the newest request write', () => {
    const latest = new Latest<'open'>();
    const a = latest.next('open');
    const b = latest.next('open');
    expect(latest.current('open', a)).toBe(false);
    expect(latest.current('open', b)).toBe(true);
  });
});

describe('pickNote', () => {
  it('stands in for the actions of an expired search pick only', () => {
    expect(pickNote({ ...topic, expired: true })).toBe('Search result expired, search again');
    expect(pickNote({ ...topic, expired: false })).toBeNull();
    expect(pickNote(topic)).toBeNull();
  });
});
