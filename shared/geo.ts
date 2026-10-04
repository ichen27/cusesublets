export interface GeoPoint { lat: number; lng: number }
export interface GeoBounds { south: number; north: number; west: number; east: number }
export interface SearchArea { id: string; label: string; points: GeoPoint[] }

export const SERVICE_BOUNDS: GeoBounds = {
  south: 42.9,
  north: 43.15,
  west: -76.3,
  east: -75.95,
};

const EPS = 1e-10;
function cross(a: GeoPoint, b: GeoPoint, c: GeoPoint): number {
  return (b.lng - a.lng) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lng - a.lng);
}
function onSegment(a: GeoPoint, b: GeoPoint, p: GeoPoint): boolean {
  return Math.abs(cross(a, b, p)) < EPS &&
    p.lat >= Math.min(a.lat, b.lat) - EPS && p.lat <= Math.max(a.lat, b.lat) + EPS &&
    p.lng >= Math.min(a.lng, b.lng) - EPS && p.lng <= Math.max(a.lng, b.lng) + EPS;
}
function segmentsIntersect(a: GeoPoint, b: GeoPoint, c: GeoPoint, d: GeoPoint): boolean {
  const abC = cross(a, b, c), abD = cross(a, b, d);
  const cdA = cross(c, d, a), cdB = cross(c, d, b);
  if (Math.abs(abC) < EPS && onSegment(a, b, c)) return true;
  if (Math.abs(abD) < EPS && onSegment(a, b, d)) return true;
  if (Math.abs(cdA) < EPS && onSegment(c, d, a)) return true;
  if (Math.abs(cdB) < EPS && onSegment(c, d, b)) return true;
  return (abC > 0) !== (abD > 0) && (cdA > 0) !== (cdB > 0);
}
function pointInPolygon(point: GeoPoint, polygon: GeoPoint[]): boolean {
  let inside = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const a = polygon[j], b = polygon[i];
    if (onSegment(a, b, point)) return true;
    if ((a.lat > point.lat) !== (b.lat > point.lat) &&
      point.lng < (b.lng - a.lng) * (point.lat - a.lat) / (b.lat - a.lat) + a.lng) inside = !inside;
  }
  return inside;
}
function inBounds(point: GeoPoint, bounds: GeoBounds): boolean {
  return point.lat >= bounds.south && point.lat <= bounds.north &&
    point.lng >= bounds.west && point.lng <= bounds.east;
}
export function validateAreas(input: unknown): SearchArea[] {
  if (!Array.isArray(input) || input.length < 1 || input.length > 5) throw new Error("Select between 1 and 5 areas.");
  const ids = new Set<string>();
  return input.map((item: unknown) => {
    if (!item || typeof item !== "object") throw new Error("Invalid area.");
    const area = item as Record<string, unknown>;
    if (typeof area.id !== "string" || !area.id.trim() || area.id.length > 80 || ids.has(area.id)) throw new Error("Invalid area ID.");
    ids.add(area.id);
    if (typeof area.label !== "string" || !area.label.trim() || area.label.length > 80) throw new Error("Give each area a short label.");
    if (!Array.isArray(area.points) || area.points.length < 3 || area.points.length > 25) throw new Error("Each area needs 3 to 25 points.");
    const points = area.points.map((raw: unknown) => {
      if (!raw || typeof raw !== "object") throw new Error("Invalid map point.");
      const p = raw as Record<string, unknown>;
      if (typeof p.lat !== "number" || typeof p.lng !== "number" || !Number.isFinite(p.lat) || !Number.isFinite(p.lng) ||
          !inBounds({ lat: p.lat, lng: p.lng }, SERVICE_BOUNDS)) throw new Error("Area points must be inside the Syracuse service area.");
      return { lat: p.lat, lng: p.lng };
    });
    for (let i = 0; i < points.length; i++) {
      if (points[i].lat === points[(i + 1) % points.length].lat && points[i].lng === points[(i + 1) % points.length].lng) {
        throw new Error("Area points must be distinct.");
      }
      for (let j = i + 1; j < points.length; j++) {
        if (j === i + 1 || (i === 0 && j === points.length - 1)) continue;
        if (segmentsIntersect(points[i], points[(i + 1) % points.length], points[j], points[(j + 1) % points.length])) {
          throw new Error("Area boundaries cannot cross.");
        }
      }
    }
    const twiceArea = points.reduce((sum, p, i) => {
      const next = points[(i + 1) % points.length];
      return sum + p.lng * next.lat - next.lng * p.lat;
    }, 0);
    if (Math.abs(twiceArea) < EPS) throw new Error("Area must enclose space.");
    return { id: area.id, label: area.label.trim(), points };
  });
}
export function pointInAnyArea(lat: number, lng: number, areas: SearchArea[]): boolean {
  return areas.some((area) => pointInPolygon({ lat, lng }, area.points));
}
export function areasIntersectBounds(areas: SearchArea[], bounds: GeoBounds): boolean {
  if (![bounds.south, bounds.north, bounds.west, bounds.east].every(Number.isFinite) ||
    bounds.south > bounds.north || bounds.west > bounds.east) return false;
  const corners: GeoPoint[] = [
    { lat: bounds.south, lng: bounds.west }, { lat: bounds.south, lng: bounds.east },
    { lat: bounds.north, lng: bounds.east }, { lat: bounds.north, lng: bounds.west },
  ];
  return areas.some(({ points }) => {
    if (points.some((point) => inBounds(point, bounds))) return true;
    if (corners.some((point) => pointInPolygon(point, points))) return true;
    for (let i = 0; i < points.length; i++) {
      for (let j = 0; j < corners.length; j++) {
        if (segmentsIntersect(points[i], points[(i + 1) % points.length], corners[j], corners[(j + 1) % corners.length])) return true;
      }
    }
    return false;
  });
}
