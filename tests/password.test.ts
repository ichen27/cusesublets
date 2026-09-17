import { describe, it, expect } from "vitest";
import {
  hashPassword,
  verifyPassword,
  validPassword,
} from "../worker/password";
describe("password hashing", () => {
  it("uses unique salts and checks exact passwords", async () => {
    const a = await hashPassword("a long example password");
    const b = await hashPassword("a long example password");
    expect(a).not.toBe(b);
    expect(a).toMatch(/^scrypt\$16384\$8\$5\$[a-f0-9]{32}\$[a-f0-9]{64}$/);
    expect(await verifyPassword("a long example password", a)).toBe(true);
    expect(await verifyPassword("a wrong example password", a)).toBe(false);
    expect(await verifyPassword("a long example password", "broken")).toBe(
      false,
    );
  });
});

describe("existing credential policy", () => {
  it("accepts provisioned shorter credentials only for authentication", () => {
    expect(validPassword("test-short", false)).toBe("test-short");
    expect(() => validPassword("test-short")).toThrow();
    expect(() => validPassword("", false)).toThrow();
    expect(() => validPassword("x".repeat(129), false)).toThrow();
  });
});
