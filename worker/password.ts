import { scrypt, randomBytes, timingSafeEqual, createHash } from "node:crypto";
import { HttpError, requireThat } from "./policy";
import type { User } from "../shared/types";
const derive = (password: string, salt: string) =>
  new Promise<Buffer>((resolve, reject) =>
    scrypt(
      password,
      Buffer.from(salt, "hex"),
      32,
      { N: 16384, r: 8, p: 5, maxmem: 64 * 1024 * 1024 },
      (err, key) => (err ? reject(err) : resolve(key)),
    ),
  );
export async function hashPassword(password: string) {
  const salt = randomBytes(16).toString("hex");
  return `scrypt$16384$8$5$${salt}$${(await derive(password, salt)).toString("hex")}`;
}
const dummy = `scrypt$16384$8$5$${"0".repeat(32)}$${"0".repeat(64)}`;
export async function verifyPassword(password: string, encoded: string) {
  const match = /^scrypt\$16384\$8\$5\$([a-f0-9]{32})\$([a-f0-9]{64})$/.exec(
    encoded,
  );
  if (!match) return false;
  return timingSafeEqual(
    await derive(password, match[1]),
    Buffer.from(match[2], "hex"),
  );
}
const digest = (value: string) =>
  createHash("sha256").update(value).digest("hex");
export const passwordToken = (req: Request) =>
  req.headers
    .get("Cookie")
    ?.match(/(?:^|;\s*)cuse_password_session=([^;]*)/)?.[1];
export const passwordCookie = (token: string, demo: boolean) =>
  `cuse_password_session=${token}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${token ? 28800 : 0}${demo ? "" : "; Secure"}`;
