import { describe, it, expect } from "vitest";
import { filterListings } from "../src/search";
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
