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
