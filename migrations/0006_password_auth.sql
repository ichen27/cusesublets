CREATE TABLE password_credentials(userId TEXT PRIMARY KEY REFERENCES users(id),passwordHash TEXT NOT NULL);
CREATE TABLE password_sessions(tokenHash TEXT PRIMARY KEY,userId TEXT NOT NULL REFERENCES users(id),expires INTEGER NOT NULL);
CREATE INDEX password_sessions_user ON password_sessions(userId);
CREATE INDEX password_sessions_expiry ON password_sessions(expires);
CREATE TABLE auth_limits(key TEXT PRIMARY KEY,window INTEGER NOT NULL,count INTEGER NOT NULL);
CREATE INDEX auth_limits_window ON auth_limits(window);
