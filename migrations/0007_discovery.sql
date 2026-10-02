-- Two-sided discovery. Older listings have unknown post times and remain undated in Recent.
ALTER TABLE listings ADD COLUMN createdAt TEXT;
CREATE TABLE seeker_requests(
 id TEXT PRIMARY KEY,
 ownerId TEXT NOT NULL REFERENCES users(id),
 status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','closed','removed')),
 data TEXT NOT NULL,
 createdAt TEXT NOT NULL,
 updatedAt TEXT NOT NULL
);
CREATE INDEX seeker_requests_owner ON seeker_requests(ownerId,createdAt);
CREATE INDEX seeker_requests_active ON seeker_requests(status,createdAt);
ALTER TABLE conversations ADD COLUMN requestId TEXT REFERENCES seeker_requests(id);
CREATE TRIGGER conversation_request_insert BEFORE INSERT ON conversations
 WHEN NEW.requestId IS NOT NULL AND NOT EXISTS(
  SELECT 1 FROM seeker_requests WHERE id=NEW.requestId AND ownerId=NEW.buyerId
 ) BEGIN SELECT RAISE(ABORT,'Request participant mismatch'); END;
CREATE TRIGGER conversation_request_update BEFORE UPDATE OF requestId ON conversations
 WHEN NEW.requestId IS NOT NULL AND NOT EXISTS(
  SELECT 1 FROM seeker_requests WHERE id=NEW.requestId AND ownerId=NEW.buyerId
 ) BEGIN SELECT RAISE(ABORT,'Request participant mismatch'); END;
