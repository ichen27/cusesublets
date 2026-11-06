export const TOUR_LIMIT = 64 * 1024 * 1024;
export type TourStatus =
  "uploading" | "queued" | "processing" | "ready" | "failed" | "deleting";
export interface TourResult {
  method: string;
  views: number;
  gaussians: number;
  camera: { position: number[]; target: number[]; up: number[] };
}
export interface TourMesh {
  method: string;
  views: number;
  vertices: number;
  triangles: number;
  voxel: number;
  bounds: [number[], number[]];
}
export const MESH_LIMITS = { vertices: 2_000_000, triangles: 1_000_000 };
export interface RoomTour {
  id: string;
  listingId: string;
  name: string;
  status: TourStatus;
  published: boolean;
  createdAt: string;
  result: TourResult | null;
  /** Coloured PLY mesh in ARKit world coordinates, when processing built one. */
  mesh: TourMesh | null;
  error: string | null;
}
// The processor validates the PLY itself; this is the bounded display metadata contract.
export function validateTourResult(value: unknown): TourResult {
  const r = value as Partial<TourResult> | null;
  if (
    !r ||
    typeof r.method !== "string" ||
    r.method.length < 1 ||
    r.method.length > 180 ||
    !Number.isInteger(r.views) ||
    r.views! < 30 ||
    r.views! > 180 ||
    !Number.isInteger(r.gaussians) ||
    r.gaussians! < 1 ||
    r.gaussians! > 500000
  ) {
    throw new Error("Invalid reconstruction result");
  }
  const c = r.camera;
  if (
    !c ||
    ![c.position, c.target, c.up].every(
      (v) =>
        Array.isArray(v) &&
        v.length === 3 &&
        v.every(
          (n) =>
            typeof n === "number" && Number.isFinite(n) && Math.abs(n) < 10000,
        ),
    )
  ) {
    throw new Error("Invalid reconstruction camera");
  }
  if (
    Math.hypot(...c.up) < 0.01 ||
    Math.hypot(...c.position.map((n, i) => n - c.target[i])) < 0.01
  )
    throw new Error("Invalid reconstruction camera");
  return {
    method: r.method,
    views: r.views!,
    gaussians: r.gaussians!,
    camera: c,
  };
}

const finite = (n: unknown): n is number =>
  typeof n === "number" && Number.isFinite(n) && Math.abs(n) < 10000;
const count = (n: unknown, max: number): n is number =>
  Number.isInteger(n) && (n as number) >= 1 && (n as number) <= max;

// The processor writes and checks the PLY; this is the bounded display metadata contract.
export function validateTourMesh(value: unknown): TourMesh {
  const m = value as Partial<TourMesh> | null;
  if (
    !m ||
    typeof m.method !== "string" ||
    m.method.length < 1 ||
    m.method.length > 180 ||
    !count(m.views, 180) ||
    !count(m.vertices, MESH_LIMITS.vertices) ||
    !count(m.triangles, MESH_LIMITS.triangles) ||
    !finite(m.voxel) ||
    m.voxel < 0.005 ||
    m.voxel > 0.2
  )
    throw new Error("Invalid mesh result");
  const b = m.bounds;
  if (
    !Array.isArray(b) ||
    b.length !== 2 ||
    !b.every((c) => Array.isArray(c) && c.length === 3 && c.every(finite)) ||
    b[0].some((n, i) => n > b[1][i])
  )
    throw new Error("Invalid mesh bounds");
  return {
    method: m.method,
    views: m.views,
    vertices: m.vertices,
    triangles: m.triangles,
    voxel: m.voxel,
    bounds: [[...b[0]], [...b[1]]],
  };
}
