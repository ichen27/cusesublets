export const TOUR_LIMIT = 64 * 1024 * 1024;
export type TourStatus =
  "uploading" | "queued" | "processing" | "ready" | "failed";
export interface TourResult {
  method: string;
  views: number;
  gaussians: number;
  camera: { position: number[]; target: number[]; up: number[] };
}
export interface RoomTour {
  id: string;
  listingId: string;
  name: string;
  status: TourStatus;
  published: boolean;
  createdAt: string;
  result: TourResult | null;
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
