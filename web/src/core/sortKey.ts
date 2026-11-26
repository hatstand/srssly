/**
 * Fractional sort keys: lowercase `a-z` strings that sort in list order and
 * always fit a new key between two others. Port of `SortKey` in Swift; see
 * docs/cloudkit-schema.md.
 */
const digits = "abcdefghijklmnopqrstuvwxyz";
const base = digits.length;

/** The key for a lone item, and the default for a new subscription. */
export const middleKey = "n";

const toDigits = (s: string): number[] => [...s].map((c) => Math.max(0, digits.indexOf(c)));
const fromDigits = (d: number[]): string => d.map((n) => digits[n]).join("");

function compare(a: number[], b: number[]): number {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

function midpoint(a: number[], b: number[] | undefined): number[] {
  if (b) {
    let n = 0;
    while (n < b.length && (a[n] ?? 0) === b[n]) n++;
    if (n > 0) return [...b.slice(0, n), ...midpoint(a.slice(n), b.slice(n))];
  }
  const digitA = a[0] ?? 0;
  const digitB = b ? (b[0] ?? 0) : base;
  if (digitB - digitA > 1) return [Math.floor((digitA + digitB + 1) / 2)];
  if (b && b.length > 1) return [b[0] ?? 0];
  return [digitA, ...midpoint(a.slice(1), undefined)];
}

/** A key strictly between `a` and `b` (undefined means the start or end). */
export function keyBetween(a: string | undefined, b: string | undefined): string {
  const lo = toDigits(a ?? "");
  const hi = b === undefined ? undefined : toDigits(b);
  if (hi && compare(lo, hi) >= 0) throw new Error(`keyBetween: ${a} must sort before ${b}`);
  return fromDigits(midpoint(lo, hi));
}

/** `count` evenly spread keys strictly between `a` and `b`. */
export function keysBetween(a: string | undefined, b: string | undefined, count: number): string[] {
  if (count <= 0) return [];
  if (count === 1) return [keyBetween(a, b)];
  const mid = keyBetween(a, b);
  const left = Math.floor((count - 1) / 2);
  return [...keysBetween(a, mid, left), mid, ...keysBetween(mid, b, count - 1 - left)];
}

/** Plain code-unit comparison, as the schema requires (not localeCompare). */
export const compareKeys = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);
