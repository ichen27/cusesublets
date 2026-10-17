import type { User } from "../shared/types";
import {
  TOUR_LIMIT,
  validateTourResult,
  type RoomTour,
} from "../shared/room-tour";
import { HttpError, requireThat, text } from "./policy";
export type TourEnv = Pick<Cloudflare.Env, "DB" | "UPLOADS"> & {
  TOUR_PROCESSOR_TOKEN?: string;
};
type Row = Omit<RoomTour, "published" | "result"> & {
  ownerId: string;
  published: number;
  result: string | null;
  inputHash: string;
  inputSize: number;
  inputKey: string | null;
  modelKey: string | null;
  claim: string | null;
  leaseUntil: number | null;
  attempts: number;
  deleting: number;
};
const json = (v: unknown, status = 200) =>
  Response.json(v, {
    status,
    headers: {
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
const view = (r: Row): RoomTour => ({
  id: r.id,
  listingId: r.listingId,
  name: r.name,
  status: r.deleting ? "deleting" : r.status,
  published: !!r.published,
  createdAt: r.createdAt,
  result: r.result ? JSON.parse(r.result) : null,
  error: r.error,
});
const active =
  "EXISTS(SELECT 1 FROM users u JOIN listings l ON l.ownerId=u.id WHERE u.id=room_tours.ownerId AND u.suspended=0 AND l.id=room_tours.listingId)";
const uuid = (v: unknown): v is string =>
  typeof v === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
async function body(req: Request): Promise<Record<string, unknown>> {
  const reader = req.body?.getReader();
  requireThat(reader, 400, "Provide JSON");
  const pieces: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 4096) {
      await reader.cancel();
      throw new HttpError(413, "Request too large");
    }
    pieces.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of pieces) {
    bytes.set(part, offset);
    offset += part.length;
  }
  try {
    const b: unknown = JSON.parse(new TextDecoder().decode(bytes));
    requireThat(
      b && typeof b === "object" && !Array.isArray(b),
      400,
      "Provide a JSON object",
    );
    return b as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "Invalid JSON");
  }
}
async function streamUpload(
  req: Request,
  env: TourEnv,
  key: string,
  size: number,
  hash: string,
) {
  requireThat(
    req.body && Number.isInteger(size) && size > 0 && size <= TOUR_LIMIT,
    413,
    "Choose a capture under 64 MB",
  );
  requireThat(/^[a-f0-9]{64}$/.test(hash), 400, "Invalid file checksum");
  // FixedLengthStream bounds memory and rejects both truncated and oversized bodies.
  const stream = new FixedLengthStream(size);
  const pumping = req.body.pipeTo(stream.writable);
  const storing = env.UPLOADS.put(key, stream.readable, {
    sha256: hash,
    httpMetadata: { contentType: "application/octet-stream" },
  });
  const results = await Promise.allSettled([pumping, storing]);
  if (results.some((r) => r.status === "rejected")) {
    await env.UPLOADS.delete(key);
    throw new HttpError(
      400,
      "Upload length or checksum did not match. Retry the saved capture.",
    );
  }
}
async function asset(env: TourEnv, key: string, name: string) {
  const object = await env.UPLOADS.get(key);
  requireThat(object, 404, "File unavailable");
  return new Response(object.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(object.size),
      "Content-Disposition": `attachment; filename="${name}"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
export async function roomTourRoute(
  req: Request,
  env: TourEnv,
  user: User | null,
): Promise<Response | null> {
  const match = new URL(req.url).pathname.match(
    /^\/api\/listings\/([^/]+)\/tours(?:\/([^/]+)(?:\/(upload|visibility|retry|delete|model))?)?$/,
  );
  if (!match) return null;
  const [, listingId, tourId, action] = match;
  const listing = await env.DB.prepare(
    "SELECT l.ownerId,l.status,u.suspended FROM listings l JOIN users u ON u.id=l.ownerId WHERE l.id=?",
  )
    .bind(listingId)
    .first<{ ownerId: string; status: string; suspended: number }>();
  requireThat(listing, 404, "Listing not found");
  const owner = user?.id === listing.ownerId && !user.suspended;
  if (req.method === "GET") {
    requireThat(
      owner || (listing.status === "approved" && !listing.suspended),
      404,
      "Listing not found",
    );
    if (!tourId) {
      const rows = await env.DB.prepare(
        `SELECT * FROM room_tours WHERE listingId=? ${owner ? "" : "AND deleting=0 AND published=1 AND status='ready'"} ORDER BY createdAt DESC`,
      )
        .bind(listingId)
        .all<Row>();
      return json({
        tours: rows.results.map(view),
        captureEnabled: (env.TOUR_PROCESSOR_TOKEN?.length ?? 0) >= 32,
      });
    }
    const row = await env.DB.prepare(
      `SELECT * FROM room_tours WHERE id=? AND listingId=? ${owner ? "" : "AND deleting=0 AND published=1 AND status='ready'"}`,
    )
      .bind(tourId, listingId)
      .first<Row>();
    requireThat(row, 404, "Tour not found");
    if (action === "model") {
      requireThat(
        !row.deleting && row.status === "ready" && row.modelKey,
        404,
        "Tour is not ready",
      );
      return asset(env, row.modelKey, "room.ply");
    }
    requireThat(!action, 404, "Not found");
    return json({ tour: view(row) });
  }
  requireThat(req.method === "POST", 405, "Method not allowed");
  requireThat(user, 401, "Sign in to manage tours");
  requireThat(owner, 403, "Only the active listing owner can manage tours");
  if (!tourId) {
    requireThat(
      env.TOUR_PROCESSOR_TOKEN,
      503,
      "Photographic processing is not configured yet",
    );
    const b = await body(req);
    requireThat(uuid(b.id), 400, "Invalid capture ID");
    const name = text(b.name, "Room name", 80);
    requireThat(
      typeof b.sha256 === "string" && /^[a-f0-9]{64}$/.test(b.sha256),
      400,
      "Invalid capture checksum",
    );
    requireThat(
      Number.isInteger(b.size) &&
        Number(b.size) > 0 &&
        Number(b.size) <= TOUR_LIMIT,
      413,
      "Choose a capture under 64 MB",
    );
    await env.DB.prepare(
      `INSERT INTO room_tours(id,listingId,ownerId,name,status,inputHash,inputSize,createdAt) SELECT ?,?,?,?,'uploading',?,?,? WHERE EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0) AND (SELECT COUNT(*) FROM room_tours WHERE listingId=?)<6 ON CONFLICT(id) DO NOTHING`,
    )
      .bind(
        b.id,
        listingId,
        user.id,
        name,
        b.sha256,
        b.size,
        new Date().toISOString(),
        user.id,
        listingId,
      )
      .run();
    const r = await env.DB.prepare(
      "SELECT * FROM room_tours WHERE id=? AND listingId=? AND ownerId=?",
    )
      .bind(b.id, listingId, user.id)
      .first<Row>();
    requireThat(
      r && r.inputHash === b.sha256 && r.inputSize === b.size,
      409,
      "Capture changed, account unavailable, or six-tour limit reached",
    );
    return json({ tour: view(r) }, 201);
  }
  const row = await env.DB.prepare(
    "SELECT * FROM room_tours WHERE id=? AND listingId=? AND ownerId=?",
  )
    .bind(tourId, listingId, user.id)
    .first<Row>();
  requireThat(row, 404, "Tour not found");
  if (action === "upload") {
    requireThat(
      !row.deleting,
      409,
      "Tour deletion is pending; retry Delete tour",
    );
    if (row.inputKey) return json({ tour: view(row) });
    requireThat(
      row.status === "uploading",
      409,
      "Capture cannot be uploaded in this state",
    );
    const key = `tours/${row.id}/input-${crypto.randomUUID()}.roomcapture`;
    await streamUpload(req, env, key, row.inputSize, row.inputHash);
    const saved = await env.DB.prepare(
      `UPDATE room_tours SET inputKey=?,status='queued' WHERE id=? AND deleting=0 AND status='uploading' AND inputKey IS NULL AND ${active}`,
    )
      .bind(key, row.id)
      .run();
    if (saved.meta.changes !== 1) await env.UPLOADS.delete(key);
    const current = await env.DB.prepare(
      "SELECT * FROM room_tours WHERE id=? AND ownerId=?",
    )
      .bind(row.id, user.id)
      .first<Row>();
    requireThat(
      current && !current.deleting && current.inputKey,
      409,
      "Capture or account changed",
    );
    return json({ tour: view(current) });
  }
  const b = await body(req);
  if (action === "delete") {
    const deleted = await env.DB.prepare(
      `UPDATE room_tours SET deleting=1,published=0,claim=NULL,leaseUntil=NULL WHERE id=? AND ownerId=? AND ${active}`,
    )
      .bind(row.id, user.id)
      .run();
    requireThat(deleted.meta.changes === 1, 409, "Capture or account changed");
    // Keep a nonpublic tombstone until every object is gone; deletion is retryable.
    await finishTourDeletion(env.UPLOADS, `tours/${row.id}/`, async () => {
      await env.DB.prepare(
        "DELETE FROM room_tours WHERE id=? AND ownerId=? AND deleting=1",
      )
        .bind(row.id, user.id)
        .run();
    });
    return json({ ok: true });
  }
  let result: D1Result;
  if (action === "visibility") {
    requireThat(
      typeof b.published === "boolean",
      400,
      "Choose tour visibility",
    );
    result = await env.DB.prepare(
      `UPDATE room_tours SET published=? WHERE id=? AND deleting=0 AND status='ready' AND ${active}`,
    )
      .bind(b.published ? 1 : 0, row.id)
      .run();
  } else if (action === "retry") {
    requireThat(
      env.TOUR_PROCESSOR_TOKEN,
      503,
      "Photographic processing is not configured yet",
    );
    result = await env.DB.prepare(
      `UPDATE room_tours SET status='queued',error=NULL,claim=NULL,leaseUntil=NULL,attempts=0 WHERE id=? AND deleting=0 AND status='failed' AND inputKey IS NOT NULL AND ${active}`,
    )
      .bind(row.id)
      .run();
  } else throw new HttpError(404, "Not found");
  requireThat(result.meta.changes === 1, 409, "Tour state or account changed");
  return json({ ok: true });
}
async function processorAuthorized(req: Request, secret: string | undefined) {
  requireThat(
    secret && secret.length >= 32,
    503,
    "Tour processor is not configured",
  );
  const candidate =
    req.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(secret),
  );
  requireThat(
    await crypto.subtle.verify(
      "HMAC",
      key,
      signature,
      encoder.encode(candidate),
    ),
    401,
    "Processor authentication required",
  );
}
export async function tourProcessorRoute(
  req: Request,
  env: TourEnv,
): Promise<Response | null> {
  const match = new URL(req.url).pathname.match(
    /^\/api\/tour-processor\/(claim|([a-f0-9-]+)\/(input|heartbeat|complete|fail))$/i,
  );
  if (!match) return null;
  await processorAuthorized(req, env.TOUR_PROCESSOR_TOKEN);
  const [, route, id, action] = match;
  const now = Date.now();
  if (route === "claim") {
    requireThat(req.method === "POST", 405, "Method not allowed");
    await env.DB.prepare(
      "UPDATE room_tours SET status='failed',error='Processing was interrupted repeatedly. Retry when processing is available.',claim=NULL,leaseUntil=NULL WHERE status='processing' AND leaseUntil<? AND attempts>=3",
    )
      .bind(now)
      .run();
    const claim = crypto.randomUUID();
    // Single-statement claim plus fencing token prevents duplicate workers from committing a result.
    const row = await env.DB.prepare(
      `UPDATE room_tours SET status='processing',claim=?,leaseUntil=?,attempts=attempts+1,error=NULL WHERE id=(SELECT id FROM room_tours WHERE deleting=0 AND (status='queued' OR (status='processing' AND leaseUntil<?)) AND ${active} ORDER BY createdAt LIMIT 1) RETURNING *`,
    )
      .bind(claim, now + 180000, now)
      .first<Row>();
    return json({
      job: row
        ? {
            id: row.id,
            claim,
            inputSize: row.inputSize,
            inputHash: row.inputHash,
          }
        : null,
    });
  }
  const claim = req.headers.get("X-Tour-Claim");
  requireThat(uuid(claim), 400, "Invalid processing claim");
  const row = await env.DB.prepare(
    `SELECT * FROM room_tours WHERE id=? AND claim=? AND deleting=0 AND status='processing' AND leaseUntil>? AND ${active}`,
  )
    .bind(id, claim, now)
    .first<Row>();
  requireThat(row, 409, "Processing lease expired or capture unavailable");
  if (action === "input") {
    requireThat(req.method === "GET" && row.inputKey, 405, "Input unavailable");
    return asset(env, row.inputKey, "room.roomcapture");
  }
  requireThat(req.method === "POST", 405, "Method not allowed");
  const guard = `id=? AND claim=? AND deleting=0 AND status='processing' AND leaseUntil>? AND ${active}`;
  if (action === "complete") {
    let metadata;
    try {
      metadata = validateTourResult(
        JSON.parse(req.headers.get("X-Tour-Result") || "null"),
      );
    } catch {
      throw new HttpError(400, "Invalid reconstruction result");
    }
    const key = `tours/${row.id}/model-${claim}-${crypto.randomUUID()}.ply`;
    await streamUpload(
      req,
      env,
      key,
      Number(req.headers.get("X-File-Size")),
      req.headers.get("X-File-SHA256") || "",
    );
    const saved = await env.DB.prepare(
      `UPDATE room_tours SET status='ready',modelKey=?,result=?,claim=NULL,leaseUntil=NULL WHERE ${guard}`,
    )
      .bind(key, JSON.stringify(metadata), id, claim, Date.now())
      .run();
    if (saved.meta.changes !== 1) {
      await env.UPLOADS.delete(key);
      throw new HttpError(
        409,
        "Processing lease expired or capture unavailable",
      );
    }
    return json({ ok: true });
  }
  let result: D1Result;
  if (action === "heartbeat")
    result = await env.DB.prepare(
      `UPDATE room_tours SET leaseUntil=? WHERE ${guard}`,
    )
      .bind(now + 180000, id, claim, now)
      .run();
  else {
    const b = await body(req);
    const messages: Record<string, string> = {
      capture_invalid:
        "The capture did not contain enough stable views. Walk slowly around the room and try a new capture.",
      processing_failed:
        "Reconstruction failed. Retry, or capture the room again with more overlap.",
      timeout: "Processing took too long. Retry, or capture a smaller room.",
      model_too_large:
        "This tour is too large. Capture a smaller area and try again.",
    };
    const message = messages[String(b.code)] || messages.processing_failed;
    result = await env.DB.prepare(
      `UPDATE room_tours SET status='failed',error=?,claim=NULL,leaseUntil=NULL WHERE ${guard}`,
    )
      .bind(message, id, claim, now)
      .run();
  }
  requireThat(
    result.meta.changes === 1,
    409,
    "Processing lease expired or capture unavailable",
  );
  return json({ ok: true });
}

export async function finishTourDeletion(
  bucket: Pick<R2Bucket, "list" | "delete">,
  prefix: string,
  finish: () => Promise<void>,
) {
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix, cursor });
    if (page.objects.length)
      await bucket.delete(page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  await finish();
}
