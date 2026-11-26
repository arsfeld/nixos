-- A +1 or −1 on a Stash scene (design: 2026-11-26-plab-taste-feedback-design.md). One row
-- per scene; clearing a vote deletes the row. `voted_at` is when it was last set, for decay.
CREATE TABLE scene_vote (
  scene_id TEXT PRIMARY KEY,
  vote INTEGER NOT NULL CHECK (vote IN (-1, 1)),
  voted_at INTEGER NOT NULL
);
