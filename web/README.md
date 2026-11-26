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

## iCloud sync

`src/sync/` syncs subscriptions and read/starred state with the iOS app
through the user's private CloudKit database, using the schema in
[docs/cloudkit-schema.md](../docs/cloudkit-schema.md) unchanged. It works
like `CloudSync` on iOS: each record keeps the server's fields as last seen
(the base), local edits are records whose fields differ from the base, and
fetched changes merge field by field (`modifiedAt` breaks same-field ties,
the server wins exact ties). It fetches changes with the zone's sync token,
so no queryable indexes are needed.

CloudKit JS (Apple's script) only loads when a token is configured and
after the app has rendered, so it never delays the first paint. Without a
token the app works the same, just without sync.

### Setting up sync (manual, John)

1. [CloudKit Console](https://icloud.developer.apple.com/) → the
   `iCloud.com.purplehatstands.srssly` container → **API Access** → **API
   Tokens** → add a token:
   - Sign in callback: **postMessage**
   - Allowed origins: `http://localhost:5173` (plus the deployed origin later)
   - Discoverability / sign-in: the defaults are fine
2. Put it in `web/.env.local` (git-ignored):

   ```sh
   VITE_CLOUDKIT_API_TOKEN=<token>
   VITE_CLOUDKIT_ENVIRONMENT=development   # debug builds from Xcode
   ```

   Use `production` to share data with TestFlight and App Store builds (after
   the schema is deployed to production, see docs/cloudkit-schema.md).
   Tokens are per environment, so create one for each.
3. `npm run dev`, then click **Sign in with Apple ID** in the sidebar.

**Advanced Data Protection:** with ADP on, Apple may refuse web access to
the private database (`ACCESS_DENIED`, "private db access disabled for this
account"), possibly even with *Access iCloud Data on the Web* turned on.
The app shows that error in the sidebar and carries on without sync.
