-- Persistent listing/renter threads. Legacy messages keep their original schema.
CREATE TABLE conversations(
 id TEXT PRIMARY KEY, listingId TEXT NOT NULL REFERENCES listings(id),
 buyerId TEXT NOT NULL REFERENCES users(id), sellerId TEXT NOT NULL REFERENCES users(id),
 createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL,
 UNIQUE(listingId,buyerId), CHECK(buyerId<>sellerId)
);
INSERT INTO conversations
 SELECT lower(hex(randomblob(16))), listingId,buyerId,sellerId,MIN(createdAt),MAX(createdAt)
 FROM (
 SELECT m.listingId,CASE WHEN m.senderId=l.ownerId THEN m.recipientId ELSE m.senderId END buyerId,l.ownerId sellerId,m.createdAt
 FROM messages m JOIN listings l ON l.id=m.listingId
 WHERE (m.senderId=l.ownerId OR m.recipientId=l.ownerId) AND m.senderId<>m.recipientId
 UNION ALL SELECT listingId,buyerId,sellerId,strftime('%Y-%m-%dT%H:%M:%fZ','now') FROM offers
 ) GROUP BY listingId,buyerId,sellerId;
ALTER TABLE offers ADD COLUMN conversationId TEXT REFERENCES conversations(id);
ALTER TABLE offers ADD COLUMN proposedBy TEXT REFERENCES users(id);
ALTER TABLE offers ADD COLUMN parentOfferId TEXT REFERENCES offers(id);
ALTER TABLE offers ADD COLUMN createdAt TEXT;
ALTER TABLE offers ADD COLUMN kind TEXT NOT NULL DEFAULT 'offer' CHECK(kind IN ('offer','request'));
UPDATE offers SET proposedBy=buyerId,conversationId=(SELECT id FROM conversations c WHERE c.listingId=offers.listingId AND c.buyerId=offers.buyerId),createdAt=COALESCE((SELECT createdAt FROM bookings b WHERE b.offerId=offers.id),strftime('%Y-%m-%dT%H:%M:%fZ','now'));
CREATE INDEX offers_conversation ON offers(conversationId,createdAt);
CREATE TABLE chat_attachments(
 id TEXT PRIMARY KEY,conversationId TEXT NOT NULL REFERENCES conversations(id),senderId TEXT NOT NULL REFERENCES users(id),
 name TEXT NOT NULL,type TEXT NOT NULL,size INTEGER NOT NULL CHECK(size>0 AND size<=5242880),objectKey TEXT NOT NULL,createdAt TEXT NOT NULL
);
CREATE TABLE chat_events(
 id TEXT PRIMARY KEY,conversationId TEXT NOT NULL REFERENCES conversations(id),actorId TEXT NOT NULL REFERENCES users(id),
 kind TEXT NOT NULL,body TEXT NOT NULL,offerId TEXT REFERENCES offers(id),createdAt TEXT NOT NULL
);
CREATE INDEX events_conversation ON chat_events(conversationId,createdAt);
CREATE INDEX attachments_conversation ON chat_attachments(conversationId,createdAt);
CREATE TRIGGER conversation_owner_guard BEFORE INSERT ON conversations WHEN NOT EXISTS(SELECT 1 FROM listings WHERE id=NEW.listingId AND ownerId=NEW.sellerId)
 BEGIN SELECT RAISE(ABORT,'Conversation participants changed'); END;
-- Also captures legacy message inserts, including local sample seeds.
CREATE TRIGGER message_thread AFTER INSERT ON messages BEGIN
 INSERT INTO conversations(id,listingId,buyerId,sellerId,createdAt,updatedAt)
 SELECT lower(hex(randomblob(16))),l.id,CASE WHEN NEW.senderId=l.ownerId THEN NEW.recipientId ELSE NEW.senderId END,l.ownerId,NEW.createdAt,NEW.createdAt FROM listings l
 WHERE l.id=NEW.listingId AND (NEW.senderId=l.ownerId OR NEW.recipientId=l.ownerId) AND NEW.senderId<>NEW.recipientId
 ON CONFLICT(listingId,buyerId) DO UPDATE SET updatedAt=MAX(updatedAt,excluded.updatedAt);
END;
CREATE TRIGGER chat_event_touch AFTER INSERT ON chat_events BEGIN
 UPDATE conversations SET updatedAt=MAX(updatedAt,NEW.createdAt) WHERE id=NEW.conversationId;
END;
CREATE TRIGGER chat_attachment_touch AFTER INSERT ON chat_attachments BEGIN
 UPDATE conversations SET updatedAt=MAX(updatedAt,NEW.createdAt) WHERE id=NEW.conversationId;
END;
-- Validate lineage at write time, then supersede the parent in the same transaction.
CREATE TRIGGER proposal_guard BEFORE INSERT ON offers WHEN NOT EXISTS(
 SELECT 1 FROM conversations c JOIN listings l ON l.id=c.listingId JOIN users buyer ON buyer.id=c.buyerId JOIN users seller ON seller.id=c.sellerId
 WHERE c.id=NEW.conversationId AND NEW.listingId=c.listingId AND NEW.buyerId=c.buyerId AND NEW.sellerId=c.sellerId AND l.ownerId=c.sellerId
 AND NEW.proposedBy IN(c.buyerId,c.sellerId) AND buyer.suspended=0 AND seller.suspended=0 AND l.status='approved'
 AND NEW.startDate>=json_extract(l.data,'$.startDate') AND NEW.endDate<=json_extract(l.data,'$.endDate')
 AND (NEW.parentOfferId IS NULL OR EXISTS(SELECT 1 FROM offers p WHERE p.id=NEW.parentOfferId AND p.conversationId=c.id AND p.status='pending' AND p.proposedBy<>NEW.proposedBy))
) BEGIN SELECT RAISE(ABORT,'Proposal prerequisites changed'); END;
CREATE TRIGGER proposal_counter AFTER INSERT ON offers WHEN NEW.parentOfferId IS NOT NULL BEGIN
 UPDATE offers SET status='countered' WHERE id=NEW.parentOfferId AND status='pending';
END;
CREATE TRIGGER booking_availability_guard BEFORE INSERT ON bookings WHEN NOT EXISTS(
 SELECT 1 FROM listings l WHERE l.id=NEW.listingId AND NEW.startDate>=json_extract(l.data,'$.startDate') AND NEW.endDate<=json_extract(l.data,'$.endDate')
) BEGIN SELECT RAISE(ABORT,'Reservation prerequisites changed'); END;
