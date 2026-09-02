/** Client-safe currency formatting. This module must remain free of server imports. */
export const money = (amount: number, currency = "INR") =>
  new Intl.NumberFormat("en-IN", { style: "currency", currency }).format(amount);
