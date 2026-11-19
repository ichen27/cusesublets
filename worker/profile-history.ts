/** What a public profile says about the subleases a member has finished here. */

export interface CompletedSubleases {
  /** Subleases of their own place that someone else stayed in. */
  subleaser: number;
  /** Stays in someone else's place. */
  subtenant: number;
}

export interface PublicReview {
  id: string;
  authorId: string;
  authorName: string;
  rating: number;
  body: string;
  createdAt: string;
  listingTitle: string;
  /** Which side of the sublease the reviewer was on. */
  authorRole: "subleaser" | "subtenant";
  /** The month the stay ended, as `yyyy-MM`. */
  stayEnded: string;
}

/**
 * How many subleases a member has finished on each side. A sublease is finished when it was
 * paid for, moved into and has ended, and is neither cancelled nor in an open dispute: the same
 * rule that lets its two people review each other.
 */
export async function completedSubleases(
  db: D1Database,
  userId: string,
  paidStatuses: string[],
  today: string,
): Promise<CompletedSubleases> {
  const row = await db
    .prepare(
      `SELECT coalesce(sum(sellerId=?),0) subleaser,coalesce(sum(buyerId=?),0) subtenant FROM bookings
       WHERE (sellerId=? OR buyerId=?) AND paymentStatus IN (SELECT value FROM json_each(?))
       AND moveInAt IS NOT NULL AND endDate<? AND status<>'cancelled' AND disputeStatus<>'open'`,
    )
    .bind(userId, userId, userId, userId, JSON.stringify(paidStatuses), today)
    .first<CompletedSubleases>();
  return {
    subleaser: Number(row?.subleaser ?? 0),
    subtenant: Number(row?.subtenant ?? 0),
  };
}

/** The reviews written about a member, newest first. */
export async function profileReviews(db: D1Database, targetId: string) {
  const found = await db
    .prepare(
      `SELECT r.id,r.authorId,a.name authorName,r.rating,r.body,r.createdAt,
       json_extract(l.data,'$.title') listingTitle,
       CASE WHEN b.buyerId=r.authorId THEN 'subtenant' ELSE 'subleaser' END authorRole,
       substr(b.endDate,1,7) stayEnded
       FROM profile_reviews r JOIN users a ON a.id=r.authorId JOIN bookings b ON b.id=r.bookingId
       JOIN listings l ON l.id=b.listingId WHERE r.targetId=? ORDER BY r.rowid DESC LIMIT 200`,
    )
    .bind(targetId)
    .all<PublicReview>();
  return found.results;
}

/** The month an account was created, as `yyyy-MM`. Other people are not shown the moment. */
export function joinedMonth(joinedAt: string | null | undefined) {
  return /^\d{4}-\d{2}-\d{2}/.test(joinedAt ?? "")
    ? joinedAt!.slice(0, 7)
    : undefined;
}
