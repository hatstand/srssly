import { type UUID, uuidV5 } from "./uuid";

/** Srssly's UUIDv5 namespace for feed URLs (`FeedURL.namespace` in Swift). */
export const feedNamespace = "3b0f6f1e-6a3c-5d2b-9a57-5352535353c1" as UUID;

// scheme : [// authority] path [? query] [# fragment], taken from the raw
// string (like Foundation's URLComponents) rather than WHATWG URL, which
// normalizes paths and would give different keys from the iOS app.
const urlPattern = /^([a-zA-Z][a-zA-Z0-9+.-]*):(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#.*)?$/s;

/**
 * A canonical string used to spot duplicate subscriptions, such as
 * `http://www.popehat.com/feed/` and `https://popehat.com/feed`. Port of
 * `FeedURL.canonicalKey` (see docs/cloudkit-schema.md).
 */
export function canonicalKey(url: string): string {
  const m = urlPattern.exec(url);
  if (!m) return url;
  const authority = m[2] ?? "";
  let path = m[3] ?? "";
  const query = m[4];

  const hostPort = authority.slice(authority.lastIndexOf("@") + 1);
  const hostMatch = /^(\[[^\]]*\]|[^:]*)(?::(\d*))?$/.exec(hostPort);
  let host = hostMatch?.[1] ?? hostPort;
  const port = hostMatch?.[2] ? Number(hostMatch[2]) : undefined;
  host = host.toLowerCase();
  if (host.startsWith("www.")) host = host.slice(4);
  if (port !== undefined && port !== 80 && port !== 443) host += `:${port}`;

  while (path.length > 1 && path.endsWith("/")) path = path.slice(0, -1);
  if (path === "/") path = "";
  return host + path + (query === undefined ? "" : `?${query}`);
}

/** The subscription ID for a feed: a version 5 UUID of its canonical key. */
export function subscriptionID(url: string): Promise<UUID> {
  return uuidV5(feedNamespace, canonicalKey(url));
}
