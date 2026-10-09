import { cleanText } from "@/lib/formatting/text";

export const addressFields = ["address_line_1", "address_line_2", "city", "district", "state", "postal_code", "country"] as const;
export type AddressSnapshot = Record<(typeof addressFields)[number], string> & { address_type?: string };

export function addressSnapshot(value: Record<string, unknown> | null | undefined): AddressSnapshot {
  return Object.fromEntries(addressFields.map(key => [key, cleanText(String(value?.[key] ?? ""))])) as AddressSnapshot;
}

export function readAddressSnapshot(form: FormData, kind: "billing" | "shipping"): AddressSnapshot | undefined {
  // Old forms/API callers can omit overrides and retain their existing master-derived snapshots.
  if (!form.has(`${kind}_address_line_1`)) return undefined;
  return Object.fromEntries(addressFields.map(key => [key, cleanText(String(form.get(`${kind}_${key}`) ?? "")).trim()])) as AddressSnapshot;
}
