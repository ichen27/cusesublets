import type { Booking, Listing } from "../shared/types";
export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}
export function requireThat(
  condition: unknown,
  status: number,
  message: string,
): asserts condition {
  if (!condition) throw new HttpError(status, message);
}
export function demoAllowed(env: string, hostname: string) {
  return (
    env === "development" &&
    ["localhost", "127.0.0.1", "[::1]"].includes(hostname)
  );
}
export function text(
  value: unknown,
  label: string,
  max = 2000,
  min = 1,
): string {
  requireThat(
    typeof value === "string" &&
      value.trim().length >= min &&
      value.trim().length <= max,
    400,
    `${label} must contain ${min}–${max} characters`,
  );
  return value.trim();
}
export function number(
  value: unknown,
  label: string,
  min: number,
  max: number,
) {
  requireThat(
    typeof value === "number" &&
      Number.isFinite(value) &&
      value >= min &&
      value <= max,
    400,
    `${label} must be between ${min} and ${max}`,
  );
  return value;
}
export function dates(start: unknown, end: unknown) {
  const valid = (v: unknown): v is string =>
    typeof v === "string" &&
    /^\d{4}-\d{2}-\d{2}$/.test(v) &&
    Number.isFinite(Date.parse(v)) &&
    new Date(v).toISOString().slice(0, 10) === v;
  requireThat(
    valid(start) && valid(end) && start < end,
    400,
    "Choose valid start and end dates",
  );
  return { startDate: start, endDate: end };
}
export function payoutBlockers(b: Booking, l: Listing, now = Date.now()) {
  const reasons: string[] = [];
  if (b.paymentStatus !== "demo_paid") reasons.push("Payment pending");
  if (!b.buyerSigned || !b.sellerSigned)
    reasons.push("Both acknowledgments required");
  if (
    l.status !== "approved" ||
    l.leaseStatus !== "verified" ||
    l.permissionStatus !== "verified" ||
    l.hostIdentity !== "verified"
  )
    reasons.push("Required reviews incomplete");
  if (!b.moveInAt || now < Date.parse(b.moveInAt) + 48 * 3600000)
    reasons.push("48-hour move-in window incomplete");
  if (b.disputeStatus === "open") reasons.push("Open dispute");
  return reasons;
}
export function mediaUrl(value: unknown, matterport = false) {
  if (value === undefined || value === "") return undefined;
  const input = text(value, "Media URL", 1500);
  let u: URL;
  try {
    u = new URL(input);
  } catch {
    throw new HttpError(400, "Enter a valid HTTPS media URL");
  }
  requireThat(
    u.protocol === "https:" && !u.username && !u.password,
    400,
    "Media must use HTTPS",
  );
  if (matterport)
    requireThat(
      u.hostname === "my.matterport.com" &&
        u.pathname === "/show/" &&
        !!u.searchParams.get("m"),
      400,
      "Use a Matterport tour URL",
    );
  return u.href;
}
