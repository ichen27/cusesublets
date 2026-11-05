-- Deletion removes personal content while preserving disconnected shared transaction references.
ALTER TABLE users ADD COLUMN deletedAt TEXT;
CREATE TABLE account_deletions(
 userId TEXT PRIMARY KEY REFERENCES users(id), receiptHash TEXT NOT NULL UNIQUE,
 requestedAt INTEGER NOT NULL, completedAt INTEGER, nextCheck INTEGER NOT NULL DEFAULT 0,
 resources TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX account_deletion_retry ON account_deletions(nextCheck);
CREATE TABLE account_deletion_resources(userId TEXT NOT NULL,key TEXT NOT NULL,isPrefix INTEGER NOT NULL,PRIMARY KEY(userId,key));
CREATE TABLE account_deletion_targets(userId TEXT NOT NULL, targetId TEXT NOT NULL, PRIMARY KEY(userId,targetId));
-- Audit identity/action/time remain immutable. Only a deletion job may erase its free-text reason.
DROP TRIGGER audit_no_update;
CREATE TRIGGER audit_no_update BEFORE UPDATE ON audit WHEN NOT (
 NEW.id=OLD.id AND NEW.actorId=OLD.actorId AND NEW.action=OLD.action AND NEW.targetId=OLD.targetId AND NEW.createdAt=OLD.createdAt
 AND NEW.reason='[Removed after account deletion]'
 AND EXISTS(SELECT 1 FROM account_deletions d WHERE d.userId=OLD.actorId OR EXISTS(SELECT 1 FROM account_deletion_targets t WHERE t.userId=d.userId AND t.targetId=OLD.targetId))
) BEGIN SELECT RAISE(ABORT,'Audit is append-only'); END;
CREATE TRIGGER deleted_user_immutable BEFORE UPDATE ON users WHEN OLD.deletedAt IS NOT NULL BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_sessions_insert BEFORE INSERT ON sessions WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_sessions_update BEFORE UPDATE ON sessions WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_password_sessions_insert BEFORE INSERT ON password_sessions WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_password_sessions_update BEFORE UPDATE ON password_sessions WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_password_credentials_insert BEFORE INSERT ON password_credentials WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_password_credentials_update BEFORE UPDATE ON password_credentials WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_mobile_auth_codes_insert BEFORE INSERT ON mobile_auth_codes WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_mobile_auth_codes_update BEFORE UPDATE ON mobile_auth_codes WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_apple_identities_insert BEFORE INSERT ON apple_identities WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_apple_identities_update BEFORE UPDATE ON apple_identities WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_listings_insert BEFORE INSERT ON listings WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_listings_update BEFORE UPDATE ON listings WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_seeker_requests_insert BEFORE INSERT ON seeker_requests WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_seeker_requests_update BEFORE UPDATE ON seeker_requests WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_messages_insert BEFORE INSERT ON messages WHEN EXISTS(SELECT 1 FROM users WHERE id IN(NEW.senderId,NEW.recipientId) AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_messages_update BEFORE UPDATE ON messages WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.senderId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_chat_attachments_insert BEFORE INSERT ON chat_attachments WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.senderId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_chat_attachments_update BEFORE UPDATE ON chat_attachments WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.senderId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_chat_events_insert BEFORE INSERT ON chat_events WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.actorId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_chat_events_update BEFORE UPDATE ON chat_events WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.actorId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_identity_documents_insert BEFORE INSERT ON identity_documents WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_identity_documents_update BEFORE UPDATE ON identity_documents WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_profile_media_insert BEFORE INSERT ON profile_media WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_profile_media_update BEFORE UPDATE ON profile_media WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_profile_reviews_insert BEFORE INSERT ON profile_reviews WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.authorId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_profile_reviews_update BEFORE UPDATE ON profile_reviews WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.authorId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_private_drafts_insert BEFORE INSERT ON private_drafts WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_private_drafts_update BEFORE UPDATE ON private_drafts WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_room_scans_insert BEFORE INSERT ON room_scans WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_room_scans_update BEFORE UPDATE ON room_scans WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_room_tours_insert BEFORE INSERT ON room_tours WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_room_tours_update BEFORE UPDATE ON room_tours WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.ownerId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_reports_insert BEFORE INSERT ON reports WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.reporterId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_reports_update BEFORE UPDATE ON reports WHEN NEW.reason<>'[Deleted]' AND EXISTS(SELECT 1 FROM users WHERE id=NEW.reporterId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_request_reports_insert BEFORE INSERT ON request_reports WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.reporterId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_request_reports_update BEFORE UPDATE ON request_reports WHEN NEW.reason<>'[Deleted]' AND EXISTS(SELECT 1 FROM users WHERE id=NEW.reporterId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_social_likes_insert BEFORE INSERT ON social_likes WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_social_likes_update BEFORE UPDATE ON social_likes WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_social_saves_insert BEFORE INSERT ON social_saves WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_social_saves_update BEFORE UPDATE ON social_saves WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.userId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_social_comments_insert BEFORE INSERT ON social_comments WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.authorId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_social_comments_update BEFORE UPDATE ON social_comments WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.authorId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_social_comment_reports_insert BEFORE INSERT ON social_comment_reports WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.reporterId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_social_comment_reports_update BEFORE UPDATE ON social_comment_reports WHEN NEW.reason<>'[Deleted]' AND EXISTS(SELECT 1 FROM users WHERE id=NEW.reporterId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_audit_insert BEFORE INSERT ON audit WHEN EXISTS(SELECT 1 FROM users WHERE id=NEW.actorId AND deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_documents_insert BEFORE INSERT ON documents WHEN EXISTS(SELECT 1 FROM users u JOIN listings l ON l.ownerId=u.id WHERE l.id=NEW.listingId AND u.deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
CREATE TRIGGER deleted_documents_update BEFORE UPDATE ON documents WHEN EXISTS(SELECT 1 FROM users u JOIN listings l ON l.ownerId=u.id WHERE l.id=NEW.listingId AND u.deletedAt IS NOT NULL) BEGIN SELECT RAISE(ABORT,'Account deleted'); END;
DROP TRIGGER social_unlike_limit;
DROP TRIGGER social_unlike_rate;
CREATE TRIGGER social_unlike_limit BEFORE DELETE ON social_likes WHEN NOT EXISTS(SELECT 1 FROM account_deletions WHERE userId=OLD.userId) BEGIN SELECT CASE WHEN (SELECT count(*) FROM social_rate_events WHERE userId=OLD.userId AND kind='reaction' AND at>unixepoch()-600)>=120 THEN RAISE(ABORT,'Social reaction rate limit') END; END;
CREATE TRIGGER social_unlike_rate AFTER DELETE ON social_likes WHEN NOT EXISTS(SELECT 1 FROM account_deletions WHERE userId=OLD.userId) BEGIN INSERT INTO social_rate_events VALUES(OLD.userId,'reaction',unixepoch()); END;
DROP TRIGGER social_unsave_limit;
DROP TRIGGER social_unsave_rate;
CREATE TRIGGER social_unsave_limit BEFORE DELETE ON social_saves WHEN NOT EXISTS(SELECT 1 FROM account_deletions WHERE userId=OLD.userId) BEGIN SELECT CASE WHEN (SELECT count(*) FROM social_rate_events WHERE userId=OLD.userId AND kind='reaction' AND at>unixepoch()-600)>=120 THEN RAISE(ABORT,'Social reaction rate limit') END; END;
CREATE TRIGGER social_unsave_rate AFTER DELETE ON social_saves WHEN NOT EXISTS(SELECT 1 FROM account_deletions WHERE userId=OLD.userId) BEGIN INSERT INTO social_rate_events VALUES(OLD.userId,'reaction',unixepoch()); END;