export async function passwordUser(req: Request, db: D1Database) {
  const token = passwordToken(req);
  if (!token || !/^[a-f0-9]{64}$/.test(token)) return null;
  return db
    .prepare(
      "SELECT u.* FROM users u JOIN password_sessions s ON s.userId=u.id WHERE s.tokenHash=? AND s.expires>? AND u.suspended=0",
    )
    .bind(digest(token), Date.now())
    .first<User>();
}
export async function revokePassword(req: Request, db: D1Database) {
  const token = passwordToken(req);
  if (token)
    await db
      .prepare("DELETE FROM password_sessions WHERE tokenHash=?")
      .bind(digest(token))
      .run();
}
async function session(db: D1Database, userId: string, expectedHash: string) {
  const token = randomBytes(32).toString("hex");
  const result = await db
    .prepare(
      "INSERT INTO password_sessions SELECT ?,u.id,? FROM users u JOIN password_credentials p ON p.userId=u.id WHERE u.id=? AND p.passwordHash=? AND u.suspended=0",
    )
    .bind(digest(token), Date.now() + 28800000, userId, expectedHash)
    .run();
  requireThat(
    result.meta.changes === 1,
    401,
    "Credentials changed. Sign in again.",
  );
  return token;
}
async function throttle(req: Request, db: D1Database, email: string) {
  const time = Date.now(),
    window = Math.floor(time / 900000);
  const keys = [
    [`ip:${req.headers.get("CF-Connecting-IP") || "local"}`, 40],
    [`email:${email}`, 10],
  ] as const;
  const results = await db.batch(
    keys.map(([key]) =>
      db
        .prepare(
          "INSERT INTO auth_limits(key,window,count) VALUES(?,?,1) ON CONFLICT(key) DO UPDATE SET count=CASE WHEN window=excluded.window THEN count+1 ELSE 1 END,window=excluded.window RETURNING count",
        )
        .bind(digest(key), window),
    ),
  );
  await db.batch([
    db
      .prepare(
        "DELETE FROM auth_limits WHERE key IN (SELECT key FROM auth_limits WHERE window<? LIMIT 100)",
      )
      .bind(window - 1),
    db
      .prepare(
        "DELETE FROM password_sessions WHERE tokenHash IN (SELECT tokenHash FROM password_sessions WHERE expires<? LIMIT 100)",
      )
      .bind(time),
  ]);
  requireThat(
    results.every(
      (r, i) =>
        Number((r.results[0] as { count: number })?.count) <= keys[i][1],
    ),
    429,
    "Too many attempts. Try again in 15 minutes.",
  );
}
const validPassword = (value: unknown): string => {
  requireThat(
    typeof value === "string" && value.length >= 15 && value.length <= 128,
    400,
    "Use a password between 15 and 128 characters.",
  );
  return value;
};
export async function passwordAuth(
  req: Request,
  db: D1Database,
  action: string,
  b: Record<string, unknown>,
) {
  if (action === "password") {
    const user = await passwordUser(req, db);
    requireThat(user, 401, "Sign in with your email and password first.");
    await throttle(req, db, user.email.toLowerCase());
    const credential = await db
      .prepare("SELECT passwordHash FROM password_credentials WHERE userId=?")
      .bind(user.id)
      .first<{ passwordHash: string }>();
    const current = validPassword(b.currentPassword),
      next = validPassword(b.newPassword);
    requireThat(
      credential && (await verifyPassword(current, credential.passwordHash)),
      401,
      "Current password is incorrect.",
    );
    const hash = await hashPassword(next);
    const token = randomBytes(32).toString("hex");
    const results = await db.batch([
      db
        .prepare(
          "UPDATE password_credentials SET passwordHash=? WHERE userId=? AND passwordHash=? AND EXISTS(SELECT 1 FROM users WHERE id=? AND suspended=0)",
        )
        .bind(hash, user.id, credential.passwordHash, user.id),
      db
        .prepare(
          "DELETE FROM password_sessions WHERE userId=? AND EXISTS(SELECT 1 FROM password_credentials WHERE userId=? AND passwordHash=?)",
        )
        .bind(user.id, user.id, hash),
      db
        .prepare(
          "INSERT INTO password_sessions SELECT ?,userId,? FROM password_credentials WHERE userId=? AND passwordHash=?",
        )
        .bind(digest(token), Date.now() + 28800000, user.id, hash),
    ]);
    requireThat(
      results[0].meta.changes === 1 && results[2].meta.changes === 1,
      409,
      "Password changed in another session. Sign in again.",
    );
    return { user, token };
  }
  requireThat(
    typeof b.email === "string" && b.email.length <= 254,
    400,
    "Enter a valid email address.",
  );
  const email = b.email.trim().toLowerCase();
  requireThat(
    /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email),
    400,
    "Enter a valid email address.",
  );
  await throttle(req, db, email);
  const password = validPassword(b.password);
  if (action === "signup") {
    requireThat(
      typeof b.name === "string" &&
        b.name.trim().length >= 1 &&
        b.name.trim().length <= 80,
      400,
      "Enter your name (up to 80 characters).",
    );
    const existing = await db
      .prepare("SELECT id FROM users WHERE lower(email)=?")
      .bind(email)
      .first();
    requireThat(
      !existing,
      409,
      "Unable to create this account. Try signing in with your existing login method.",
    );
    const userId = "password:" + crypto.randomUUID(),
      hash = await hashPassword(password);
    try {
      await db.batch([
        db
          .prepare(
            "INSERT INTO users(id,name,email,role,identity) VALUES(?,?,?,\u0027member\u0027,\u0027pending\u0027)",
          )
          .bind(userId, b.name.trim(), email),
        db
          .prepare("INSERT INTO password_credentials VALUES(?,?)")
          .bind(userId, hash),
      ]);
    } catch (error) {
      if (String(error).includes("UNIQUE"))
        throw new HttpError(
          409,
          "Unable to create this account. Try signing in with your existing login method.",
        );
      throw error;
    }
    const user = (await db
      .prepare("SELECT * FROM users WHERE id=?")
      .bind(userId)
      .first<User>())!;
    return { user, token: await session(db, userId, hash) };
  }
  const user = await db
    .prepare(
      "SELECT u.*,p.passwordHash FROM users u JOIN password_credentials p ON p.userId=u.id WHERE lower(u.email)=?",
    )
    .bind(email)
    .first<User & { passwordHash: string }>();
  const valid = await verifyPassword(password, user?.passwordHash || dummy);
  requireThat(
    user && valid && !user.suspended,
    401,
    "Email or password is incorrect.",
  );
  return { user, token: await session(db, user.id, user.passwordHash) };
}
