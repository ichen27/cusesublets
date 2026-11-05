import { createHash, randomBytes } from "node:crypto";
import {
  createRemoteJWKSet,
  importPKCS8,
  jwtVerify,
  SignJWT,
  type JWTVerifyGetKey,
} from "jose";
import { HttpError, requireThat, text } from "./policy";
import { passwordCookie } from "./password";
export type AppleEnv = Pick<Cloudflare.Env, "DB"> & {
  APPLE_CLIENT_ID?: string;
  APPLE_TEAM_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string;
  APPLE_TOKEN_KEY?: string;
};
const issuer = "https://appleid.apple.com";
const appleKeys = createRemoteJWKSet(new URL(issuer + "/auth/keys"));
const digest = (value: string) =>
  createHash("sha256").update(value).digest("hex");
const json = (value: unknown) =>
  Response.json(value, { headers: { "Cache-Control": "no-store" } });
export function appleConfigured(e: AppleEnv) {
  return !!(
    e.APPLE_CLIENT_ID &&
    e.APPLE_TEAM_ID &&
    e.APPLE_KEY_ID &&
    e.APPLE_PRIVATE_KEY &&
    /^[a-f0-9]{64}$/i.test(e.APPLE_TOKEN_KEY || "")
  );
}
export async function verifyAppleIdentity(
  token: string,
  clientId: string,
  nonce: string,
  keys: JWTVerifyGetKey = appleKeys,
) {
  const { payload } = await jwtVerify(token, keys, {
    issuer,
    audience: clientId,
    algorithms: ["RS256"],
    requiredClaims: ["exp", "iat", "sub", "nonce"],
    maxTokenAge: "5m",
  });
  requireThat(
    payload.nonce === nonce &&
      typeof payload.sub === "string" &&
      payload.sub.length > 0,
    401,
    "Apple sign-in did not match this request",
  );
  return payload;
}
async function clientSecret(e: AppleEnv) {
  requireThat(appleConfigured(e), 503, "Apple sign-in is not configured");
  const key = await importPKCS8(e.APPLE_PRIVATE_KEY!, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: e.APPLE_KEY_ID! })
    .setIssuer(e.APPLE_TEAM_ID!)
    .setAudience(issuer)
    .setSubject(e.APPLE_CLIENT_ID!)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key);
}
export async function sealAppleToken(
  value: string,
  keyHex: string,
  subject: string,
) {
  const key = await crypto.subtle.importKey(
    "raw",
    Buffer.from(keyHex, "hex"),
    "AES-GCM",
    false,
    ["encrypt"],
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(subject) },
    key,
    new TextEncoder().encode(value),
  );
  return (
    "v1." +
    Buffer.from(iv).toString("base64url") +
    "." +
    Buffer.from(ciphertext).toString("base64url")
  );
}
export async function openAppleToken(
  value: string,
  keyHex: string,
  subject: string,
) {
  const [version, iv, data] = value.split(".");
  requireThat(
    version === "v1" && iv && data,
    500,
    "Apple credential storage unavailable",
  );
  const key = await crypto.subtle.importKey(
    "raw",
    Buffer.from(keyHex, "hex"),
    "AES-GCM",
    false,
    ["decrypt"],
  );
  return new TextDecoder().decode(
    await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: Buffer.from(iv, "base64url"),
        additionalData: new TextEncoder().encode(subject),
      },
      key,
      Buffer.from(data, "base64url"),
    ),
  );
}
export async function appleChallenge(req: Request, e: AppleEnv) {
  requireThat(appleConfigured(e), 503, "Apple sign-in is not configured");
  const window = Math.floor(Date.now() / 900000),
    ip = digest("apple:" + (req.headers.get("CF-Connecting-IP") || "local"));
  const limit = await e.DB.prepare(
    "INSERT INTO auth_limits(key,window,count) VALUES(?,?,1) ON CONFLICT(key) DO UPDATE SET count=CASE WHEN window=excluded.window THEN count+1 ELSE 1 END,window=excluded.window RETURNING count",
  )
    .bind(ip, window)
    .first<{ count: number }>();
  requireThat(
    limit && limit.count <= 40,
    429,
    "Too many sign-in attempts. Try again later.",
  );
  const id = crypto.randomUUID(),
    nonce = randomBytes(32).toString("hex");
  await e.DB.batch([
    e.DB.prepare("DELETE FROM apple_auth_challenges WHERE expires<?").bind(
      Date.now(),
    ),
    e.DB.prepare("INSERT INTO apple_auth_challenges VALUES(?,?,?)").bind(
      id,
      nonce,
      Date.now() + 300000,
    ),
  ]);
  return json({ id, nonce });
}
export async function appleExchange(
  b: Record<string, unknown>,
  e: AppleEnv,
  demo: boolean,
) {
  requireThat(appleConfigured(e), 503, "Apple sign-in is not configured");
  const token = text(b.identityToken, "Apple identity token", 16000),
    code = text(b.code, "Apple authorization code", 4096),
    challengeID = text(b.challengeID, "Sign-in request", 64);
  const challenge = await e.DB.prepare(
    "SELECT nonce FROM apple_auth_challenges WHERE id=? AND expires>?",
  )
    .bind(challengeID, Date.now())
    .first<{ nonce: string }>();
  requireThat(challenge, 401, "Sign-in expired. Please try again.");
  let identity;
  try {
    identity = await verifyAppleIdentity(
      token,
      e.APPLE_CLIENT_ID!,
      challenge.nonce,
    );
  } catch {
    throw new HttpError(401, "Apple sign-in could not be verified");
  }
  const consumed = await e.DB.prepare(
    "DELETE FROM apple_auth_challenges WHERE id=? AND expires>? RETURNING id",
  )
    .bind(challengeID, Date.now())
    .first();
  requireThat(consumed, 401, "Sign-in expired. Please try again.");
  let exchanged: { id_token?: string; refresh_token?: string };
  try {
    const response = await fetch(issuer + "/auth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: e.APPLE_CLIENT_ID!,
        client_secret: await clientSecret(e),
        code,
        grant_type: "authorization_code",
      }),
      redirect: "error",
      signal: AbortSignal.timeout(15000),
    });
    requireThat(
      response.ok,
      401,
      "Apple authorization expired. Please try again.",
    );
    exchanged = await response.json();
    requireThat(
      typeof exchanged.id_token === "string" &&
        typeof exchanged.refresh_token === "string" &&
        exchanged.refresh_token.length < 8192,
      401,
      "Apple returned incomplete authorization",
    );
    const verified = await verifyAppleIdentity(
      exchanged.id_token,
      e.APPLE_CLIENT_ID!,
      challenge.nonce,
    );
    requireThat(
      verified.sub === identity.sub,
      401,
      "Apple account changed during sign-in",
    );
  } catch {
    throw new HttpError(
      401,
      "Apple authorization could not be completed. Please try again.",
    );
  }
  const existing = await e.DB.prepare(
    "SELECT a.userId,u.suspended FROM apple_identities a JOIN users u ON u.id=a.userId WHERE a.subject=?",
  )
    .bind(identity.sub)
    .first<{ userId: string; suspended: number }>();
  requireThat(!existing?.suspended, 403, "Account unavailable");
  const encrypted = await sealAppleToken(
    exchanged.refresh_token!,
    e.APPLE_TOKEN_KEY!,
    identity.sub!,
  );
  const authenticatedAt = Math.round(Number(identity.iat) * 1000);
  let userId = existing?.userId;
  if (!userId) {
    requireThat(
      typeof identity.email === "string" &&
        identity.email.length <= 254 &&
        (identity.email_verified === true ||
          identity.email_verified === "true"),
      401,
      "Apple did not provide a verified email address",
    );
    const email = identity.email.toLowerCase();
    const collision = await e.DB.prepare(
      "SELECT id FROM users WHERE lower(email)=?",
    )
      .bind(email)
      .first();
    requireThat(
      !collision,
      409,
      "This email already has an account. Use its existing sign-in method.",
    );
    userId = crypto.randomUUID();
    const name = b.name ? text(b.name, "Name", 80) : "Member";
    await e.DB.batch([
      e.DB.prepare(
        "INSERT INTO users(id,name,email,role) SELECT ?,?,?,'member' WHERE NOT EXISTS(SELECT 1 FROM apple_account_events WHERE subject=? AND revokedAt>=?)",
      ).bind(userId, name, email, identity.sub, authenticatedAt),
      e.DB.prepare(
        "INSERT INTO apple_identities(subject,userId,refreshToken,authenticatedAt) SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM users WHERE id=?) AND NOT EXISTS(SELECT 1 FROM apple_account_events WHERE subject=? AND revokedAt>=?)",
      ).bind(
        identity.sub,
        userId,
        encrypted,
        authenticatedAt,
        userId,
        identity.sub,
        authenticatedAt,
      ),
    ]);
  } else {
    await e.DB.prepare(
      "UPDATE apple_identities SET refreshToken=?,revokedAt=NULL,authenticatedAt=? WHERE subject=? AND authenticatedAt<=? AND NOT EXISTS(SELECT 1 FROM apple_account_events WHERE subject=apple_identities.subject AND revokedAt>=?) AND EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0)",
    )
      .bind(
        encrypted,
        authenticatedAt,
        identity.sub,
        authenticatedAt,
        authenticatedAt,
        userId,
      )
      .run();
  }
  const session = randomBytes(32).toString("hex");
  const saved = await e.DB.prepare(
    "INSERT INTO password_sessions SELECT ?,u.id,? FROM users u JOIN apple_identities a ON a.userId=u.id WHERE u.id=? AND u.suspended=0 AND a.subject=? AND a.authenticatedAt=? AND a.revokedAt IS NULL AND NOT EXISTS(SELECT 1 FROM apple_account_events v WHERE v.subject=a.subject AND v.revokedAt>=a.authenticatedAt)",
  )
    .bind(
      digest(session),
      Date.now() + 28800000,
      userId,
      identity.sub,
      authenticatedAt,
    )
    .run();
  requireThat(saved.meta.changes === 1, 401, "Account changed. Sign in again.");
  return Response.json(
    { ok: true, appleUserID: identity.sub },
    {
      headers: {
        "Cache-Control": "no-store",
        "Set-Cookie": passwordCookie(session, demo),
      },
    },
  );
}
export async function revokeAppleAccount(e: AppleEnv, userId: string) {
  const identity = await e.DB.prepare(
    "SELECT subject,refreshToken FROM apple_identities WHERE userId=?",
  )
    .bind(userId)
    .first<{ subject: string; refreshToken: string }>();
  if (!identity) return;
  requireThat(
    appleConfigured(e),
    503,
    "Apple account revocation needs server configuration",
  );
  const token = await openAppleToken(
    identity.refreshToken,
    e.APPLE_TOKEN_KEY!,
    identity.subject,
  );
  const response = await fetch(issuer + "/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: e.APPLE_CLIENT_ID!,
      client_secret: await clientSecret(e),
      token,
      token_type_hint: "refresh_token",
    }),
    redirect: "error",
    signal: AbortSignal.timeout(15000),
  });
  requireThat(
    response.ok,
    503,
    "Apple authorization could not be revoked. Please retry account deletion.",
  );
  await e.DB.prepare("DELETE FROM apple_identities WHERE userId=?")
    .bind(userId)
    .run();
}

