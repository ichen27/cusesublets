import { describe, it, expect } from "vitest";
import {
  CIRCLE_RANGE,
  PICK_RADIUS,
  clampPitch,
  floorHit,
  lookDirection,
  nearbySpots,
  overviewBounds,
  pickSpot,
} from "../src/spot-viewer-math";
import type { TourSpot } from "../shared/spot-tour";

const spot = (n: number, x: number, z: number, y = 0): TourSpot => ({
  spot: n,
  position: [x, y, z],
  floorY: -1.4,
  panorama: { offset: 512 * n, length: 10, width: 4096, height: 2048 },
});

describe("spot viewer geometry", () => {
  it("lists other spots within range, nearest first", () => {
    const here = spot(1, 0, 0);
    const spots = [here, spot(2, 4, 0), spot(3, 1, 1), spot(4, CIRCLE_RANGE + 0.1, 0)];
    expect(nearbySpots(here, spots).map((s) => s.spot)).toEqual([3, 2]);
  });
  it("measures range horizontally only", () => {
    const here = spot(1, 0, 0);
    expect(nearbySpots(here, [here, spot(2, 5.9, 0, 3)]).map((s) => s.spot)).toEqual([2]);
  });
  it("hits the floor in front of a downward ray", () => {
    const hit = floorHit([0, 0, 0], [0, -1, -1], -1.4)!;
    expect(hit[0]).toBeCloseTo(0);
    expect(hit[1]).toBeCloseTo(-1.4);
    expect(hit[2]).toBeCloseTo(-1.4);
  });
  it("misses the floor at or above the horizon", () => {
    expect(floorHit([0, 0, 0], [0, 0, -1], -1.4)).toBeNull();
    expect(floorHit([0, 0, 0], [0, 0.2, -1], -1.4)).toBeNull();
  });
  it("picks the nearest circle within the pick radius", () => {
    const candidates = [spot(2, 1, 0), spot(3, 1.2, 0)];
    expect(pickSpot([1.15, -1.4, 0], candidates)?.spot).toBe(3);
    expect(pickSpot([1 - PICK_RADIUS + 0.01, -1.4, 0], candidates)?.spot).toBe(2);
    expect(pickSpot([1 - PICK_RADIUS - 0.01, -1.4, 0], candidates)).toBeNull();
  });
  it("faces −Z at yaw 0 and turns clockwise towards +X", () => {
    const ahead = lookDirection(0, 0);
    expect(ahead[0]).toBeCloseTo(0);
    expect(ahead[1]).toBeCloseTo(0);
    expect(ahead[2]).toBeCloseTo(-1);
    const right = lookDirection(Math.PI / 2, 0);
    expect(right[0]).toBeCloseTo(1);
    expect(lookDirection(0, Math.PI / 2)[1]).toBeCloseTo(1);
  });
  it("clamps pitch to ±85°", () => {
    const limit = (85 * Math.PI) / 180;
    expect(clampPitch(2)).toBeCloseTo(limit);
    expect(clampPitch(-2)).toBeCloseTo(-limit);
    expect(clampPitch(0.3)).toBe(0.3);
  });
  it("frames the mesh bounds when there is a mesh", () => {
    const b = overviewBounds([spot(1, 0, 0)], {
      method: "m",
      views: 30,
      vertices: 3,
      triangles: 1,
      voxel: 0.02,
      bounds: [
        [-2, -1.4, -3],
        [2, 1, 1],
      ],
    });
    [0, -0.2, -1].forEach((v, i) => expect(b.center[i]).toBeCloseTo(v));
    expect(b.size).toBeCloseTo(4);
  });
  it("falls back to the spots, with a minimum size, without a mesh", () => {
    const b = overviewBounds([spot(1, 0, 0), spot(2, 2, 0)], null);
    expect(b.center[0]).toBeCloseTo(1);
    expect(b.center[1]).toBeCloseTo(-1.4);
    expect(b.size).toBeGreaterThanOrEqual(3);
  });
});
