import type { User } from "../shared/types";
import { validateRoomLayout, type RoomScan } from "../shared/room-scan";
import { HttpError, requireThat, text } from "./policy";
type Env = Pick<Cloudflare.Env, "DB">;
type ScanRow = Omit<RoomScan, "layout" | "published"> & {
  ownerId: string;
  layout: string;
  published: number;
};
const json = (value: unknown, status = 200) =>
  Response.json(value, {
    status,
    headers: {
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
const view = (r: ScanRow): RoomScan => ({
  id: r.id,
  listingId: r.listingId,
  name: r.name,
  layout: JSON.parse(r.layout),
  published: !!r.published,
  createdAt: r.createdAt,
});
async function input(req: Request) {
  const reader = req.body?.getReader();
  requireThat(reader, 400, "Provide a scan");
  const parts: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > 128 * 1024) {
      await reader.cancel();
      throw new HttpError(413, "Room scan is too large");
    }
    parts.push(value);
  }
  const bytes = new Uint8Array(length);
  let at = 0;
  for (const part of parts) {
    bytes.set(part, at);
    at += part.length;
  }
  try {
    const b: unknown = JSON.parse(new TextDecoder().decode(bytes));
    requireThat(
      b && typeof b === "object" && !Array.isArray(b),
      400,
      "Use a JSON object",
    );
    return b as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "Invalid scan JSON");
  }
}
export async function roomScanRoute(
  req: Request,
  env: Env,
  user: User | null,
): Promise<Response | null> {
  const p = new URL(req.url).pathname;
  const match = p.match(
    /^\/api\/listings\/([^/]+)\/scans(?:\/([^/]+)\/(visibility|delete))?$/,
  );
  if (!match) return null;
  const [, listingId, scanId, action] = match;
  const listing = await env.DB.prepare(
    "SELECT l.ownerId,l.status,u.suspended FROM listings l JOIN users u ON u.id=l.ownerId WHERE l.id=?",
  )
    .bind(listingId)
    .first<{ ownerId: string; status: string; suspended: number }>();
  requireThat(listing, 404, "Listing not found");
  const owner = user?.id === listing.ownerId;
  if (req.method === "GET" && !action) {
    requireThat(
      owner || (listing.status === "approved" && !listing.suspended),
      404,
      "Listing not found",
    );
    const rows = await env.DB.prepare(
      `SELECT * FROM room_scans WHERE listingId=? ${owner ? "" : "AND published=1"} ORDER BY createdAt DESC`,
    )
      .bind(listingId)
      .all<ScanRow>();
    return json({ scans: rows.results.map(view) });
  }
  requireThat(req.method === "POST", 405, "Method not allowed");
  requireThat(user, 401, "Sign in to manage room scans");
  requireThat(
    owner && !user.suspended,
    403,
    "Only the active listing owner can manage scans",
  );
  const b = await input(req);
  const active = "EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0)";
  if (action) {
    requireThat(
      action !== "visibility" || typeof b.published === "boolean",
      400,
      "Choose scan visibility",
    );
    const sql =
      action === "delete"
        ? `DELETE FROM room_scans WHERE id=? AND listingId=? AND ownerId=? AND ${active}`
        : `UPDATE room_scans SET published=? WHERE id=? AND listingId=? AND ownerId=? AND ${active}`;
    const result = await env.DB.prepare(sql)
      .bind(
        ...(action === "visibility" ? [b.published ? 1 : 0] : []),
        scanId,
        listingId,
        user.id,
        user.id,
      )
      .run();
    requireThat(
      result.meta.changes === 1,
      404,
      "Scan not found or account changed",
    );
    return json({ ok: true });
  }
  const name = text(b.name, "Room name", 80);
  let layout;
  try {
    layout = validateRoomLayout(b.layout);
  } catch (error) {
    throw new HttpError(400, (error as Error).message);
  }
  // Client UUID makes retrying after an uncertain network response safe.
  requireThat(
    typeof b.id === "string" &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        b.id,
      ),
    400,
    "Invalid scan ID",
  );
  const serialized = JSON.stringify(layout);
  const existing = await env.DB.prepare(
    "SELECT * FROM room_scans WHERE id=? AND ownerId=? AND listingId=?",
  )
    .bind(b.id, user.id, listingId)
    .first<ScanRow>();
  if (existing) {
    requireThat(
      existing.layout === serialized && existing.name === name,
      409,
      "This scan ID already contains different data",
    );
    return json({ scan: view(existing) });
  }
  await env.DB.prepare(
    `INSERT INTO room_scans SELECT ?,?,?,?,?,0,? WHERE ${active} AND (SELECT COUNT(*) FROM room_scans WHERE listingId=?)<12 ON CONFLICT(id) DO NOTHING`,
  )
    .bind(
      b.id,
      listingId,
      user.id,
      name,
      serialized,
      new Date().toISOString(),
      user.id,
      listingId,
    )
    .run();
  const saved = await env.DB.prepare(
    "SELECT * FROM room_scans WHERE id=? AND ownerId=? AND listingId=?",
  )
    .bind(b.id, user.id, listingId)
    .first<ScanRow>();
  requireThat(
    saved && saved.layout === serialized && saved.name === name,
    409,
    "Scan limit reached, scan changed, or account unavailable",
  );
  return json({ scan: view(saved) }, 201);
}
