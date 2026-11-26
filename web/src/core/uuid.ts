import { sha1, toHex, utf8 } from "./hash";

/** A lowercase UUID string, as used for CloudKit record names. */
export type UUID = string & { readonly __brand: "UUID" };

const pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function parseUUID(s: string): UUID | undefined {
  const lower = s.toLowerCase();
  return pattern.test(lower) ? (lower as UUID) : undefined;
}

function bytes(uuid: UUID): Uint8Array<ArrayBuffer> {
  const hex = uuid.replaceAll("-", "");
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function format(b: Uint8Array): UUID {
  const h = toHex(b);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}` as UUID;
}

/** RFC 4122 version 5 (SHA-1, name-based) UUID, matching `FeedURL.uuidV5`. */
export async function uuidV5(namespace: UUID, name: string): Promise<UUID> {
  const ns = bytes(namespace);
  const n = utf8(name);
  const data = new Uint8Array(ns.length + n.length);
  data.set(ns);
  data.set(n, ns.length);
  const hash = (await sha1(data)).slice(0, 16);
  hash[6] = ((hash[6] ?? 0) & 0x0f) | 0x50;
  hash[8] = ((hash[8] ?? 0) & 0x3f) | 0x80;
  return format(hash);
}
