import { FeedError, type ParsedFeed } from "./types";
import { discoverFeeds, parseFeed } from "./parse";

/** Base URL of the CORS proxy (proxy/handler.ts). Same-origin `/proxy` in dev. */
export const proxyBase: string = import.meta.env.VITE_PROXY_URL ?? "/proxy";

export interface Validators {
  etag?: string;
  lastModified?: string;
}

export type FetchResult =
  | { status: "notModified"; validators: Validators }
  | {
      status: "ok";
      text: string;
      contentType: string;
      finalURL: string;
      /** Set when the URL moved permanently: store it as the new feed URL. */
      permanentURL?: string;
      validators: Validators;
    };

export class FetchError extends Error {
  readonly status: number;
  /** The error response's body: some sites (SMBC) serve real pages as 500s. */
  readonly body: string;
  constructor(status: number, body: string) {
    super(`HTTP ${status}${body.length < 200 && body ? `: ${body}` : ""}`);
    this.status = status;
    this.body = body;
  }
}

export function proxied(url: string, validators: Validators = {}): string {
  const params = new URLSearchParams({ url });
  if (validators.etag) params.set("etag", validators.etag);
  if (validators.lastModified) params.set("lm", validators.lastModified);
  const base = new URL(proxyBase, location.href);
  base.search = params.toString();
  return base.href;
}

/** Decodes using the HTTP charset, else the XML prolog's encoding, else UTF-8. */
export function decode(bytes: ArrayBuffer, contentType: string): string {
  const header = /charset=["']?([\w-]+)/i.exec(contentType)?.[1];
  const head = new TextDecoder("latin1").decode(bytes.slice(0, 200));
  const prolog = /^\s*<\?xml[^>]*encoding=["']([\w-]+)["']/i.exec(head)?.[1];
  for (const label of [header, prolog, "utf-8"]) {
    if (!label) continue;
    try {
      return new TextDecoder(label).decode(bytes);
    } catch {
      // unknown label: try the next
    }
  }
  return new TextDecoder().decode(bytes);
}

export async function fetchViaProxy(url: string, validators: Validators = {}, signal?: AbortSignal): Promise<FetchResult> {
  const res = await fetch(proxied(url, validators), signal ? { signal } : {});
  const etag = res.headers.get("ETag");
  const lastModified = res.headers.get("Last-Modified");
  const next: Validators = { ...(etag ? { etag } : {}), ...(lastModified ? { lastModified } : {}) };
  if (res.status === 304) return { status: "notModified", validators: { ...validators, ...next } };
  if (!res.ok) throw new FetchError(res.status, await res.text());
  const contentType = res.headers.get("Content-Type") ?? "";
  const permanentURL = res.headers.get("X-Srssly-Permanent-URL");
  return {
    status: "ok",
    text: decode(await res.arrayBuffer(), contentType),
    contentType,
    finalURL: res.headers.get("X-Srssly-Final-URL") ?? url,
    ...(permanentURL ? { permanentURL } : {}),
    validators: next,
  };
}

/**
 * Fetches a feed, following an HTML page's advertised feed link when the URL
 * turns out to be a site rather than a feed (adding by site address, or an
 * old feed URL that now redirects to the home page).
 */
export async function fetchFeed(
  url: string,
  validators: Validators = {},
  signal?: AbortSignal,
): Promise<{ result: FetchResult; feed?: ParsedFeed; feedURL: string }> {
  const result = await fetchViaProxy(url, validators, signal);
  if (result.status === "notModified") return { result, feedURL: url };
  try {
    return { result, feed: parseFeed(result.text, result.finalURL), feedURL: result.permanentURL ?? url };
  } catch (e) {
    if (!(e instanceof FeedError) || e.detail.kind !== "htmlPage") throw e;
    const [discovered] = discoverFeeds(result.text, result.finalURL);
    if (!discovered || discovered === url) throw e;
    const again = await fetchViaProxy(discovered, {}, signal);
    if (again.status === "notModified") throw e;
    return { result: again, feed: parseFeed(again.text, again.finalURL), feedURL: again.permanentURL ?? discovered };
  }
}
