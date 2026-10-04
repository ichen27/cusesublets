-- Private questionnaire state is separate from publicly discoverable records.
CREATE TABLE private_drafts(
 ownerId TEXT NOT NULL REFERENCES users(id),
 id TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('search','listing')),
 step INTEGER NOT NULL CHECK(step BETWEEN 1 AND 4),
 revision INTEGER NOT NULL CHECK(revision > 0),
 data TEXT NOT NULL CHECK(json_valid(data)),
 deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)),
 updatedAt TEXT NOT NULL,
 PRIMARY KEY(ownerId,id),
 CHECK((kind='search' AND id='search') OR (kind='listing' AND id<>'search'))
);
CREATE INDEX private_drafts_owner ON private_drafts(ownerId,deleted,updatedAt);
-- Account-scoped publication identity survives retries after a lost HTTP response.
ALTER TABLE listings ADD COLUMN createKey TEXT;
CREATE UNIQUE INDEX listing_create_key ON listings(ownerId,createKey) WHERE createKey IS NOT NULL;
