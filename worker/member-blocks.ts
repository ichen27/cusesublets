import type { User } from "../shared/types";
import { HttpError, requireThat } from "./policy";
export async function blockedMemberIDs(db: D1Database, userId: string | null) {
  if (!userId) return new Set<string>();
  const rows = await db
    .prepare(
      "SELECT blockedId id FROM user_blocks WHERE userId=? UNION SELECT userId FROM user_blocks WHERE blockedId=?",
    )
    .bind(userId, userId)
    .all<{ id: string }>();
  return new Set(rows.results.map((r) => r.id));
}
export async function memberBlockRoute(
  req: Request,
  db: D1Database,
  user: User | null,
): Promise<Response | null> {
  const p = new URL(req.url).pathname;
  const match = p.match(/^\/api\/members\/([^/]+)\/(block|unblock)$/);
  if (p != "/api/blocked-members" && !match) return null;
  requireThat(user, 401, "Sign in to manage blocked members");
  requireThat(!user.suspended, 403, "Account unavailable");
  const json = (data: unknown) =>
    Response.json(data, { headers: { "Cache-Control": "no-store" } });
  if (p === "/api/blocked-members" && req.method === "GET") {
    const result = await db
      .prepare(
        "SELECT u.id,u.name,b.createdAt FROM user_blocks b JOIN users u ON u.id=b.blockedId WHERE b.userId=? ORDER BY b.createdAt DESC",
      )
      .bind(user.id)
      .all();
    return json({
      members: result.results,
      hiddenMemberIDs: [...(await blockedMemberIDs(db, user.id))],
    });
  }
  requireThat(match && req.method === "POST", 405, "Method not allowed");
  let target: string;
  try {
    target = decodeURIComponent(match[1]);
  } catch {
    throw new HttpError(400,"Invalid member");
  }
  requireThat(target !== user.id, 400, "You cannot block yourself");
  requireThat(
    await db.prepare("SELECT id FROM users WHERE id=?").bind(target).first(),
    404,
    "Member not found",
  );
  if (match[2] === "block")
    await db
      .prepare("INSERT INTO user_blocks VALUES(?,?,?) ON CONFLICT DO NOTHING")
      .bind(user.id, target, new Date().toISOString())
      .run();
  else
    await db
      .prepare("DELETE FROM user_blocks WHERE userId=? AND blockedId=?")
      .bind(user.id, target)
      .run();
  return json({ ok: true });
}
