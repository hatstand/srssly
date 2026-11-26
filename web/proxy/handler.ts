/**
 * A minimal fetch proxy so the browser can read feeds that don't send CORS
 * headers (most of them). Stateless: it fetches one public URL and passes
 * the body back with CORS headers. Used by the Vite dev server (see
 * vite.config.ts) and deployable as a Cloudflare Worker (worker.ts).
 *
 *   GET /proxy?url=<target>[&etag=<etag>][&lm=<last-modified>]
 *
 * Validators travel as query parameters, not headers, so the browser's
 * request stays "simple" and needs no CORS preflight round trip.
 *
 * Response headers:
 *   X-Srssly-Final-URL      the URL after redirects
 *   X-Srssly-Permanent-URL  set when the feed moved permanently (301/308)
 *   ETag, Last-Modified     passed through for conditional GET
 */
export interface ProxyOptions {
  /** Origins allowed to call the proxy. `*` allows any (dev only). */
  allowedOrigins: readonly string[];
  /** Identifies the client to sites, like the iOS app's User-Agent. */
  userAgent: string;
  maxBytes?: number;
  fetch?: typeof fetch;
}

// Feeds and pages: text/*, and application types like rss+xml, x-rss+xml or
// feed+json. Untyped bodies are allowed only if they look like markup.
const allowedTypes = /^(text\/[\w.+-]+|application\/[\w.+-]*(xml|json|rss|atom|rdf)[\w.+-]*)\s*(;|$)/i;
const untyped = /^(application\/octet-stream|binary\/octet-stream)?\s*(;|$)/i;
const maxRedirects = 5;

/** Rejects non-HTTP URLs and literal loopback/private addresses. */
export function isPublicHTTPURL(raw: string): URL | undefined {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return undefined;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return undefined;
  if (url.username || url.password) return undefined;
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) {
    return undefined;
  }
  const v4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(host);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    if (a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
        (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224) {
      return undefined;
    }
  }
  if (host.includes(":")) {
    if (host === "::1" || host === "::" || /^(fc|fd|fe80|::ffff:)/.test(host)) return undefined;
  }
  return url;
}

function corsHeaders(origin: string | null, opts: ProxyOptions): Headers {
  const h = new Headers({
    "Access-Control-Expose-Headers": "ETag, Last-Modified, X-Srssly-Final-URL, X-Srssly-Permanent-URL",
    Vary: "Origin",
  });
  if (opts.allowedOrigins.includes("*")) h.set("Access-Control-Allow-Origin", "*");
  else if (origin && opts.allowedOrigins.includes(origin)) h.set("Access-Control-Allow-Origin", origin);
  return h;
}

function error(status: number, message: string, headers: Headers): Response {
  headers.set("Content-Type", "text/plain; charset=utf-8");
  return new Response(message, { status, headers });
}

export async function handleProxy(request: Request, opts: ProxyOptions): Promise<Response> {
  const origin = request.headers.get("Origin");
  const headers = corsHeaders(origin, opts);
  if (request.method === "OPTIONS") {
    headers.set("Access-Control-Allow-Methods", "GET");
    return new Response(null, { status: 204, headers });
  }
  if (request.method !== "GET") return error(405, "GET only", headers);
  if (origin && !headers.has("Access-Control-Allow-Origin")) return error(403, "Origin not allowed", headers);

  const params = new URL(request.url).searchParams;
  let target = isPublicHTTPURL(params.get("url") ?? "");
  if (!target) return error(400, "url must be a public http(s) URL", headers);

  const upstreamHeaders = new Headers({
    "User-Agent": opts.userAgent,
    Accept: "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5",
  });
  const etag = params.get("etag");
  const lastModified = params.get("lm");
  if (etag) upstreamHeaders.set("If-None-Match", etag);
  if (lastModified) upstreamHeaders.set("If-Modified-Since", lastModified);

  const doFetch = opts.fetch ?? fetch;
  let permanent: URL | undefined;
  let stillPermanent = true;
  let upstream: Response;
  for (let hop = 0; ; hop++) {
    try {
      upstream = await doFetch(target.href, { headers: upstreamHeaders, redirect: "manual" });
    } catch (e) {
      return error(502, `Fetch failed: ${e instanceof Error ? e.message : String(e)}`, headers);
    }
    const location = upstream.headers.get("Location");
    if (upstream.status < 300 || upstream.status >= 400 || upstream.status === 304 || !location) break;
    if (hop >= maxRedirects) return error(508, "Too many redirects", headers);
    const next = isPublicHTTPURL(new URL(location, target).href);
    if (!next) return error(400, "Redirect to a non-public URL", headers);
    stillPermanent &&= upstream.status === 301 || upstream.status === 308;
    if (stillPermanent) permanent = next;
    target = next;
  }

  headers.set("X-Srssly-Final-URL", target.href);
  if (permanent) headers.set("X-Srssly-Permanent-URL", permanent.href);
  for (const name of ["ETag", "Last-Modified"]) {
    const v = upstream.headers.get(name);
    if (v) headers.set(name, v);
  }
  if (upstream.status === 304) return new Response(null, { status: 304, headers });

  const type = upstream.headers.get("Content-Type") ?? "";
  const sniff = untyped.test(type);
  if (!sniff && !allowedTypes.test(type)) return error(415, `Unsupported content type ${type}`, headers);
  headers.set("Cache-Control", "no-store");

  const max = opts.maxBytes ?? 10 * 1024 * 1024;
  const declared = Number(upstream.headers.get("Content-Length"));
  if (declared > max) return error(413, "Too large", headers);
  const body = await readCapped(upstream, max);
  if (!body) return error(413, "Too large", headers);
  if (sniff) {
    const head = new TextDecoder().decode(body.slice(0, 512)).replace(/^[\s\uFEFF]+/, "");
    if (!head.startsWith("<") && !head.startsWith("{")) return error(415, "Unsupported content", headers);
  }
  headers.set("Content-Type", sniff ? "application/xml" : type);
  return new Response(body, { status: upstream.status, headers });
}

async function readCapped(response: Response, max: number): Promise<Uint8Array | undefined> {
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel();
      return undefined;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}
