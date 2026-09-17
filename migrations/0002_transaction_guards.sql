-- The reservation insert and review checks execute within one SQLite transaction.
CREATE TRIGGER booking_review_guard BEFORE INSERT ON bookings WHEN NOT EXISTS (
 SELECT 1 FROM listings l JOIN users u ON u.id=l.ownerId JOIN offers o ON o.id=NEW.offerId
 WHERE l.id=NEW.listingId AND l.status='approved' AND l.leaseStatus='verified'
 AND l.permissionStatus='verified' AND u.identity='verified' AND o.status='pending'
 AND NEW.sellerId=l.ownerId AND NEW.buyerId=o.buyerId AND NEW.sellerId=o.sellerId
 AND NEW.startDate=o.startDate AND NEW.endDate=o.endDate AND NEW.amount=o.amount
) BEGIN SELECT RAISE(ABORT,'Reservation prerequisites changed'); END;
CREATE TRIGGER payment_review_guard BEFORE UPDATE OF paymentStatus ON bookings WHEN NEW.paymentStatus='demo_paid' AND (
 NEW.buyerSigned<>1 OR NEW.sellerSigned<>1 OR NEW.disputeStatus='open' OR NOT EXISTS(
 SELECT 1 FROM listings l JOIN users u ON u.id=l.ownerId WHERE l.id=NEW.listingId AND l.status='approved'
 AND l.leaseStatus='verified' AND l.permissionStatus='verified' AND u.identity='verified'
)) BEGIN SELECT RAISE(ABORT,'Reservation prerequisites changed'); END;
