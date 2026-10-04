import type { Listing, SeekerRequest } from "./types";

export interface MatchResult {
  score: number;
  reasons: string[];
}

// Match on housing requirements. Identity and profile details are never ranking inputs.
export function matchListingToRequest(
  listing: Listing,
  request: Pick<SeekerRequest, "ownerId" | "status" | "startDate" | "endDate" | "maxBudget" | "roomType" | "neighborhood" | "amenities">,
  today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date()),
): MatchResult | null {
  if (
    listing.status !== "approved" ||
    request.status !== "active" ||
    listing.ownerId === request.ownerId ||
    listing.endDate <= today || request.endDate <= today ||
    listing.startDate > request.startDate ||
    listing.endDate < request.endDate ||
    listing.price > request.maxBudget ||
    (request.roomType !== "Any" && listing.roomType !== request.roomType)
  ) return null;

  const reasons = ["Covers the full stay", "Within budget"];
  let score = 50;
  if (request.neighborhood && listing.neighborhood.toLowerCase() === request.neighborhood.toLowerCase()) {
    score += 25;
    reasons.push("Preferred area");
  }
  if (request.roomType !== "Any") {
    score += 10;
    reasons.push("Room type matches");
  }
  if (listing.startDate === request.startDate && listing.endDate === request.endDate) score += 5;
  if (listing.price <= request.maxBudget * 0.9) score += 5;
  const amenityMatches = request.amenities.filter((amenity) =>
    listing.amenities.some((item) => item.toLowerCase() === amenity.toLowerCase()),
  );
  score += Math.min(amenityMatches.length, 2) * 5;
  if (amenityMatches.length) reasons.push(`${amenityMatches.length} requested amenit${amenityMatches.length === 1 ? "y" : "ies"}`);
  return { score, reasons };
}

import { pointInAnyArea } from "./geo";
import type { HousingSearch } from "./types";

// The same housing requirements apply whichever side opens Top Matches.
export function matchListingToSearch(
  listing: Listing,
  search: HousingSearch,
  today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date()),
): MatchResult | null {
  if (listing.status !== "approved" || search.status !== "active" ||
      listing.ownerId === search.ownerId ||
      listing.endDate <= today || search.endDate <= today ||
      listing.startDate > search.startDate || listing.endDate < search.endDate ||
      listing.price > search.maxBudget ||
      (search.minBudget != null && listing.price < search.minBudget) ||
      (search.roomType !== "Any" && listing.roomType !== search.roomType) ||
      (search.roomType === "Entire place" && listing.roomType === "Entire place" &&
        search.minBedrooms != null && listing.beds < search.minBedrooms) ||
      !pointInAnyArea(listing.lat, listing.lng, search.areas)) return null;

  const offered = new Set(listing.amenities.map((item) => item.trim().toLowerCase()));
  if (search.requiredAmenities.some((item) => !offered.has(item.trim().toLowerCase()))) return null;
  const preferred = search.preferredAmenities.filter((item) => offered.has(item.trim().toLowerCase()));
  const reasons = ["In a chosen area", "Covers the full stay", "Within budget"];
  if (search.roomType !== "Any") reasons.push("Room type matches");
  if (search.roomType === "Entire place" && search.minBedrooms != null) reasons.push("Enough bedrooms");
  if (search.requiredAmenities.length) reasons.push("Includes required conditions");
  if (preferred.length) reasons.push(`Includes ${preferred.length} preferred condition${preferred.length === 1 ? "" : "s"}`);
  // Preference overlap dominates price; route sorting uses stable IDs for ties.
  const score = preferred.length + Math.max(0, search.maxBudget - listing.price) / 20001;
  return { score, reasons };
}
