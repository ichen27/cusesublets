CREATE TABLE room_scans (
 id TEXT PRIMARY KEY,
 listingId TEXT NOT NULL REFERENCES listings(id),
 ownerId TEXT NOT NULL REFERENCES users(id),
 name TEXT NOT NULL,
 layout TEXT NOT NULL,
 published INTEGER NOT NULL DEFAULT 0 CHECK(published IN (0,1)),
 createdAt TEXT NOT NULL
);
CREATE INDEX room_scans_listing ON room_scans(listingId,createdAt);
CREATE TABLE mobile_auth_codes (
 codeHash TEXT PRIMARY KEY,
 userId TEXT NOT NULL REFERENCES users(id),
 challenge TEXT NOT NULL,
 expires INTEGER NOT NULL
);
