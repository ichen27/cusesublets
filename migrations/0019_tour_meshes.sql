-- Optional room mesh built alongside the Gaussian model. The key names the processing claim that
-- uploaded it, so completion can drop a mesh left by an earlier, failed attempt.
ALTER TABLE room_tours ADD COLUMN meshKey TEXT;
ALTER TABLE room_tours ADD COLUMN mesh TEXT;
