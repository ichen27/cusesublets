ALTER TABLE users ADD COLUMN suspended INTEGER NOT NULL DEFAULT 0 CHECK(suspended IN (0,1));
CREATE TABLE reports(id TEXT PRIMARY KEY,listingId TEXT NOT NULL REFERENCES listings(id),reporterId TEXT NOT NULL REFERENCES users(id),reason TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved')),createdAt TEXT NOT NULL);
CREATE UNIQUE INDEX one_open_report ON reports(listingId,reporterId) WHERE status='open';
CREATE TRIGGER booking_suspension_guard BEFORE INSERT ON bookings WHEN EXISTS(SELECT 1 FROM users WHERE id IN (NEW.buyerId,NEW.sellerId) AND suspended=1) BEGIN SELECT RAISE(ABORT,'Reservation prerequisites changed'); END;
CREATE TRIGGER payment_suspension_guard BEFORE UPDATE OF paymentStatus ON bookings WHEN NEW.paymentStatus='demo_paid' AND EXISTS(SELECT 1 FROM users WHERE id IN (NEW.buyerId,NEW.sellerId) AND suspended=1) BEGIN SELECT RAISE(ABORT,'Reservation prerequisites changed'); END;
CREATE TRIGGER offer_suspension_guard BEFORE INSERT ON offers WHEN EXISTS(SELECT 1 FROM users WHERE id IN (NEW.buyerId,NEW.sellerId) AND suspended=1) BEGIN SELECT RAISE(ABORT,'Reservation prerequisites changed'); END;
