ALTER TABLE users ADD COLUMN bio TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN phone TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN socials TEXT NOT NULL DEFAULT '{}';
ALTER TABLE users ADD COLUMN avatar TEXT;
ALTER TABLE users ADD COLUMN identityNote TEXT;
ALTER TABLE users ADD COLUMN nameVersion INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN joinedAt TEXT;
CREATE TABLE identity_documents(id TEXT PRIMARY KEY,userId TEXT NOT NULL REFERENCES users(id),name TEXT NOT NULL,type TEXT NOT NULL,objectKey TEXT NOT NULL,createdAt TEXT NOT NULL,nameVersion INTEGER NOT NULL);
CREATE INDEX identity_owner ON identity_documents(userId);
CREATE TABLE profile_media(id TEXT PRIMARY KEY,userId TEXT NOT NULL REFERENCES users(id),kind TEXT NOT NULL CHECK(kind IN ('avatar','photo')),type TEXT NOT NULL,objectKey TEXT NOT NULL,createdAt TEXT NOT NULL);
CREATE TABLE profile_reviews(id TEXT PRIMARY KEY,bookingId TEXT NOT NULL REFERENCES bookings(id),authorId TEXT NOT NULL REFERENCES users(id),targetId TEXT NOT NULL REFERENCES users(id),rating INTEGER NOT NULL CHECK(rating BETWEEN 1 AND 5),body TEXT NOT NULL,createdAt TEXT NOT NULL,UNIQUE(bookingId,authorId),CHECK(authorId<>targetId));
CREATE TRIGGER profile_review_guard BEFORE INSERT ON profile_reviews WHEN NOT EXISTS(
 SELECT 1 FROM bookings b JOIN users a ON a.id=NEW.authorId JOIN users t ON t.id=NEW.targetId WHERE b.id=NEW.bookingId
 AND ((b.buyerId=NEW.authorId AND b.sellerId=NEW.targetId) OR (b.sellerId=NEW.authorId AND b.buyerId=NEW.targetId))
 AND b.paymentStatus IN ('paid','demo_paid') AND b.moveInAt IS NOT NULL
 AND b.status<>'cancelled' AND b.disputeStatus<>'open' AND a.suspended=0 AND t.suspended=0
) BEGIN SELECT RAISE(ABORT,'Review prerequisites changed'); END;
