-- Retain opaque deletion IDs so late writes from interrupted uploads remain discoverable.
CREATE TABLE tour_deletions (
  id TEXT PRIMARY KEY,
  ownerId TEXT NOT NULL,
  lastChecked INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX tour_deletions_sweep ON tour_deletions(lastChecked);
