CREATE TABLE user_blocks(
 userId TEXT NOT NULL REFERENCES users(id),blockedId TEXT NOT NULL REFERENCES users(id),createdAt TEXT NOT NULL,
 PRIMARY KEY(userId,blockedId),CHECK(userId<>blockedId)
);
CREATE INDEX user_blocks_reverse ON user_blocks(blockedId,userId);
CREATE TRIGGER block_member_guard BEFORE INSERT ON user_blocks WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND (suspended=1 OR deletedAt IS NOT NULL)) BEGIN SELECT RAISE(ABORT,'Account unavailable'); END;
CREATE TRIGGER blocked_message BEFORE INSERT ON messages WHEN EXISTS(SELECT 1 FROM user_blocks WHERE (userId=NEW.senderId AND blockedId=NEW.recipientId) OR (userId=NEW.recipientId AND blockedId=NEW.senderId)) BEGIN SELECT RAISE(ABORT,'Member contact is blocked'); END;
CREATE TRIGGER blocked_conversation BEFORE INSERT ON conversations WHEN EXISTS(SELECT 1 FROM user_blocks WHERE (userId=NEW.buyerId AND blockedId=NEW.sellerId) OR (userId=NEW.sellerId AND blockedId=NEW.buyerId)) BEGIN SELECT RAISE(ABORT,'Member contact is blocked'); END;
CREATE TRIGGER blocked_offer BEFORE INSERT ON offers WHEN EXISTS(SELECT 1 FROM user_blocks WHERE (userId=NEW.buyerId AND blockedId=NEW.sellerId) OR (userId=NEW.sellerId AND blockedId=NEW.buyerId)) BEGIN SELECT RAISE(ABORT,'Member contact is blocked'); END;
CREATE TRIGGER blocked_attachment BEFORE INSERT ON chat_attachments WHEN EXISTS(SELECT 1 FROM user_blocks b JOIN conversations c ON c.id=NEW.conversationId WHERE (b.userId=c.buyerId AND b.blockedId=c.sellerId) OR (b.userId=c.sellerId AND b.blockedId=c.buyerId)) BEGIN SELECT RAISE(ABORT,'Member contact is blocked'); END;
CREATE TRIGGER blocked_review BEFORE INSERT ON profile_reviews WHEN EXISTS(SELECT 1 FROM user_blocks WHERE (userId=NEW.authorId AND blockedId=NEW.targetId) OR (userId=NEW.targetId AND blockedId=NEW.authorId)) BEGIN SELECT RAISE(ABORT,'Member contact is blocked'); END;
CREATE VIEW social_target_owners AS SELECT 'listing' targetType,id targetId,ownerId FROM listings UNION ALL SELECT 'search',id,ownerId FROM seeker_requests;
CREATE TRIGGER blocked_comment BEFORE INSERT ON social_comments WHEN EXISTS(
 SELECT 1 FROM user_blocks b JOIN social_target_owners t ON t.targetType=NEW.targetType AND t.targetId=NEW.targetId WHERE (b.userId=NEW.authorId AND b.blockedId=t.ownerId) OR (b.userId=t.ownerId AND b.blockedId=NEW.authorId)
) OR EXISTS(SELECT 1 FROM user_blocks b JOIN social_comments p ON p.id=NEW.parentId WHERE (b.userId=NEW.authorId AND b.blockedId=p.authorId) OR (b.userId=p.authorId AND b.blockedId=NEW.authorId)) BEGIN SELECT RAISE(ABORT,'Member contact is blocked'); END;
CREATE TABLE member_reports(id TEXT PRIMARY KEY,reporterId TEXT NOT NULL REFERENCES users(id),targetId TEXT NOT NULL REFERENCES users(id),reason TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'open' CHECK(status IN('open','resolved')),createdAt TEXT NOT NULL);
CREATE UNIQUE INDEX member_report_open ON member_reports(reporterId,targetId) WHERE status='open';
CREATE TRIGGER deleted_member_report BEFORE INSERT ON member_reports WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.reporterId AND (suspended=1 OR deletedAt IS NOT NULL)) BEGIN SELECT RAISE(ABORT,'Account unavailable'); END;

CREATE TRIGGER member_report_rate BEFORE INSERT ON member_reports WHEN (SELECT count(*) FROM member_reports WHERE reporterId=NEW.reporterId AND createdAt>strftime('%Y-%m-%dT%H:%M:%fZ','now','-1 hour'))>=10 BEGIN SELECT RAISE(ABORT,'Member report rate limit'); END;

CREATE TRIGGER blocked_booking BEFORE INSERT ON bookings WHEN EXISTS(SELECT 1 FROM user_blocks WHERE (userId=NEW.buyerId AND blockedId=NEW.sellerId) OR (userId=NEW.sellerId AND blockedId=NEW.buyerId)) BEGIN SELECT RAISE(ABORT,'Member contact is blocked'); END;
