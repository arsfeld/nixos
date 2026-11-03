import { describe, expect, it } from 'vitest';
import { resolvePick, lastFailed, upsertSummary } from './assistant';
import type { Conversation, Topic } from './types';

const topic = { id: 5, title: 'Alpha One' } as Topic;
const conv: Conversation = {
  id: 1, title: 't', kind: 'chat', updatedAt: 2, now: 3, topicUrl: 'u', degraded: [],
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
  it('is true only when the last turn is an error', () => {
    expect(lastFailed(conv)).toBe(false);
    const failed = { ...conv, turns: [...conv.turns, { seq: 3, role: 'assistant' as const, text: '', picks: [], error: 'boom' }] };
    expect(lastFailed(failed)).toBe(true);
  });
});

describe('upsertSummary', () => {
  it('moves the conversation to the top', () => {
    const list = [{ id: 2, title: 'b', kind: 'chat' as const, updatedAt: 1 }, { id: 1, title: 'old', kind: 'chat' as const, updatedAt: 0 }];
    expect(upsertSummary(list, conv).map((c) => [c.id, c.title])).toEqual([[1, 't'], [2, 'b']]);
  });
});
