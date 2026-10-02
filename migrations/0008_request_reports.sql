CREATE TABLE request_reports(
 id TEXT PRIMARY KEY,
 requestId TEXT NOT NULL REFERENCES seeker_requests(id),
 reporterId TEXT NOT NULL REFERENCES users(id),
 reason TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved')),
 createdAt TEXT NOT NULL
);
CREATE UNIQUE INDEX one_open_request_report ON request_reports(requestId,reporterId) WHERE status='open';
