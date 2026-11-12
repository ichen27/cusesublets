// Spot tours: one stitched 360° panorama per capture spot, served from a single bundle.
export type TourKind = "splat" | "spots";
export const TOUR_KINDS: readonly TourKind[] = ["splat", "spots"];
export const SPOT_TOUR_LIMIT = 96 * 1024 * 1024;
export const MAX_SPOTS = 8;
export const PANORAMA_WIDTH = 4096;
export const PANORAMA_HEIGHT = 2048;
export const PANORAMA_LIMIT = 16 * 1024 * 1024;

export interface SpotPanorama {
  /** Byte offset of the JPEG inside the bundle object; USTAR data starts on 512-byte blocks. */
  offset: number;
  length: number;
  width: typeof PANORAMA_WIDTH;
  height: typeof PANORAMA_HEIGHT;
}
export interface TourSpot {
  spot: number;
  /** Where the camera stood, ARKit world metres (+Y up). */
  position: [number, number, number];
  floorY: number;
  panorama: SpotPanorama;
}
export interface SpotTourResult {
  method: string;
  spots: TourSpot[];
  slices: number;
}

const finite = (n: unknown): n is number =>
  typeof n === "number" && Number.isFinite(n) && Math.abs(n) < 10000;
const integer = (n: unknown, min: number, max: number): n is number =>
  Number.isInteger(n) && (n as number) >= min && (n as number) <= max;

// The processor builds the bundle; this bounds what the API stores and serves from it.
export function validateSpotTourResult(value: unknown, bundleSize: number): SpotTourResult {
  const r = value as Partial<SpotTourResult> | null;
  if (
    !r ||
    typeof r.method !== "string" ||
    r.method.length < 1 ||
    r.method.length > 180 ||
    !integer(r.slices, 1, MAX_SPOTS * 64) ||
    !Array.isArray(r.spots) ||
    r.spots.length < 1 ||
    r.spots.length > MAX_SPOTS
  )
    throw new Error("Invalid spot tour result");
  const seen = new Set<number>();
  const spots = r.spots.map((value): TourSpot => {
    const s = value as Partial<TourSpot> | null;
    const p = s?.panorama as Partial<SpotPanorama> | undefined;
    if (
      !s ||
      !integer(s.spot, 0, 99) ||
      seen.has(s.spot) ||
      !Array.isArray(s.position) ||
      s.position.length !== 3 ||
      !s.position.every(finite) ||
      !finite(s.floorY) ||
      !p ||
      !integer(p.offset, 512, bundleSize) ||
      p.offset % 512 !== 0 ||
      !integer(p.length, 1, PANORAMA_LIMIT) ||
      p.offset + p.length > bundleSize ||
      p.width !== PANORAMA_WIDTH ||
      p.height !== PANORAMA_HEIGHT
    )
      throw new Error("Invalid spot");
    seen.add(s.spot);
    return {
      spot: s.spot,
      position: [s.position[0], s.position[1], s.position[2]],
      floorY: s.floorY,
      panorama: { offset: p.offset, length: p.length, width: PANORAMA_WIDTH, height: PANORAMA_HEIGHT },
    };
  });
  const ranges = spots.map((s) => s.panorama).sort((a, b) => a.offset - b.offset);
  for (let i = 1; i < ranges.length; i++)
    if (ranges[i - 1].offset + ranges[i - 1].length > ranges[i].offset)
      throw new Error("Overlapping panoramas");
  return { method: r.method, spots, slices: r.slices };
}
