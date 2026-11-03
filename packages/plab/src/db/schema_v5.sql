-- The last curated run's hits; refresh merges them into the video list. The curated job
-- replaces the whole table in one transaction.
CREATE TABLE curated_hit (
  topic_id INTEGER NOT NULL REFERENCES topic(id),
  filter TEXT NOT NULL,
  reason TEXT NOT NULL,            -- the term that found it: the card's badge
  PRIMARY KEY (topic_id, filter)
);

-- A release from an indexer other than the tracker, and the plab id it is known by.
-- Ids start at 1<<40, far above any tracker topic id.
CREATE TABLE external_release (
  id INTEGER PRIMARY KEY AUTOINCREMENT,   -- never reused: a stored .torrent or download row
                                          -- keyed by an id can't be inherited by another release
  indexer TEXT NOT NULL,
  guid TEXT NOT NULL,
  link TEXT NOT NULL,              -- Prowlarr download URL: yields a .torrent or a magnet
  info_url TEXT,                   -- the release's page, for the card's link
  scene_id TEXT,                   -- the scene database's id; NULL = not matched (yet)
  UNIQUE (indexer, guid)
);

-- AUTOINCREMENT hands out sqlite_sequence.seq + 1, so seeding it with EXTERNAL_BASE - 1
-- (1099511627775, kept in step with db::EXTERNAL_BASE) makes the first id exactly 1<<40.
INSERT INTO sqlite_sequence (name, seq) VALUES ('external_release', 1099511627775);
