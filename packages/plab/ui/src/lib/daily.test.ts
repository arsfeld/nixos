import { describe, expect, it } from 'vitest';
import { dailyAnswer, groupPicks, show } from './daily';
import type { Conversation, Daily, PickedTopic } from './types';

const topic = { id: 5, title: 'Alpha One', section: 'video' } as PickedTopic;
const conv: Conversation = {
  id: 1, title: 't', kind: 'recommend', updatedAt: 2, now: 3, topicUrl: 'u', degraded: [], scenesUnavailable: false,
  turns: [
    { seq: 1, role: 'user', text: 'ask', picks: [], error: null },
    { seq: 2, role: 'assistant', text: 'Here.', picks: [
      { ref: 't:5', action: 'download', reason: 'r' },
      { ref: 's:4', action: 'watch', reason: 'w' },
      { ref: 't:9', action: 'stream', reason: 'gone' },
    ], error: null },
    { seq: 3, role: 'user', text: 'why?', picks: [], error: null },
    { seq: 4, role: 'assistant', text: 'Because.', picks: [], error: null },
  ],
  topics: [topic],
  scenes: [{ ref: 's:4', id: '4', title: 'S', studio: null, performers: [], screenshot: null, link: null }],
};
const d = (over: Partial<Daily>): Daily => ({ conversation: null, generatedOn: null, refreshing: false, error: null, ready: true, ...over });

describe('dailyAnswer', () => {
  it('is the first assistant turn, not a follow-up', () => {
    expect(dailyAnswer(conv)?.seq).toBe(2);
    expect(dailyAnswer({ ...conv, turns: [conv.turns[0]] })).toBeNull();
  });
});

describe('groupPicks', () => {
  it('splits watch from stream and download, dropping unresolved picks', () => {
    const g = groupPicks(conv, conv.turns[1]);
    expect(g.watch.map((r) => r.pick.ref)).toEqual(['s:4']);
    expect(g.get.map((r) => r.pick.ref)).toEqual(['t:5']);
  });
});

describe('show', () => {
  it('names what For you shows', () => {
    expect(show(null)).toBe('loading');
    expect(show(d({ refreshing: true }))).toBe('first');
    expect(show(d({ conversation: conv, refreshing: true }))).toBe('picks');
    expect(show(d({ error: 'no prompt', ready: false }))).toBe('empty');
  });
});
