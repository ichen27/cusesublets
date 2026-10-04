import type { User } from "../shared/types";
import type { SocialComment, SocialSummary } from "../shared/social";
import { HttpError, requireThat, text, syracuseDate } from "./policy";
type Env = Pick<Cloudflare.Env, "DB">;
type CommentRow = {
  id: string;
  targetType: string;
  targetId: string;
  authorId: string;
  authorName: string;
  parentId: string | null;
  body: string;
  createdAt: string;
  editedAt: string | null;
  deleted: number;
  removed: number;
  suspended: number;
};
const json = (value: unknown, status = 200) =>
  Response.json(value, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
// These predicates are embedded in each mutation; a stale prior read never authorizes a write.
const visible =
  "EXISTS(SELECT 1 FROM social_visible_targets v WHERE v.targetType=? AND v.targetId=? AND v.endDate>?)";
const actor = "EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0)";
const staff =
  "EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0 AND role='admin')";
const selectComment =
  "SELECT c.*,u.name authorName,u.suspended FROM social_comments c JOIN users u ON u.id=c.authorId";
const projection = (c: CommentRow): SocialComment => ({
  id: c.id,
  authorId: c.deleted || c.removed || c.suspended ? null : c.authorId,
  authorName:
    c.deleted || c.removed || c.suspended ? "Community member" : c.authorName,
  parentId: c.parentId,
  body: c.deleted || c.removed || c.suspended ? "Comment unavailable" : c.body,
  createdAt: c.createdAt,
  editedAt: c.editedAt,
  unavailable: !!(c.deleted || c.removed || c.suspended),
});
const encode = (values: string[]) => btoa(JSON.stringify(values));
function cursor(value: string | null, size: number): string[] | null {
  if (!value) return null;
  try {
    const parsed: unknown = JSON.parse(atob(value));
    requireThat(
      Array.isArray(parsed) &&
        parsed.length === size &&
        parsed.every((x) => typeof x === "string" && x.length <= 100),
      400,
      "Invalid page cursor",
    );
    return parsed as string[];
  } catch {
    throw new HttpError(400, "Invalid page cursor");
  }
}
async function body(req: Request): Promise<Record<string, unknown>> {
  const raw = await req.text();
  requireThat(raw.length <= 6000, 413, "Request is too large");
  try {
    const b: unknown = JSON.parse(raw);
    requireThat(
      b && typeof b === "object" && !Array.isArray(b),
      400,
      "Use a JSON object",
    );
    return b as Record<string, unknown>;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "Invalid JSON");
  }
}
async function requireVisible(env: Env, type: string, id: string) {
  requireThat(
    await env.DB.prepare(`SELECT 1 ok WHERE ${visible}`)
      .bind(type, id, syracuseDate())
      .first(),
    404,
    "This post is no longer available",
  );
}
function signed(user: User | null): asserts user is User {
  requireThat(user, 401, "Sign in to participate");
  requireThat(!user.suspended, 403, "This account is suspended");
}
async function comments(
  env: Env,
  type: string,
  id: string,
  after: string | null,
  limit: number,
  preview = false,
) {
  const page = cursor(after, 2);
  const rows = (
    await env.DB.prepare(
      selectComment +
        ` WHERE c.targetType=? AND c.targetId=? ${page ? "AND (c.createdAt,c.id)>(?,?)" : ""} ORDER BY c.createdAt ${preview ? "DESC" : "ASC"},c.id ${preview ? "DESC" : "ASC"} LIMIT ?`,
    )
      .bind(type, id, ...(page ?? []), limit + 1)
      .all<CommentRow>()
  ).results;
  const more = rows.length > limit;
  const selected = rows.slice(0, limit);
  if (preview) selected.reverse();
  return {
    comments: selected.map(projection),
    nextCursor:
      !preview && more
        ? encode([
            selected[selected.length - 1].createdAt,
            selected[selected.length - 1].id,
          ])
        : null,
  };
}
async function summary(
  env: Env,
  type: string,
  id: string,
  user: User | null,
): Promise<SocialSummary> {
  const row = await env.DB.prepare(
    `SELECT (SELECT count(*) FROM social_likes l JOIN users u ON u.id=l.userId WHERE l.targetType=?1 AND l.targetId=?2 AND u.suspended=0) likeCount,(SELECT count(*) FROM social_comments c JOIN users u ON u.id=c.authorId WHERE c.targetType=?1 AND c.targetId=?2 AND c.deleted=0 AND c.removed=0 AND u.suspended=0) commentCount,EXISTS(SELECT 1 FROM social_likes WHERE targetType=?1 AND targetId=?2 AND userId=?3) liked,EXISTS(SELECT 1 FROM social_saves WHERE targetType=?1 AND targetId=?2 AND userId=?3) saved`,
  )
    .bind(type, id, user?.id ?? "")
    .first<{
      likeCount: number;
      commentCount: number;
      liked: number;
      saved: number;
    }>();
  return {
    ...row!,
    liked: !!row?.liked,
    saved: !!row?.saved,
    ...(await comments(env, type, id, null, 2, true)),
  };
}
export async function socialRoute(
  req: Request,
  env: Env,
  user: User | null,
): Promise<Response | null> {
  const url = new URL(req.url),
    path = url.pathname.replace(/^\/api/, "");
  if (!path.startsWith("/social/")) return null;
  try {
    if (path === "/social/saved" && req.method === "GET") {
      signed(user);
      const page = cursor(url.searchParams.get("cursor"), 3);
      const rows = (
        await env.DB.prepare(
          `SELECT s.targetType,s.targetId,s.createdAt savedAt,EXISTS(SELECT 1 FROM social_visible_targets v WHERE v.targetType=s.targetType AND v.targetId=s.targetId AND v.endDate>?) available FROM social_saves s WHERE s.userId=? ${page ? "AND (s.createdAt,s.targetType,s.targetId)<(?,?,?)" : ""} ORDER BY s.createdAt DESC,s.targetType DESC,s.targetId DESC LIMIT 51`,
        )
          .bind(syracuseDate(), user.id, ...(page ?? []))
          .all<{
            targetType: string;
            targetId: string;
            savedAt: string;
            available: number;
          }>()
      ).results;
      const items = rows.slice(0, 50),
        last = items[items.length - 1];
      return json({
        items: items.map((x) => ({ ...x, available: !!x.available })),
        nextCursor:
          rows.length > 50
            ? encode([last.savedAt, last.targetType, last.targetId])
            : null,
      });
    }
    if (path === "/social/moderation" && req.method === "GET") {
      signed(user);
      requireThat(user.role === "admin", 403, "Staff access required");
      const page = cursor(url.searchParams.get("cursor"), 2);
      const status =
        url.searchParams.get("status") === "resolved" ? "resolved" : "open";
      const reports = (
        await env.DB.prepare(
          `SELECT r.id,r.commentId,r.reason,r.status,r.createdAt,c.body,c.targetType,c.targetId,c.removed,c.deleted,u.name authorName FROM social_comment_reports r JOIN social_comments c ON c.id=r.commentId JOIN users u ON u.id=c.authorId WHERE r.status=? ${page ? "AND (r.createdAt,r.id)>(?,?)" : ""} ORDER BY r.createdAt,r.id LIMIT 51`,
        )
          .bind(status, ...(page ?? []))
          .all<{ id: string; createdAt: string }>()
      ).results;
      const rows = reports.slice(0, 50),
        last = rows[rows.length - 1];
      return json({
        reports: rows,
        nextCursor:
          reports.length > 50 ? encode([last.createdAt, last.id]) : null,
      });
    }
    const resolve = path.match(/^\/social\/reports\/([^/]+)\/resolve$/);
    if (resolve && req.method === "POST") {
      signed(user);
      requireThat(user.role === "admin", 403, "Staff access required");
      const b = await body(req);
      const reason = text(b.reason, "Resolution reason", 1000);
      const r = await env.DB.prepare(
        `UPDATE social_comment_reports SET status='resolved',resolverId=?,resolutionReason=? WHERE id=? AND status='open' AND ${staff} RETURNING id`,
      )
        .bind(user.id, reason, resolve[1], user.id)
        .first();
      requireThat(r, 409, "Report changed or staff access is unavailable");
      return json({ ok: true });
    }
    const action = path.match(
      /^\/social\/comments\/([^/]+)\/(edit|delete|report|moderate)$/,
    );
    if (action && req.method === "POST") {
      signed(user);
      const b = await body(req);
      const c = await env.DB.prepare(selectComment + " WHERE c.id=?")
        .bind(action[1])
        .first<CommentRow>();
      requireThat(c, 404, "Comment not found");
      if (action[2] === "moderate") {
        requireThat(user.role === "admin", 403, "Staff access required");
        requireThat(
          typeof b.removed === "boolean",
          400,
          "Choose remove or restore",
        );
        const reason = text(b.reason, "Moderation reason", 1000);
        const result = await env.DB.prepare(
          `UPDATE social_comments SET removed=?,moderatorId=?,moderationReason=? WHERE id=? AND deleted=0 AND ${staff} RETURNING id`,
        )
          .bind(b.removed ? 1 : 0, user.id, reason, c.id, user.id)
          .first();
        requireThat(result, 409, "Comment was deleted or staff access changed");
        return json({ ok: true });
      }
      await requireVisible(env, c.targetType, c.targetId);
      if (action[2] === "report") {
        requireThat(
          c.authorId !== user.id,
          400,
          "You can edit or delete your own comment",
        );
        requireThat(
          !c.deleted && !c.removed && !c.suspended,
          409,
          "Comment is unavailable",
        );
        const reason = text(b.reason, "Report reason", 1000);
        await env.DB.prepare(
          `INSERT INTO social_comment_reports(id,commentId,reporterId,reason,createdAt) SELECT ?,?,?,?,? WHERE ${visible} AND ${actor} AND EXISTS(SELECT 1 FROM social_comments c JOIN users u ON u.id=c.authorId WHERE c.id=? AND c.deleted=0 AND c.removed=0 AND u.suspended=0) AND NOT EXISTS(SELECT 1 FROM social_comment_reports WHERE commentId=? AND reporterId=? AND status='open')`,
        )
          .bind(
            crypto.randomUUID(),
            c.id,
            user.id,
            reason,
            new Date().toISOString(),
            c.targetType,
            c.targetId,
            syracuseDate(),
            user.id,
            c.id,
            c.id,
            user.id,
          )
          .run();
        const exists = await env.DB.prepare(
          "SELECT id FROM social_comment_reports WHERE commentId=? AND reporterId=? AND status='open'",
        )
          .bind(c.id, user.id)
          .first();
        requireThat(exists, 409, "Comment is no longer available");
        return json({ ok: true });
      }
      requireThat(
        c.authorId === user.id,
        403,
        "Only the author can change this comment",
      );
      const edited = action[2] === "edit";
      const commentBody = edited ? text(b.body, "Comment", 1500) : c.body;
      const result = await env.DB.prepare(
        `UPDATE social_comments SET body=?,editedAt=CASE WHEN ?=1 THEN ? ELSE editedAt END,deleted=? WHERE id=? AND authorId=? AND deleted=0 AND removed=0 AND ${visible} AND ${actor} RETURNING id`,
      )
        .bind(
          commentBody,
          edited ? 1 : 0,
          new Date().toISOString(),
          edited ? 0 : 1,
          c.id,
          user.id,
          c.targetType,
          c.targetId,
          syracuseDate(),
          user.id,
        )
        .first();
      requireThat(result, 409, "Comment or post is no longer available");
      return json({ ok: true });
    }
    const target = path.match(
      /^\/social\/(listing|search)\/([^/]+)(?:\/(comments|like|save))?$/,
    );
    if (!target) throw new HttpError(404, "Social route not found");
    const [, type, id, operation] = target;
    if (req.method === "GET") {
      await requireVisible(env, type, id);
      if (!operation) return json(await summary(env, type, id, user));
      if (operation === "comments")
        return json(
          await comments(env, type, id, url.searchParams.get("cursor"), 20),
        );
      throw new HttpError(405, "Method not allowed");
    }
    requireThat(req.method === "POST", 405, "Method not allowed");
    signed(user);
    const b = await body(req);
    // Removing a private bookmark remains possible when its public post is unavailable.
    if (!(operation === "save" && b.saved === false))
      await requireVisible(env, type, id);
    if (operation === "like" || operation === "save") {
      const key = operation === "like" ? "liked" : "saved";
      requireThat(
        typeof b[key] === "boolean",
        400,
        "Choose an explicit reaction state",
      );
      const table = operation === "like" ? "social_likes" : "social_saves";
      if (b[key]) {
        await env.DB.prepare(
          `INSERT INTO ${table}(targetType,targetId,userId,createdAt) SELECT ?,?,?,? WHERE ${visible} AND ${actor} AND NOT EXISTS(SELECT 1 FROM ${table} WHERE targetType=? AND targetId=? AND userId=?)`,
        )
          .bind(
            type,
            id,
            user.id,
            new Date().toISOString(),
            type,
            id,
            syracuseDate(),
            user.id,
            type,
            id,
            user.id,
          )
          .run();
        requireThat(
          await env.DB.prepare(
            `SELECT 1 FROM ${table} WHERE targetType=? AND targetId=? AND userId=?`,
          )
            .bind(type, id, user.id)
            .first(),
          409,
          "Post is no longer available",
        );
      } else {
        await env.DB.prepare(
          `DELETE FROM ${table} WHERE targetType=? AND targetId=? AND userId=? AND ${actor} ${operation === "like" ? `AND ${visible}` : ""}`,
        )
          .bind(
            type,
            id,
            user.id,
            user.id,
            ...(operation === "like" ? [type, id, syracuseDate()] : []),
          )
          .run();
      }
      return json({ ok: true, [key]: b[key] });
    }
    if (operation === "comments") {
      const content = text(b.body, "Comment", 1500),
        clientId = text(b.clientId, "Submission identifier", 80);
      requireThat(
        /^[a-zA-Z0-9_-]{8,80}$/.test(clientId),
        400,
        "Invalid submission identifier",
      );
      const parentId =
        b.parentId == null ? null : text(b.parentId, "Parent comment", 80);
      const existing = await env.DB.prepare(
        selectComment + " WHERE c.authorId=? AND c.clientId=?",
      )
        .bind(user.id, clientId)
        .first<CommentRow>();
      if (existing) {
        requireThat(
          existing.targetType === type &&
            existing.targetId === id &&
            existing.body === content &&
            existing.parentId === parentId,
          409,
          "This submission identifier belongs to a different comment",
        );
        return json({ comment: projection(existing) }, 200);
      }
      await env.DB.prepare(
        `INSERT INTO social_comments(id,targetType,targetId,authorId,parentId,body,clientId,createdAt) SELECT ?,?,?,?,?,?,?,? WHERE ${visible} AND ${actor} AND NOT EXISTS(SELECT 1 FROM social_comments WHERE authorId=? AND clientId=?) ON CONFLICT(authorId,clientId) DO NOTHING`,
      )
        .bind(
          crypto.randomUUID(),
          type,
          id,
          user.id,
          parentId,
          content,
          clientId,
          new Date().toISOString(),
          type,
          id,
          syracuseDate(),
          user.id,
          user.id,
          clientId,
        )
        .run();
      const created = await env.DB.prepare(
        selectComment + " WHERE c.authorId=? AND c.clientId=?",
      )
        .bind(user.id, clientId)
        .first<CommentRow>();
      requireThat(created, 409, "Post is no longer available");
      requireThat(
        created.targetType === type &&
          created.targetId === id &&
          created.body === content &&
          created.parentId === parentId,
        409,
        "This submission identifier belongs to a different comment",
      );
      return json({ comment: projection(created) }, 201);
    }
    throw new HttpError(405, "Method not allowed");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("Social ") && message.includes("rate limit"))
      return json(
        {
          error:
            "Too many actions. Please wait up to 10 minutes and try again.",
        },
        429,
      );
    if (message.includes("Reply parent unavailable"))
      return json(
        {
          error:
            "Replies must be to an available top-level comment on this post.",
        },
        409,
      );
    throw error;
  }
}
