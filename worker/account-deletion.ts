import { createHash } from "node:crypto";
import type { User } from "../shared/types";
import { revokeAppleAccount, type AppleEnv } from "./apple-auth";
import { requireThat } from "./policy";

type Env = AppleEnv & Pick<Cloudflare.Env, "UPLOADS">;
type Resource = { key: string; prefix: boolean };
type Job = {
  userId: string;
  requestedAt: number;
  completedAt: number | null;
  resources: string;
};
const receiptHash = (receipt: unknown) => {
  requireThat(
    typeof receipt === "string" && /^[a-f0-9]{64}$/i.test(receipt),
    400,
    "Invalid deletion receipt",
  );
  return createHash("sha256").update(receipt).digest("hex");
};
const json = (data: unknown, status = 200) =>
  Response.json(data, { status, headers: { "Cache-Control": "no-store" } });

export async function beginAccountDeletion(
  e: Env,
  user: User,
  receipt: unknown,
) {
  const hash = receiptHash(receipt);
  const existing = await e.DB.prepare(
    "SELECT receiptHash FROM account_deletions WHERE userId=?",
  )
    .bind(user.id)
    .first<{ receiptHash: string }>();
  if (existing) {
    requireThat(
      existing.receiptHash === hash,
      409,
      "Account deletion is already requested",
    );
    return;
  }
  const at = Date.now();
  const q = (sql: string, ...args: unknown[]) =>
    e.DB.prepare(sql).bind(...args);
  // One transaction erases user-authored content and seals the identity. Any earlier authenticated writer is fenced by migration triggers.
  await e.DB.batch([
    q(
      "INSERT INTO account_deletions(userId,receiptHash,requestedAt,resources) VALUES(?,?,?,?)",
      user.id,
      hash,
      at,
      "[]",
    ),
    q(
      "INSERT INTO account_deletion_resources VALUES(?,?,1),(?,?,1)",
      user.id,
      `identity/${user.id}/`,
      user.id,
      `profile/${user.id}/`,
    ),
    q(
      "INSERT INTO account_deletion_resources SELECT ?,id||'/',1 FROM listings WHERE ownerId=?",
      user.id,
      user.id,
    ),
    q(
      "INSERT INTO account_deletion_resources SELECT ?,'tours/'||id||'/',1 FROM room_tours WHERE ownerId=?",
      user.id,
      user.id,
    ),
    q(
      "INSERT INTO account_deletion_resources SELECT ?,'chat/'||id||'/'||?||'/',1 FROM conversations WHERE buyerId=? OR sellerId=?",
      user.id,
      user.id,
      user.id,
      user.id,
    ),
    q(
      "INSERT INTO account_deletion_resources SELECT ?,objectKey,0 FROM chat_attachments WHERE senderId=?",
      user.id,
      user.id,
    ),
    q(
      "UPDATE account_deletions SET resources=(SELECT json_group_array(json_object('key',key,'prefix',isPrefix)) FROM account_deletion_resources WHERE userId=?) WHERE userId=?",
      user.id,
      user.id,
    ),
    q("DELETE FROM account_deletion_resources WHERE userId=?", user.id),
    q("INSERT INTO account_deletion_targets VALUES(?,?)", user.id, user.id),
    q(
      "INSERT OR IGNORE INTO account_deletion_targets SELECT ?,id FROM listings WHERE ownerId=?",
      user.id,
      user.id,
    ),
    q(
      "INSERT OR IGNORE INTO account_deletion_targets SELECT ?,id FROM seeker_requests WHERE ownerId=?",
      user.id,
      user.id,
    ),
    q(
      "INSERT OR IGNORE INTO account_deletion_targets SELECT ?,id FROM reports WHERE reporterId=?",
      user.id,
      user.id,
    ),
    q(
      "INSERT OR IGNORE INTO account_deletion_targets SELECT ?,id FROM request_reports WHERE reporterId=?",
      user.id,
      user.id,
    ),
    q(
      "INSERT OR IGNORE INTO account_deletion_targets SELECT ?,id FROM social_comments WHERE authorId=?",
      user.id,
      user.id,
    ),
    q(
      "INSERT OR IGNORE INTO account_deletion_targets SELECT ?,id FROM bookings WHERE buyerId=? OR sellerId=?",
      user.id,
      user.id,
      user.id,
    ),
    q(
      "UPDATE audit SET reason='[Removed after account deletion]' WHERE actorId=? OR targetId=? OR targetId IN(SELECT targetId FROM account_deletion_targets WHERE userId=?)",
      user.id,
      user.id,
      user.id,
    ),
    q(
      "INSERT OR IGNORE INTO account_deletion_targets SELECT ?,id FROM member_reports WHERE reporterId=? OR targetId=?",
      user.id,
      user.id,
      user.id,
    ),
    q(
      "UPDATE audit SET reason='[Removed after account deletion]' WHERE targetId IN(SELECT id FROM member_reports WHERE reporterId=? OR targetId=?)",
      user.id,
      user.id,
    ),
    q(
      "UPDATE member_reports SET reason='[Deleted]' WHERE reporterId=? OR targetId=?",
      user.id,
      user.id,
    ),
    q(
      "DELETE FROM user_blocks WHERE userId=? OR blockedId=?",
      user.id,
      user.id,
    ),
    q("DELETE FROM sessions WHERE userId=?", user.id),
    q("DELETE FROM password_sessions WHERE userId=?", user.id),
    q("DELETE FROM password_credentials WHERE userId=?", user.id),
    q("DELETE FROM mobile_auth_codes WHERE userId=?", user.id),
    q("DELETE FROM private_drafts WHERE ownerId=?", user.id),
    q("DELETE FROM room_scans WHERE ownerId=?", user.id),
    q(
      "INSERT INTO tour_deletions(id,ownerId) SELECT id,ownerId FROM room_tours WHERE ownerId=? ON CONFLICT(id) DO NOTHING",
      user.id,
    ),
    q("DELETE FROM room_tours WHERE ownerId=?", user.id),
    q("DELETE FROM identity_documents WHERE userId=?", user.id),
    q("DELETE FROM profile_media WHERE userId=?", user.id),
    q(
      "DELETE FROM documents WHERE listingId IN(SELECT id FROM listings WHERE ownerId=?)",
      user.id,
    ),
    q("DELETE FROM chat_attachments WHERE senderId=?", user.id),
    q(
      "DELETE FROM profile_reviews WHERE authorId=? OR targetId=?",
      user.id,
      user.id,
    ),
    q("DELETE FROM social_likes WHERE userId=?", user.id),
    q("DELETE FROM social_saves WHERE userId=?", user.id),
    q("DELETE FROM social_rate_events WHERE userId=?", user.id),
    q(
      "UPDATE social_comments SET body='[Deleted]',deleted=1,moderationReason=NULL,clientId=id WHERE authorId=?",
      user.id,
    ),
    q(
      "UPDATE social_comment_reports SET reason='[Deleted]',resolutionReason=NULL WHERE reporterId=? OR commentId IN(SELECT id FROM social_comments WHERE authorId=?)",
      user.id,
      user.id,
    ),
    q(
      "UPDATE reports SET reason='[Deleted]' WHERE reporterId=? OR listingId IN(SELECT id FROM listings WHERE ownerId=?)",
      user.id,
      user.id,
    ),
    q(
      "UPDATE request_reports SET reason='[Deleted]' WHERE reporterId=? OR requestId IN(SELECT id FROM seeker_requests WHERE ownerId=?)",
      user.id,
      user.id,
    ),
    q(
      "UPDATE messages SET body='[Removed after account deletion]' WHERE senderId=?",
      user.id,
    ),
    q(
      "UPDATE chat_events SET body='[Removed after account deletion]' WHERE actorId=?",
      user.id,
    ),
    q(
      "UPDATE bookings SET disputeReason=NULL WHERE buyerId=? OR sellerId=?",
      user.id,
      user.id,
    ),
    q(
      "UPDATE offers SET status='withdrawn' WHERE (buyerId=? OR sellerId=?) AND status='pending'",
      user.id,
      user.id,
    ),
    q(
      "UPDATE listings SET status='removed',leaseStatus='pending',permissionStatus='pending',reviewNote=NULL,data=json_object('title','Deleted listing','description','','address','','neighborhood','','images',json('[]'),'amenities',json('[]'),'lat',0,'lng',0,'sample',json('false'),'price',0,'beds',0,'baths',0,'roomType','Private room','startDate','2000-01-01','endDate','2000-01-02') WHERE ownerId=?",
      user.id,
    ),
    q(
      "UPDATE seeker_requests SET status='removed',data=json_object('title','Deleted search','description','','areas',json('[]'),'startDate','2000-01-01','endDate','2000-01-02','budgetMin',0,'budgetMax',0,'amenities',json('[]')) WHERE ownerId=?",
      user.id,
    ),
    q(
      "UPDATE users SET name='Deleted member',email=?||'@deleted.invalid',role='member',identity='pending',suspended=1,bio='',phone='',socials='{}',avatar=NULL,identityNote=NULL,joinedAt=NULL,deletedAt=? WHERE id=? AND deletedAt IS NULL",
      crypto.randomUUID(),
      new Date(at).toISOString(),
      user.id,
    ),
  ]);
}

