import { beforeAll, describe, expect, it } from "vitest";
import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  SignJWT,
  type CryptoKey,
} from "jose";
import {
  openAppleToken,
  sealAppleToken,
  verifyAppleIdentity,
} from "../worker/apple-auth";
let privateKey: CryptoKey, keys: ReturnType<typeof createLocalJWKSet>;
beforeAll(async () => {
  const pair = await generateKeyPair("RS256");
  privateKey = pair.privateKey;
  keys = createLocalJWKSet({
    keys: [{ ...(await exportJWK(pair.publicKey)), kid: "test", alg: "RS256" }],
  });
});
async function token(overrides: Record<string, unknown> = {}) {
  return new SignJWT({
    nonce: "server-challenge",
    email: "relay@example.test",
    email_verified: true,
    ...overrides,
  })
    .setProtectedHeader({ alg: "RS256", kid: "test" })
    .setSubject("apple-user")
    .setIssuer("https://appleid.apple.com")
    .setAudience("com.example.test")
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(privateKey);
}
describe("Apple identity boundary", () => {
  it("verifies the signature, application audience and bound challenge", async () => {
    const signed = await token();
    expect(
      (
        await verifyAppleIdentity(
          signed,
          "com.example.test",
          "server-challenge",
          keys,
        )
      ).sub,
    ).toBe("apple-user");
    await expect(
      verifyAppleIdentity(signed, "another.app", "server-challenge", keys),
    ).rejects.toThrow();
    await expect(
      verifyAppleIdentity(signed, "com.example.test", "other-challenge", keys),
    ).rejects.toThrow();
    await expect(
      verifyAppleIdentity(
        signed.slice(0, -8) + "tampered",
        "com.example.test",
        "server-challenge",
        keys,
      ),
    ).rejects.toThrow();
  });
  it("rejects expired identity tokens", async () => {
    const expired = await new SignJWT({ nonce: "server-challenge" })
      .setProtectedHeader({ alg: "RS256", kid: "test" })
      .setSubject("apple-user")
      .setIssuer("https://appleid.apple.com")
      .setAudience("com.example.test")
      .setIssuedAt(1)
      .setExpirationTime(2)
      .sign(privateKey);
    await expect(
      verifyAppleIdentity(
        expired,
        "com.example.test",
        "server-challenge",
        keys,
      ),
    ).rejects.toThrow();
  });
  it("encrypts revocation credentials and binds them to the Apple subject", async () => {
    const key = "ab".repeat(32),
      sealed = await sealAppleToken(
        "synthetic-refresh-token",
        key,
        "subject-one",
      );
    expect(sealed).not.toContain("synthetic-refresh-token");
    expect(await openAppleToken(sealed, key, "subject-one")).toBe(
      "synthetic-refresh-token",
    );
    await expect(openAppleToken(sealed, key, "subject-two")).rejects.toThrow();
    await expect(
      openAppleToken(sealed, "cd".repeat(32), "subject-one"),
    ).rejects.toThrow();
  });
});
