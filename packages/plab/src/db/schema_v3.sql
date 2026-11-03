-- Every .torrent plab grabs. The tracker caps grabs per day, so a grab is kept rather
-- than spent twice; only the media a stream fetches is scratch.
CREATE TABLE torrent_file (
  topic_id INTEGER PRIMARY KEY,
  data BLOB NOT NULL,              -- the .torrent bytes as the tracker served them
  fetched INTEGER NOT NULL         -- unix time
);
