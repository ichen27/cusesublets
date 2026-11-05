import { describe, it, expect } from "vitest";
import { validateRoomLayout } from "../shared/room-scan";
const wall = () => ({
  kind: "wall",
  dimensions: [4, 2.4, 0],
  transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 2, 1],
});
describe("room layout boundary", () => {
  it("preserves metric geometry and strips unknown fields", () => {
    const r = validateRoomLayout({
      version: 1,
      elements: [{ ...wall(), identity: "verified" }],
      ownerId: "injected",
    });
    expect(r.elements[0].transform[12]).toBe(3);
    expect(r).not.toHaveProperty("ownerId");
    expect(r.elements[0]).not.toHaveProperty("identity");
  });
  it("rejects malformed, unbounded and non-affine geometry", () => {
    for (const change of [
      { dimensions: [Infinity, 2, 0] },
      { transform: [1, 2] },
      { kind: "script" },
      { dimensions: [-1, 2, 0] },
      { transform: [1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] },
    ])
      expect(() =>
        validateRoomLayout({
          version: 1,
          elements: [{ ...wall(), ...change }],
        }),
      ).toThrow();
  });
  it("requires walls and bounds scene complexity", () => {
    expect(() =>
      validateRoomLayout({
        version: 1,
        elements: [{ ...wall(), kind: "object" }],
      }),
    ).toThrow();
    expect(() =>
      validateRoomLayout({
        version: 1,
        elements: Array.from({ length: 301 }, wall),
      }),
    ).toThrow();
  });
});
