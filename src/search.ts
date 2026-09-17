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
