-- Spot tours store stitched panoramas in one bundle; older rows are Gaussian (splat) tours.
ALTER TABLE room_tours ADD COLUMN kind TEXT NOT NULL DEFAULT 'splat' CHECK(kind IN ('splat','spots'));
