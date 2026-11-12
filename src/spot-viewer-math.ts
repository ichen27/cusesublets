// Geometry for the spot viewer. World is ARKit's: metres, +Y up, yaw 0 looks along −Z and
// positive yaw turns clockwise seen from above (towards +X), matching the panoramas.
import type { TourMesh } from "../shared/room-tour";
import type { TourSpot } from "../shared/spot-tour";

export type Vec3 = [number, number, number];
/** Floor circles are drawn for other spots up to this far away, in metres. */
export const CIRCLE_RANGE = 6;
/** A tap selects a circle whose centre is within this distance of the tapped floor point. */
export const PICK_RADIUS = 0.35;
const PITCH_LIMIT = (85 * Math.PI) / 180;

const horizontal = (a: Vec3, b: Vec3) => Math.hypot(a[0] - b[0], a[2] - b[2]);

export function nearbySpots(current: TourSpot, spots: TourSpot[]): TourSpot[] {
  return spots
    .filter((s) => s.spot !== current.spot)
    .map((s) => ({ s, d: horizontal(s.position, current.position) }))
    .filter(({ d }) => d <= CIRCLE_RANGE)
    .sort((a, b) => a.d - b.d)
    .map(({ s }) => s);
}

/** Where a view ray meets the floor plane, or null for rays at or above the horizon. */
export function floorHit(eye: Vec3, dir: Vec3, floorY: number): Vec3 | null {
  if (dir[1] >= -1e-6 || eye[1] <= floorY) return null;
  const t = (floorY - eye[1]) / dir[1];
  return [eye[0] + dir[0] * t, floorY, eye[2] + dir[2] * t];
}

export function pickSpot(hit: Vec3, candidates: TourSpot[]): TourSpot | null {
  let best: TourSpot | null = null;
  let bestDistance = PICK_RADIUS;
  for (const s of candidates) {
    const d = horizontal(hit, s.position);
    if (d <= bestDistance) {
      best = s;
      bestDistance = d;
    }
  }
  return best;
}

export function lookDirection(yaw: number, pitch: number): Vec3 {
  return [
    Math.cos(pitch) * Math.sin(yaw),
    Math.sin(pitch),
    -Math.cos(pitch) * Math.cos(yaw),
  ];
}

export const clampPitch = (p: number) => Math.max(-PITCH_LIMIT, Math.min(PITCH_LIMIT, p));

/** Centre and horizontal extent to frame in the overview: the mesh when there is one, else the spots. */
export function overviewBounds(
  spots: TourSpot[],
  mesh: TourMesh | null,
): { center: Vec3; size: number } {
  if (mesh) {
    const [low, high] = mesh.bounds;
    const center: Vec3 = [(low[0] + high[0]) / 2, (low[1] + high[1]) / 2, (low[2] + high[2]) / 2];
    return { center, size: Math.max(high[0] - low[0], high[2] - low[2], 1) };
  }
  const xs = spots.map((s) => s.position[0]);
  const zs = spots.map((s) => s.position[2]);
  const floor = spots.length ? Math.min(...spots.map((s) => s.floorY)) : 0;
  const center: Vec3 = [
    (Math.min(...xs) + Math.max(...xs)) / 2,
    floor,
    (Math.min(...zs) + Math.max(...zs)) / 2,
  ];
  const span = Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...zs) - Math.min(...zs));
  return { center, size: Math.max(span + 2, 3) };
}
