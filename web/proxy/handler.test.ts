import { describe, expect, it } from "vitest";
import { handleProxy, isPublicHTTPURL } from "./handler";

const opts = (responses: Record<string, Response>) => ({
  allowedOrigins: ["https://app.example"],
  userAgent: "test",
  fetch: (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const r = responses[url];
    if (!r) throw new Error(`unexpected fetch ${url}`);
    expect(init?.redirect).toBe("manual");
    return r.clone();
  }) as typeof fetch,
});

const get = (target: string, extra = "", origin = "https://app.example") =>
  new Request(`https://proxy.example/proxy?url=${encodeURIComponent(target)}${extra}`, { headers: { Origin: origin } });

describe("feed proxy", () => {
  it("rejects private and non-HTTP targets", () => {
    for (const bad of ["file:///etc/passwd", "http://localhost/", "http://127.0.0.1/", "http://10.1.2.3/",
      "http://192.168.0.1/", "http://169.254.169.254/latest", "http://[::1]/", "http://u:p@example.com/"]) {
      expect(isPublicHTTPURL(bad), bad).toBeUndefined();
    }
    expect(isPublicHTTPURL("https://xkcd.com/rss.xml")?.href).toBe("https://xkcd.com/rss.xml");
  });

  it("passes a feed through with CORS and validators", async () => {
    const res = await handleProxy(get("https://xkcd.com/rss.xml"), opts({
      "https://xkcd.com/rss.xml": new Response("<rss/>", { headers: { "Content-Type": "application/rss+xml", ETag: '"1"' } }),
    }));
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("<rss/>");
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("https://app.example");
    expect(res.headers.get("ETag")).toBe('"1"');
    expect(res.headers.get("X-Srssly-Permanent-URL")).toBeNull();
  });

  it("reports permanent redirects but not temporary ones after them", async () => {
    const res = await handleProxy(get("http://a.example/feed"), opts({
      "http://a.example/feed": new Response(null, { status: 301, headers: { Location: "https://a.example/feed" } }),
      "https://a.example/feed": new Response(null, { status: 302, headers: { Location: "/cdn/feed.xml" } }),
      "https://a.example/cdn/feed.xml": new Response("<rss/>", { headers: { "Content-Type": "text/xml" } }),
    }));
    expect(res.headers.get("X-Srssly-Final-URL")).toBe("https://a.example/cdn/feed.xml");
    expect(res.headers.get("X-Srssly-Permanent-URL")).toBe("https://a.example/feed");
  });

  it("refuses unknown origins, binaries and redirects into private networks", async () => {
    expect((await handleProxy(get("https://x.example/", "", "https://evil.example"), opts({}))).status).toBe(403);
    expect((await handleProxy(get("https://x.example/a.zip"), opts({
      "https://x.example/a.zip": new Response("PK", { headers: { "Content-Type": "application/zip" } }),
    }))).status).toBe(415);
    expect((await handleProxy(get("https://x.example/b"), opts({
      "https://x.example/b": new Response("\x00\x01", { headers: { "Content-Type": "application/octet-stream" } }),
    }))).status).toBe(415);
    for (const type of ["application/x-rss+xml", "application/feed+json", "text/html; charset=utf-8", "application/octet-stream"]) {
      const ok = await handleProxy(get("https://x.example/f"), opts({
        "https://x.example/f": new Response("<rss/>", { headers: { "Content-Type": type } }),
      }));
      expect(ok.status, type).toBe(200);
    }
    expect((await handleProxy(get("https://x.example/r"), opts({
      "https://x.example/r": new Response(null, { status: 302, headers: { Location: "http://127.0.0.1/admin" } }),
    }))).status).toBe(400);
  });

  it("forwards conditional GET validators and passes 304 through", async () => {
    let seen: Headers | undefined;
    const res = await handleProxy(get("https://x.example/feed", "&etag=%22abc%22"), {
      ...opts({}),
      fetch: (async (_: unknown, init?: RequestInit) => {
        seen = new Headers(init?.headers);
        return new Response(null, { status: 304, headers: { ETag: '"abc"' } });
      }) as typeof fetch,
    });
    expect(seen?.get("If-None-Match")).toBe('"abc"');
    expect(res.status).toBe(304);
  });
});
