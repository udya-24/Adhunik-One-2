/** Dates shown to users always use India time, independent of the host/browser timezone. */
export const INDIA_TIME_ZONE = "Asia/Kolkata";
type DateValue = string | number | Date | null | undefined;
const dateParts = new Intl.DateTimeFormat("en-GB", {
  timeZone: INDIA_TIME_ZONE, day: "2-digit", month: "short", year: "numeric",
});
const timeParts = new Intl.DateTimeFormat("en-US", {
  timeZone: INDIA_TIME_ZONE, hour: "2-digit", minute: "2-digit", hour12: true,
});

function parse(value: DateValue): Date | null {
  if (value == null || value === "") return null;
  // A business date is a calendar date; an unzoned datetime input is India local time.
  const normalized = typeof value === "string"
    ? /^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T00:00:00+05:30`
      : /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$/.test(value)
        ? `${value.replace(" ", "T")}+05:30` : value
    : value;
  const date = new Date(normalized);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function formatDate(value: DateValue, fallback = "—"): string {
  const date = parse(value);
  if (!date) return fallback;
  const parts = Object.fromEntries(dateParts.formatToParts(date).map(p => [p.type, p.value]));
  return `${parts.day}-${parts.month}-${parts.year}`;
}

export function formatTime(value: DateValue, fallback = "—"): string {
  const date = parse(value);
  if (!date) return fallback;
  const parts = Object.fromEntries(timeParts.formatToParts(date).map(p => [p.type, p.value]));
  return `${parts.hour}:${parts.minute} ${parts.dayPeriod.toUpperCase()}`;
}

export function formatDateTime(value: DateValue, fallback = "—"): string {
  return parse(value) ? `${formatDate(value)} ${formatTime(value)}` : fallback;
}

/** ISO calendar value for native date controls, filters and storage (not display). */
export function indiaDateInput(value: DateValue = new Date()): string {
  const date = parse(value);
  if (!date) return "";
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-GB", {
    timeZone: INDIA_TIME_ZONE, day: "2-digit", month: "2-digit", year: "numeric",
  }).formatToParts(date).map(p => [p.type, p.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export function indiaDateTimeInput(value: DateValue = new Date()): string {
  const date = parse(value);
  if (!date) return "";
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-GB", {
    timeZone: INDIA_TIME_ZONE, hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(date).map(p => [p.type, p.value]));
  return `${indiaDateInput(date)}T${parts.hour}:${parts.minute}`;
}

export function indiaDateTimeToIso(value: string): string | null {
  return value ? parse(value)?.toISOString() ?? null : null;
}

export function formatMonth(year: number, month: number, includeYear = false): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: INDIA_TIME_ZONE, month: "long", ...(includeYear ? { year: "numeric" as const } : {}),
  }).format(new Date(Date.UTC(year, month - 1, 1)));
}

export function indiaDayRange(value: DateValue = new Date()): { start: Date; end: Date } {
  const start = parse(indiaDateInput(value))!;
  return { start, end: new Date(start.getTime() + 24 * 60 * 60 * 1000) };
}
