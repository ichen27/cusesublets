-- Preserve every historical request ID for conversations, reports and audit.
-- Only one row per owner may represent the current profile search.
ALTER TABLE seeker_requests ADD COLUMN profileSearch INTEGER NOT NULL DEFAULT 0 CHECK(profileSearch IN (0,1));
CREATE UNIQUE INDEX one_profile_search_per_owner ON seeker_requests(ownerId) WHERE profileSearch=1;
UPDATE seeker_requests SET profileSearch=1
WHERE id IN (
  SELECT id FROM (
    SELECT id, ROW_NUMBER() OVER (
      PARTITION BY ownerId
      ORDER BY CASE WHEN status='active' THEN 0 WHEN status='removed' THEN 2 ELSE 1 END,
               createdAt DESC, rowid DESC
    ) AS priority
    FROM seeker_requests
  ) WHERE priority=1
);
-- No old post becomes public until its owner chooses areas and turns it on.
UPDATE seeker_requests SET status='paused', updatedAt=datetime('now')
WHERE status='active' OR (profileSearch=1 AND status='closed');
