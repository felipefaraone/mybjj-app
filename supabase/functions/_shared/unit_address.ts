// supabase/functions/_shared/unit_address.ts
//
// THE unit address line for every Edge Function: what the emails show and what the
// directions / Maps links search for. units.address already holds the full
// address ("120 Military Rd, Neutral Bay NSW 2089"), so the line is the address
// as stored, trimmed. units.city is NOT appended (it is "Sydney" for every unit,
// and after the postcode it was redundant). trial.html has the same rule in its
// own unitAddressLine().

export function unitAddressLine(address: unknown): string | null {
  const s = typeof address === "string" ? address.trim() : "";
  return s || null;
}

// Google Maps search for that same line (null when there is no address).
export function unitMapsUrl(addressLine: string | null): string | null {
  return addressLine ? "https://www.google.com/maps/search/?api=1&query=" + encodeURIComponent(addressLine) : null;
}
