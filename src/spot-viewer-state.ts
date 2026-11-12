import type { TourSpot } from "../shared/spot-tour";
import { nearbySpots } from "./spot-viewer-math";

export type ViewerMode = "3D" | "Plan" | "Walk";

/** The tour opens at the lowest-numbered spot, the first one captured. */
export const firstSpot = (spots: TourSpot[]) =>
  spots.length ? spots.reduce((a, b) => (b.spot < a.spot ? b : a)) : null;

/** Fetch the panorama being viewed first, then the ones a tap could move to, nearest first. */
export const panoramaOrder = (current: TourSpot, spots: TourSpot[]) => [
  current,
  ...nearbySpots(current, spots),
];

export const panoramaUrl = (listing: string, tour: string, spot: number) =>
  `/api/listings/${encodeURIComponent(listing)}/tours/${encodeURIComponent(tour)}/panorama/${spot}`;

/** The dollhouse needs the mesh; without one, the plan shows spot markers only. */
export const viewerModes = (hasMesh: boolean): ViewerMode[] =>
  hasMesh ? ["3D", "Plan", "Walk"] : ["Plan", "Walk"];
