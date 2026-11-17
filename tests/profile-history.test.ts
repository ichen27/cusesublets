import { expect, it } from "vitest";
import { testDatabase } from "./sqlite-d1";
import {
  completedSubleases,
  joinedMonth,
  profileReviews,
} from "../worker/profile-history";

const today = "2026-11-17";

/** Ana subleases "place"; Ben subleases "flat". Each booking is one stay. */
function marketplace() {
  const made = testDatabase();
  const { sql } = made;
  sql.exec(`INSERT INTO users(id,name,email,identity) VALUES
      ('ana','Ana Host','ana@example.test','verified'),
      ('ben','Ben Renter','ben@example.test','verified'),
      ('cy','Cy Renter','cy@example.test','verified');
    INSERT INTO listings(id,ownerId,status,leaseStatus,permissionStatus,data) VALUES
      ('place','ana','approved','verified','verified','{"title":"Ana place","startDate":"2025-01-01","endDate":"2027-08-01"}'),
      ('flat','ben','approved','verified','verified','{"title":"Ben flat","startDate":"2025-01-01","endDate":"2027-08-01"}');
    INSERT INTO conversations(id,listingId,buyerId,sellerId,createdAt,updatedAt) VALUES
      ('place-ben','place','ben','ana','2025-12-01','2025-12-01'),
      ('place-cy','place','cy','ana','2025-12-01','2025-12-01'),
      ('flat-ana','flat','ana','ben','2025-12-01','2025-12-01'),
      ('flat-cy','flat','cy','ben','2025-12-01','2025-12-01');`);
  const stay = (
    id: string,
    listing: string,
    buyer: string,
    seller: string,
    start: string,
    end: string,
    paymentStatus = "paid",
    movedIn = true,
  ) => {
    sql
      .prepare(
        "INSERT INTO offers(id,listingId,buyerId,sellerId,amount,startDate,endDate,proposedBy,conversationId) VALUES(?,?,?,?,800,?,?,?,?)",
      )
      .run("offer-" + id, listing, buyer, seller, start, end, buyer, listing + "-" + buyer);
    sql
      .prepare(
        "INSERT INTO bookings(id,offerId,listingId,buyerId,sellerId,amount,startDate,endDate,paymentStatus,moveInAt,createdAt) VALUES(?,?,?,?,?,800,?,?,?,?,'2025-12-01')",
      )
      .run(
        id,
        "offer-" + id,
        listing,
        buyer,
        seller,
        start,
        end,
        paymentStatus,
        movedIn ? start + "T12:00:00Z" : null,
      );
  };
  return { ...made, stay };
}

it("counts only subleases that were paid for, moved into and have ended", async () => {
  const { sql, DB, stay } = marketplace();
  try {
    stay("spring", "place", "ben", "ana", "2026-01-05", "2026-05-15");
    stay("summer", "place", "cy", "ana", "2026-06-01", "2026-08-01");
    stay("ana-away", "flat", "ana", "ben", "2026-02-01", "2026-03-01");
    // None of these is a finished sublease.
    stay("cancelled", "place", "cy", "ana", "2026-09-01", "2026-10-01");
    sql.exec("UPDATE bookings SET status='cancelled' WHERE id='cancelled'");
    stay("still-there", "place", "ben", "ana", "2026-11-01", "2027-02-01");
    stay("never-paid", "flat", "cy", "ben", "2026-04-01", "2026-05-01", "unpaid");
    stay("never-moved-in", "flat", "cy", "ben", "2026-06-01", "2026-07-01", "paid", false);
    stay("disputed", "flat", "cy", "ben", "2026-08-01", "2026-09-01");
    sql.exec("UPDATE bookings SET disputeStatus='open' WHERE id='disputed'");

    expect(await completedSubleases(DB, "ana", ["paid"], today)).toEqual({
      subleaser: 2,
      subtenant: 1,
    });
    expect(await completedSubleases(DB, "ben", ["paid"], today)).toEqual({
      subleaser: 1,
      subtenant: 1,
    });
    expect(await completedSubleases(DB, "cy", ["paid"], today)).toEqual({
      subleaser: 0,
      subtenant: 1,
    });
  } finally {
    sql.close();
  }
});

it("counts a practice payment only where practice payments are allowed", async () => {
  const { sql, DB, stay } = marketplace();
  try {
    stay("practice", "place", "ben", "ana", "2026-01-05", "2026-05-15", "demo_paid");
    expect(await completedSubleases(DB, "ana", ["paid"], today)).toEqual({
      subleaser: 0,
      subtenant: 0,
    });
    expect(
      await completedSubleases(DB, "ana", ["paid", "demo_paid"], today),
    ).toEqual({ subleaser: 1, subtenant: 0 });
  } finally {
    sql.close();
  }
});

it("says which side of the sublease a reviewer was on and the month it ended", async () => {
  const { sql, DB, stay } = marketplace();
  try {
    stay("spring", "place", "ben", "ana", "2026-01-05", "2026-05-15");
    sql.exec(`INSERT INTO profile_reviews VALUES
      ('by-ben','spring','ben','ana',5,'Keys on time and the place matched the listing.','2026-05-20T10:00:00Z'),
      ('by-ana','spring','ana','ben',4,'Left the room clean and paid on time.','2026-05-21T10:00:00Z');`);

    expect(await profileReviews(DB, "ana")).toEqual([
      {
        id: "by-ben",
        authorId: "ben",
        authorName: "Ben Renter",
        rating: 5,
        body: "Keys on time and the place matched the listing.",
        createdAt: "2026-05-20T10:00:00Z",
        listingTitle: "Ana place",
        authorRole: "subtenant",
        stayEnded: "2026-05",
      },
    ]);
    const aboutBen = await profileReviews(DB, "ben");
    expect(aboutBen.map((r) => [r.authorName, r.authorRole])).toEqual([
      ["Ana Host", "subleaser"],
    ]);
  } finally {
    sql.close();
  }
});

it("records when an account was created, once", () => {
  const { sql } = testDatabase();
  try {
    sql.exec(
      "INSERT INTO users(id,name,email) VALUES('new','New Member','new@example.test')",
    );
    const joined = sql.prepare("SELECT joinedAt FROM users WHERE id='new'").get()
      ?.joinedAt as string;
    expect(joined).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);

    // Signing in again through the university login rewrites the row; the date stays.
    sql.exec("UPDATE users SET joinedAt='2026-09-03T14:00:00.000Z' WHERE id='new'");
    sql.exec(
      "INSERT INTO users(id,name,email,role) VALUES('new','new','new@example.test','member') ON CONFLICT(id) DO UPDATE SET email=excluded.email,role=excluded.role",
    );
    expect(
      sql.prepare("SELECT joinedAt FROM users WHERE id='new'").get()?.joinedAt,
    ).toBe("2026-09-03T14:00:00.000Z");

    sql.exec(
      "INSERT INTO users(id,name,email,joinedAt) VALUES('moved','Moved Member','moved@example.test','2024-01-02T00:00:00.000Z')",
    );
    expect(
      sql.prepare("SELECT joinedAt FROM users WHERE id='moved'").get()?.joinedAt,
    ).toBe("2024-01-02T00:00:00.000Z");
  } finally {
    sql.close();
  }
});

it("shows other people the month someone joined, not the moment", () => {
  expect(joinedMonth("2026-09-03T14:00:00.000Z")).toBe("2026-09");
  expect(joinedMonth(null)).toBeUndefined();
  expect(joinedMonth(undefined)).toBeUndefined();
  expect(joinedMonth("not a date")).toBeUndefined();
});
