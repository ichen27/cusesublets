CREATE TABLE room_tours (
  id TEXT PRIMARY KEY,
  listingId TEXT NOT NULL REFERENCES listings(id),
  ownerId TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('uploading','queued','processing','ready','failed')),
  deleting INTEGER NOT NULL DEFAULT 0 CHECK(deleting IN (0,1)),
  published INTEGER NOT NULL DEFAULT 0 CHECK(published IN (0,1)),
  inputHash TEXT NOT NULL,
  inputSize INTEGER NOT NULL,
  inputKey TEXT,
  modelKey TEXT,
  result TEXT,
  error TEXT,
  claim TEXT,
  leaseUntil INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT NOT NULL
);
CREATE INDEX room_tours_listing ON room_tours(listingId,createdAt);
CREATE INDEX room_tours_queue ON room_tours(status,leaseUntil,createdAt);
