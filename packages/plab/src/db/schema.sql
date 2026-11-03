CREATE TABLE topic (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  forum INTEGER NOT NULL,
  size INTEGER NOT NULL,
  seeders INTEGER NOT NULL,
  leechers INTEGER NOT NULL,
  completed INTEGER NOT NULL,
  added INTEGER NOT NULL,          -- tracker upload time
  images TEXT,                     -- JSON array; NULL = not fetched yet
  production TEXT,                 -- JSON {"class","confidence"}; NULL = unclassified
  seen_at INTEGER NOT NULL
);
CREATE TABLE listing (
  section TEXT NOT NULL,
  position INTEGER NOT NULL,
  topic_id INTEGER NOT NULL REFERENCES topic(id),
  filters TEXT NOT NULL,           -- JSON array of curated filter names
  curated_reason TEXT,
  PRIMARY KEY (section, position)
);
CREATE TABLE listing_meta (
  section TEXT PRIMARY KEY,
  updated INTEGER NOT NULL,
  filters TEXT NOT NULL            -- JSON array, file order
);
CREATE TABLE search_hit (
  topic_id INTEGER PRIMARY KEY REFERENCES topic(id),
  at INTEGER NOT NULL
);
CREATE TABLE download (
  id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,            -- 'plab' | 'grab'
  topic_id INTEGER,                -- plab only
  release_title TEXT NOT NULL,
  section TEXT NOT NULL,
  download_dir TEXT,               -- NULL for rows imported from added.json
  state TEXT NOT NULL,             -- 'queued' | 'added'
  torrent_hash TEXT,
  queued_at INTEGER,
  added_at INTEGER
);
CREATE UNIQUE INDEX download_topic ON download(topic_id) WHERE topic_id IS NOT NULL;
CREATE TABLE grab_seen (
  studio TEXT NOT NULL,
  scene_key TEXT NOT NULL,
  title TEXT NOT NULL,
  at TEXT NOT NULL,                -- ISO 8601, as vault-grab wrote it
  download_id INTEGER REFERENCES download(id),
  PRIMARY KEY (studio, scene_key)
);
CREATE TABLE identify_attempt (
  scene_id TEXT PRIMARY KEY,
  failures INTEGER NOT NULL DEFAULT 0,
  done INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE job_run (
  job TEXT PRIMARY KEY,
  last_started INTEGER,
  last_finished INTEGER,
  ok INTEGER,
  error TEXT
);
CREATE TABLE kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  rev INTEGER NOT NULL
);
