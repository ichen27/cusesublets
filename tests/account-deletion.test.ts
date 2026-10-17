import { describe, it, expect, vi } from "vitest";
import { testDatabase } from "./sqlite-d1";
import {
  beginAccountDeletion,
  processAccountDeletion,
  sweepAccountDeletions,
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

it("resumes bounded pages and requires a complete sweep begun after late uploads settle", async () => {
  const { sql, env, user, bucket } = fixture();
  try {
    await beginAccountDeletion(env, user, "cd".repeat(32));
    const resources = Array.from({ length: 17 }, (_, i) => ({
      key: `owned/${i}/`,
      prefix: true,
    }));
    sql
      .prepare("UPDATE account_deletions SET resources=?")
      .run(JSON.stringify(resources));
    const row = () => sql.prepare("SELECT * FROM account_deletions").get()!;
    const job = () => ({
      userId: "one",
      requestedAt: Number(row().requestedAt),
      completedAt: null,
      resources: String(row().resources),
      resourceIndex: Number(row().resourceIndex),
      passStartedAt: Number(row().passStartedAt),
    });
    const start = job().requestedAt;
    const files = new Set(resources.map((r) => r.key + "file"));
    bucket.list.mockImplementation(async (options?: { prefix: string }) => ({
      objects: [...files]
        .filter((k) => k.startsWith(options!.prefix))
        .map((key) => ({ key })),
      truncated: false,
    }));
    bucket.delete.mockImplementation(async (keys?: string | string[]) => {
      for (const key of Array.isArray(keys) ? keys : [keys!]) files.delete(key);
    });
    await processAccountDeletion(env, job(), start + 1);
    expect(row().resourceIndex).toBe(8);
    expect(bucket.list).toHaveBeenCalledTimes(8);
    bucket.delete.mockRejectedValueOnce(new Error("temporary failure"));
    await expect(
      processAccountDeletion(env, job(), start + 1000),
    ).rejects.toThrow("temporary failure");
    expect(row().resourceIndex).toBe(8);
    files.add("owned/0/late-upload");
    await processAccountDeletion(env, job(), start + 16 * 60000);
    await processAccountDeletion(env, job(), start + 17 * 60000);
    expect(row().completedAt).toBeNull(); // Finishing late does not make an early-started pass sufficient.
    expect(row().resourceIndex).toBe(0);
    expect(files.has("owned/0/late-upload")).toBe(true);
    for (let i = 0; i < 3; i++)
      await processAccountDeletion(env, job(), start + (32 + i) * 60000);
    expect(files.size).toBe(0);
    expect(row().completedAt).not.toBeNull();
  } finally {
    sql.close();
  }
});

it("leases a due job so overlapping schedulers do not both process it", async () => {
  const { sql, env, user, bucket } = fixture();
  try {
    await beginAccountDeletion(env, user, "ef".repeat(32));
    await Promise.all([sweepAccountDeletions(env), sweepAccountDeletions(env)]);
    expect(
      sql.prepare("SELECT attempts FROM account_deletions").get()?.attempts,
    ).toBe(1);
    expect(bucket.list).toHaveBeenCalledTimes(3);
  } finally {
    sql.close();
  }
});
