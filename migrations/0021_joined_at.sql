-- users.joinedAt has existed since 0005 and is shown on public profiles, but nothing wrote it.
-- Record it when an account is created, whichever sign-in made it. Accounts from before this
-- keep no date, and their profiles say nothing about when they joined.
CREATE TRIGGER users_joined_at AFTER INSERT ON users WHEN NEW.joinedAt IS NULL BEGIN
 UPDATE users SET joinedAt=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=NEW.id AND joinedAt IS NULL;
END;
