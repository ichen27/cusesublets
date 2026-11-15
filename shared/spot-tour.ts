// Spot tours: one stitched 360° panorama per capture spot, served from a single bundle.
export type TourKind = "splat" | "spots";
export const TOUR_KINDS: readonly TourKind[] = ["splat", "spots"];
export const SPOT_TOUR_LIMIT = 96 * 1024 * 1024;
export const MAX_SPOTS = 8;
/** Panoramas are equirectangular, twice as wide as high. 8192 is the current size; tours
 * stitched before the sharper capture are 4096. */
export const PANORAMA_WIDTHS: readonly number[] = [4096, 8192];
export const PANORAMA_WIDTH = 8192;
export const PANORAMA_HEIGHT = 4096;
export const PANORAMA_LIMIT = 16 * 1024 * 1024;

export interface SpotPanorama {
  /** Byte offset of the JPEG inside the bundle object; USTAR data starts on 512-byte blocks. */
  offset: number;
  length: number;
  width: number;
  height: number;
}
export interface TourSpot {
  spot: number;
  /** Where the camera stood, ARKit world metres (+Y up). */
  position: [number, number, number];
  floorY: number;
  /** Lowest and highest pitch, in degrees, that the spot photographed. Above and below it the
   * panorama is a soft fill. Absent on tours stitched before level-only capture. */
  band?: [number, number];
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
      !PANORAMA_WIDTHS.includes(p.width as number) ||
      p.height !== (p.width as number) / 2 ||
      (s.band !== undefined &&
        (!Array.isArray(s.band) ||
          s.band.length !== 2 ||
          !s.band.every((x) => typeof x === "number" && x >= -90 && x <= 90) ||
          s.band[0] >= s.band[1]))
    )
      throw new Error("Invalid spot");
    seen.add(s.spot);
    return {
      spot: s.spot,
      position: [s.position[0], s.position[1], s.position[2]],
      floorY: s.floorY,
      ...(s.band ? { band: [s.band[0], s.band[1]] as [number, number] } : {}),
      panorama: { offset: p.offset, length: p.length, width: p.width!, height: p.height! },
    };
  });
  const ranges = spots.map((s) => s.panorama).sort((a, b) => a.offset - b.offset);
  for (let i = 1; i < ranges.length; i++)
    if (ranges[i - 1].offset + ranges[i - 1].length > ranges[i].offset)
      throw new Error("Overlapping panoramas");
  return { method: r.method, spots, slices: r.slices };
}
