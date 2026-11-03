-- What an external release is: 'torrent' (a Prowlarr result) or 'album' (an album index
-- entry, which plab only links to). files: an album's file count. first_seen: unix time
-- plab first saw the release; an album's age is measured from it, since the index shows
-- no dates. Album rows are never pruned, so an album that ages out is not re-seen as new.
ALTER TABLE external_release ADD COLUMN kind TEXT NOT NULL DEFAULT 'torrent';
ALTER TABLE external_release ADD COLUMN files INTEGER;
ALTER TABLE external_release ADD COLUMN first_seen INTEGER NOT NULL DEFAULT 0;
