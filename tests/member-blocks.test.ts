import { expect, it } from "vitest";
import { testDatabase } from "./sqlite-d1";

it("fences a reservation accepted after a concurrent block without removing earlier history", () => {
  const { sql } = testDatabase();
  try {
    sql.exec(`INSERT INTO users(id,name,email) VALUES('buyer','Buyer','b@example.test'),('seller','Seller','s@example.test');
      INSERT INTO listings(id,ownerId,status,data) VALUES('place','seller','approved','{"startDate":"2027-01-01","endDate":"2027-08-01"}');
      INSERT INTO conversations(id,listingId,buyerId,sellerId,createdAt,updatedAt) VALUES('thread','place','buyer','seller','2026-10-16','2026-10-16');
      INSERT INTO offers(id,listingId,buyerId,sellerId,amount,startDate,endDate,proposedBy,conversationId) VALUES('offer','place','buyer','seller',800,'2027-01-01','2027-02-01','buyer','thread'); UPDATE listings SET leaseStatus='verified',permissionStatus='verified'; UPDATE users SET identity='verified';`);
    // The request read its active participants before another request committed the block.
    expect(sql.prepare("SELECT count(*) n FROM user_blocks").get()?.n).toBe(0);
    sql.exec("INSERT INTO user_blocks VALUES('seller','buyer','2026-10-16')");
    const book = () =>
      sql.exec(`INSERT INTO bookings(id,offerId,listingId,buyerId,sellerId,amount,startDate,endDate,createdAt)
      VALUES('booking','offer','place','buyer','seller',800,'2027-01-01','2027-02-01','2026-10-16')`);
    expect(book).toThrow("Member contact is blocked");
    expect(sql.prepare("SELECT count(*) n FROM offers").get()?.n).toBe(1);
    sql.exec("DELETE FROM user_blocks");
    book();
    expect(sql.prepare("SELECT count(*) n FROM bookings").get()?.n).toBe(1);
  } finally {
    sql.close();
  }
});
