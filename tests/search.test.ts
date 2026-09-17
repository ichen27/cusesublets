import { describe, it, expect } from "vitest";
import { filterListings, listingsInBounds } from "../src/search";
import type { Listing } from "../shared/types";
const base = {
  title: "Sunny room",
  neighborhood: "Westcott",
  description: "Furnished",
  price: 800,
  roomType: "Private room",
  startDate: "2027-01-01",
  endDate: "2027-06-01",
  amenities: ["Furnished"],
  leaseStatus: "verified",
  permissionStatus: "verified",
} as Listing;
describe("discovery filters", () => {
  it("matches neighborhood and ignores case", () =>
    expect(filterListings([base], { query: "WESTCOTT" })).toHaveLength(1));
  it("excludes unaffordable rooms", () =>
    expect(filterListings([base], { maxPrice: 750 })).toHaveLength(0));
  it("requires listing to cover requested stay", () =>
    expect(
      filterListings([base], {
        startDate: "2026-12-01",
        endDate: "2027-03-01",
      }),
    ).toHaveLength(0));
  it("combines room type and amenities", () =>
    expect(
      filterListings([base], { roomType: "Entire place", furnished: true }),
    ).toHaveLength(0));
  it("requires both reviews for reviewed-only filter", () =>
    expect(
      filterListings([{ ...base, permissionStatus: "pending" }], {
        verified: true,
      }),
    ).toHaveLength(0));
});

it("excludes expired listings for move-in-only searches", () =>
  expect(filterListings([base], { startDate: "2028-01-01" })).toHaveLength(0));
it("excludes future listings for move-out-only searches", () =>
  expect(filterListings([base], { endDate: "2026-12-01" })).toHaveLength(0));
it("rejects inverted date intervals", () =>
  expect(
    filterListings([base], { startDate: "2027-05-01", endDate: "2027-02-01" }),
  ).toHaveLength(0));

describe("visible map results", () => {
  const homes = [
    { ...base, id: "west", lat: 43.04, lng: -76.15 },
    { ...base, id: "campus", lat: 43.04, lng: -76.13 },
    { ...base, id: "east", lat: 43.04, lng: -76.11 },
  ];
  it("shows all candidates before the map is visible", () => {
    expect(listingsInBounds(homes, null)).toEqual(homes);
  });
  it("narrows when zooming and restores candidates when zooming out", () => {
    expect(
      listingsInBounds(homes, {
        south: 43.03,
        north: 43.05,
        west: -76.14,
        east: -76.12,
      }).map((l) => l.id),
    ).toEqual(["campus"]);
    expect(
      listingsInBounds(homes, {
        south: 43,
        north: 43.1,
        west: -76.2,
        east: -76.1,
      }),
    ).toHaveLength(3);
  });
  it("includes markers on viewport boundaries", () => {
    expect(
      listingsInBounds(homes, {
        south: 43.04,
        north: 43.04,
        west: -76.15,
        east: -76.13,
      }),
    ).toHaveLength(2);
  });
  it("preserves budget filtering within the visible area", () => {
    const eligible = filterListings([...homes, { ...homes[1], price: 2000 }], {
      maxPrice: 900,
    });
    expect(
      listingsInBounds(eligible, {
        south: 43,
        north: 44,
        west: -77,
        east: -76,
      }),
    ).toHaveLength(3);
  });
});
