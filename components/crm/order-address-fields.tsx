"use client";
import type { AddressSnapshot } from "@/lib/crm/order-address";
import { addressFields } from "@/lib/crm/order-address";

const labels = {
  address_line_1: "Address Line 1", address_line_2: "Address Line 2", city: "City",
  district: "District", state: "State", postal_code: "Postal Code", country: "Country",
};

export function OrderAddressFields({ kind, value, onChange }: {
  kind: "billing" | "shipping";
  value: AddressSnapshot;
  onChange: (value: AddressSnapshot) => void;
}) {
  return <div className="mt-3 grid gap-3 sm:grid-cols-2">
    {addressFields.map(key => <label key={key} className={`text-sm ${key.startsWith("address_line") ? "sm:col-span-2" : ""}`}>
      {labels[key]}{key === "address_line_1" ? " *" : ""}
      <input className="field mt-1" name={`${kind}_${key}`} value={value[key]}
        required={key === "address_line_1"} maxLength={key === "address_line_1" || key === "address_line_2" ? 500 : 150}
        onChange={event => onChange({ ...value, [key]: event.target.value })}/>
    </label>)}
  </div>;
}
