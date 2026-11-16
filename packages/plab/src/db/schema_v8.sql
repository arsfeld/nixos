-- Stash scenes queued to watch (design: 2026-11-16-plab-watchlist-design.md).
CREATE TABLE watchlist (
  scene_id TEXT PRIMARY KEY,       -- Stash scene id
  added_at INTEGER NOT NULL        -- unix time it was queued
);
