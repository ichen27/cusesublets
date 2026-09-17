import { describe, it, expect } from "vitest";
import { demoAllowed, dates, number, payoutBlockers } from "../worker/policy";
import worker from "../worker/index";
import type { Booking, Listing } from "../shared/types";
describe("API trust boundaries", () => {
  it("demo requires local hostname and development", () => {
    expect(demoAllowed("production", "localhost")).toBe(false);
    expect(demoAllowed("development", "example.com")).toBe(false);
    expect(demoAllowed("development", "localhost")).toBe(true);
  });
  it("rejects impossible dates and reversed intervals", () => {
    expect(() => dates("2027-02-30", "2027-03-10")).toThrow();
    expect(() => dates("2027-04-01", "2027-03-10")).toThrow();
  });
  it("rejects nonfinite and nonpositive money", () => {
    for (const n of [NaN, Infinity, 0, -1, 20001])
      expect(() => number(n, "Amount", 1, 20000)).toThrow();
  });
  it("blocks payout on dispute and incomplete review", () => {
    const b = {
      paymentStatus: "demo_paid",
      buyerSigned: true,
      sellerSigned: true,
      moveInAt: "2026-01-01",
      disputeStatus: "open",
    } as Booking;
    const l = {
      status: "approved",
      leaseStatus: "verified",
      permissionStatus: "verified",
      hostIdentity: "pending",
    } as Listing;
    expect(payoutBlockers(b, l)).toEqual([
      "Required reviews incomplete",
      "Open dispute",
    ]);
  });
  it("guest writes return 401 before DB access", async () => {
    const response = await worker.fetch(
      new Request("http://localhost/api/listings", {
        method: "POST",
        headers: {
          Origin: "http://localhost",
          "Content-Type": "application/json",
        },
        body: "{}",
      }),
      { APP_ENV: "production" } as never,
    );
    expect(response.status).toBe(401);
  });
  it("rejects arbitrary origin writes", async () => {
    const response = await worker.fetch(
      new Request("http://localhost/api/dev/session", {
        method: "POST",
        headers: { Origin: "https://evil.example" },
        body: "{}",
      }),
      { APP_ENV: "development" } as never,
    );
    expect(response.status).toBe(403);
  });
});
