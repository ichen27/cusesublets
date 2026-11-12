import { describe, it, expect } from "vitest";
import { parsePly } from "../src/ply";
import { panoramaOrder, panoramaUrl, viewerModes, firstSpot } from "../src/spot-viewer-state";
import type { TourSpot } from "../shared/spot-tour";

const spot = (n: number, x: number): TourSpot => ({
  spot: n,
  position: [x, 0, 0],
  floorY: -1.4,
  panorama: { offset: 512 * n, length: 10, width: 4096, height: 2048 },
});

function ply(vertices: [number, number, number, number, number, number][], faces: number[][]) {
  const header = new TextEncoder().encode(
    "ply\nformat binary_little_endian 1.0\ncomment x\n" +
      `element vertex ${vertices.length}\nproperty float x\nproperty float y\nproperty float z\n` +
      "property uchar red\nproperty uchar green\nproperty uchar blue\n" +
      `element face ${faces.length}\nproperty list uchar int vertex_indices\nend_header\n`,
  );
  const body = new DataView(new ArrayBuffer(vertices.length * 15 + faces.length * 13));
  let o = 0;
  for (const [x, y, z, r, g, b] of vertices) {
    body.setFloat32(o, x, true);
    body.setFloat32(o + 4, y, true);
    body.setFloat32(o + 8, z, true);
    body.setUint8(o + 12, r);
    body.setUint8(o + 13, g);
    body.setUint8(o + 14, b);
    o += 15;
  }
  for (const f of faces) {
    body.setUint8(o, 3);
    f.forEach((v, i) => body.setInt32(o + 1 + 4 * i, v, true));
    o += 13;
  }
  const out = new Uint8Array(header.length + body.byteLength);
  out.set(header);
  out.set(new Uint8Array(body.buffer), header.length);
  return out.buffer;
}

describe("spot viewer state", () => {
  it("loads the current panorama first, then nearby spots nearest first", () => {
    const spots = [spot(1, 0), spot(2, 4), spot(3, 1), spot(4, 20)];
    expect(panoramaOrder(spots[0], spots).map((s) => s.spot)).toEqual([1, 3, 2]);
  });
  it("starts at the lowest-numbered spot", () => {
    expect(firstSpot([spot(3, 0), spot(1, 1), spot(2, 2)])?.spot).toBe(1);
    expect(firstSpot([])).toBeNull();
  });
  it("builds encoded same-origin panorama URLs", () => {
    expect(panoramaUrl("a b", "t/1", 2)).toBe("/api/listings/a%20b/tours/t%2F1/panorama/2");
  });
  it("offers 3D only when the tour has a mesh", () => {
    expect(viewerModes(true)).toEqual(["3D", "Plan", "Walk"]);
    expect(viewerModes(false)).toEqual(["Plan", "Walk"]);
  });
});

describe("binary PLY parsing", () => {
  it("reads positions, colours and triangle indices", () => {
    const mesh = parsePly(
      ply(
        [
          [0, 0, 0, 255, 0, 0],
          [1, 0, 0, 0, 255, 0],
          [0, 1, -2, 0, 0, 255],
        ],
        [[0, 1, 2]],
      ),
    );
    expect(Array.from(mesh.positions)).toEqual([0, 0, 0, 1, 0, 0, 0, 1, -2]);
    expect(Array.from(mesh.colors.slice(0, 4))).toEqual([255, 0, 0, 255]);
    expect(Array.from(mesh.indices)).toEqual([0, 1, 2]);
  });
  it("rejects other formats and out-of-range indices", () => {
    const ascii = new TextEncoder().encode("ply\nformat ascii 1.0\nend_header\n").buffer;
    expect(() => parsePly(ascii)).toThrow();
    expect(() => parsePly(ply([[0, 0, 0, 1, 1, 1]], [[0, 0, 5]]))).toThrow();
    expect(() => parsePly(ply([[0, 0, 0, 1, 1, 1]], [[0, 0, 0]]).slice(0, 60))).toThrow();
  });
});
