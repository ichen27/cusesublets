import { describe, it, expect } from "vitest";
import { validateTourResult } from "../shared/room-tour";
const result = {
  method: "ARKit + Brush",
  views: 60,
  gaussians: 500,
  camera: { position: [0, 0, 0], target: [0, 0, -1], up: [0, 1, 0] },
};
describe("tour metadata", () => {
  it("requires bounded finite Gaussian output and a usable camera", () => {
    expect(validateTourResult(result)).toEqual(result);
    for (const bad of [
      { ...result, views: 2 },
      { ...result, gaussians: 0 },
      { ...result, gaussians: 500001 },
      { ...result, camera: { ...result.camera, target: [0, 0, 0] } },
      { ...result, camera: { ...result.camera, up: [0, 0, 0] } },
      { ...result, camera: { ...result.camera, position: [NaN, 0, 0] } },
    ])
      expect(() => validateTourResult(bad)).toThrow();
  });
  it("does not forward processor diagnostic paths or extra fields", () => {
    expect(
      validateTourResult({ ...result, privatePath: "/private/job/log" }),
    ).toEqual(result);
  });
});

import { finishTourDeletion } from "../worker/room-tours";
import { vi } from "vitest";
it("retains the deletion record across object storage failure and retries cleanup", async () => {
  const list = vi
    .fn<R2Bucket["list"]>()
    .mockRejectedValueOnce(new Error("Storage unavailable"))
    .mockResolvedValue({
      objects: [],
      truncated: false,
      delimitedPrefixes: [],
    });
  const remove = vi.fn<R2Bucket["delete"]>();
  const finish = vi.fn(async () => {});
  await expect(
    finishTourDeletion({ list, delete: remove }, "tours/example/", finish),
  ).rejects.toThrow("Storage unavailable");
  expect(finish).not.toHaveBeenCalled();
  await finishTourDeletion({ list, delete: remove }, "tours/example/", finish);
  expect(finish).toHaveBeenCalledOnce();
});

it("a retained deletion record sweeps a late upload after its immediate cleanup fails", async () => {
  const objects = new Set<string>();
  const object = (key: string): R2Object => ({
    key,
    version: "v1",
    size: 1,
    etag: "a",
    httpEtag: '"a"',
    uploaded: new Date(),
    checksums: { toJSON: () => ({}) },
    storageClass: "Standard",
    writeHttpMetadata: () => {},
  });
  const list = vi
    .fn<R2Bucket["list"]>()
    .mockImplementation(async () => ({
      objects: [...objects].map(object),
      truncated: false,
      delimitedPrefixes: [],
    }));
  const remove = vi
    .fn<R2Bucket["delete"]>()
    .mockImplementation(async (keys) => {
      for (const key of typeof keys === "string" ? [keys] : keys)
        objects.delete(key);
    });
  const retainedDeletion = "tours/example/";
  await finishTourDeletion(
    { list, delete: remove },
    retainedDeletion,
    async () => {},
  );
  // A writer that started before the first sweep finishes after it.
  objects.add(retainedDeletion + "late-input");
  remove.mockRejectedValueOnce(new Error("Transient cleanup failure"));
  await expect(remove([...objects])).rejects.toThrow(
    "Transient cleanup failure",
  );
  await finishTourDeletion(
    { list, delete: remove },
    retainedDeletion,
    async () => {},
  );
  expect(objects.size).toBe(0);
});
