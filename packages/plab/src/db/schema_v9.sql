-- Why the grab job took a download (design: the Grabs tab). JSON of db::GrabReason; NULL
-- for plab's own adds and for grabs made before this column existed.
ALTER TABLE download ADD COLUMN grab_reason TEXT;
