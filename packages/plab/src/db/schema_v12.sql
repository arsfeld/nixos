-- A deleted scene's Stash file paths, newline-separated, read just before Stash deletes it:
-- a grab matched to its scene only by release folder finds it here once Stash cannot.
ALTER TABLE scene_deleted ADD COLUMN paths TEXT;
