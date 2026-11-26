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
