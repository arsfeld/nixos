-- One row per job run, for the jobs page; jobs::record writes it. Kept to the newest 50
-- per job. finished/ok are NULL while the run is in progress.
CREATE TABLE job_history (
    id       INTEGER PRIMARY KEY,
    job      TEXT NOT NULL,
    started  INTEGER NOT NULL,
    finished INTEGER,
    ok       INTEGER,
    error    TEXT
);
CREATE INDEX job_history_job ON job_history (job, started DESC);
