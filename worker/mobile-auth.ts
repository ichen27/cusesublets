import { createHash, randomBytes } from "node:crypto";
import type { User } from "../shared/types";
import { requireThat } from "./policy";
import { passwordCookie } from "./password";
const hash = (value: string) =>
  createHash("sha256").update(value).digest("hex");
export async function mobileAuthCallback(
  url: URL,
  user: User,
  db: D1Database,
): Promise<Response | null> {
  const challenge = url.searchParams.get("mobile_challenge");
  if (!challenge) return null;
  const state = url.searchParams.get("state") || "";
  requireThat(
    /^[A-Za-z0-9_-]{43}$/.test(challenge) && /^[a-f0-9-]{36}$/i.test(state),
    400,
    "Invalid mobile sign-in request",
  );
  requireThat(!user.suspended, 403, "Account unavailable");
  const code = randomBytes(32).toString("hex");
  await db.batch([
    db
      .prepare("DELETE FROM mobile_auth_codes WHERE expires<? OR userId=?")
      .bind(Date.now(), user.id),
    db
      .prepare("INSERT INTO mobile_auth_codes VALUES(?,?,?,?)")
      .bind(hash(code), user.id, challenge, Date.now() + 60000),
  ]);
  return new Response(null, {
    status: 302,
    headers: {
      Location: `cusesublets://auth?code=${code}&state=${state}`,
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
    },
  });
}
export async function mobileAuthExchange(
  b: Record<string, unknown>,
  db: D1Database,
  demo: boolean,
) {
  requireThat(
    typeof b.code === "string" && /^[a-f0-9]{64}$/.test(b.code),
    400,
    "Invalid authorization code",
  );
  requireThat(
    typeof b.verifier === "string" &&
      /^[A-Za-z0-9_-]{43,128}$/.test(b.verifier),
    400,
    "Invalid authorization verifier",
  );
  const challenge = createHash("sha256").update(b.verifier).digest("base64url");
  // One-time consumption and verifier binding are checked in the same statement.
  const row = await db
    .prepare(
      "DELETE FROM mobile_auth_codes WHERE codeHash=? AND challenge=? AND expires>? RETURNING userId",
    )
    .bind(hash(b.code), challenge, Date.now())
    .first<{ userId: string }>();
  requireThat(row, 401, "Sign-in expired. Please try again.");
  const token = randomBytes(32).toString("hex");
  const result = await db
    .prepare(
      "INSERT INTO password_sessions SELECT ?,id,? FROM users WHERE id=? AND suspended=0",
    )
    .bind(hash(token), Date.now() + 28800000, row.userId)
    .run();
  requireThat(result.meta.changes === 1, 401, "Account unavailable");
  return Response.json(
    { ok: true },
    {
      headers: {
        "Set-Cookie": passwordCookie(token, demo),
        "Cache-Control": "no-store",
      },
    },
  );
}