export async function processAccountDeletion(
  e: Env,
  job: Job,
  now = Date.now(),
) {
  // Metadata is already erased. Keep cleanup resources durably, including prefixes that catch late uploads.
  for (const resource of JSON.parse(job.resources) as Resource[]) {
    if (!resource.prefix) {
      await e.UPLOADS.delete(resource.key);
      continue;
    }
    let cursor: string | undefined;
    do {
      const page = await e.UPLOADS.list({
        prefix: resource.key,
        cursor,
        limit: 1000,
      });
      if (page.objects.length)
        await e.UPLOADS.delete(page.objects.map((o) => o.key));
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  }
  await revokeAppleAccount(e, job.userId);
  // A second sweep after the upload settling window precedes the completion receipt.
  const completed =
    now - job.requestedAt >= 15 * 60 * 1000 ? (job.completedAt ?? now) : null;
  await e.DB.prepare(
    "UPDATE account_deletions SET completedAt=?,nextCheck=?,attempts=attempts+1 WHERE userId=?",
  )
    .bind(completed, now + (completed ? 86400000 : 900000), job.userId)
    .run();
}
export async function sweepAccountDeletions(e: Env) {
  const jobs = await e.DB.prepare(
    "SELECT * FROM account_deletions WHERE nextCheck<=? ORDER BY nextCheck LIMIT 10",
  )
    .bind(Date.now())
    .all<Job>();
  let failed = false;
  for (const job of jobs.results) {
    try {
      await processAccountDeletion(e, job);
    } catch {
      failed = true;
      await e.DB.prepare(
        "UPDATE account_deletions SET nextCheck=?,attempts=attempts+1 WHERE userId=?",
      )
        .bind(Date.now() + 900000, job.userId)
        .run();
      console.error(JSON.stringify({ event: "account_deletion_retry" }));
    }
  }
  if (failed) throw new Error("Account cleanup requires retry");
}
export async function accountDeletionStatus(e: Env, receipt: unknown) {
  const job = await e.DB.prepare(
    "SELECT completedAt,requestedAt FROM account_deletions WHERE receiptHash=?",
  )
    .bind(receiptHash(receipt))
    .first<{ completedAt: number | null; requestedAt: number }>();
  requireThat(job, 404, "No deletion request matches this receipt");
  return json({
    status: job.completedAt ? "complete" : "processing",
    requestedAt: job.requestedAt,
    completedAt: job.completedAt,
  });
}
