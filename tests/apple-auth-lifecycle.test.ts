import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  generateKeyPair,
  exportJWK,
  exportPKCS8,
  SignJWT,
  type CryptoKey,
} from "jose";
import {
  appleChallenge,
  appleExchange,
  appleNotification,
  revokeAppleAccount,
  type AppleEnv,
} from "../worker/apple-auth";
import { testDatabase } from "./sqlite-d1";
let signing: CryptoKey, jwk: Record<string, unknown>, privateKey: string;
beforeAll(async () => {
  const rsa = await generateKeyPair("RS256");
  signing = rsa.privateKey;
  jwk = { ...(await exportJWK(rsa.publicKey)), kid: "lifecycle", alg: "RS256" };
  privateKey = await exportPKCS8(
    (await generateKeyPair("ES256", { extractable: true })).privateKey,
  );
});
afterEach(() => vi.unstubAllGlobals());
function environment(options: Parameters<typeof testDatabase>[0] = {}) {
  const db = testDatabase(options);
  const env: AppleEnv = {
    DB: db.DB,
    APPLE_CLIENT_ID: "com.example.lifecycle",
    APPLE_TEAM_ID: "TEAM",
    APPLE_KEY_ID: "KEY",
    APPLE_PRIVATE_KEY: privateKey,
    APPLE_TOKEN_KEY: "ab".repeat(32),
  };
  return { ...db, env };
}
async function signed(claims: Record<string, unknown>) {
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "RS256", kid: "lifecycle" })
    .setIssuer("https://appleid.apple.com")
    .setAudience("com.example.lifecycle")
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(signing);
}
function provider(identityToken: string) {
  const exchange = vi.fn();
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/auth/keys")) return Response.json({ keys: [jwk] });
      if (url.endsWith("/auth/revoke"))
        return new Response(null, { status: 200 });
      if (url.endsWith("/auth/token")) {
        exchange();
        return Response.json({
          id_token: identityToken,
          refresh_token: "synthetic-refresh",
        });
      }
      throw new Error("Unexpected network destination");
    }),
  );
  return exchange;
}
async function challenge(env: AppleEnv) {
  return (await (
    await appleChallenge(
      new Request("https://example.test/api/auth/apple/challenge"),
      env,
    )
  ).json()) as { id: string; nonce: string };
}
describe("Apple sign-in with real database transitions", () => {
  for (const trigger of [
    "UPDATE apple_identities SET refreshToken",
    "INSERT INTO password_sessions",
  ]) {
    it(`fences revocation arriving before ${trigger}`, async () => {
      let notification: () => Promise<void> = async () => {};
      let injected = false;
      const { env, sql } = environment({
        beforeRun: async (query) => {
          if (!injected && query.startsWith(trigger)) {
            injected = true;
            await notification();
          }
        },
      });
      sql.exec(
        "INSERT INTO users(id,name,email) VALUES('member','Member','relay@example.test'); INSERT INTO apple_identities(subject,userId,refreshToken,authenticatedAt) VALUES('subject','member','encrypted',0)",
      );
      const c = await challenge(env),
        token = await signed({ sub: "subject", nonce: c.nonce });
      provider(token);
      const at = Math.floor(Date.now() / 1000) + 1;
      const event = await signed({
        jti: crypto.randomUUID(),
        events: { type: "consent-revoked", sub: "subject", event_time: at },
      });
      notification = async () => {
        await appleNotification({ payload: event }, env);
      };
      await expect(
        appleExchange(
          { identityToken: token, code: "code", challengeID: c.id },
          env,
          true,
        ),
      ).rejects.toThrow("Account changed");
      expect(injected).toBe(true);
      expect(
        sql.prepare("SELECT count(*) n FROM password_sessions").get()?.n,
      ).toBe(0);
      expect(
        sql.prepare("SELECT revokedAt FROM apple_identities").get()?.revokedAt,
      ).toBe(String(at * 1000));
      sql.close();
    });
  }

  it("creates an account once, consumes the challenge and revokes its credential", async () => {
    const { env, sql } = environment();
    const c = await challenge(env),
      token = await signed({
        sub: "subject",
        nonce: c.nonce,
        email: "relay@example.test",
        email_verified: true,
      });
    const exchange = provider(token),
      body = {
        identityToken: token,
        code: "authorization-code",
        challengeID: c.id,
        name: "Synthetic",
      };
    const response = await appleExchange(body, env, true);
    expect(response.status).toBe(200);
    expect(response.headers.get("Set-Cookie")).toContain(
      "cuse_password_session=",
    );
    expect(sql.prepare("SELECT count(*) n FROM users").get()?.n).toBe(1);
    expect(
      sql.prepare("SELECT count(*) n FROM password_sessions").get()?.n,
    ).toBe(1);
    await expect(appleExchange(body, env, true)).rejects.toThrow("expired");
    expect(exchange).toHaveBeenCalledTimes(1);
    const userId = sql.prepare("SELECT id FROM users").get()!.id as string;
    await revokeAppleAccount(env, userId);
    expect(
      sql.prepare("SELECT count(*) n FROM apple_identities").get()?.n,
    ).toBe(0);
    sql.close();
  });
  it("rejects an existing email without linking identities or creating a session", async () => {
    const { env, sql } = environment();
    sql
      .prepare(
        "INSERT INTO users(id,name,email) VALUES('existing','Original','relay@example.test')",
      )
      .run();
    const c = await challenge(env),
      token = await signed({
        sub: "subject",
        nonce: c.nonce,
        email: "relay@example.test",
        email_verified: "true",
      });
    provider(token);
    await expect(
      appleExchange(
        { identityToken: token, code: "code", challengeID: c.id },
        env,
        true,
      ),
    ).rejects.toThrow("existing sign-in");
    expect(
      sql.prepare("SELECT count(*) n FROM apple_identities").get()?.n,
    ).toBe(0);
    expect(
      sql.prepare("SELECT count(*) n FROM password_sessions").get()?.n,
    ).toBe(0);
    sql.close();
  });
  it("rejects suspended identities and never writes a session", async () => {
    const { env, sql } = environment();
    sql
      .prepare(
        "INSERT INTO users(id,name,email,suspended) VALUES('blocked','Blocked','relay@example.test',1)",
      )
      .run();
    sql
      .prepare(
        "INSERT INTO apple_identities(subject,userId,refreshToken) VALUES('subject','blocked','encrypted')",
      )
      .run();
    const c = await challenge(env),
      token = await signed({ sub: "subject", nonce: c.nonce });
    provider(token);
    await expect(
      appleExchange(
        { identityToken: token, code: "code", challengeID: c.id },
        env,
        true,
      ),
    ).rejects.toThrow("unavailable");
    expect(
      sql.prepare("SELECT count(*) n FROM password_sessions").get()?.n,
    ).toBe(0);
    sql.close();
  });
  it("revokes sessions on authenticated Apple events and ignores events older than reauthentication", async () => {
    const { env, sql } = environment();
    sql
      .prepare(
        "INSERT INTO users(id,name,email) VALUES('member','Member','relay@example.test')",
      )
      .run();
    const now = Math.floor(Date.now() / 1000);
    sql
      .prepare(
        "INSERT INTO apple_identities(subject,userId,refreshToken,authenticatedAt) VALUES('subject','member','encrypted',?)",
      )
      .run((now - 10) * 1000);
    sql
      .prepare("INSERT INTO password_sessions VALUES('session','member',?)")
      .run(Date.now() + 100000);
    provider("unused");
    const event = await signed({
      jti: "one",
      events: { type: "consent-revoked", sub: "subject", event_time: now },
    });
    await appleNotification({ payload: event }, env);
    expect(
      sql.prepare("SELECT count(*) n FROM password_sessions").get()?.n,
    ).toBe(0);
    sql
      .prepare("UPDATE apple_identities SET authenticatedAt=?,revokedAt=NULL")
      .run((now + 1) * 1000);
    sql
      .prepare("INSERT INTO password_sessions VALUES('new','member',?)")
      .run(Date.now() + 100000);
    await appleNotification({ payload: event }, env);
    expect(
      sql.prepare("SELECT count(*) n FROM password_sessions").get()?.n,
    ).toBe(1);
    await expect(
      appleNotification({ payload: event.slice(0, -8) + "tampered" }, env),
    ).rejects.toThrow("verified");
    sql.close();
  });
});
