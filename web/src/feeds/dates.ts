/**
 * Parses the date formats feeds use in practice: RFC 822 for RSS (with its
 * variations) and RFC 3339 / ISO 8601 for Atom and Dublin Core. Port of
 * FeedDates.swift: zoneless ISO times are UTC, not local time.
 */
const months: Record<string, number> = {
  jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11,
};

const zones: Record<string, number> = {
  ut: 0, utc: 0, gmt: 0, z: 0,
  est: -5, edt: -4, cst: -6, cdt: -5, mst: -7, mdt: -6, pst: -8, pdt: -7,
  bst: 1, cet: 1, cest: 2, eet: 2, eest: 3, ist: 5.5, jst: 9, aest: 10, aedt: 11,
};

const rfc822 =
  /^(?:[a-z]{3,9},?\s*)?(\d{1,2})\s+([a-z]{3})[a-z]*\.?\s+(\d{2,4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?\s*([+-]\d{4}|[a-z]{1,5})?\s*$/i;

function parseRFC822(s: string): Date | undefined {
  const m = rfc822.exec(s);
  if (!m) return undefined;
  const month = months[(m[2] ?? "").toLowerCase()];
  if (month === undefined) return undefined;
  let year = Number(m[3]);
  if (year < 100) year += year < 50 ? 2000 : 1900;
  let offsetMinutes = 0;
  const zone = m[7];
  if (zone && /^[+-]\d{4}$/.test(zone)) {
    const sign = zone.startsWith("-") ? -1 : 1;
    offsetMinutes = sign * (Number(zone.slice(1, 3)) * 60 + Number(zone.slice(3, 5)));
  } else if (zone) {
    const hours = zones[zone.toLowerCase()];
    if (hours === undefined) return undefined;
    offsetMinutes = hours * 60;
  }
  const utc = Date.UTC(year, month, Number(m[1]), Number(m[4] ?? 0), Number(m[5] ?? 0), Number(m[6] ?? 0));
  return new Date(utc - offsetMinutes * 60_000);
}

const isoDate = /^\d{4}-\d{2}-\d{2}$/;
const isoDateTime = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$/i;

export function parseFeedDate(raw: string | null | undefined): Date | undefined {
  const s = raw?.trim();
  if (!s) return undefined;
  if (isoDate.test(s)) return new Date(`${s}T00:00:00Z`);
  const iso = isoDateTime.exec(s);
  if (iso) {
    const d = new Date(iso[1] ? s : `${s}Z`);
    return Number.isNaN(d.getTime()) ? undefined : d;
  }
  return parseRFC822(s);
}
