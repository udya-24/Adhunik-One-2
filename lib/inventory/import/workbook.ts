import JSZip from "jszip";
import sax from "sax";
import { createHash } from "node:crypto";

export const headers = ["New code", "Item name", "Item group", "Type", "Family", "Store", "Unit", "Status", "Opening qty", "Rejected qty", "Rate (Rs)", "Value (Rs)", "Rejected value (Rs)", "Uses in 6 months", "Last used"];
export const normalize = (s: string) => s.trim().replace(/\s+/g, " ").toLowerCase();
export type SourceRow = { row: number; raw: Record<string, string>; issues: string[]; warnings: string[] };
type XmlNode = { name: string; attrs: Record<string, string>; text: string; children: XmlNode[] };
function xml(value: string): XmlNode {
  if (/<!DOCTYPE|<!ENTITY/i.test(value)) throw new Error("XML declarations with entities are not supported.");
  const parser = sax.parser(true, { xmlns: false, strictEntities: true });
  const root: XmlNode = { name: "root", attrs: {}, text: "", children: [] }, stack = [root];
  parser.onopentag = (tag) => {
    if (stack.length > 40) throw new Error("Workbook XML is too deeply nested.");
    const node: XmlNode = { name: tag.name.split(":").pop()!, attrs: tag.attributes as Record<string, string>, text: "", children: [] };
    stack[stack.length - 1].children.push(node); stack.push(node);
  };
  parser.ontext = parser.oncdata = (text) => { stack[stack.length - 1].text += text; };
  parser.onclosetag = () => { stack.pop(); };
  parser.write(value).close();
  return root.children[0];
}
const children = (node: XmlNode, name: string) => node.children.filter(x => x.name === name);
const child = (node: XmlNode, name: string) => children(node, name)[0];
const text = (node?: XmlNode): string => node ? node.text + node.children.map(text).join("") : "";

