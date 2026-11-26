const hasScheme = /^[a-z][a-z0-9+.-]*:/i;

/**
 * Resolves a URL from a feed against `base`, like Foundation's
 * `URL(string:relativeTo:).absoluteString`: an absolute URL is returned as
 * written (WHATWG URL would normalize it, which changes article keys).
 */
export function resolveURL(raw: string | null | undefined, base: string | undefined): string | undefined {
  const s = raw?.trim();
  if (!s) return undefined;
  if (hasScheme.test(s)) return s;
  try {
    return new URL(s, base).href;
  } catch {
    return undefined;
  }
}

export function hostOf(url: string | undefined): string | undefined {
  if (!url) return undefined;
  try {
    return new URL(url).hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return undefined;
  }
}
