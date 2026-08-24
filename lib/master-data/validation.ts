export const GSTIN_PATTERN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;
export const PAN_PATTERN = /^[A-Z]{5}[0-9]{4}[A-Z]$/;
export const normalizeOptional = (value: FormDataEntryValue | null) => String(value ?? "").trim() || null;
export const normalizeUpper = (value: FormDataEntryValue | null) => normalizeOptional(value)?.toUpperCase() ?? null;
export function friendlyDatabaseError(message: string) { if (message.includes("customer_companies_code_unique")) return "That company code is already in use."; if (message.includes("customer_companies_gstin_unique")) return "That GSTIN is already assigned to another company."; if (message.includes("one_primary")) return "Only one active primary record is allowed. Change the current primary record first."; return "The change could not be saved. Please check the details and try again."; }
