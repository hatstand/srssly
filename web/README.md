# Srssly web (prototype)

A browser client for Srssly, sharing subscriptions and read/starred state
with the iOS app through the CloudKit schema in
[docs/cloudkit-schema.md](../docs/cloudkit-schema.md).

Vite, React and TypeScript with `strict` plus the stricter extras
(`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, …).

```sh
cd web
npm install
npm run dev        # http://localhost:5173
npm test           # vitest
npm run typecheck
npm run build      # dist/
```

## Layout

- `src/core/`: ports of the iOS identity rules that must match byte for
  byte: `canonicalKey` and `subscriptionID` (FeedURL.swift), `articleKey`
  (ArticleKey.swift) and fractional sort keys (SortKey.swift). The tests use
  vectors computed with Python's `uuid` and `hashlib`, independently of
  both ports.
- `src/feeds/`: feed parsing (RSS 2, RSS 1, Atom via `DOMParser`), dates,
  OPML and feed autodiscovery, ported from SrsslyCore with its tests.
- `src/store/`: the `Library`, held in memory and written through to
  IndexedDB. The UI renders from it at once and never waits on the network;
  refreshes run in the background (six at a time, conditional GET).
- `src/reader/`: sanitizing feed HTML (DOMPurify) and the site rules: xkcd and
  SMBC hover text as captions, SMBC's red-button bonus panel from the page.
- `src/ui/`: React components. Three panes on wide screens, one at a time on
  phones. Keys: `j`/`k` next/previous, `s` star, `m` read/unread, `o` open.
- `proxy/`: the feed proxy (below).

## Why a proxy

Browsers only let a page read a cross-site response when the site sends
CORS headers, and almost no feeds do. So the web client fetches feeds and
pages through `proxy/handler.ts`, a stateless pass-through:

- `npm run dev` serves it at `/proxy` from the Vite dev server, so local
  development needs nothing else.
- For a deployed client it runs as a Cloudflare Worker (`proxy/worker.ts`).

Privacy: the proxy stores nothing and logs nothing, and the sites see the
proxy's IP address rather than the reader's. It only fetches public http(s)
URLs (no private or local addresses), only returns feed, HTML and text
content, caps responses at 10 MB, and only answers the origins in
`ALLOWED_ORIGINS`. Images in articles still load directly from their sites.

### Deploying the Worker (manual, John)

1. `npx wrangler login` (a free Cloudflare account is enough).
2. Set `ALLOWED_ORIGINS` in `proxy/wrangler.toml` to the web client's origin.
3. `npx wrangler deploy --config proxy/wrangler.toml`.
4. In the Cloudflare dashboard, check Workers → srssly-proxy → Settings:
   Observability / Workers Logs off, no Logpush jobs, no KV/D1 bindings.
5. Build the client with `VITE_PROXY_URL=https://srssly-proxy.<you>.workers.dev npm run build`.
