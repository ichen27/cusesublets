-- Stable housing targets. No duplicate public seeker-post table.
CREATE VIEW social_visible_targets AS
 SELECT 'listing' targetType,l.id targetId,json_extract(l.data,'$.endDate') endDate FROM listings l JOIN users u ON u.id=l.ownerId WHERE l.status='approved' AND u.suspended=0
 UNION ALL
 SELECT 'search',s.id,json_extract(s.data,'$.endDate') FROM seeker_requests s JOIN users u ON u.id=s.ownerId WHERE s.status='active' AND s.profileSearch=1 AND u.suspended=0;
CREATE TABLE social_likes(targetType TEXT NOT NULL CHECK(targetType IN ('listing','search')),targetId TEXT NOT NULL,userId TEXT NOT NULL REFERENCES users(id),createdAt TEXT NOT NULL,PRIMARY KEY(targetType,targetId,userId));
CREATE TABLE social_saves(targetType TEXT NOT NULL CHECK(targetType IN ('listing','search')),targetId TEXT NOT NULL,userId TEXT NOT NULL REFERENCES users(id),createdAt TEXT NOT NULL,PRIMARY KEY(targetType,targetId,userId));
CREATE INDEX social_saves_owner ON social_saves(userId,createdAt,targetType,targetId);
CREATE TABLE social_comments(id TEXT PRIMARY KEY,targetType TEXT NOT NULL CHECK(targetType IN ('listing','search')),targetId TEXT NOT NULL,authorId TEXT NOT NULL REFERENCES users(id),parentId TEXT REFERENCES social_comments(id),body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 1500),clientId TEXT NOT NULL,createdAt TEXT NOT NULL,editedAt TEXT,deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)),removed INTEGER NOT NULL DEFAULT 0 CHECK(removed IN (0,1)),moderatorId TEXT REFERENCES users(id),moderationReason TEXT,UNIQUE(authorId,clientId));
CREATE INDEX social_comments_post ON social_comments(targetType,targetId,createdAt,id);
CREATE INDEX social_comments_parent ON social_comments(parentId);
CREATE TABLE social_comment_reports(id TEXT PRIMARY KEY,commentId TEXT NOT NULL REFERENCES social_comments(id),reporterId TEXT NOT NULL REFERENCES users(id),reason TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved')),createdAt TEXT NOT NULL,resolverId TEXT REFERENCES users(id),resolutionReason TEXT);
CREATE UNIQUE INDEX social_one_open_report ON social_comment_reports(commentId,reporterId) WHERE status='open';
CREATE TABLE social_rate_events(userId TEXT NOT NULL REFERENCES users(id),kind TEXT NOT NULL,at INTEGER NOT NULL);
CREATE INDEX social_rate_window ON social_rate_events(userId,kind,at);
CREATE INDEX social_rate_expiration ON social_rate_events(at);
-- Trigger-based rolling windows serialize alongside the mutation: parallel requests cannot overspend a limit.
CREATE TRIGGER social_comment_limit BEFORE INSERT ON social_comments BEGIN
 SELECT CASE WHEN (SELECT count(*) FROM social_rate_events WHERE userId=NEW.authorId AND kind='comment' AND at>unixepoch()-600)>=10 THEN RAISE(ABORT,'Social comment rate limit') END;
 SELECT CASE WHEN NEW.parentId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM social_comments p JOIN users u ON u.id=p.authorId WHERE p.id=NEW.parentId AND p.targetType=NEW.targetType AND p.targetId=NEW.targetId AND p.parentId IS NULL AND p.deleted=0 AND p.removed=0 AND u.suspended=0) THEN RAISE(ABORT,'Reply parent unavailable') END;
END;
CREATE TRIGGER social_comment_rate AFTER INSERT ON social_comments BEGIN INSERT INTO social_rate_events VALUES(NEW.authorId,'comment',unixepoch()); DELETE FROM social_rate_events WHERE at<unixepoch()-86400; END;
CREATE TRIGGER social_like_limit BEFORE INSERT ON social_likes BEGIN SELECT CASE WHEN (SELECT count(*) FROM social_rate_events WHERE userId=NEW.userId AND kind='reaction' AND at>unixepoch()-600)>=120 THEN RAISE(ABORT,'Social reaction rate limit') END; END;
CREATE TRIGGER social_like_rate AFTER INSERT ON social_likes BEGIN INSERT INTO social_rate_events VALUES(NEW.userId,'reaction',unixepoch()); DELETE FROM social_rate_events WHERE at<unixepoch()-86400; END;
CREATE TRIGGER social_unlike_limit BEFORE DELETE ON social_likes BEGIN SELECT CASE WHEN (SELECT count(*) FROM social_rate_events WHERE userId=OLD.userId AND kind='reaction' AND at>unixepoch()-600)>=120 THEN RAISE(ABORT,'Social reaction rate limit') END; END;
CREATE TRIGGER social_unlike_rate AFTER DELETE ON social_likes BEGIN INSERT INTO social_rate_events VALUES(OLD.userId,'reaction',unixepoch()); END;
CREATE TRIGGER social_save_limit BEFORE INSERT ON social_saves BEGIN SELECT CASE WHEN (SELECT count(*) FROM social_rate_events WHERE userId=NEW.userId AND kind='reaction' AND at>unixepoch()-600)>=120 THEN RAISE(ABORT,'Social reaction rate limit') END; END;
CREATE TRIGGER social_save_rate AFTER INSERT ON social_saves BEGIN INSERT INTO social_rate_events VALUES(NEW.userId,'reaction',unixepoch()); DELETE FROM social_rate_events WHERE at<unixepoch()-86400; END;
CREATE TRIGGER social_unsave_limit BEFORE DELETE ON social_saves BEGIN SELECT CASE WHEN (SELECT count(*) FROM social_rate_events WHERE userId=OLD.userId AND kind='reaction' AND at>unixepoch()-600)>=120 THEN RAISE(ABORT,'Social reaction rate limit') END; END;
CREATE TRIGGER social_unsave_rate AFTER DELETE ON social_saves BEGIN INSERT INTO social_rate_events VALUES(OLD.userId,'reaction',unixepoch()); END;
CREATE TRIGGER social_report_limit BEFORE INSERT ON social_comment_reports BEGIN SELECT CASE WHEN (SELECT count(*) FROM social_rate_events WHERE userId=NEW.reporterId AND kind='report' AND at>unixepoch()-600)>=10 THEN RAISE(ABORT,'Social report rate limit') END; END;
CREATE TRIGGER social_report_rate AFTER INSERT ON social_comment_reports BEGIN INSERT INTO social_rate_events VALUES(NEW.reporterId,'report',unixepoch()); DELETE FROM social_rate_events WHERE at<unixepoch()-86400; END;
CREATE TRIGGER social_moderation_audit AFTER UPDATE OF removed ON social_comments BEGIN INSERT INTO audit VALUES(lower(hex(randomblob(16))),NEW.moderatorId,CASE WHEN NEW.removed=1 THEN 'comment.remove' ELSE 'comment.restore' END,NEW.id,NEW.moderationReason,strftime('%Y-%m-%dT%H:%M:%fZ','now')); END;
CREATE TRIGGER social_resolution_audit AFTER UPDATE OF status ON social_comment_reports WHEN OLD.status<>NEW.status BEGIN INSERT INTO audit VALUES(lower(hex(randomblob(16))),NEW.resolverId,'comment.report.resolve',NEW.id,NEW.resolutionReason,strftime('%Y-%m-%dT%H:%M:%fZ','now')); END;
