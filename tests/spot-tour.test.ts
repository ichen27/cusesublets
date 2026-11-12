import { describe, it, expect, vi } from "vitest";
import { validateSpotTourResult, SPOT_TOUR_LIMIT } from "../shared/spot-tour";
import { TOUR_LIMIT } from "../shared/room-tour";
import { roomTourRoute, tourProcessorRoute } from "../worker/room-tours";
import { testDatabase } from "./sqlite-d1";
import type { User } from "../shared/types";

const spot = (n: number, offset: number, length = 1000) => ({
  spot: n,
  position: [0.5 * n, 0.1, -1] as [number, number, number],
  floorY: -1.4,
  panorama: { offset, length, width: 4096, height: 2048 },
});
const result = {
  method: "ARKit slices + stitching",
  spots: [spot(1, 512), spot(2, 2048)],
  slices: 58,
};

describe("spot tour result contract", () => {
  it("accepts a valid result", () => {
    expect(validateSpotTourResult(result, 4096)).toEqual(result);
  });
  it("rejects zero or nine spots", () => {
    expect(() => validateSpotTourResult({ ...result, spots: [] }, 4096)).toThrow();
    const nine = Array.from({ length: 9 }, (_, i) => spot(i + 1, 512 * (i + 1) * 4, 512));
    expect(() => validateSpotTourResult({ ...result, spots: nine }, 1 << 20)).toThrow();
  });
  it("rejects duplicate spot numbers", () => {
    expect(() =>
      validateSpotTourResult({ ...result, spots: [spot(1, 512), spot(1, 2048)] }, 4096),
    ).toThrow();
  });
  it("rejects overlapping or out-of-bundle ranges", () => {
    expect(() =>
      validateSpotTourResult({ ...result, spots: [spot(1, 512, 2000), spot(2, 2048)] }, 4096),
    ).toThrow();
    expect(() => validateSpotTourResult(result, 3000)).toThrow();
  });
  it("rejects unaligned offsets, oversize panoramas and wrong dimensions", () => {
    expect(() =>
      validateSpotTourResult({ ...result, spots: [spot(1, 513)] }, 4096),
    ).toThrow();
    expect(() =>
      validateSpotTourResult({ ...result, spots: [spot(1, 512, 16 * 1024 * 1024 + 1)] }, 1 << 26),
    ).toThrow();
    expect(() =>
      validateSpotTourResult(
        { ...result, spots: [{ ...spot(1, 512), panorama: { offset: 512, length: 10, width: 100, height: 50 } }] },
        4096,
      ),
    ).toThrow();
  });
  it("rejects non-finite or huge coordinates", () => {
    expect(() =>
      validateSpotTourResult({ ...result, spots: [{ ...spot(1, 512), position: [NaN, 0, 0] }] }, 4096),
    ).toThrow();
    expect(() =>
      validateSpotTourResult({ ...result, spots: [{ ...spot(1, 512), floorY: 1e6 }] }, 4096),
    ).toThrow();
  });
  it("drops extra fields", () => {
    const extra = {
      ...result,
      privatePath: "/private/job",
      spots: [{ ...spot(1, 512), debug: "x", panorama: { ...spot(1, 512).panorama, key: "r2" } }],
    };
    expect(validateSpotTourResult(extra, 4096)).toEqual({ ...result, spots: [spot(1, 512)] });
  });
});

function fixture() {
  const db = testDatabase();
  db.sql.exec(
    "INSERT INTO users(id,name,email) VALUES('one','Owner','one@example.test'); INSERT OR IGNORE INTO schools VALUES('syracuse','Syracuse'); INSERT INTO listings(id,ownerId,status,data) VALUES('place','one','approved','{}');",
  );
  const objects = new Map<string, Uint8Array>();
  const bucket = {
    put: vi.fn(async (key: string, body: ReadableStream) => {
      objects.set(key, new Uint8Array(await new Response(body).arrayBuffer()));
    }),
    get: vi.fn(async (key: string, options?: { range?: { offset: number; length: number } }) => {
      const data = objects.get(key);
      if (!data) return null;
      const part = options?.range
        ? data.slice(options.range.offset, options.range.offset + options.range.length)
        : data;
      return { body: new Blob([part.slice().buffer as ArrayBuffer]).stream(), size: part.length };
    }),
    delete: vi.fn(async (key: string) => void objects.delete(key)),
  };
  const env = {
    DB: db.DB,
    UPLOADS: bucket as unknown as R2Bucket,
    TOUR_PROCESSOR_TOKEN: "x".repeat(40),
  };
  const user: User = { id: "one", name: "Owner", email: "one@example.test", role: "member", identity: "pending" };
  return { ...db, env, user, objects };
}
const create = (env: ReturnType<typeof fixture>["env"], user: User, body: object) =>
  roomTourRoute(
    new Request("https://app.test/api/listings/place/tours", {
      method: "POST",
      body: JSON.stringify(body),
    }),
    env,
    user,
  );
