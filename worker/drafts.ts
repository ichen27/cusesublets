import type { User } from "../shared/types";
import {
  cleanDraftData,
  draftIdPattern,
  type DraftKind,
  type PrivateDraft,
} from "../shared/drafts";
import { HttpError, requireThat } from "./policy";
type Env = { DB: D1Database };
type Row = Omit<PrivateDraft, "data"> & { data: string; deleted: number };
const json = (data: unknown, status = 200) =>
  Response.json(data, {
    status,
    headers: {
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
const view = (row: Row): PrivateDraft => ({
  id: row.id,
  kind: row.kind,
  step: row.step,
  revision: row.revision,
  data: JSON.parse(row.data),
  updatedAt: row.updatedAt,
});
export async function draftRoute(
  req: Request,
  env: Env,
  user: User | null,
): Promise<Response | null> {
  const path = new URL(req.url).pathname;
  if (path !== "/api/drafts" && !path.startsWith("/api/drafts/")) return null;
  requireThat(user, 401, "Sign in to save or resume your work.");
  requireThat(!user.suspended, 403, "This account is suspended.");
  if (path === "/api/drafts" && req.method === "GET") {
    const rows = await env.DB.prepare(
      "SELECT * FROM private_drafts WHERE ownerId=? AND deleted=0 ORDER BY updatedAt DESC LIMIT 21",
    )
      .bind(user.id)
      .all<Row>();
    return json({ drafts: rows.results.map(view) });
  }
  const match = path.match(/^\/api\/drafts\/([^/]+)(\/delete)?$/);
  requireThat(match, 404, "Draft not found.");
  const draftId = match[1];
  requireThat(
    draftId === "search" || draftIdPattern.test(draftId),
    400,
    "Invalid draft ID.",
  );
  const read = () =>
    env.DB.prepare("SELECT * FROM private_drafts WHERE ownerId=? AND id=?")
      .bind(user.id, draftId)
      .first<Row>();
  if (req.method === "GET" && !match[2]) {
    const row = await read();
    return json({
      draft: row && !row.deleted ? view(row) : null,
      revision: row?.revision || 0,
    });
  }
  requireThat(req.method === "POST", 405, "Method not allowed.");
  const raw = await req.text();
  requireThat(raw.length <= 40000, 413, "Draft is too large.");
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new HttpError(400, "Invalid draft JSON.");
  }
  requireThat(
    body && typeof body === "object" && !Array.isArray(body),
    400,
    "Invalid draft.",
  );
  requireThat(
    Number.isSafeInteger(body.revision) && Number(body.revision) >= 0,
    400,
    "A draft revision is required.",
  );
  const revision = Number(body.revision),
    timestamp = new Date().toISOString();
  let changed: Row | null;
  if (match[2]) {
    changed = await env.DB.prepare(
      "UPDATE private_drafts SET deleted=1,data='{}',revision=revision+1,updatedAt=? WHERE ownerId=? AND id=? AND revision=? AND deleted=0 AND EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0) RETURNING *",
    )
      .bind(timestamp, user.id, draftId, revision, user.id)
      .first<Row>();
  } else {
    const kind: DraftKind = draftId === "search" ? "search" : "listing";
    requireThat(body.kind === kind, 400, "Draft type does not match its ID.");
    requireThat(
      Number.isInteger(body.step) &&
        Number(body.step) >= 1 &&
        Number(body.step) <= 4,
      400,
      "Choose a valid setup step.",
    );
    let data: PrivateDraft["data"];
    try {
      data = cleanDraftData(kind, body.data);
    } catch (cause) {
      throw new HttpError(400, (cause as Error).message);
    }
    if (revision === 0) {
      changed = await env.DB.prepare(
        "INSERT INTO private_drafts(ownerId,id,kind,step,revision,data,updatedAt) SELECT ?,?,?,?,1,?,? WHERE EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0) AND (SELECT COUNT(*) FROM private_drafts WHERE ownerId=? AND kind=? AND deleted=0) < ? ON CONFLICT(ownerId,id) DO NOTHING RETURNING *",
      )
        .bind(
          user.id,
          draftId,
          kind,
          body.step,
          JSON.stringify(data),
          timestamp,
          user.id,
          user.id,
          kind,
          kind === "search" ? 1 : 20,
        )
        .first<Row>();
    } else {
      changed = await env.DB.prepare(
        "UPDATE private_drafts SET step=?,data=?,revision=revision+1,deleted=0,updatedAt=? WHERE ownerId=? AND id=? AND revision=? AND kind=? AND EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0) AND (deleted=0 OR (SELECT COUNT(*) FROM private_drafts WHERE ownerId=? AND kind=? AND deleted=0) < ?) RETURNING *",
      )
        .bind(
          body.step,
          JSON.stringify(data),
          timestamp,
          user.id,
          draftId,
          revision,
          kind,
          user.id,
          user.id,
          kind,
          kind === "search" ? 1 : 20,
        )
        .first<Row>();
    }
  }
  requireThat(
    changed,
    409,
    "This draft changed in another tab, or your draft limit was reached. Your entries are still here. Reload the saved version to review before saving again.",
  );
  return json({
    draft: !changed.deleted ? view(changed) : null,
    revision: changed.revision,
  });
}
