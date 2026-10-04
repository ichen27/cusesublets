import { validateAreas, type SearchArea } from "./geo";
export type DraftKind = "search" | "listing";
export interface SearchDraftData {
  startDate: string;
  endDate: string;
  minBudget: string;
  maxBudget: string;
  minBedrooms: string;
  roomType: "Any" | "Private room" | "Entire place";
  requiredAmenities: string[];
  preferredAmenities: string[];
  areas: SearchArea[];
  introduction: string;
  activate: boolean;
}
export interface ListingDraftData {
  title: string;
  neighborhood: string;
  address: string;
  price: number;
  beds: number;
  baths: number;
  roomType: string;
  startDate: string;
  endDate: string;
  description: string;
  images: string;
  matterportUrl: string;
  videoUrl: string;
  walkMinutes: number;
  lat: number;
  lng: number;
  amenities: string[];
}
export interface PrivateDraft {
  id: string;
  kind: DraftKind;
  step: number;
  revision: number;
  data: Partial<SearchDraftData> | Partial<ListingDraftData>;
  updatedAt: string;
}
export const draftIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Drafts accept incomplete questionnaires, but never arbitrary account/document payloads.
export function cleanDraftData(
  kind: DraftKind,
  input: unknown,
): PrivateDraft["data"] {
  if (!input || typeof input !== "object" || Array.isArray(input))
    throw new Error("Draft details must be an object.");
  const out: Record<string, unknown> = {};
  const limits: Record<string, number> =
    kind === "search"
      ? {
          startDate: 10,
          endDate: 10,
          minBudget: 10,
          maxBudget: 10,
          minBedrooms: 3,
          roomType: 20,
          introduction: 500,
        }
      : {
          title: 100,
          neighborhood: 80,
          address: 160,
          roomType: 20,
          startDate: 10,
          endDate: 10,
          description: 4000,
          images: 16000,
          matterportUrl: 2000,
          videoUrl: 2000,
        };
  const numeric: Record<string, [number, number]> =
    kind === "listing"
      ? {
          price: [0, 20000],
          beds: [0, 20],
          baths: [0, 20],
          walkMinutes: [0, 120],
          lat: [42.9, 43.15],
          lng: [-76.3, -75.95],
        }
      : {};
  for (const [key, value] of Object.entries(input)) {
    if (Object.hasOwn(limits, key)) {
      if (typeof value !== "string" || value.length > limits[key])
        throw new Error(`Invalid draft ${key}.`);
      out[key] = value;
    } else if (Object.hasOwn(numeric, key)) {
      if (
        typeof value !== "number" ||
        !Number.isFinite(value) ||
        value < numeric[key][0] ||
        value > numeric[key][1]
      )
        throw new Error(`Invalid draft ${key}.`);
      out[key] = value;
    } else if (
      (kind === "search" &&
        ["requiredAmenities", "preferredAmenities"].includes(key)) ||
      (kind === "listing" && key === "amenities")
    ) {
      if (
        !Array.isArray(value) ||
        value.length > 20 ||
        value.some((v) => typeof v !== "string" || v.length > 50)
      )
        throw new Error("Invalid draft conditions.");
      out[key] = [...new Set(value)];
    } else if (kind === "search" && key === "areas") {
      out[key] =
        Array.isArray(value) && !value.length ? [] : validateAreas(value);
    } else if (kind === "search" && key === "activate") {
      if (typeof value !== "boolean")
        throw new Error("Invalid visibility choice.");
      out[key] = value;
    } else throw new Error(`Unsupported draft field: ${key}.`);
  }
  if (
    out.roomType !== undefined &&
    !(
      kind === "search"
        ? ["Any", "Private room", "Entire place"]
        : ["Private room", "Entire place"]
    ).includes(out.roomType as string)
  )
    throw new Error("Invalid room type.");
  return out;
}