const capture = (size: number, kind?: string) => ({
  id: crypto.randomUUID(),
  name: "Bedroom",
  size,
  sha256: "a".repeat(64),
  ...(kind ? { kind } : {}),
});

describe("tour kinds", () => {
  it("create caps splat at 64 MB and spots at 96 MB", async () => {
    const { env, user } = fixture();
    await expect(create(env, user, capture(TOUR_LIMIT + 1))).rejects.toMatchObject({
      status: 413,
      message: "Choose a capture under 64 MB",
    });
    const spots = await create(env, user, capture(TOUR_LIMIT + 1, "spots"));
    expect(spots!.status).toBe(201);
    expect(((await spots!.json()) as { tour: { kind: string } }).tour.kind).toBe("spots");
    await expect(create(env, user, capture(SPOT_TOUR_LIMIT + 1, "spots"))).rejects.toMatchObject({
      status: 413,
      message: "Choose a capture under 96 MB",
    });
  });
  it("defaults to splat and rejects unknown kinds", async () => {
    const { env, user } = fixture();
    const splat = await create(env, user, capture(1000));
    expect(((await splat!.json()) as { tour: { kind: string } }).tour.kind).toBe("splat");
    await expect(create(env, user, capture(1000, "mesh"))).rejects.toMatchObject({ status: 400 });
  });
  it("claim reports the job's kind", async () => {
    const { env, user, sql } = fixture();
    const body = capture(1000, "spots");
    await create(env, user, body);
    sql.prepare("UPDATE room_tours SET status='queued',inputKey='k' WHERE id=?").run(body.id);
    const response = await tourProcessorRoute(
      new Request("https://app.test/api/tour-processor/claim", {
        method: "POST",
        headers: { Authorization: "Bearer " + "x".repeat(40), Origin: "https://app.test" },
        body: "{}",
      }),
      env,
    );
    expect(((await response!.json()) as { job: { kind: string } }).job.kind).toBe("spots");
  });
  it("serves one panorama per spot from the bundle by byte range", async () => {
    const { env, user, sql, objects } = fixture();
    const body = capture(1000, "spots");
    await create(env, user, body);
    const bundle = new Uint8Array(4096);
    bundle.set([0xff, 0xd8, 1, 2], 512);
    bundle.set([0xff, 0xd8, 3, 4], 2048);
    objects.set("tours/bundle", bundle);
    const stored = { ...result, spots: [spot(1, 512, 4), spot(2, 2048, 4)] };
    sql
      .prepare("UPDATE room_tours SET status='ready',modelKey='tours/bundle',result=? WHERE id=?")
      .run(JSON.stringify(stored), body.id);
    const get = (n: string, who: User | null) =>
      roomTourRoute(
        new Request(`https://app.test/api/listings/place/tours/${body.id}/panorama/${n}`),
        env,
        who,
      );
    const second = await get("2", user);
    expect(second!.headers.get("Content-Type")).toBe("image/jpeg");
    expect([...new Uint8Array(await second!.arrayBuffer())]).toEqual([0xff, 0xd8, 3, 4]);
    await expect(get("7", user)).rejects.toMatchObject({ status: 404 });
    // Unpublished tours stay private to the owner.
    await expect(get("1", null)).rejects.toMatchObject({ status: 404 });
    sql.prepare("UPDATE room_tours SET published=1 WHERE id=?").run(body.id);
    expect((await get("1", null))!.status).toBe(200);
  });
  it("splat tours have no panoramas", async () => {
    const { env, user, sql } = fixture();
    const body = capture(1000);
    await create(env, user, body);
    sql.prepare("UPDATE room_tours SET status='ready',modelKey='m' WHERE id=?").run(body.id);
    await expect(
      roomTourRoute(
        new Request(`https://app.test/api/listings/place/tours/${body.id}/panorama/0`),
        env,
        user,
      ),
    ).rejects.toMatchObject({ status: 404 });
  });
});
