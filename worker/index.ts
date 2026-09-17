import { createRemoteJWKSet, jwtVerify } from "jose";
import type {
  User,
  Listing,
  Booking,
  Offer,
  DocumentRecord,
  Report,
} from "../shared/types";
import {
  HttpError,
  requireThat,
  demoAllowed,
  text,
  number,
  dates,
  payoutBlockers,
  mediaUrl,
  syracuseDate,
} from "./policy";
type Env = Pick<Cloudflare.Env, "DB" | "UPLOADS" | "ASSETS"> & {
  APP_ENV: string;
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUD?: string;
  ADMIN_EMAILS?: string;
  APP_ORIGIN?: string;
};
type Row = Record<string, unknown>;
const json = (
  data: unknown,
  status = 200,
  headers: Record<string, string> = {},
) =>
  Response.json(data, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...headers,
    },
  });
const id = () => crypto.randomUUID();
const now = () => new Date().toISOString();
const stmt = (e: Env, sql: string, ...v: unknown[]) =>
  e.DB.prepare(sql).bind(...v);
const all = async <T>(e: Env, sql: string, ...v: unknown[]) =>
  (await stmt(e, sql, ...v).all<T>()).results;
const one = <T>(e: Env, sql: string, ...v: unknown[]) =>
  stmt(e, sql, ...v).first<T>();
const listingSQL =
  "SELECT l.*,u.name hostName,u.identity hostIdentity,u.suspended hostSuspended FROM listings l JOIN users u ON u.id=l.ownerId";
type InternalListing = Listing & { hostSuspended: boolean };
const userView = (u: User): User => ({ ...u, suspended: !!u.suspended });
function listing(row: Row): InternalListing {
  const { data, ...rest } = row;
  return {
    ...JSON.parse(data as string),
    ...rest,
    hostSuspended: !!rest.hostSuspended,
  } as InternalListing;
}
// Explicit public projection: private review reasons and future database columns stay private.
function listingView(l: Listing, viewer: User | null = null): Listing {
  const result: Listing = {
    id: l.id,
    ownerId: l.ownerId,
    title: l.title,
    neighborhood: l.neighborhood,
    address: l.address,
    lat: l.lat,
    lng: l.lng,
    price: l.price,
    beds: l.beds,
    baths: l.baths,
    roomType: l.roomType,
    startDate: l.startDate,
    endDate: l.endDate,
    description: l.description,
    amenities: l.amenities,
    images: l.images,
    videoUrl: l.videoUrl,
    matterportUrl: l.matterportUrl,
    status: l.status,
    leaseStatus: l.leaseStatus,
    permissionStatus: l.permissionStatus,
    hostName: l.hostName,
    hostIdentity: l.hostIdentity,
    walkMinutes: l.walkMinutes,
    sample: l.sample,
  };
  if (viewer && (viewer.id === l.ownerId || viewer.role === "admin"))
    result.reviewNote = l.reviewNote;
  return result;
}
const listings = async (e: Env, where: string, ...v: unknown[]) =>
  (await all<Row>(e, listingSQL + " " + where, ...v)).map(listing);
