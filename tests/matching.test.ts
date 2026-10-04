import { describe, expect, it } from "vitest";
import { matchListingToRequest } from "../shared/matching";
import type { Listing } from "../shared/types";

const listing = {
  id: "home-1", ownerId: "host-1", status: "approved", title: "Westcott room",
  neighborhood: "Westcott", price: 800, roomType: "Private room",
  startDate: "2027-01-01", endDate: "2027-05-31", amenities: ["Furnished", "Wi-Fi"],
} as Listing;
const request = {
  id: "request-1", ownerId: "seeker-1", status: "active" as const, title: "Spring room",
  neighborhood: "Westcott", maxBudget: 900, roomType: "Private room" as const,
  startDate: "2027-01-15", endDate: "2027-05-15", amenities: ["Furnished"],
};

describe("two-sided match ranking", () => {
  it("returns an explainable match when a listing covers the entire stay and budget", () => {
    const match = matchListingToRequest(listing, request);
    expect(match).not.toBeNull();
    expect(match?.reasons).toContain("Covers the full stay");
    expect(match?.reasons).toContain("Within budget");
    expect(match?.reasons).toContain("Preferred area");
  });
  it("does not suggest a listing that misses dates, exceeds budget, or belongs to the seeker", () => {
    expect(matchListingToRequest({ ...listing, endDate: "2027-04-01" }, request)).toBeNull();
    expect(matchListingToRequest({ ...listing, price: 950 }, request)).toBeNull();
    expect(matchListingToRequest({ ...listing, ownerId: "seeker-1" }, request)).toBeNull();
  });
  it("does not match stays that have already ended", () => {
    expect(matchListingToRequest(listing, request, "2027-06-01")).toBeNull();
  });
  it("ranks a preferred neighborhood above another qualifying neighborhood", () => {
    const preferred = matchListingToRequest(listing, request);
    const elsewhere = matchListingToRequest({ ...listing, neighborhood: "University Hill" }, request);
    expect(preferred?.score).toBeGreaterThan(elsewhere?.score ?? 0);
  });
});

import { matchListingToSearch } from "../shared/matching";
import type { HousingSearch } from "../shared/types";
const search: HousingSearch = {
  id: "search-1", ownerId: "seeker-1", ownerName: "Seeker", ownerIdentity: "pending",
  status: "active", startDate: "2027-01-15", endDate: "2027-05-15",
  minBudget: 700, maxBudget: 900, roomType: "Private room",
  requiredAmenities: ["Furnished"], preferredAmenities: ["Wi-Fi"],
  areas: [{ id: "campus", label: "Campus", points: [
    { lat: 43.01, lng: -76.16 }, { lat: 43.01, lng: -76.10 },
    { lat: 43.07, lng: -76.10 }, { lat: 43.07, lng: -76.16 },
  ] }],
  introduction: "Looking for a quiet place", createdAt: "2026-10-01", updatedAt: "2026-10-01",
};
const locatedListing = { ...listing, lat: 43.04, lng: -76.13 };

describe("profile search fit", () => {
  it("explains a full-area, full-date, budget and conditions match", () => {
    const result = matchListingToSearch(locatedListing, search, "2026-12-01");
    expect(result).not.toBeNull();
    expect(result?.reasons.join(" ")).toMatch(/area/i);
    expect(result?.reasons.join(" ")).toMatch(/stay/i);
    expect(result?.reasons.join(" ")).toMatch(/budget/i);
    expect(result?.reasons.join(" ")).not.toMatch(/%/);
  });
  it("enforces all hard requirements and inclusive price limits", () => {
    expect(matchListingToSearch({ ...locatedListing, price: 700 }, search, "2026-12-01")).not.toBeNull();
    expect(matchListingToSearch({ ...locatedListing, price: 900 }, search, "2026-12-01")).not.toBeNull();
    expect(matchListingToSearch({ ...locatedListing, price: 699 }, search, "2026-12-01")).toBeNull();
    expect(matchListingToSearch({ ...locatedListing, price: 901 }, search, "2026-12-01")).toBeNull();
    expect(matchListingToSearch({ ...locatedListing, endDate: "2027-05-14" }, search, "2026-12-01")).toBeNull();
    expect(matchListingToSearch({ ...locatedListing, startDate: "2027-01-16" }, search, "2026-12-01")).toBeNull();
    expect(matchListingToSearch({ ...locatedListing, lat: 43.1 }, search, "2026-12-01")).toBeNull();
    expect(matchListingToSearch({ ...locatedListing, amenities: ["Wi-Fi"] }, search, "2026-12-01")).toBeNull();
    expect(matchListingToSearch({ ...locatedListing, roomType: "Entire place" }, search, "2026-12-01")).toBeNull();
  });
  it("uses minimum bedrooms for an entire place and ranks preferred conditions", () => {
    const entire = { ...search, roomType: "Entire place" as const, minBedrooms: 2 };
    const place = { ...locatedListing, roomType: "Entire place" as const, beds: 2 };
    expect(matchListingToSearch({ ...place, beds: 1 }, entire, "2026-12-01")).toBeNull();
    expect(matchListingToSearch(place, entire, "2026-12-01")).not.toBeNull();
    const withWifi = matchListingToSearch(locatedListing, search, "2026-12-01");
    const withoutWifi = matchListingToSearch({ ...locatedListing, amenities: ["Furnished"] }, search, "2026-12-01");
    expect(withWifi!.score).toBeGreaterThan(withoutWifi!.score);
  });
  it("excludes off, expired, unavailable and self-owned pairs", () => {
    expect(matchListingToSearch(locatedListing, { ...search, status: "paused" }, "2026-12-01")).toBeNull();
    expect(matchListingToSearch(locatedListing, search, "2027-06-01")).toBeNull();
    expect(matchListingToSearch({ ...locatedListing, status: "paused" }, search, "2026-12-01")).toBeNull();
    expect(matchListingToSearch({ ...locatedListing, ownerId: search.ownerId }, search, "2026-12-01")).toBeNull();
  });
});
