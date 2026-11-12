import type { User } from "../shared/types";
import {
  TOUR_LIMIT,
  validateTourMesh,
  validateTourResult,
  type RoomTour,
} from "../shared/room-tour";
import {
  SPOT_TOUR_LIMIT,
  TOUR_KINDS,
  validateSpotTourResult,
  type SpotTourResult,
  type TourKind,
} from "../shared/spot-tour";
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
  meshKey: string | null;
  mesh: string | null;
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
  kind: r.kind,
  published: !!r.published,
  createdAt: r.createdAt,
  result: r.result ? JSON.parse(r.result) : null,
  mesh: r.status === "ready" && r.meshKey && r.mesh ? JSON.parse(r.mesh) : null,
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
  limit = TOUR_LIMIT,
) {
  requireThat(
    req.body && Number.isInteger(size) && size > 0 && size <= limit,
    413,
    limitMessage(limit),
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
const limitMessage = (limit: number) =>
  `Choose a capture under ${Math.round(limit / 1024 / 1024)} MB`;
const kindLimit = (kind: TourKind) => (kind === "spots" ? SPOT_TOUR_LIMIT : TOUR_LIMIT);
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
    /^\/api\/listings\/([^/]+)\/tours(?:\/([^/]+)(?:\/(upload|visibility|retry|delete|model|mesh|panorama\/(\d{1,2})))?)?$/,
  );
  if (!match) return null;
  const [, listingId, tourId, fullAction, panorama] = match;
  const action = panorama === undefined ? fullAction : "panorama";
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
    if (action === "mesh") {
      requireThat(
        !row.deleting && row.status === "ready" && row.meshKey,
        404,
        "Tour mesh is not available",
      );
      return asset(env, row.meshKey, "room-mesh.ply");
    }
    if (action === "panorama") {
      requireThat(
        !row.deleting && row.status === "ready" && row.kind === "spots" && row.modelKey,
        404,
        "Tour panorama is not available",
      );
      const spot = (JSON.parse(row.result || "null") as SpotTourResult | null)?.spots.find(
        (s) => s.spot === Number(panorama),
      );
      requireThat(spot, 404, "Spot not found");
      const object = await env.UPLOADS.get(row.modelKey, {
        range: { offset: spot.panorama.offset, length: spot.panorama.length },
      });
      requireThat(object, 404, "File unavailable");
      return new Response(object.body, {
        headers: {
          "Content-Type": "image/jpeg",
          "Content-Length": String(spot.panorama.length),
          "Cache-Control": "private, no-store",
          "X-Content-Type-Options": "nosniff",
        },
      });
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
    const kind = (b.kind ?? "splat") as TourKind;
    requireThat(TOUR_KINDS.includes(kind), 400, "Unknown tour kind");
    requireThat(
      Number.isInteger(b.size) &&
        Number(b.size) > 0 &&
        Number(b.size) <= kindLimit(kind),
      413,
      limitMessage(kindLimit(kind)),
    );
    await env.DB.prepare(
      `INSERT INTO room_tours(id,listingId,ownerId,name,status,inputHash,inputSize,createdAt,kind) SELECT ?,?,?,?,'uploading',?,?,?,? WHERE EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0) AND (SELECT COUNT(*) FROM room_tours WHERE listingId=?)<6 AND NOT EXISTS(SELECT 1 FROM tour_deletions WHERE id=?) ON CONFLICT(id) DO NOTHING`,
    )
      .bind(
        b.id,
        listingId,
        user.id,
        name,
        b.sha256,
        b.size,
        new Date().toISOString(),
        kind,
        user.id,
        listingId,
        b.id,
      )
      .run();
    const r = await env.DB.prepare(
      "SELECT * FROM room_tours WHERE id=? AND listingId=? AND ownerId=?",
    )
      .bind(b.id, listingId, user.id)
      .first<Row>();
    requireThat(
      r && r.inputHash === b.sha256 && r.inputSize === b.size && r.kind === kind,
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
  if (!row && action === "delete") {
    const deleted = await env.DB.prepare(
      "SELECT id FROM tour_deletions WHERE id=? AND ownerId=?",
    )
      .bind(tourId, user.id)
      .first<{ id: string }>();
    requireThat(deleted, 404, "Tour not found");
    await sweepDeletedTour(env, deleted.id);
    return json({ ok: true });
  }
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
    await streamUpload(req, env, key, row.inputSize, row.inputHash, kindLimit(row.kind));
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
    const deleted = await env.DB.batch([
      env.DB.prepare(
        `UPDATE room_tours SET deleting=1,published=0,claim=NULL,leaseUntil=NULL WHERE id=? AND ownerId=? AND ${active}`,
      ).bind(row.id, user.id),
      env.DB.prepare(
        "INSERT INTO tour_deletions(id,ownerId) SELECT id,ownerId FROM room_tours WHERE id=? AND ownerId=? AND deleting=1 ON CONFLICT(id) DO NOTHING",
      ).bind(row.id, user.id),
    ]);
    requireThat(
      deleted[0].meta.changes === 1,
      409,
      "Capture or account changed",
    );
    await sweepDeletedTour(env, row.id);
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
    /^\/api\/tour-processor\/(claim|([a-f0-9-]+)\/(input|heartbeat|mesh|complete|fail))$/i,
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
    const cleanup = await env.DB.prepare(
      "SELECT id FROM tour_deletions ORDER BY lastChecked LIMIT 5",
    ).all<{ id: string }>();
    for (const record of cleanup.results) {
      try {
        await sweepDeletedTour(env, record.id);
      } catch {
        /* Durable record remains for the next serial sweep. */
      }
      await env.DB.prepare("UPDATE tour_deletions SET lastChecked=? WHERE id=?")
        .bind(now, record.id)
        .run();
    }
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
            kind: row.kind,
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
  // Meshes are named by the claim that uploaded them; completion keeps only the current claim's.
  const meshPrefix = `tours/${row.id}/mesh-${claim}-`;
  if (action === "mesh") {
    let metadata;
    try {
      metadata = validateTourMesh(
        JSON.parse(req.headers.get("X-Tour-Result") || "null"),
      );
    } catch {
      throw new HttpError(400, "Invalid mesh result");
    }
    const key = `${meshPrefix}${crypto.randomUUID()}.ply`;
    await streamUpload(
      req,
      env,
      key,
      Number(req.headers.get("X-File-Size")),
      req.headers.get("X-File-SHA256") || "",
    );
    const saved = await env.DB.prepare(
      `UPDATE room_tours SET meshKey=?,mesh=? WHERE ${guard}`,
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
    if (row.meshKey && row.meshKey !== key)
      await env.UPLOADS.delete(row.meshKey);
    return json({ ok: true });
  }
  if (action === "complete") {
    let metadata;
    try {
      const reported: unknown = JSON.parse(req.headers.get("X-Tour-Result") || "null");
      metadata =
        row.kind === "spots"
          ? validateSpotTourResult(reported, Number(req.headers.get("X-File-Size")))
          : validateTourResult(reported);
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
    // SQLite evaluates every SET expression against the row before the update.
    const saved = await env.DB.prepare(
      `UPDATE room_tours SET status='ready',modelKey=?,result=?,claim=NULL,leaseUntil=NULL,meshKey=CASE WHEN substr(meshKey,1,?)=? THEN meshKey END,mesh=CASE WHEN substr(meshKey,1,?)=? THEN mesh END WHERE ${guard}`,
    )
      .bind(
        key,
        JSON.stringify(metadata),
        meshPrefix.length,
        meshPrefix,
        meshPrefix.length,
        meshPrefix,
        id,
        claim,
        Date.now(),
      )
      .run();
    if (saved.meta.changes !== 1) {
      await env.UPLOADS.delete(key);
      throw new HttpError(
        409,
        "Processing lease expired or capture unavailable",
      );
    }
    // A mesh left by an earlier, failed attempt no longer belongs to this tour's result.
    const current = await env.DB.prepare(
      "SELECT meshKey FROM room_tours WHERE id=?",
    )
      .bind(id)
      .first<{ meshKey: string | null }>();
    if (row.meshKey && row.meshKey !== current?.meshKey)
      await env.UPLOADS.delete(row.meshKey);
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

async function sweepDeletedTour(env: TourEnv, id: string) {
  await finishTourDeletion(env.UPLOADS, `tours/${id}/`, async () => {
    await env.DB.prepare("DELETE FROM room_tours WHERE id=? AND deleting=1")
      .bind(id)
      .run();
    // Do not delete tour_deletions: an in-flight writer can finish after this sweep.
  });
}
