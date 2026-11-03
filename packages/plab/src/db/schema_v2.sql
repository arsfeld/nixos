CREATE TABLE download_file (
  download_id INTEGER NOT NULL REFERENCES download(id),
  path TEXT NOT NULL,              -- library-relative, the form Paths::rel_path gives
  scene_id TEXT,                   -- set once a Stash scene with this path is seen
  outcome TEXT,                    -- 'stash' | 'scrape' | 'llm' | 'none' | 'gave-up'
  label TEXT,                      -- "Title · Studio": what it was identified as
  PRIMARY KEY (download_id, path)
);
CREATE INDEX download_file_path ON download_file(path);
CREATE INDEX download_file_scene ON download_file(scene_id);
-- 0: files pending, 1: files recorded (the torrent finished), 2: added before provenance
-- existed. A 2 is never synced and gets no status: its files were never recorded, so it
-- would read "failed: lost". Queued downloads have not started, so they stay 0.
ALTER TABLE download ADD COLUMN files_synced INTEGER NOT NULL DEFAULT 0;
UPDATE download SET files_synced = 2 WHERE state = 'added';
ALTER TABLE download ADD COLUMN cover TEXT;  -- absolute path of the copied tracker image
