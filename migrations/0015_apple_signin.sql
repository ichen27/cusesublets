CREATE TABLE apple_auth_challenges(id TEXT PRIMARY KEY,nonce TEXT NOT NULL,expires INTEGER NOT NULL);
CREATE INDEX apple_challenge_expiry ON apple_auth_challenges(expires);
CREATE TABLE apple_identities(
  subject TEXT PRIMARY KEY,
  userId TEXT NOT NULL UNIQUE REFERENCES users(id),
  refreshToken TEXT NOT NULL,
  authenticatedAt INTEGER NOT NULL DEFAULT 0,
  emailEnabled INTEGER NOT NULL DEFAULT 1,
  emailEventAt INTEGER NOT NULL DEFAULT 0,
  revokedAt TEXT
);

-- Keep revocations even if they arrive before initial identity persistence.
CREATE TABLE apple_account_events(subject TEXT PRIMARY KEY,revokedAt INTEGER NOT NULL);
