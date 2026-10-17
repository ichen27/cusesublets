import { describe, it, expect, vi } from "vitest";
import { testDatabase } from "./sqlite-d1";
import {
  beginAccountDeletion,
  processAccountDeletion,
} from "../worker/account-deletion";
import type { User } from "../shared/types";
function fixture() {
  const db = testDatabase();
  db.sql.exec(
    "INSERT INTO users(id,name,email) VALUES('one','Sensitive name','one@example.test'); INSERT OR IGNORE INTO schools VALUES('syracuse','Syracuse'); INSERT INTO listings(id,ownerId,status,data) VALUES('place','one','approved','{\"title\":\"Private address\"}'); INSERT INTO audit VALUES('event','one','profile.update','one','Sensitive note','2026-01-01');",
  );
  const bucket = {
    list: vi.fn(async () => ({
      objects: [{ key: "profile/one/late-upload" }],
      truncated: false,
    })),
    delete: vi.fn(async () => {}),
  };
  const env = { DB: db.DB, UPLOADS: bucket as unknown as R2Bucket };
  const user: User = {
    id: "one",
    name: "Sensitive name",
    email: "one@example.test",
    role: "member",
    identity: "pending",
  };
  return { ...db, bucket, env, user };
}
describe("durable account erasure", () => {
  it("redacts content atomically, fences late writers and preserves the receipt after cleanup failure", async () => {
    const { sql, env, user, bucket } = fixture();
    await beginAccountDeletion(env, user, "ab".repeat(32));
    expect(sql.prepare("SELECT name,email,bio FROM users").get()).toMatchObject(
      { name: "Deleted member", bio: "" },
    );
    expect(sql.prepare("SELECT reason FROM audit").get()?.reason).toBe(
      "[Removed after account deletion]",
    );
    expect(() =>
      sql.prepare("UPDATE users SET name='restored' WHERE id='one'").run(),
    ).toThrow("Account deleted");
    expect(() =>
      sql
        .prepare(
          "INSERT INTO profile_media VALUES('late','one','photo','image/png','profile/one/late','today')",
        )
        .run(),
    ).toThrow("Account deleted");
    expect(() =>
      sql
        .prepare(
          "INSERT INTO password_sessions VALUES('new','one',9999999999999)",
        )
        .run(),
    ).toThrow("Account deleted");
    expect(() =>
      sql.prepare("UPDATE audit SET reason='tampered'").run(),
    ).toThrow("append-only");
    const job = sql.prepare("SELECT * FROM account_deletions").get()!;
    const typed = {
      userId: "one",
      requestedAt: Number(job.requestedAt),
      completedAt: null,
      resources: String(job.resources),
    };
    bucket.delete.mockRejectedValueOnce(new Error("Storage offline"));
    await expect(
      processAccountDeletion(env, typed, typed.requestedAt + 1800000),
    ).rejects.toThrow("Storage offline");
    expect(
      sql.prepare("SELECT completedAt FROM account_deletions").get()
        ?.completedAt,
    ).toBeNull();
    await processAccountDeletion(env, typed, typed.requestedAt + 1800000);
    expect(
      sql.prepare("SELECT completedAt FROM account_deletions").get()
        ?.completedAt,
    ).not.toBeNull();
    expect(JSON.parse(String(job.resources))).toContainEqual({
      key: "place/",
      prefix: 1,
    });
    expect(
      sql.prepare("SELECT resources FROM account_deletions").get()?.resources,
    ).toBe(job.resources);
    sql.close();
  });
});