// Exact decimal conversion, including Excel's scientific notation. No binary arithmetic for COGS.
export function decimal(value: string, scale: number): { fixed: string; rounded: boolean; scaled: bigint } {
  const match = /^(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(value.trim());
  if (!match || value.length > 100) throw new Error("Expected a finite non-negative decimal.");
  const exponent = Number(match[3] || 0); if (Math.abs(exponent) > 40) throw new Error("Number is out of range.");
  const digits = BigInt(match[1] + (match[2] || "")), shift = scale + exponent - (match[2]?.length || 0);
  const divisor = shift < 0 ? BigInt(10) ** BigInt(-shift) : BigInt(1);
  const scaled = shift >= 0 ? digits * BigInt(10) ** BigInt(shift) : (digits + divisor / BigInt(2)) / divisor;
  const s = scaled.toString().padStart(scale + 1, "0");
  return { fixed: scale ? s.slice(0, -scale) + "." + s.slice(-scale) : s, rounded: shift < 0 && digits % divisor !== BigInt(0), scaled };
}

export async function readWorkbook(bytes: Buffer) {
  if (!bytes.length || bytes.length > 10 * 1024 * 1024) throw new Error("Upload an XLSX workbook of at most 10 MB.");
  const zip = await JSZip.loadAsync(bytes);
  if (Object.keys(zip.files).length > 1000) throw new Error("Too many workbook entries.");
  if (Object.keys(zip.files).some(p => /vbaProject|externalLinks|embeddings/i.test(p))) throw new Error("Macros, embedded objects and external links are not supported.");
  let expanded = 0;
  async function entry(path: string, optional = false): Promise<XmlNode | undefined> {
    const file = zip.file(path); if (!file) { if (optional) return; throw new Error("Missing workbook part: " + path); }
    // Bound decompression by consuming the stream; never allocate an unbounded inflated entry.
    const chunks: Buffer[] = []; let size = 0;
    await new Promise<void>((resolve, reject) => {
      const stream = file.nodeStream("nodebuffer");
      stream.on("data", (part: Buffer | string) => {
        const chunk = Buffer.isBuffer(part) ? part : Buffer.from(part);
        size += chunk.length; expanded += chunk.length;
        if (size > 24 * 1024 * 1024 || expanded > 40 * 1024 * 1024) {
          stream.pause(); reject(new Error("Expanded workbook exceeds the import limit.")); return;
        }
        chunks.push(chunk);
      });
      stream.on("error", reject); stream.on("end", resolve);
    });
    return xml(Buffer.concat(chunks).toString("utf8"));
  }
  const workbook = (await entry("xl/workbook.xml"))!, rels = (await entry("xl/_rels/workbook.xml.rels"))!;
  const sheets = children(child(workbook, "sheets"), "sheet");
  if (sheets.length !== 1) throw new Error("This import expects exactly one product sheet; review multi-sheet workbooks separately.");
  const sheet = sheets[0], rel = rels.children.find(x => x.attrs.Id === sheet.attrs["r:id"]);
  if (!rel || rel.attrs.TargetMode === "External") throw new Error("Invalid sheet relationship.");
  const path = rel.attrs.Target.startsWith("/") ? rel.attrs.Target.slice(1) : "xl/" + rel.attrs.Target;
  if (path.includes("..")) throw new Error("Invalid sheet path.");
  const shared = await entry("xl/sharedStrings.xml", true), strings = shared ? children(shared, "si").map(text) : [];
  const worksheet = (await entry(path))!, data = child(worksheet, "sheetData");
  if (!data) throw new Error("Product sheet has no rows.");
  const source = children(data, "row");
  if (source.length < 2 || source.length > 10001) throw new Error("Expected 1–10,000 product rows.");
  const rows: SourceRow[] = [];
  const columns: Record<string, string> = {};
  const sharedFormulas = new Map<string, { formula: string; col: string; start: number; end: number }>();
  for (const row of source) {
    const values: Record<string, string> = {}, fs: Record<string, string> = {}, seen = new Set<string>();
    for (const cell of children(row, "c")) {
      const address = cell.attrs.r, col = address?.replace(/\d+$/, "");
      if (!col || seen.has(col)) throw new Error("Missing or duplicate cell address."); seen.add(col);
      let value = text(child(cell, "v"));
      if (cell.attrs.t === "s") { if (!/^\d+$/.test(value) || strings[Number(value)] === undefined) throw new Error("Invalid shared string."); value = strings[Number(value)]; }
      if (cell.attrs.t === "inlineStr") value = text(child(cell, "is"));
      if (cell.attrs.t === "e") throw new Error("Excel error in " + address);
      if (value.length > 4000) throw new Error("Cell " + address + " exceeds 4,000 characters.");
      values[col] = value;
      const f = child(cell, "f");
      if (f) {
        let formula = text(f);
        if (f.attrs.t === "shared") {
          if (formula) {
            const range = /^([A-Z]+)([0-9]+):([A-Z]+)([0-9]+)$/.exec(f.attrs.ref || "");
            if (!range || range[1] !== col || range[3] !== col || Number(range[2]) !== Number(row.attrs.r)) throw new Error("Unsupported shared formula range.");
            sharedFormulas.set(f.attrs.si, { formula, col, start: Number(range[2]), end: Number(range[4]) });
          } else {
            const anchor = sharedFormulas.get(f.attrs.si), n = Number(row.attrs.r);
            if (!anchor || col !== anchor.col || n < anchor.start || n > anchor.end) throw new Error("Invalid shared formula reference.");
            formula = anchor.formula.replace(/(\$?[A-Z]+)(\$?)([0-9]+)/g, (_, column, absolute, number) => column + absolute + (Number(number) + (absolute ? 0 : n - anchor.start)));
          }
        } else if (f.attrs.t && f.attrs.t !== "normal") throw new Error("Unsupported formula type.");
        fs[col] = formula;
      }
    }
    const rowNumber = Number(row.attrs.r);
    if (!Number.isInteger(rowNumber) || rowNumber < 1) throw new Error("Invalid source row number.");
    if (!Object.keys(columns).length) {
      if (Object.keys(fs).length) throw new Error("Header formulas are not supported.");
      for (const [col, value] of Object.entries(values)) {
        if (!value.trim()) continue;
        const header = headers.find(h => normalize(h) === normalize(value));
        if (!header || Object.values(columns).includes(header)) throw new Error("Unknown or duplicate header: " + value);
        columns[col] = header;
      }
      if (headers.some(h => !Object.values(columns).includes(h))) throw new Error("Required columns: " + headers.join(", "));
      continue;
    }
    if (!Object.values(values).some(v => v.trim())) continue;
    if (Object.keys(values).some(c => values[c].trim() && !columns[c])) throw new Error("Data outside the declared columns.");
    const raw = Object.fromEntries(Object.entries(columns).map(([c, h]) => [h, values[c] ?? ""]));
    const issues: string[] = [], warnings: string[] = [];
    for (const [col, formula] of Object.entries(fs)) {
      const header = columns[col];
      const inputCol = Object.keys(columns).find(c => columns[c] === (header === "Value (Rs)" ? "Opening qty" : "Rejected qty"));
      const rateCol = Object.keys(columns).find(c => columns[c] === "Rate (Rs)");
      if (!["Value (Rs)", "Rejected value (Rs)"].includes(header) || formula.replace(/\$/g, "").toUpperCase() !== `${inputCol}${rowNumber}*${rateCol}${rowNumber}`.toUpperCase()) issues.push("Unsupported formula in " + col + rowNumber);
    }
    for (const h of headers.slice(8, 14)) {
      try {
        const d = decimal(raw[h], h === "Rate (Rs)" ? 4 : 6);
        if (d.scaled >= BigInt(10) ** BigInt(h === "Rate (Rs)" ? 15 : 24)) issues.push(h + " is out of database range.");
        if (d.rounded) warnings.push(`${h}: ${raw[h]} rounds to ${d.fixed}`);
      } catch { issues.push(h + " must be a finite non-negative number."); }
    }
    if (raw["Last used"]) {
      const serial = Number(raw["Last used"]), date1904 = child(workbook, "workbookPr")?.attrs.date1904;
      if (!Number.isFinite(serial) || serial < 0 || serial > 2958465) issues.push("Last used is not a valid Excel date.");
      else warnings.push("Last used (source only): " + new Date(Date.UTC(date1904 === "1" || date1904 === "true" ? 1904 : 1899, date1904 === "1" || date1904 === "true" ? 0 : 11, date1904 === "1" || date1904 === "true" ? 1 : 30) + serial * 86400000).toISOString().slice(0, 10));
    }
    rows.push({ row: rowNumber, raw, issues, warnings });
  }
  if (new Set(rows.map(r => r.row)).size !== rows.length) throw new Error("Duplicate source row numbers.");
  return { sheet: sheet.attrs.name, rows, sha256: createHash("sha256").update(bytes).digest("hex") };
}
