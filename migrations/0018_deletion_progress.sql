-- Bounded cleanup resumes across Worker invocations and requires a full post-settling sweep.
ALTER TABLE account_deletions ADD COLUMN resourceIndex INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account_deletions ADD COLUMN passStartedAt INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account_deletions ADD COLUMN leaseUntil INTEGER NOT NULL DEFAULT 0;
