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
