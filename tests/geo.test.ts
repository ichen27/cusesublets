import { describe, expect, it } from "vitest";
import { areasIntersectBounds, pointInAnyArea, validateAreas, type SearchArea } from "../shared/geo";

const area: SearchArea = {
  id: "near-campus",
  label: "Near campus",
  points: [
    { lat: 43.02, lng: -76.15 },
    { lat: 43.02, lng: -76.11 },
    { lat: 43.06, lng: -76.11 },
    { lat: 43.06, lng: -76.15 },
  ],
};

describe("search areas", () => {
  it("includes points inside or on the edge of a desired area", () => {
    expect(pointInAnyArea(43.04, -76.13, [area])).toBe(true);
    expect(pointInAnyArea(43.02, -76.13, [area])).toBe(true);
    expect(pointInAnyArea(43.09, -76.13, [area])).toBe(false);
  });

  it("detects edge crossings even when no area vertex is inside the viewport", () => {
    const viewport = { south: 43.03, north: 43.05, west: -76.17, east: -76.09 };
    expect(areasIntersectBounds([area], viewport)).toBe(true);
    expect(areasIntersectBounds([area, area], viewport)).toBe(true);
    expect(areasIntersectBounds([area], { south: 43.08, north: 43.1, west: -76.17, east: -76.09 })).toBe(false);
  });

  it("validates geometry and limits", () => {
    expect(validateAreas([area])).toEqual([area]);
    expect(() => validateAreas([])).toThrow();
    expect(() => validateAreas(Array(6).fill(area))).toThrow();
    expect(() => validateAreas([{ ...area, label: " " }])).toThrow();
    expect(() => validateAreas([{ ...area, points: area.points.slice(0, 2) }])).toThrow();
    expect(() => validateAreas([{ ...area, points: [...area.points, area.points[0]] }])).toThrow();
    expect(() => validateAreas([{ ...area, points: [{ lat: 100, lng: -76.12 }, ...area.points.slice(1)] }])).toThrow();
    expect(() => validateAreas([{ ...area, points: [
      { lat: 43.02, lng: -76.15 }, { lat: 43.06, lng: -76.11 },
      { lat: 43.02, lng: -76.11 }, { lat: 43.06, lng: -76.15 },
    ] }])).toThrow();
  });
});
