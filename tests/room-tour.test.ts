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
