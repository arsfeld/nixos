-- One row per stream started from the page's Stream button. Streams never reach Stash, so
-- without this a streamed-but-never-downloaded release is invisible to the assistant.
CREATE TABLE stream_view (
  id INTEGER PRIMARY KEY,
  topic_id INTEGER NOT NULL,       -- tracker topic or external_release id
  started_at INTEGER NOT NULL
);
CREATE INDEX stream_view_topic ON stream_view(topic_id, started_at);
CREATE INDEX stream_view_at ON stream_view(started_at);

-- The assistant's conversations (design: 2026-11-03-plab-assistant-design.md).
CREATE TABLE conversation (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  kind TEXT NOT NULL,              -- 'recommend' | 'chat'
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- The full transcript as OpenRouter message objects (JSON), system context and tool calls
-- included, so a conversation resumes exactly as the model last saw it. Keys starting
-- with plab_ are plab's own and are stripped before sending.
CREATE TABLE message (
  id INTEGER PRIMARY KEY,
  conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  role TEXT NOT NULL,              -- 'system' | 'user' | 'assistant' | 'tool'
  content TEXT NOT NULL,
  at INTEGER NOT NULL,
  UNIQUE (conversation_id, seq)
);
