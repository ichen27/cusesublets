import type { Listing } from "../shared/types";
export interface Filters {
  query?: string;
  maxPrice?: number;
  roomType?: string;
  startDate?: string;
  endDate?: string;
  furnished?: boolean;
  verified?: boolean;
  tour?: boolean;
}
export function filterListings(listings: Listing[], f: Filters) {
  if (f.startDate && f.endDate && f.startDate >= f.endDate) return [];
  return listings.filter(
    (l) =>
      (!f.query ||
        `${l.title} ${l.neighborhood} ${l.description}`
          .toLowerCase()
          .includes(f.query.toLowerCase())) &&
      (!f.maxPrice || l.price <= f.maxPrice) &&
      (!f.roomType || l.roomType === f.roomType) &&
      (!f.startDate ||
        (l.startDate <= f.startDate && f.startDate < l.endDate)) &&
      (!f.endDate || (l.endDate >= f.endDate && f.endDate > l.startDate)) &&
      (!f.furnished || l.amenities.includes("Furnished")) &&
      (!f.verified ||
        (l.leaseStatus === "verified" && l.permissionStatus === "verified")) &&
      (!f.tour || !!l.matterportUrl),
  );
}

export type MapBounds = {
  south: number;
  north: number;
  west: number;
  east: number;
};
export function listingsInBounds(
  listings: Listing[],
  bounds: MapBounds | null,
) {
  if (!bounds) return listings;
  return listings.filter(
    (l) =>
      l.lat >= bounds.south &&
      l.lat <= bounds.north &&
      l.lng >= bounds.west &&
      l.lng <= bounds.east,
  );
}

import type { HousingSearch } from "../shared/types";
import { areasIntersectBounds } from "../shared/geo";
export function searchesInBounds(searches: HousingSearch[], bounds: MapBounds | null) {
  const seen = new Set<string>();
  return searches.filter((search) => {
    if (seen.has(search.ownerId) || (bounds && !areasIntersectBounds(search.areas, bounds))) return false;
    seen.add(search.ownerId);
    return true;
  });
}
export function filterHousingSearches(searches: HousingSearch[], f: Filters) {
  if (f.startDate && f.endDate && f.startDate >= f.endDate) return [];
  return searches.filter((s) =>
    (!f.query || [s.ownerName, s.introduction, ...s.areas.map((a) => a.label)].join(" ").toLowerCase().includes(f.query.toLowerCase())) &&
    (!f.maxPrice || (s.minBudget || 0) <= f.maxPrice) &&
    (!f.roomType || s.roomType === "Any" || s.roomType === f.roomType) &&
    (!f.startDate || s.endDate > f.startDate) &&
    (!f.endDate || s.startDate < f.endDate) &&
    (!f.furnished || [...s.requiredAmenities, ...s.preferredAmenities].includes("Furnished")));
}