async function getListing(e: Env, key: string) {
  const l = (await listings(e, "WHERE l.id=?", key))[0];
  requireThat(l, 404, "Listing not found");
  return l;
}
async function getBooking(e: Env, key: string) {
  const b = await one<Booking>(e, "SELECT * FROM bookings WHERE id=?", key);
  requireThat(b, 404, "Booking not found");
  return decorateBooking(e, b);
}
async function decorateBooking(e: Env, b: Booking) {
  const l = await getListing(e, b.listingId);
  const normalized = {
    ...b,
    buyerSigned: !!b.buyerSigned,
    sellerSigned: !!b.sellerSigned,
    listingTitle: l.title,
  };
  const blockers = payoutBlockers(normalized, l);
  const suspended = await one(
    e,
    "SELECT id FROM users WHERE id IN (?,?) AND suspended=1 LIMIT 1",
    b.buyerId,
    b.sellerId,
  );
  if (suspended) blockers.push("Account suspension requires review");
  return {
    ...normalized,
    payoutEligible: blockers.length === 0,
    payoutBlockers: blockers,
    totalCents: Math.round(
      (b.amount * 100 * (Date.parse(b.endDate) - Date.parse(b.startDate))) /
        (30 * 86400000),
    ),
    currency: "USD",
  };
}
async function body(req: Request, limit = 32768): Promise<Row> {
  const bytes = await bounded(req, limit);
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    requireThat(
      value && typeof value === "object" && !Array.isArray(value),
      400,
      "Expected JSON object",
    );
    return value;
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw new HttpError(400, "Invalid JSON");
  }
}
async function bounded(req: Request, limit: number) {
  requireThat(
    Number(req.headers.get("content-length") || 0) <= limit,
    413,
    "Upload is too large",
  );
  const reader = req.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new HttpError(413, "Upload is too large");
    }
    chunks.push(value);
  }
  const result = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    result.set(c, at);
    at += c.length;
  }
  return result;
}
async function authenticate(
  req: Request,
  e: Env,
  demo: boolean,
): Promise<User | null> {
  if (demo) {
    const token = req.headers
      .get("Cookie")
      ?.match(/(?:^|;\s*)cuse_session=([a-f0-9-]+)/)?.[1];
    if (!token) return null;
    return one<User>(
      e,
      "SELECT u.* FROM users u JOIN sessions s ON s.userId=u.id WHERE s.token=? AND s.expires>?",
      token,
      Date.now(),
    );
  }
  const token =
    req.headers.get("Cf-Access-Jwt-Assertion") ||
    req.headers.get("Cookie")?.match(/(?:^|;\s*)CF_Authorization=([^;]+)/)?.[1];
  if (!token) return null;
  requireThat(
    e.ACCESS_TEAM_DOMAIN && e.ACCESS_AUD,
    503,
    "Authentication setup required: configure Cloudflare Access",
  );
  requireThat(
    /^[a-z0-9-]+\.cloudflareaccess\.com$/.test(e.ACCESS_TEAM_DOMAIN),
    503,
    "Authentication domain configuration invalid",
  );
  let email: string;
  let subject: string;
  try {
    const issuer = `https://${e.ACCESS_TEAM_DOMAIN}`;
    const { payload } = await jwtVerify(
      token,
      createRemoteJWKSet(new URL(issuer + "/cdn-cgi/access/certs")),
      { issuer, audience: e.ACCESS_AUD, algorithms: ["RS256"] },
    );
    requireThat(
      typeof payload.email === "string" && typeof payload.sub === "string",
      401,
      "Invalid identity",
    );
    email = payload.email.toLowerCase();
    subject = payload.sub;
  } catch {
    throw new HttpError(401, "Invalid or expired authentication");
  }
  const admin = (e.ADMIN_EMAILS || "")
    .split(",")
    .map((x) => x.trim().toLowerCase())
    .filter(Boolean)
    .includes(email);
  const uid = "access:" + subject;
  await stmt(
    e,
    "INSERT INTO users(id,name,email,role) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET email=excluded.email,role=excluded.role",
    uid,
    email.split("@")[0],
    email,
    admin ? "admin" : "member",
  ).run();
  return one<User>(e, "SELECT * FROM users WHERE id=?", uid);
}
function audit(
  e: Env,
  u: User,
  action: string,
  target: string,
  reason: string,
) {
  return stmt(
    e,
    "INSERT INTO audit VALUES(?,?,?,?,?,?)",
    id(),
    u.id,
    action,
    target,
    reason,
    now(),
  );
}
function participant(b: { buyerId: string; sellerId: string }, u: User) {
  requireThat(
    b.buyerId === u.id || b.sellerId === u.id,
    403,
    "This reservation is private",
  );
}
function reviewed(l: InternalListing) {
  requireThat(
    !l.hostSuspended &&
      l.status === "approved" &&
      l.leaseStatus === "verified" &&
      l.permissionStatus === "verified" &&
      l.hostIdentity === "verified",
    409,
    "Complete all listing and identity reviews before reserving or paying",
  );
}
export default {
  async fetch(req: Request, e: Env): Promise<Response> {
    try {
      return await route(req, e);
    } catch (err) {
      if (err instanceof HttpError)
        return json({ error: err.message }, err.status);
      const msg = err instanceof Error ? err.message : "";
      if (msg.includes("Reservation prerequisites changed"))
        return json(
          {
            error:
              "Reservation review requirements changed. Refresh and try again.",
          },
          409,
        );
      if (
        msg.includes("Booking dates overlap") ||
        msg.includes("UNIQUE constraint failed: bookings.offerId")
      )
        return json(
          { error: "These dates or this offer are already reserved" },
          409,
        );
      console.error(JSON.stringify({ event: "api_error", message: msg }));
      return json({ error: "Something went wrong. Please try again." }, 500);
    }
  },
};
async function route(req: Request, e: Env) {
  const url = new URL(req.url),
    p = url.pathname,
    m = req.method,
    demo = demoAllowed(e.APP_ENV, url.hostname);
  if (!p.startsWith("/api/")) return e.ASSETS.fetch(req);
  const preview = e.APP_ENV === "hosted-preview";
  if (
    preview &&
    !(
      m === "GET" &&
      (p === "/api/session" || /^\/api\/listings(?:\/[^/]+)?$/.test(p))
    )
  )
    throw new HttpError(
      403,
      "This private preview supports browsing only. Accounts and transactions are not enabled.",
    );
  if (!["GET", "POST"].includes(m))
    throw new HttpError(405, "Method not allowed");
  if (m === "POST") {
    const origin = req.headers.get("Origin");
    requireThat(
      origin === (demo ? url.origin : e.APP_ORIGIN || url.origin),
      403,
      "Same-origin requests required",
    );
    requireThat(
      req.headers.get("Sec-Fetch-Site") !== "cross-site",
      403,
      "Cross-site request rejected",
    );
  }
  if (p === "/api/dev/session" && m === "POST") {
    requireThat(demo, 404, "Not found");
    const b = await body(req);
    requireThat(
      ["renter", "host", "admin"].includes(String(b.role)),
      400,
      "Choose renter, host or admin",
    );
    const user = await one<User>(
      e,
      "SELECT * FROM users WHERE id=?",
      "demo-" + b.role,
    );
    requireThat(user, 503, "Apply the local demo seed first");
    const token = id();
    await stmt(e, "DELETE FROM sessions WHERE expires<?", Date.now()).run();
    await stmt(
      e,
      "INSERT INTO sessions VALUES(?,?,?)",
      token,
      user.id,
      Date.now() + 8 * 3600000,
    ).run();
    return json({ user: userView(user), demo }, 200, {
      "Set-Cookie": `cuse_session=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800`,
    });
  }
  const authenticated = preview ? null : await authenticate(req, e, demo);
  const u = authenticated ? userView(authenticated) : null;
  if (p === "/api/login" && m === "GET") {
    requireThat(
      u,
      503,
      "Google sign-in setup required: configure Cloudflare Access for /api/login",
    );
    return new Response(null, {
      status: 302,
      headers: { Location: "/#account", "Cache-Control": "no-store" },
    });
  }
  if (p === "/api/session" && m === "GET")
    return json({ user: u, demo, preview, staging: e.APP_ENV === "staging" });
  if (p === "/api/logout" && m === "POST") {
    const token = req.headers
      .get("Cookie")
      ?.match(/(?:^|;\s*)cuse_session=([a-f0-9-]+)/)?.[1];
    if (demo && token)
      await stmt(e, "DELETE FROM sessions WHERE token=?", token).run();
    return json({ ok: true }, 200, {
      "Set-Cookie":
        "cuse_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0",
    });
  }
  if (p === "/api/listings" && m === "GET")
    return json({
      listings: (
        await listings(
          e,
          "WHERE l.status='approved' AND u.suspended=0 ORDER BY l.rowid LIMIT 200",
        )
      ).map((l) => listingView(l)),
    });
  const listingMatch = p.match(/^\/api\/listings\/([^/]+)$/);
  if (listingMatch && m === "GET") {
    const l = await getListing(e, listingMatch[1]);
    requireThat(
      (l.status === "approved" && !l.hostSuspended) ||
        l.ownerId === u?.id ||
        u?.role === "admin",
      404,
      "Listing not found",
    );
    return json({ listing: listingView(l, u) });
  }
  const mediaMatch = p.match(/^\/api\/media\/([^/]+)$/);
  if (mediaMatch && m === "GET") {
    const doc = await one<DocumentRecord & { objectKey: string; type: string }>(
      e,
      "SELECT * FROM documents WHERE id=? AND kind IN ('image','video')",
      mediaMatch[1],
    );
    requireThat(doc, 404, "Media not found");
    const l = await getListing(e, doc.listingId);
    requireThat(
      (l.status === "approved" && !l.hostSuspended) ||
        l.ownerId === u?.id ||
        u?.role === "admin",
      404,
      "Media not found",
    );
    const object = await e.UPLOADS.get(doc.objectKey);
    requireThat(object, 404, "Media not found");
    return new Response(object.body, {
      headers: {
        "Content-Type": doc.type,
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
      },
    });
  }
  requireThat(u, 401, "Sign in to continue");
  if (
    m === "POST" &&
    u.suspended &&
    !/^\/api\/bookings\/[^/]+\/action$/.test(p)
  )
    throw new HttpError(
      403,
      "Your account is suspended. Existing reservations and disputes remain accessible.",
    );
  if (p.startsWith("/api/admin"))
    requireThat(u.role === "admin", 403, "Admin access required");
  if (p === "/api/profile" && m === "POST") {
    const b = await body(req);
    await stmt(
      e,
      "UPDATE users SET name=? WHERE id=?",
      text(b.name, "Name", 80),
      u.id,
    ).run();
    return json({
      user: userView(
        (await one<User>(e, "SELECT * FROM users WHERE id=?", u.id))!,
      ),
    });
  }
  if (p === "/api/mine" && m === "GET")
    return json({
      listings: await listings(e, "WHERE l.ownerId=?", u.id),
      documents: await all(
        e,
        "SELECT d.id,d.listingId,d.name,d.kind,d.createdAt FROM documents d JOIN listings l ON l.id=d.listingId WHERE l.ownerId=?",
        u.id,
      ),
    });
  if (p === "/api/listings" && m === "POST") {
    const b = await body(req);
    const interval = dates(b.startDate, b.endDate);
    requireThat(
      interval.endDate > syracuseDate(),
      400,
      "Availability must end in the future",
    );
    requireThat(
      ["Private room", "Entire place"].includes(String(b.roomType)),
      400,
      "Select a room type",
    );
    const amenities = b.amenities ?? [];
    requireThat(
      Array.isArray(amenities) && amenities.length <= 20,
      400,
      "Use up to 20 amenities",
    );
    const images = b.images ?? [];
    requireThat(
      Array.isArray(images) && images.length <= 12,
      400,
      "Use up to 12 photos",
    );
    const data = {
      title: text(b.title, "Title", 100),
      neighborhood: text(b.neighborhood, "Neighborhood", 80),
      address: text(b.address, "Approximate location", 160),
      lat:
        Math.round(number(b.lat ?? 43.037, "Latitude", 42.9, 43.15) * 1000) /
        1000,
      lng:
        Math.round(
          number(b.lng ?? -76.127, "Longitude", -76.3, -75.95) * 1000,
        ) / 1000,
      price: number(b.price, "Monthly rent", 1, 20000),
      beds: number(b.beds, "Beds", 1, 20),
      baths: number(b.baths, "Baths", 0.5, 20),
      roomType: b.roomType,
      ...interval,
      description: text(b.description, "Description", 4000, 20),
      amenities: amenities.map((a) => text(a, "Amenity", 50)),
      images: images.map((i) => mediaUrl(i)),
      videoUrl: mediaUrl(b.videoUrl),
      matterportUrl: mediaUrl(b.matterportUrl, true),
      walkMinutes: number(b.walkMinutes ?? 10, "Walk minutes", 1, 120),
      sample: demo,
    };
    const key = id();
    await stmt(
      e,
      "INSERT INTO listings(id,ownerId,data) VALUES(?,?,?)",
      key,
      u.id,
      JSON.stringify(data),
    ).run();
    return json({ listing: await getListing(e, key) }, 201);
  }
  if (p === "/api/messages" && m === "GET") {
    const messages = await all(
      e,
      "SELECT * FROM messages WHERE senderId=? OR recipientId=? ORDER BY createdAt LIMIT 500",
      u.id,
      u.id,
    );
    return json({
      messages,
      listings: (
        await listings(
          e,
          "WHERE l.id IN (SELECT listingId FROM messages WHERE senderId=? OR recipientId=?)",
          u.id,
          u.id,
        )
      ).map((l) => listingView(l, u)),
    });
  }
  if (p === "/api/messages" && m === "POST") {
    const b = await body(req);
    const l = await getListing(e, text(b.listingId, "Listing", 80));
    let recipient = l.ownerId;
    if (u.id === l.ownerId) {
      recipient = text(b.recipientId, "Recipient", 100);
      requireThat(
        await one(
          e,
          "SELECT id FROM messages WHERE listingId=? AND senderId=? AND recipientId=? LIMIT 1",
          l.id,
          recipient,
          u.id,
        ),
        403,
        "Reply to an existing conversation",
      );
    } else
      requireThat(
        l.status === "approved" && !l.hostSuspended,
        404,
        "Listing not found",
      );
    requireThat(recipient !== u.id, 400, "You cannot message yourself");
    const message = {
      id: id(),
      listingId: l.id,
      senderId: u.id,
      recipientId: recipient,
      body: text(b.body, "Message", 2000),
      createdAt: now(),
    };
    await stmt(
      e,
      "INSERT INTO messages VALUES(?,?,?,?,?,?)",
      ...Object.values(message),
    ).run();
    return json({ message }, 201);
  }
  if (p === "/api/offers" && m === "GET")
    return json({
      offers: await all(
        e,
        "SELECT o.*,u.name buyerName,json_extract(l.data,'$.title') listingTitle FROM offers o JOIN users u ON u.id=o.buyerId JOIN listings l ON l.id=o.listingId WHERE buyerId=? OR sellerId=? ORDER BY o.rowid DESC LIMIT 200",
        u.id,
        u.id,
      ),
    });
  if (p === "/api/offers" && m === "POST") {
    const b = await body(req),
      l = await getListing(e, text(b.listingId, "Listing", 80));
    requireThat(
      l.status === "approved" && !l.hostSuspended,
      404,
      "Listing not found",
    );
    requireThat(
      l.ownerId !== u.id,
      400,
      "You cannot offer on your own listing",
    );
    const interval = dates(b.startDate, b.endDate);
    requireThat(
      interval.startDate >= l.startDate && interval.endDate <= l.endDate,
      400,
      "Dates must fit current listing availability",
    );
    requireThat(
      interval.startDate >= syracuseDate(),
      400,
      "Start date cannot be in the past (Syracuse time)",
    );
    const offer = {
      id: id(),
      listingId: l.id,
      buyerId: u.id,
      sellerId: l.ownerId,
      amount: Math.round(number(b.amount, "Amount", 1, 20000) * 100) / 100,
      ...interval,
      status: "pending",
    };
    await stmt(
      e,
      "INSERT INTO offers VALUES(?,?,?,?,?,?,?,?)",
      ...Object.values(offer),
    ).run();
    return json({ offer }, 201);
  }
  const accept = p.match(/^\/api\/offers\/([^/]+)\/accept$/);
  if (accept && m === "POST") {
    const o = await one<Offer>(e, "SELECT * FROM offers WHERE id=?", accept[1]);
    requireThat(o, 404, "Offer not found");
    requireThat(
      o.sellerId === u.id && o.buyerId !== u.id,
      403,
      "Only the listing owner can accept this offer",
    );
    requireThat(o.status === "pending", 409, "This offer is no longer pending");
    const l = await getListing(e, o.listingId);
    reviewed(l);
    requireThat(
      o.startDate >= syracuseDate(),
      409,
      "Offer start date has passed",
    );
    const key = id();
    await e.DB.batch([
      stmt(
        e,
        "INSERT INTO bookings(id,offerId,listingId,buyerId,sellerId,amount,startDate,endDate,createdAt) SELECT ?,id,listingId,buyerId,sellerId,amount,startDate,endDate,? FROM offers WHERE id=? AND status='pending'",
        key,
        now(),
        o.id,
      ),
      stmt(e, "UPDATE offers SET status='accepted' WHERE id=?", o.id),
    ]);
    return json({ booking: await getBooking(e, key) }, 201);
  }
  if (p === "/api/bookings" && m === "GET") {
    const rows = await all<Booking>(
      e,
      "SELECT * FROM bookings WHERE buyerId=? OR sellerId=? ORDER BY rowid DESC LIMIT 200",
      u.id,
      u.id,
    );
    return json({
      bookings: await Promise.all(rows.map((b) => decorateBooking(e, b))),
    });
  }
  const action = p.match(/^\/api\/bookings\/([^/]+)\/action$/);
  if (action && m === "POST") {
    const b = await body(req),
      booking = await getBooking(e, action[1]);
    participant(booking, u);
    const a = b.action;
    requireThat(
      !u.suspended || a === "dispute",
      403,
      "Suspended accounts can read existing reservations and open disputes only",
    );
    requireThat(
      ["sign", "pay", "confirm-move-in", "dispute"].includes(String(a)),
      400,
      "Unknown reservation action",
    );
    if (a === "sign") {
      requireThat(
        demo,
        503,
        "Live signing setup required. Demo acknowledgments are not legal signatures.",
      );
      const field = u.id === booking.buyerId ? "buyerSigned" : "sellerSigned";
      await stmt(
        e,
        `UPDATE bookings SET ${field}=1 WHERE id=?`,
        booking.id,
      ).run();
    }
    if (a === "pay") {
      requireThat(u.id === booking.buyerId, 403, "Only the renter can pay");
      requireThat(
        demo,
        503,
        "Live payments setup required. No charge was made.",
      );
      reviewed(await getListing(e, booking.listingId));
      requireThat(
        booking.buyerSigned && booking.sellerSigned,
        409,
        "Both parties must acknowledge the demo agreement first",
      );
      requireThat(
        booking.disputeStatus !== "open",
        409,
        "Resolve the dispute before payment",
      );
      await stmt(
        e,
        "UPDATE bookings SET paymentStatus='demo_paid',status='confirmed' WHERE id=? AND paymentStatus='unpaid' AND disputeStatus<>'open'",
        booking.id,
      ).run();
    }
    if (a === "confirm-move-in") {
      requireThat(
        u.id === booking.buyerId,
        403,
        "Only the renter confirms move-in",
      );
      requireThat(
        booking.paymentStatus === "demo_paid",
        409,
        "Payment is required first",
      );
      requireThat(
        syracuseDate() >= booking.startDate,
        409,
        "Move-in confirmation opens on your start date",
      );
      await stmt(
        e,
        "UPDATE bookings SET moveInAt=COALESCE(moveInAt,?),status='moved_in' WHERE id=?",
        now(),
        booking.id,
      ).run();
    }
    if (a === "dispute") {
      requireThat(
        u.id === booking.buyerId,
        403,
        "Only the renter can open a dispute",
      );
      await stmt(
        e,
        "UPDATE bookings SET disputeStatus='open',disputeReason=? WHERE id=?",
        text(b.reason, "Dispute reason", 2000, 10),
        booking.id,
      ).run();
    }
    return json({ booking: await getBooking(e, booking.id) });
  }
  const upload = p.match(/^\/api\/listings\/([^/]+)\/(documents|media)$/);
  if (upload && m === "POST") {
    const l = await getListing(e, upload[1]);
    requireThat(l.ownerId === u.id, 403, "Only the owner can upload");
    const isMedia = upload[2] === "media",
      bytes = await bounded(req, (isMedia ? 26 : 6) * 1024 * 1024);
    const form = await new Request(req.url, {
      method: "POST",
      headers: { "Content-Type": req.headers.get("Content-Type") || "" },
      body: bytes,
    }).formData();
    const file = form.get("file");
    requireThat(file instanceof File, 400, "Choose a file");
    const kind = isMedia
      ? file.type.startsWith("video/")
        ? "video"
        : "image"
      : form.get("kind");
    requireThat(
      isMedia || ["lease", "permission"].includes(String(kind)),
      400,
      "Upload lease or permission only. Raw identity documents are not accepted",
    );
    const types = isMedia
      ? ["image/jpeg", "image/png", "image/webp", "video/mp4", "video/webm"]
      : ["application/pdf", "image/jpeg", "image/png"];
    requireThat(types.includes(file.type), 400, "Unsupported file format");
    requireThat(
      file.size > 0 && file.size <= (kind === "video" ? 25 : 5) * 1024 * 1024,
      413,
      "File exceeds size limit",
    );
    const count = await one<{ n: number }>(
      e,
      "SELECT COUNT(*) n FROM documents WHERE listingId=?",
      l.id,
    );
    requireThat((count?.n || 0) < 30, 400, "Maximum 30 uploads per listing");
    const key = id(),
      objectKey = `${l.id}/${key}`;
    await e.UPLOADS.put(objectKey, file.stream(), {
      httpMetadata: { contentType: file.type },
    });
    const document = {
      id: key,
      listingId: l.id,
      name:
        file.name.replace(/[^a-zA-Z0-9._ -]/g, "").slice(0, 120) || "document",
      kind,
      createdAt: now(),
    };
    const insertDocument = stmt(
      e,
      "INSERT INTO documents VALUES(?,?,?,?,?,?,?)",
      key,
      l.id,
      document.name,
      kind,
      objectKey,
      file.type,
      document.createdAt,
    );
    if (!isMedia) {
      // Metadata and verification invalidation commit together. The other evidence
      // type retains its result until its own replacement is submitted.
      const reviewColumn =
        kind === "lease" ? "leaseStatus" : "permissionStatus";
      await e.DB.batch([
        insertDocument,
        stmt(
          e,
          `UPDATE listings SET ${reviewColumn}='pending',status='pending',reviewNote=NULL WHERE id=?`,
          l.id,
        ),
      ]);
      return json({ document }, 201);
    }
    await insertDocument.run();
    if (isMedia) {
      const media = "/api/media/" + key;
      const data = await one<{ data: string }>(
        e,
        "SELECT data FROM listings WHERE id=?",
        l.id,
      );
      const value = JSON.parse(data!.data);
      if (kind === "video") value.videoUrl = media;
      else value.images = [...value.images, media].slice(-12);
      await stmt(
        e,
        "UPDATE listings SET data=?,status='pending',reviewNote=NULL WHERE id=?",
        JSON.stringify(value),
        l.id,
      ).run();
      return json({ url: media, listing: await getListing(e, l.id) }, 201);
    }
    return json({ document }, 201);
  }
  const document = p.match(/^\/api\/documents\/([^/]+)$/);
  if (document && m === "GET") {
    const d = await one<DocumentRecord & { objectKey: string; type: string }>(
      e,
      "SELECT * FROM documents WHERE id=?",
      document[1],
    );
    requireThat(d, 404, "Document not found");
    const l = await getListing(e, d.listingId);
    requireThat(
      l.ownerId === u.id || u.role === "admin",
      403,
      "This document is private",
    );
    const object = await e.UPLOADS.get(d.objectKey);
    requireThat(object, 404, "Document not found");
    return new Response(object.body, {
      headers: {
        "Content-Type": d.type,
        "Content-Disposition": `attachment; filename="${d.name}"`,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; sandbox",
      },
    });
  }
  if (p === "/api/admin" && m === "GET")
    return json({
      listings: await listings(e, "ORDER BY l.rowid DESC LIMIT 200"),
      users: (await all<User>(e, "SELECT * FROM users LIMIT 200")).map(
        userView,
      ),
      reports: await all<Report>(
        e,
        "SELECT * FROM reports ORDER BY rowid DESC LIMIT 200",
      ),
      documents: await all(
        e,
        "SELECT id,listingId,name,kind,createdAt FROM documents LIMIT 500",
      ),
      bookings: await all(e, "SELECT * FROM bookings LIMIT 200"),
      audit: await all(e, "SELECT * FROM audit ORDER BY rowid DESC LIMIT 200"),
    });
  const reportListing = p.match(/^\/api\/listings\/([^/]+)\/report$/);
  if (reportListing && m === "POST") {
    const b = await body(req),
      l = await getListing(e, reportListing[1]);
    requireThat(l.ownerId !== u.id, 400, "You cannot report your own listing");
    const ownBooking = await one(
      e,
      "SELECT id FROM bookings WHERE listingId=? AND buyerId=? LIMIT 1",
      l.id,
      u.id,
    );
    requireThat(
      (l.status === "approved" && !l.hostSuspended) || ownBooking,
      404,
      "Listing not found",
    );
    const reason = text(b.reason, "Report reason", 2000, 10);
    requireThat(
      !(await one(
        e,
        "SELECT id FROM reports WHERE listingId=? AND reporterId=? AND status='open'",
        l.id,
        u.id,
      )),
      409,
      "You already have an open report for this listing",
    );
    const report: Report = {
      id: id(),
      listingId: l.id,
      reporterId: u.id,
      reason,
      status: "open",
      createdAt: now(),
    };
    await e.DB.batch([
      stmt(
        e,
        "INSERT INTO reports VALUES(?,?,?,?,?,?)",
        ...Object.values(report),
      ),
      audit(e, u, "listing.report", report.id, reason),
    ]);
    return json({ report }, 201);
  }
  const userStatus = p.match(/^\/api\/admin\/users\/([^/]+)\/status$/);
  if (userStatus && m === "POST") {
    const b = await body(req),
      target = await one<User>(
        e,
        "SELECT * FROM users WHERE id=?",
        userStatus[1],
      );
    requireThat(target, 404, "User not found");
    requireThat(
      typeof b.suspended === "boolean",
      400,
      "Suspended must be true or false",
    );
    requireThat(
      target.id !== u.id && target.role !== "admin",
      403,
      "Admins cannot change their own or another admin suspension",
    );
    const reason = text(b.reason, "Status reason", 2000, 5);
    await e.DB.batch([
      stmt(
        e,
        "UPDATE users SET suspended=? WHERE id=? AND role<>'admin'",
        b.suspended ? 1 : 0,
        target.id,
      ),
      audit(
        e,
        u,
        b.suspended ? "user.suspend" : "user.restore",
        target.id,
        reason,
      ),
    ]);
    return json({
      user: userView(
        (await one<User>(e, "SELECT * FROM users WHERE id=?", target.id))!,
      ),
    });
  }
  const resolveReport = p.match(/^\/api\/admin\/reports\/([^/]+)\/resolve$/);
  if (resolveReport && m === "POST") {
    const b = await body(req),
      report = await one<Report>(
        e,
        "SELECT * FROM reports WHERE id=?",
        resolveReport[1],
      );
    requireThat(report, 404, "Report not found");
    requireThat(report.status === "open", 409, "Report is already resolved");
    const reason = text(b.reason, "Resolution reason", 2000, 10);
    await e.DB.batch([
      stmt(e, "UPDATE reports SET status='resolved' WHERE id=?", report.id),
      audit(e, u, "report.resolve", report.id, reason),
    ]);
    return json({
      report: await one<Report>(
        e,
        "SELECT * FROM reports WHERE id=?",
        report.id,
      ),
    });
  }
  const review = p.match(/^\/api\/admin\/listings\/([^/]+)\/review$/);
  if (review && m === "POST") {
    const b = await body(req),
      l = await getListing(e, review[1]);
    const reason = text(b.reason, "Review reason", 2000, 5);
    requireThat(
      ["approved", "needs_info", "rejected", "paused"].includes(
        String(b.status),
      ),
      400,
      "Invalid listing status",
    );
    for (const k of ["leaseStatus", "permissionStatus"])
      requireThat(
        ["pending", "verified", "needs_info", "rejected"].includes(
          String(b[k]),
        ),
        400,
        "Invalid review result",
      );
    if (b.status === "approved")
      requireThat(
        b.leaseStatus === "verified" && b.permissionStatus === "verified",
        400,
        "Lease and landlord permission must be reviewed before approval",
      );
    await e.DB.batch([
      stmt(
        e,
        "UPDATE listings SET status=?,leaseStatus=?,permissionStatus=?,reviewNote=? WHERE id=?",
        b.status,
        b.leaseStatus,
        b.permissionStatus,
        reason,
        l.id,
      ),
      audit(e, u, "listing.review", l.id, reason),
    ]);
    return json({ listing: await getListing(e, l.id) });
  }
  const identity = p.match(/^\/api\/admin\/users\/([^/]+)\/review$/);
  if (identity && m === "POST") {
    const b = await body(req),
      reason = text(b.reason, "Review reason", 2000, 5);
    requireThat(
      await one(e, "SELECT id FROM users WHERE id=?", identity[1]),
      404,
      "User not found",
    );
    requireThat(
      ["verified", "needs_info", "rejected"].includes(String(b.identity)),
      400,
      "Invalid identity review",
    );
    await e.DB.batch([
      stmt(
        e,
        "UPDATE users SET identity=? WHERE id=?",
        b.identity,
        identity[1],
      ),
      audit(e, u, "identity.review", identity[1], reason),
    ]);
    return json({
      user: userView(
        (await one<User>(e, "SELECT * FROM users WHERE id=?", identity[1]))!,
      ),
    });
  }
  const resolve = p.match(/^\/api\/admin\/bookings\/([^/]+)\/resolve$/);
  if (resolve && m === "POST") {
    const b = await body(req),
      booking = await getBooking(e, resolve[1]);
    requireThat(
      booking.disputeStatus === "open",
      409,
      "There is no open dispute",
    );
    const reason = text(b.reason, "Resolution reason", 2000, 10);
    await e.DB.batch([
      stmt(
        e,
        "UPDATE bookings SET disputeStatus='resolved' WHERE id=?",
        booking.id,
      ),
      audit(e, u, "dispute.resolve", booking.id, reason),
    ]);
    return json({ booking: await getBooking(e, booking.id) });
  }
  throw new HttpError(404, "Endpoint not found");
}
