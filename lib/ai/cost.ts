import type { Pricing } from "./types.ts";
// Costs are integer picodollars internally; round UP to nanodollars for PostgreSQL numeric(24,9).
const SCALE = BigInt(1_000_000_000);
export function decimalUnits(value: string): bigint {
 if (!/^\d+(?:\.\d{1,9})?$/.test(value)) throw new Error("Invalid nonnegative decimal");
 const [whole, fraction = ""] = value.split(".");
 return BigInt(whole) * SCALE + BigInt(fraction.padEnd(9,"0"));
}
export function formatUnits(value: bigint): string { return `${value / SCALE}.${(value % SCALE).toString().padStart(9,"0")}`; }
export function calculateCost(pricing: Pricing, input: number, output: number, cached = 0): string {
 if (![input,output,cached].every(n=>Number.isSafeInteger(n)&&n>=0) || cached>input) throw new Error("Invalid token usage");
 const amount = BigInt(input-cached)*decimalUnits(pricing.input_price_per_million_tokens)+BigInt(cached)*decimalUnits(pricing.cached_input_price_per_million_tokens)+BigInt(output)*decimalUnits(pricing.output_price_per_million_tokens);
 return formatUnits((amount + BigInt(999_999))/BigInt(1_000_000));
}
export function estimateCost(pricing: Pricing, input: number, output: number) {
 // Cache discounts are not assumed before a request.
 const worst = {...pricing,input_price_per_million_tokens:decimalUnits(pricing.input_price_per_million_tokens)>=decimalUnits(pricing.cached_input_price_per_million_tokens)?pricing.input_price_per_million_tokens:pricing.cached_input_price_per_million_tokens};
 return calculateCost(worst,input,output);
}
