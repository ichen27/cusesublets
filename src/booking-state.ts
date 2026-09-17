export const isPaymentComplete = (status: string) =>
  status === "paid" || status === "demo_paid";
