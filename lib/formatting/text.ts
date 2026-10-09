/** Repair legacy UTF-8 text accidentally decoded as Windows-1252, without altering valid text. */
const windows1252 = new Map<number, number>([
  [0x20ac, 0x80], [0x201a, 0x82], [0x0192, 0x83], [0x201e, 0x84], [0x2026, 0x85],
  [0x2020, 0x86], [0x2021, 0x87], [0x02c6, 0x88], [0x2030, 0x89], [0x0160, 0x8a],
  [0x2039, 0x8b], [0x0152, 0x8c], [0x017d, 0x8e], [0x2018, 0x91], [0x2019, 0x92],
  [0x201c, 0x93], [0x201d, 0x94], [0x2022, 0x95], [0x2013, 0x96], [0x2014, 0x97],
  [0x02dc, 0x98], [0x2122, 0x99], [0x0161, 0x9a], [0x203a, 0x9b], [0x0153, 0x9c],
  [0x017e, 0x9e], [0x0178, 0x9f],
]);
const decoder = new TextDecoder("utf-8", { fatal: true });

export function cleanText(value: string): string {
  return value.replace(/[^\u0000-\u007f]+/g, run => {
    let text = run;
    for (let attempt = 0; attempt < 5 && /[\u00c2-\u00f4]/.test(text); attempt++) {
      const chars = Array.from(text);
      const codes = chars.map(ch => windows1252.get(ch.codePointAt(0)!) ?? ch.codePointAt(0)!);
      let repaired = "";
      for (let index = 0; index < chars.length; index++) {
        const lead = codes[index];
        const size = lead >= 0xc2 && lead <= 0xdf ? 2 : lead >= 0xe0 && lead <= 0xef ? 3
          : lead >= 0xf0 && lead <= 0xf4 ? 4 : 0;
        const bytes = codes.slice(index, index + size);
        if (size && bytes.length === size && bytes.slice(1).every(code => code >= 0x80 && code <= 0xbf)) {
          try {
            repaired += decoder.decode(Uint8Array.from(bytes));
            index += size - 1;
            continue;
          } catch { /* Invalid byte sequences are legitimate text or cannot be recovered. */ }
        }
        repaired += chars[index];
      }
      if (repaired === text) break;
      text = repaired;
    }
    return text.replace(/\ufffd/g, "");
  });
}

export function displayText(value: unknown, fallback = "—"): string {
  if (value == null) return fallback;
  const text = cleanText(String(value));
  return text.trim() && !(fallback === "" && text.trim() === "—") ? text : fallback;
}

/** Normalize string values at JSON boundaries; IDs, keys, numbers, booleans and null stay intact. */
export function cleanJson<T>(value: T): T {
  if (typeof value === "string") return cleanText(value) as T;
  if (Array.isArray(value)) return value.map(cleanJson) as T;
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, cleanJson(item)])) as T;
  }
  return value;
}
