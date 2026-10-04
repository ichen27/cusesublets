import { describe, expect, it } from "vitest";
import { cleanDraftData } from "../shared/drafts";
describe("private questionnaire boundaries", () => {
  it("accepts incomplete data without inventing public eligibility", () => {
    expect(
      cleanDraftData("search", {
        startDate: "",
        maxBudget: "",
        areas: [],
        activate: true,
      }),
    ).toEqual({ startDate: "", maxBudget: "", areas: [], activate: true });
    expect(
      cleanDraftData("listing", { title: "A work in progress", price: 0 }),
    ).toEqual({ title: "A work in progress", price: 0 });
  });
  it("rejects arbitrary fields, files, overflow and non-finite numbers", () => {
    for (const data of [
      { email: "private@example.test" },
      { images: ["data:image/png;base64,..."] },
      { title: "x".repeat(101) },
      { price: NaN },
      { price: Infinity },
    ])
      expect(() => cleanDraftData("listing", data)).toThrow();
    expect(() =>
      cleanDraftData("search", JSON.parse('{"__proto__":"x"}')),
    ).toThrow();
    expect(() =>
      cleanDraftData("search", {
        areas: [{ id: "x", label: "Area", points: [{ lat: 0, lng: 0 }] }],
      }),
    ).toThrow();
  });
  it("keeps only validated geometry and bounded unique conditions", () => {
    const area = {
      id: "test",
      label: "Near campus",
      points: [
        { lat: 43.01, lng: -76.15 },
        { lat: 43.01, lng: -76.1 },
        { lat: 43.04, lng: -76.1 },
      ],
    };
    expect(
      cleanDraftData("search", {
        areas: [area],
        requiredAmenities: ["Wi-Fi", "Wi-Fi"],
      }),
    ).toEqual({ areas: [area], requiredAmenities: ["Wi-Fi"] });
    expect(() =>
      cleanDraftData("search", { requiredAmenities: Array(21).fill("Wi-Fi") }),
    ).toThrow();
  });
});
