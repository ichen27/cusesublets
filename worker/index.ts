import { createRemoteJWKSet, jwtVerify } from "jose";
import type {
  User,
  Listing,
  Booking,
  Offer,
  DocumentRecord,
  Report,
  Conversation,
  ConversationSummary,
  ChatAttachment,
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
const userView = (u: User): User => ({
  id: u.id,
  name: u.name,
  email: u.email,
  role: u.role,
  identity: u.identity,
  avatar: u.avatar,
  suspended: !!u.suspended,
});
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

const conversationSQL = `SELECT c.*, json_extract(l.data,'$.title') listingTitle,
 COALESCE(json_extract(l.data,'$.images[0]'),'') listingImage,peer.name peerName,
 COALESCE((SELECT body FROM messages m WHERE m.listingId=c.listingId AND
 ((m.senderId=c.buyerId AND m.recipientId=c.sellerId) OR (m.senderId=c.sellerId AND m.recipientId=c.buyerId))
 ORDER BY m.createdAt DESC,m.rowid DESC LIMIT 1),'') lastMessage
 FROM conversations c JOIN listings l ON l.id=c.listingId
 JOIN users peer ON peer.id=CASE WHEN c.buyerId=? THEN c.sellerId ELSE c.buyerId END`;
async function getConversation(e: Env, key: string, u: User) {
  const c = await one<ConversationSummary>(
    e,
    conversationSQL + " WHERE c.id=?",
    u.id,
    key,
  );
  requireThat(c, 404, "Conversation not found");
  participant(c, u);
  return c;
}
async function openConversation(e: Env, l: InternalListing, u: User) {
  requireThat(
    l.ownerId !== u.id,
    400,
    "Open a renter conversation from your inbox",
  );
  const existing = await one<Conversation>(
    e,
    "SELECT * FROM conversations WHERE listingId=? AND buyerId=?",
    l.id,
    u.id,
  );
  if (existing) return getConversation(e, existing.id, u);
  requireThat(
    l.status === "approved" && !l.hostSuspended,
    404,
    "Listing not found",
  );
  const at = now();
  await stmt(
    e,
    "INSERT INTO conversations(id,listingId,buyerId,sellerId,createdAt,updatedAt) VALUES(?,?,?,?,?,?) ON CONFLICT(listingId,buyerId) DO NOTHING",
    id(),
    l.id,
    u.id,
    l.ownerId,
    at,
    at,
  ).run();
  const c = await one<Conversation>(
    e,
    "SELECT * FROM conversations WHERE listingId=? AND buyerId=?",
    l.id,
    u.id,
  );
  return getConversation(e, c!.id, u);
}
async function activeParticipants(e: Env, c: Conversation) {
  requireThat(
    !(await one(
      e,
      "SELECT id FROM users WHERE id IN (?,?) AND suspended=1",
      c.buyerId,
      c.sellerId,
    )),
    409,
    "Conversation participant is suspended",
  );
}
function chatEvent(
  e: Env,
  c: Conversation,
  u: User,
  kind: string,
  description: string,
  offerId: string | null = null,
) {
  return stmt(
    e,
    "INSERT INTO chat_events(id,conversationId,actorId,kind,body,offerId,createdAt) VALUES(?,?,?,?,?,?,?)",
    id(),
    c.id,
    u.id,
    kind,
    description,
    offerId,
    now(),
  );
}
async function sendMessage(e: Env, c: Conversation, u: User, b: Row) {
  await activeParticipants(e, c);
  const message = {
    id: id(),
    conversationId: c.id,
    listingId: c.listingId,
    senderId: u.id,
    recipientId: u.id === c.buyerId ? c.sellerId : c.buyerId,
    body: text(b.body, "Message", 2000),
    createdAt: now(),
  };
  await stmt(
    e,
    "INSERT INTO messages(id,listingId,senderId,recipientId,body,createdAt) VALUES(?,?,?,?,?,?)",
    message.id,
    message.listingId,
    message.senderId,
    message.recipientId,
    message.body,
    message.createdAt,
  ).run();
  return message;
}
async function createProposal(e: Env, c: Conversation, u: User, b: Row) {
  await activeParticipants(e, c);
  const l = await getListing(e, c.listingId);
  requireThat(
    l.status === "approved" && !l.hostSuspended && l.ownerId === c.sellerId,
    409,
    "Listing is not currently available",
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
  const kind = b.kind ?? "offer";
  requireThat(
    kind === "offer" || kind === "request",
    400,
    "Choose offer or request",
  );
  const parentOfferId = b.parentOfferId
    ? text(b.parentOfferId, "Parent offer", 100)
    : null;
  if (parentOfferId) {
    const parent = await one<Offer>(
      e,
      "SELECT * FROM offers WHERE id=? AND conversationId=?",
      parentOfferId,
      c.id,
    );
    requireThat(parent, 404, "Parent offer not found");
    requireThat(
      parent.proposedBy !== u.id,
      403,
      "Only the other participant can counter a proposal",
    );
    requireThat(
      parent.status === "pending",
      409,
      "This proposal is no longer pending",
    );
  }
  const offer = {
    id: id(),
    conversationId: c.id,
    listingId: c.listingId,
    buyerId: c.buyerId,
    sellerId: c.sellerId,
    proposedBy: u.id,
    parentOfferId,
    createdAt: now(),
    kind,
    amount: Math.round(number(b.amount, "Amount", 1, 20000) * 100) / 100,
    ...interval,
    status: "pending",
  };
  await e.DB.batch([
    stmt(
      e,
      "INSERT INTO offers(id,listingId,buyerId,sellerId,amount,startDate,endDate,status,conversationId,proposedBy,parentOfferId,createdAt,kind) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
      offer.id,
      offer.listingId,
      offer.buyerId,
      offer.sellerId,
      offer.amount,
      offer.startDate,
      offer.endDate,
      offer.status,
      offer.conversationId,
      offer.proposedBy,
      offer.parentOfferId,
      offer.createdAt,
      offer.kind,
    ),
    chatEvent(
      e,
      c,
      u,
      parentOfferId ? "counteroffer" : kind,
      parentOfferId
        ? "Counteroffer sent"
        : kind === "request"
          ? "Date request sent"
          : "Offer sent",
      offer.id,
    ),
  ]);
  return offer;
}
function validDocumentBytes(type: string, bytes: Uint8Array) {
  const prefix = (p: number[]) => p.every((v, i) => bytes[i] === v);
  if (type === "application/pdf") return prefix([37, 80, 68, 70, 45]);
  if (type === "image/jpeg") return prefix([255, 216, 255]);
  if (type === "image/png") return prefix([137, 80, 78, 71, 13, 10, 26, 10]);
  return false;
}

type ProfileRow = User & {
  bio: string;
  phone: string;
  socials: string;
  identityNote?: string;
  nameVersion: number;
  joinedAt?: string;
};
async function identityDocs(e: Env, userId: string) {
  return all<{ id: string; name: string; type: string; createdAt: string }>(
    e,
    "SELECT d.id,d.name,d.type,d.createdAt FROM identity_documents d JOIN users u ON u.id=d.userId WHERE d.userId=? AND d.nameVersion=u.nameVersion ORDER BY d.rowid DESC",
    userId,
  );
}
async function profileData(e: Env, u: ProfileRow) {
  const photos = await all<{ id: string }>(
    e,
    "SELECT id FROM profile_media WHERE userId=? AND kind='photo' ORDER BY rowid",
    u.id,
  );
  return {
    bio: u.bio,
    phone: u.phone,
    socials: JSON.parse(u.socials),
    avatar: u.avatar || undefined,
    photos: photos.map((x) => "/api/profile-media/" + x.id),
  };
}
async function account(e: Env, u: User) {
  const current = (await one<ProfileRow>(
    e,
    "SELECT * FROM users WHERE id=?",
    u.id,
  ))!;
  return {
    user: userView(current),
    profile: await profileData(e, current),
    identityDocuments: await identityDocs(e, u.id),
    identityNote: current.identityNote,
  };
}
async function reviewable(e: Env, u: User, target: string) {
  if (u.id === target || u.suspended) return [];
  return all<{ id: string; listingTitle: string; endDate: string }>(
    e,
    "SELECT b.id,json_extract(l.data,'$.title') listingTitle,b.endDate FROM bookings b JOIN listings l ON l.id=b.listingId JOIN users t ON t.id=? WHERE ((b.buyerId=? AND b.sellerId=?) OR (b.sellerId=? AND b.buyerId=?)) AND b.paymentStatus IN ('paid',?) AND b.moveInAt IS NOT NULL AND b.endDate<? AND b.status<>'cancelled' AND b.disputeStatus<>'open' AND t.suspended=0 AND NOT EXISTS(SELECT 1 FROM profile_reviews r WHERE r.bookingId=b.id AND r.authorId=?)",
    target,
    u.id,
    target,
    u.id,
    target,
    e.APP_ENV === "development" ? "demo_paid" : "paid",
    syracuseDate(),
    u.id,
  );
}
function socialLinks(value: unknown) {
  requireThat(
    value && typeof value === "object" && !Array.isArray(value),
    400,
    "Social links must be an object",
  );
  const out: Record<string, string> = {};
  for (const key of ["instagram", "facebook", "linkedin", "website"]) {
    const raw = (value as Row)[key];
    if (raw === undefined || raw === "") continue;
    const link = text(raw, "Social link", 500);
    let url: URL;
    try {
      url = new URL(link);
    } catch {
      throw new HttpError(400, "Use full https social links");
    }
    requireThat(
      url.protocol === "https:" && !url.username && !url.password,
      400,
      "Use full https social links",
    );
    out[key] = url.href;
  }
  return out;
}
async function uploadForm(req: Request) {
  const bytes = await bounded(req, 6 * 1024 * 1024);
  return new Request(req.url, {
    method: "POST",
    headers: { "Content-Type": req.headers.get("Content-Type") || "" },
    body: bytes,
  }).formData();
}
export default {
  async fetch(req: Request, e: Env): Promise<Response> {
    try {
      return await route(req, e);
    } catch (err) {
      if (err instanceof HttpError)
        return json({ error: err.message }, err.status);
      const msg = err instanceof Error ? err.message : "";
      if (
        msg.includes("Review prerequisites changed") ||
        msg.includes("UNIQUE constraint failed: profile_reviews") ||
        msg.includes("Reservation prerequisites changed") ||
        msg.includes("Proposal prerequisites changed") ||
        msg.includes("Conversation participants changed")
      )
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
  const publicMedia = p.match(/^\/api\/profile-media\/([^/]+)$/);
  if (publicMedia && m === "GET") {
    const d = await one<{ type: string; objectKey: string }>(
      e,
      "SELECT m.* FROM profile_media m JOIN users u ON u.id=m.userId WHERE m.id=? AND u.suspended=0",
      publicMedia[1],
    );
    requireThat(d, 404, "Photo not found");
    const object = await e.UPLOADS.get(d.objectKey);
    requireThat(object, 404, "Photo not found");
    return new Response(object.body, {
      headers: {
        "Content-Type": d.type,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      },
    });
  }
  const publicUser = p.match(/^\/api\/users\/([^/]+)$/);
  if (publicUser && m === "GET") {
    const target = await one<ProfileRow>(
      e,
      "SELECT * FROM users WHERE id=? AND suspended=0",
      publicUser[1],
    );
    requireThat(target, 404, "Profile not found");
    const profile = await profileData(e, target);
    return json({
      profile: {
        id: target.id,
        name: target.name,
        identity: target.identity,
        bio: profile.bio,
        avatar: profile.avatar,
        photos: profile.photos,
        socials: profile.socials,
        joinedAt: target.joinedAt || undefined,
      },
      listings: (
        await listings(
          e,
          "WHERE l.ownerId=? AND l.status='approved'",
          target.id,
        )
      ).map((l) => listingView(l)),
      reviews: await all(
        e,
        "SELECT r.id,r.authorId,a.name authorName,r.rating,r.body,r.createdAt,json_extract(l.data,'$.title') listingTitle FROM profile_reviews r JOIN users a ON a.id=r.authorId JOIN bookings b ON b.id=r.bookingId JOIN listings l ON l.id=b.listingId WHERE r.targetId=? ORDER BY r.rowid DESC LIMIT 200",
        target.id,
      ),
      reviewableBookings: u ? await reviewable(e, u, target.id) : [],
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
  if (p === "/api/profile" && m === "GET") return json(await account(e, u));
  if (p === "/api/profile" && m === "POST") {
    const b = await body(req),
      old = await one<ProfileRow>(e, "SELECT * FROM users WHERE id=?", u.id);
    const name = b.name === undefined ? u.name : text(b.name, "Name", 80);
    const phone =
      b.phone === undefined ? old!.phone : text(b.phone, "Phone", 40, 0);
    const bio = b.bio === undefined ? old!.bio : text(b.bio, "Bio", 2000, 0);
    const socials =
      b.socials === undefined
        ? old!.socials
        : JSON.stringify(socialLinks(b.socials));
    await e.DB.batch([
      stmt(
        e,
        "UPDATE users SET name=?,phone=?,bio=?,socials=?,identity=CASE WHEN name<>? THEN 'pending' ELSE identity END,identityNote=CASE WHEN name<>? THEN NULL ELSE identityNote END,nameVersion=nameVersion+CASE WHEN name<>? THEN 1 ELSE 0 END WHERE id=?",
        name,
        phone,
        bio,
        socials,
        name,
        name,
        name,
        u.id,
      ),
      audit(
        e,
        u,
        "profile.update",
        u.id,
        name === u.name
          ? "Profile updated"
          : "Name changed; identity review invalidated",
      ),
    ]);
    return json(await account(e, u));
  }
  if (
    (p === "/api/profile/identity" || p === "/api/profile/media") &&
    m === "POST"
  ) {
    const identity = p.endsWith("/identity");
    const form = await uploadForm(req),
      file = form.get("file");
    requireThat(file instanceof File, 400, "Choose a file");
    const bytes = new Uint8Array(await file.arrayBuffer());
    requireThat(
      file.size > 0 && file.size <= 5 * 1024 * 1024,
      413,
      "Maximum file size is 5 MB",
    );
    requireThat(
      validDocumentBytes(file.type, bytes) &&
        (identity || file.type.startsWith("image/")),
      400,
      "Upload a valid " + (identity ? "PDF, JPG or PNG" : "JPG or PNG"),
    );
    const kind = form.get("kind");
    if (!identity) {
      requireThat(
        kind === "avatar" || kind === "photo",
        400,
        "Choose avatar or photo",
      );
      const count = await one<{ n: number }>(
        e,
        "SELECT COUNT(*) n FROM profile_media WHERE userId=? AND kind='photo'",
        u.id,
      );
      requireThat(
        kind === "avatar" || count!.n < 12,
        400,
        "Maximum 12 profile photos",
      );
    }
    const key = id(),
      objectKey = (identity ? "identity/" : "profile/") + u.id + "/" + key,
      createdAt = now();
    await e.UPLOADS.put(objectKey, bytes, {
      httpMetadata: { contentType: file.type },
    });
    if (identity) {
      const name =
        file.name.replace(/[^a-zA-Z0-9._ -]/g, "").slice(0, 120) || "identity";
      await e.DB.batch([
        stmt(
          e,
          "INSERT INTO identity_documents SELECT ?,id,?,?,?,?,nameVersion FROM users WHERE id=?",
          key,
          name,
          file.type,
          objectKey,
          createdAt,
          u.id,
        ),
        stmt(
          e,
          "UPDATE users SET identity='pending',identityNote=NULL WHERE id=?",
          u.id,
        ),
        audit(e, u, "identity.upload", u.id, "New identity evidence submitted"),
      ]);
      return json(
        { document: { id: key, name, type: file.type, createdAt } },
        201,
      );
    }
    const url = "/api/profile-media/" + key;
    await e.DB.batch([
      stmt(
        e,
        "INSERT INTO profile_media VALUES(?,?,?,?,?,?)",
        key,
        u.id,
        kind,
        file.type,
        objectKey,
        createdAt,
      ),
      ...(kind === "avatar"
        ? [stmt(e, "UPDATE users SET avatar=? WHERE id=?", url, u.id)]
        : []),
    ]);
    return json({ url }, 201);
  }
  if (p === "/api/profile/media/remove" && m === "POST") {
    const b = await body(req),
      url = text(b.url, "Photo URL", 200),
      key = url.match(/^\/api\/profile-media\/([^/]+)$/)?.[1];
    requireThat(key, 400, "Invalid profile photo");
    const media = await one<{ objectKey: string }>(
      e,
      "SELECT objectKey FROM profile_media WHERE id=? AND userId=?",
      key,
      u.id,
    );
    requireThat(media, 404, "Photo not found");
    await e.DB.batch([
      stmt(
        e,
        "UPDATE users SET avatar=NULL WHERE id=? AND avatar=?",
        u.id,
        url,
      ),
      stmt(e, "DELETE FROM profile_media WHERE id=? AND userId=?", key, u.id),
    ]);
    await e.UPLOADS.delete(media.objectKey);
    return json(await account(e, u));
  }
  const identityFile = p.match(/^\/api\/identity-documents\/([^/]+)$/);
  if (identityFile && m === "GET") {
    const d = await one<{
      userId: string;
      objectKey: string;
      type: string;
      name: string;
    }>(e, "SELECT * FROM identity_documents WHERE id=?", identityFile[1]);
    requireThat(d, 404, "Document not found");
    requireThat(
      d.userId === u.id || u.role === "admin",
      403,
      "This document is private",
    );
    const object = await e.UPLOADS.get(d.objectKey);
    requireThat(object, 404, "Document not found");
    return new Response(object.body, {
      headers: {
        "Content-Type": d.type,
        "Content-Disposition": 'attachment; filename="' + d.name + '"',
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; sandbox",
      },
    });
  }
  const profileReview = p.match(/^\/api\/users\/([^/]+)\/reviews$/);
  if (profileReview && m === "POST") {
    const b = await body(req),
      target = profileReview[1];
    const eligible = await reviewable(e, u, target);
    const booking = eligible.find((x) => x.id === b.bookingId);
    requireThat(
      booking,
      409,
      "Only the other participant in a completed lease can review once",
    );
    const rating = number(b.rating, "Rating", 1, 5);
    requireThat(Number.isInteger(rating), 400, "Choose a whole star rating");
    const key = id(),
      createdAt = now(),
      reviewBody = text(b.body, "Review", 2000, 10);
    await e.DB.batch([
      stmt(
        e,
        "INSERT INTO profile_reviews VALUES(?,?,?,?,?,?,?)",
        key,
        booking.id,
        u.id,
        target,
        rating,
        reviewBody,
        createdAt,
      ),
      audit(e, u, "profile.review", target, "Completed lease review submitted"),
    ]);
    return json(
      {
        review: {
          id: key,
          authorId: u.id,
          authorName: u.name,
          rating,
          body: reviewBody,
          createdAt,
          listingTitle: booking.listingTitle,
        },
      },
      201,
    );
  }
  if (p === "/api/admin/identities" && m === "GET") {
    const users = await all<ProfileRow>(
      e,
      "SELECT * FROM users WHERE EXISTS(SELECT 1 FROM identity_documents d WHERE d.userId=users.id) ORDER BY rowid DESC LIMIT 200",
    );
    return json({
      submissions: await Promise.all(
        users.map(async (x) => ({
          userId: x.id,
          name: x.name,
          email: x.email,
          identity: x.identity,
          identityNote: x.identityNote,
          documents: await identityDocs(e, x.id),
        })),
      ),
    });
  }
  if (p === "/api/mine" && m === "GET")
    return json({
      listings: await listings(e, "WHERE l.ownerId=?", u.id),
      documents: await all(
        e,
        "SELECT d.id,d.listingId,d.name,d.kind,d.createdAt FROM documents d JOIN listings l ON l.id=d.listingId WHERE l.ownerId=? ORDER BY d.rowid DESC",
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
      "INSERT INTO listings(id,ownerId,data,status) VALUES(?,?,?,'approved')",
      key,
      u.id,
      JSON.stringify(data),
    ).run();
    return json({ listing: await getListing(e, key) }, 201);
  }

  if (p === "/api/conversations" && m === "GET")
    return json({
      conversations: await all(
        e,
        conversationSQL +
          " WHERE c.buyerId=? OR c.sellerId=? ORDER BY c.updatedAt DESC",
        u.id,
        u.id,
        u.id,
      ),
    });
  if (p === "/api/conversations" && m === "POST") {
    const b = await body(req),
      l = await getListing(e, text(b.listingId, "Listing", 80));
    return json({ conversation: await openConversation(e, l, u) }, 201);
  }
  const conversationMatch = p.match(
    /^\/api\/conversations\/([^/]+)(?:\/(messages|documents|offers))?$/,
  );
  if (conversationMatch) {
    const c = await getConversation(e, conversationMatch[1], u),
      operation = conversationMatch[2];
    if (!operation && m === "GET") {
      const l = await getListing(e, c.listingId);
      const bookings = await all<Booking>(
        e,
        "SELECT b.* FROM bookings b JOIN offers o ON o.id=b.offerId WHERE o.conversationId=? ORDER BY b.createdAt",
        c.id,
      );
      return json({
        conversation: c,
        listing: listingView(l, u.id === l.ownerId ? u : null),
        peer: {
          id: u.id === c.buyerId ? c.sellerId : c.buyerId,
          name: c.peerName,
        },
        messages: await all(
          e,
          "SELECT m.*,? conversationId FROM messages m WHERE listingId=? AND ((senderId=? AND recipientId=?) OR (senderId=? AND recipientId=?)) ORDER BY createdAt,rowid",
          c.id,
          c.listingId,
          c.buyerId,
          c.sellerId,
          c.sellerId,
          c.buyerId,
        ),
        offers: await all(
          e,
          "SELECT * FROM offers WHERE conversationId=? ORDER BY createdAt,rowid",
          c.id,
        ),
        bookings: await Promise.all(bookings.map((b) => decorateBooking(e, b))),
        attachments: await all(
          e,
          "SELECT id,conversationId,senderId,name,type,size,createdAt FROM chat_attachments WHERE conversationId=? ORDER BY createdAt,rowid",
          c.id,
        ),
        events: await all(
          e,
          "SELECT * FROM chat_events WHERE conversationId=? ORDER BY createdAt,rowid",
          c.id,
        ),
      });
    }
    if (operation === "messages" && m === "POST")
      return json(
        { message: await sendMessage(e, c, u, await body(req)) },
        201,
      );
    if (operation === "offers" && m === "POST")
      return json(
        { offer: await createProposal(e, c, u, await body(req)) },
        201,
      );
    if (operation === "documents" && m === "POST") {
      await activeParticipants(e, c);
      const bytes = await bounded(req, 6 * 1024 * 1024);
      const form = await new Request(req.url, {
        method: "POST",
        headers: { "Content-Type": req.headers.get("Content-Type") || "" },
        body: bytes,
      }).formData();
      const file = form.get("file");
      requireThat(file instanceof File, 400, "Choose a file");
      requireThat(
        file.size > 0 && file.size <= 5 * 1024 * 1024,
        413,
        "File exceeds size limit",
      );
      requireThat(
        validDocumentBytes(file.type, new Uint8Array(await file.arrayBuffer())),
        400,
        "Use a PDF, JPEG or PNG with matching file contents",
      );
      const count = await one<{ n: number }>(
        e,
        "SELECT count(*) n FROM chat_attachments WHERE conversationId=?",
        c.id,
      );
      requireThat(
        (count?.n || 0) < 100,
        400,
        "Maximum 100 shared documents per conversation",
      );
      const attachment: ChatAttachment = {
        id: id(),
        conversationId: c.id,
        senderId: u.id,
        name:
          file.name.replace(/[^a-zA-Z0-9._ -]/g, "").slice(0, 120) ||
          "document",
        type: file.type,
        size: file.size,
        createdAt: now(),
      };
      const objectKey = "chat/" + c.id + "/" + attachment.id;
      await e.UPLOADS.put(objectKey, file.stream(), {
        httpMetadata: { contentType: file.type },
      });
      try {
        await e.DB.batch([
          stmt(
            e,
            "INSERT INTO chat_attachments(id,conversationId,senderId,name,type,size,objectKey,createdAt) VALUES(?,?,?,?,?,?,?,?)",
            attachment.id,
            c.id,
            u.id,
            attachment.name,
            attachment.type,
            attachment.size,
            objectKey,
            attachment.createdAt,
          ),
          chatEvent(e, c, u, "document", "Shared " + attachment.name),
        ]);
      } catch (err) {
        await e.UPLOADS.delete(objectKey);
        throw err;
      }
      return json({ attachment }, 201);
    }
  }
  const chatDocument = p.match(/^\/api\/chat-documents\/([^/]+)$/);
  if (chatDocument && m === "GET") {
    const d = await one<ChatAttachment & { objectKey: string }>(
      e,
      "SELECT * FROM chat_attachments WHERE id=?",
      chatDocument[1],
    );
    requireThat(d, 404, "Document not found");
    await getConversation(e, d.conversationId, u);
    const object = await e.UPLOADS.get(d.objectKey);
    requireThat(object, 404, "Document not found");
    return new Response(object.body, {
      headers: {
        "Content-Type": d.type,
        "Content-Disposition": `attachment; filename="${d.name}"`,
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; sandbox",
      },
    });
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
    const b = await body(req),
      l = await getListing(e, text(b.listingId, "Listing", 80));
    let c: ConversationSummary;
    if (u.id === l.ownerId) {
      const existing = await one<Conversation>(
        e,
        "SELECT * FROM conversations WHERE listingId=? AND buyerId=?",
        l.id,
        text(b.recipientId, "Recipient", 100),
      );
      requireThat(existing, 403, "Reply to an existing conversation");
      c = await getConversation(e, existing.id, u);
    } else c = await openConversation(e, l, u);
    return json({ message: await sendMessage(e, c, u, b) }, 201);
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
    const c = await openConversation(e, l, u);
    return json({ offer: await createProposal(e, c, u, b) }, 201);
  }
  const offerAction = p.match(
    /^\/api\/offers\/([^/]+)\/(accept|decline|withdraw)$/,
  );
  if (offerAction && m === "POST") {
    const o = await one<Offer>(
      e,
      "SELECT * FROM offers WHERE id=?",
      offerAction[1],
    );
    requireThat(o, 404, "Offer not found");
    const c = await getConversation(e, o.conversationId, u),
      action = offerAction[2];
    requireThat(
      action === "withdraw" ? o.proposedBy === u.id : o.proposedBy !== u.id,
      403,
      action === "withdraw"
        ? "Only the proposer can withdraw"
        : "Only the other participant can accept or decline",
    );
    requireThat(o.status === "pending", 409, "This offer is no longer pending");
    if (action !== "accept") {
      const status = action === "decline" ? "declined" : "withdrawn";
      const results = await e.DB.batch([
        stmt(
          e,
          "UPDATE offers SET status=? WHERE id=? AND status='pending'",
          status,
          o.id,
        ),
        stmt(
          e,
          "INSERT INTO chat_events(id,conversationId,actorId,kind,body,offerId,createdAt) SELECT ?,?,?,?,?,?,? WHERE changes()=1",
          id(),
          c.id,
          u.id,
          status,
          "Proposal " + status,
          o.id,
          now(),
        ),
      ]);
      requireThat(
        results[0].meta.changes === 1,
        409,
        "This offer is no longer pending",
      );
      return json({ offer: { ...o, status } });
    }
    await activeParticipants(e, c);
    const l = await getListing(e, o.listingId);
    reviewed(l);
    requireThat(
      o.startDate >= syracuseDate(),
      409,
      "Offer start date has passed",
    );
    requireThat(
      o.startDate >= l.startDate && o.endDate <= l.endDate,
      409,
      "Dates no longer fit listing availability",
    );
    const key = id();
    const results = await e.DB.batch([
      stmt(
        e,
        "INSERT INTO bookings(id,offerId,listingId,buyerId,sellerId,amount,startDate,endDate,createdAt) SELECT ?,id,listingId,buyerId,sellerId,amount,startDate,endDate,? FROM offers WHERE id=? AND status='pending' AND proposedBy<>?",
        key,
        now(),
        o.id,
        u.id,
      ),
      stmt(
        e,
        "UPDATE offers SET status='accepted' WHERE id=? AND status='pending' AND EXISTS(SELECT 1 FROM bookings WHERE id=?)",
        o.id,
        key,
      ),
      stmt(
        e,
        "INSERT INTO chat_events(id,conversationId,actorId,kind,body,offerId,createdAt) SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM bookings WHERE id=?)",
        id(),
        c.id,
        u.id,
        "accepted",
        "Proposal accepted; reservation created",
        o.id,
        now(),
        key,
      ),
    ]);
    requireThat(
      results[0].meta.changes === 1,
      409,
      "This offer is no longer pending",
    );
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
    const thread = await one<Conversation>(
      e,
      "SELECT c.* FROM conversations c JOIN offers o ON o.conversationId=c.id JOIN bookings b ON b.offerId=o.id WHERE b.id=?",
      booking.id,
    );
    if (thread) {
      const descriptions: Record<string, string> = {
        sign: "Demo agreement acknowledged (not a legal signature)",
        pay: "Demo payment simulated (no money moved)",
        "confirm-move-in": "Renter confirmed move-in",
        dispute: "Renter opened a reservation dispute",
      };
      await chatEvent(e, thread, u, String(a), descriptions[String(a)]).run();
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
    if (!isMedia)
      requireThat(
        validDocumentBytes(file.type, new Uint8Array(await file.arrayBuffer())),
        400,
        "File contents do not match PDF, JPG or PNG",
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
          `UPDATE listings SET ${reviewColumn}='pending',reviewNote=NULL WHERE id=?`,
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
        "UPDATE listings SET data=? WHERE id=?",
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
        "SELECT id,listingId,name,kind,createdAt FROM documents ORDER BY rowid DESC LIMIT 500",
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
    requireThat(
      l.ownerId !== u.id ||
        (b.leaseStatus !== "verified" && b.permissionStatus !== "verified"),
      403,
      "You cannot verify your own listing",
    );
    const evidence: Record<string, string | null> = {};
    for (const kind of ["lease", "permission"]) {
      const latest = await one<{ id: string }>(
        e,
        "SELECT id FROM documents WHERE listingId=? AND kind=? ORDER BY rowid DESC LIMIT 1",
        l.id,
        kind,
      );
      evidence[kind] = latest?.id || null;
      if (b[kind + "Status"] === "verified")
        requireThat(
          latest && b[kind + "DocumentId"] === latest.id,
          409,
          "Select the current " + kind + " evidence before verifying",
        );
    }
    const results = await e.DB.batch([
      stmt(
        e,
        "UPDATE listings SET status=?,leaseStatus=?,permissionStatus=?,reviewNote=? WHERE id=? AND COALESCE((SELECT id FROM documents WHERE listingId=? AND kind='lease' ORDER BY rowid DESC LIMIT 1),'')=? AND COALESCE((SELECT id FROM documents WHERE listingId=? AND kind='permission' ORDER BY rowid DESC LIMIT 1),'')=?",
        b.status,
        b.leaseStatus,
        b.permissionStatus,
        reason,
        l.id,
        l.id,
        evidence.lease || "",
        l.id,
        evidence.permission || "",
      ),
      stmt(
        e,
        "INSERT INTO audit SELECT ?,?,?,?,?,? WHERE changes()=1",
        id(),
        u.id,
        "listing.review",
        l.id,
        reason,
        now(),
      ),
    ]);
    requireThat(
      results[0].meta.changes === 1,
      409,
      "Evidence changed; refresh before reviewing",
    );
    return json({ listing: await getListing(e, l.id) });
  }
  const identity = p.match(
    /^\/api\/admin\/(?:identities\/([^/]+)\/review|users\/([^/]+)\/review)$/,
  );
  if (identity && m === "POST") {
    const b = await body(req),
      target = identity[1] || identity[2],
      status = b.status || b.identity,
      reason = text(b.reason, "Review reason", 2000, 5);
    requireThat(target !== u.id, 403, "You cannot review your own identity");
    const user = await one<ProfileRow>(
      e,
      "SELECT * FROM users WHERE id=?",
      target,
    );
    requireThat(user, 404, "User not found");
    requireThat(
      ["verified", "needs_info", "rejected"].includes(String(status)),
      400,
      "Invalid identity review",
    );
    const docs = await identityDocs(e, target),
      latest = docs[0];
    requireThat(
      latest && b.documentId === latest.id,
      409,
      "Select the current identity evidence before reviewing",
    );
    const result = await e.DB.batch([
      stmt(
        e,
        "UPDATE users SET identity=?,identityNote=? WHERE id=? AND nameVersion=? AND (SELECT id FROM identity_documents WHERE userId=? AND nameVersion=users.nameVersion ORDER BY rowid DESC LIMIT 1)=?",
        status,
        reason,
        target,
        user.nameVersion,
        target,
        latest.id,
      ),
      stmt(
        e,
        "INSERT INTO audit SELECT ?,?,?,?,?,? WHERE changes()=1",
        id(),
        u.id,
        "identity.review",
        target,
        reason,
        now(),
      ),
    ]);
    requireThat(
      result[0].meta.changes === 1,
      409,
      "Identity evidence changed; refresh before reviewing",
    );
    return json({
      user: userView(
        (await one<User>(e, "SELECT * FROM users WHERE id=?", target))!,
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