// Apple sends this signed server notification without a browser Origin header.
export async function appleNotification(
  b: Record<string, unknown>,
  e: AppleEnv,
) {
  requireThat(appleConfigured(e), 503, "Apple sign-in is not configured");
  let payload;
  try {
    ({ payload } = await jwtVerify(
      text(b.payload, "Apple notification", 16000),
      appleKeys,
      {
        issuer,
        audience: e.APPLE_CLIENT_ID!,
        algorithms: ["RS256"],
        requiredClaims: ["iat", "jti", "events"],
      },
    ));
  } catch {
    throw new HttpError(401, "Apple notification could not be verified");
  }
  const event =
    typeof payload.events === "string"
      ? JSON.parse(payload.events)
      : payload.events;
  requireThat(
    event &&
      typeof event === "object" &&
      typeof event.sub === "string" &&
      typeof event.event_time === "number" &&
      Number.isFinite(event.event_time) &&
      event.event_time > 0 &&
      event.event_time <= Date.now() / 1000 + 300,
    400,
    "Invalid Apple account event",
  );
  requireThat(
    [
      "consent-revoked",
      "account-deleted",
      "email-enabled",
      "email-disabled",
    ].includes(event.type),
    400,
    "Unknown Apple account event",
  );
  const at = Math.round(event.event_time * 1000),
    q = (s: string, ...v: unknown[]) => e.DB.prepare(s).bind(...v);
  if (event.type === "email-enabled" || event.type === "email-disabled") {
    await q(
      "UPDATE apple_identities SET emailEnabled=?,emailEventAt=? WHERE subject=? AND EXISTS(SELECT 1 FROM users WHERE id=apple_identities.userId AND deletedAt IS NULL) AND emailEventAt<=?",
      event.type === "email-enabled" ? 1 : 0,
      at,
      event.sub,
      at,
    ).run();
  } else {
    await e.DB.batch([
      q(
        "INSERT INTO apple_account_events VALUES(?,?) ON CONFLICT(subject) DO UPDATE SET revokedAt=MAX(revokedAt,excluded.revokedAt)",
        event.sub,
        at,
      ),
      q(
        "UPDATE apple_identities SET revokedAt=? WHERE subject=? AND EXISTS(SELECT 1 FROM users WHERE id=apple_identities.userId AND deletedAt IS NULL) AND authenticatedAt<=? AND (revokedAt IS NULL OR CAST(revokedAt AS INTEGER)<=?)",
        String(at),
        event.sub,
        at,
        at,
      ),
      q(
        "DELETE FROM password_sessions WHERE userId IN(SELECT userId FROM apple_identities WHERE subject=? AND revokedAt=?)",
        event.sub,
        String(at),
      ),
      q(
        "DELETE FROM mobile_auth_codes WHERE userId IN(SELECT userId FROM apple_identities WHERE subject=? AND revokedAt=?)",
        event.sub,
        String(at),
      ),
    ]);
  }
  return json({ ok: true });
}
