import { it, expect } from "vitest";
import { isPaymentComplete } from "../src/booking-state";
it("treats demo payment as complete without treating pending as paid", () => {
  expect(isPaymentComplete("demo_paid")).toBe(true);
  expect(isPaymentComplete("paid")).toBe(true);
  expect(isPaymentComplete("pending")).toBe(false);
  expect(isPaymentComplete("unpaid")).toBe(false);
});
