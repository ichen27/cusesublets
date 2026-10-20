/** Approximate RoomPlan geometry. Never conveys identity or property verification. */
export interface RoomElement {
  kind: "wall" | "door" | "window" | "opening" | "object";
  dimensions: [number, number, number];
  transform: number[];
}
export interface RoomLayout {
  version: 1;
  elements: RoomElement[];
}
export interface RoomScan {
  id: string;
  listingId: string;
  name: string;
  published: boolean;
  createdAt: string;
  layout: RoomLayout;
}
export function validateRoomLayout(value: unknown): RoomLayout {
  if (!value || typeof value !== "object")
    throw new Error("Invalid room layout");
  const v = value as Record<string, unknown>;
  if (
    v.version !== 1 ||
    !Array.isArray(v.elements) ||
    !v.elements.length ||
    v.elements.length > 300
  )
    throw new Error("Use a room with 1–300 elements");
  const elements = v.elements.map((item: unknown): RoomElement => {
    if (!item || typeof item !== "object")
      throw new Error("Invalid room element");
    const e = item as Record<string, unknown>;
    if (
      !["wall", "door", "window", "opening", "object"].includes(String(e.kind))
    )
      throw new Error("Invalid element type");
    if (
      !Array.isArray(e.dimensions) ||
      e.dimensions.length !== 3 ||
      e.dimensions.some(
        (n) => typeof n !== "number" || !Number.isFinite(n) || n < 0 || n > 100,
      )
    )
      throw new Error("Invalid room dimensions");
    if (
      !Array.isArray(e.transform) ||
      e.transform.length !== 16 ||
      e.transform.some(
        (n) =>
          typeof n !== "number" || !Number.isFinite(n) || Math.abs(n) > 1000,
      )
    )
      throw new Error("Invalid room transform");
    if (
      e.transform[3] !== 0 ||
      e.transform[7] !== 0 ||
      e.transform[11] !== 0 ||
      e.transform[15] !== 1
    )
      throw new Error("Invalid affine transform");
    return {
      kind: e.kind as RoomElement["kind"],
      dimensions: e.dimensions as [number, number, number],
      transform: e.transform as number[],
    };
  });
  if (!elements.some((e) => e.kind === "wall"))
    throw new Error("Scan at least one wall");
  return { version: 1, elements };
}
