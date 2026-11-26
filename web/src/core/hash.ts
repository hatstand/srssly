const encoder = new TextEncoder();

async function digest(algorithm: "SHA-1" | "SHA-256", data: Uint8Array<ArrayBuffer>): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest(algorithm, data));
}

export function utf8(s: string): Uint8Array<ArrayBuffer> {
  return encoder.encode(s);
}

export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

export const sha1 = (data: Uint8Array<ArrayBuffer>): Promise<Uint8Array> => digest("SHA-1", data);
export const sha256 = (data: Uint8Array<ArrayBuffer>): Promise<Uint8Array> => digest("SHA-256", data);
