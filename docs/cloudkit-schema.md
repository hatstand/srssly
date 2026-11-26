# CloudKit schema

Srssly syncs through CloudKit with its own record types (not SwiftData's
automatic mirroring), so other clients, such as a web app using
[CloudKit JS](https://developer.apple.com/documentation/cloudkitjs) or the
CloudKit Web Services, can read and write the same data.

- **Container:** `iCloud.com.purplehatstands.srssly`
- **Database:** private
- **Zone:** `Srssly` (custom zone)
- **Conflicts:** merged field by field. Each client keeps a copy of every
  record as it last saw it on the server (the *base*). When the server copy
  has changed, a field the client edited since the base keeps the client's
  value, and any other field takes the server's. Only when both sides changed
  the *same* field does the later `modifiedAt` win (the server wins exact
  ties). A client must set `modifiedAt` to the current time whenever it
  changes a record.
- **Booleans** are `Int64` 0 or 1.

Only user-authored state syncs. Articles aren't synced: every client fetches
the feeds itself.

## `Subscription`

Record name: the subscription's UUID, lowercase. New subscriptions use a
version 5 UUID of the feed's canonical URL, so two clients subscribing to
the same feed create the same record instead of a duplicate:

- Namespace: `3b0f6f1e-6a3c-5d2b-9a57-5352535353c1`
- Name: the canonical key, which is the URL without its scheme, a leading
  `www.`, default ports, the fragment or a trailing slash, with the host
  lowercased. For example `http://www.popehat.com/feed/` → `popehat.com/feed`.
  See `FeedURL.canonicalKey`.

The ID never changes afterwards, even if `feedURL` does.

| Field | Type | Notes |
|---|---|---|
| `feedURL` | String | The URL to fetch. Updated when the feed moves permanently. |
| `siteURL` | String? | The site's home page. |
| `title` | String | Display name. Empty until the first fetch fills it. |
| `folder` | String? | Folder name, or none. |
| `sortKey` | String | Order within the list: sort ascending by plain string comparison. A fractional key of lowercase letters `a-z` only (so case-insensitive and localized sorts agree), and a new key always fits between two others. See `SortKey`. |
| `cacheMode` | String | `automatic`, `feedContent`, `extractedArticle` or `fullPage`. |
| `addedAt` | Date/time | |
| `modifiedAt` | Date/time | Last change, for conflicts. |

Deleting a subscription deletes its record.

## `ArticleState`

Read and starred state for one article. Records exist only for articles the
user has touched.

Record name: the article key, `<subscription UUID>:<32 hex chars>`.

| Field | Type | Notes |
|---|---|---|
| `articleKey` | String | Same as the record name. |
| `subscriptionID` | String | The subscription UUID (prefix of the key), for queries. |
| `isRead` | Int64 | 0 or 1 |
| `isStarred` | Int64 | 0 or 1 |
| `modifiedAt` | Date/time | Last change, for conflicts. |

### Computing an article key

The hex part is the first 16 bytes of SHA-256, as lowercase hex, of the
item's identity in the feed:

1. `"g:" + guid` (RSS `guid` or Atom `id`), trimmed, if present; otherwise
2. `"l:" + link` (the item URL as a string), if present; otherwise
3. `"t:" + title + "|" + publishedUnixSeconds` (empty string when there is no date).

See `ArticleKey.make` in `Packages/SrsslyCore/Sources/SrsslyCore/ArticleKey.swift`.

## Deploying

[`cloudkit/schema.ckdb`](../cloudkit/schema.ckdb) is this schema in
CloudKit's schema language. Keep it in step with the tables above and with
`CloudSchema` in `CloudRecords.swift`.

Production never changes by itself. The development schema only grows as
debug builds save records, and a field that has only ever been nil (say
`folder`) never gets created, so TestFlight and App Store builds would fail
to save it. So before the first TestFlight build, and after any schema
change:

1. Get a management token: CloudKit Console → (account menu) → Manage
   Tokens → CloudKit Management Token, then
   `xcrun cktool save-token --type management`.
2. Load the file into development (this only adds; it never removes
   fields production has):

   ```sh
   xcrun cktool validate-schema --team-id CZ8XD8GTGZ \
     --container-id iCloud.com.purplehatstands.srssly \
     --environment development --file cloudkit/schema.ckdb
   xcrun cktool import-schema --team-id CZ8XD8GTGZ \
     --container-id iCloud.com.purplehatstands.srssly \
     --environment development --file cloudkit/schema.ckdb
   ```

3. In the [CloudKit Console](https://icloud.developer.apple.com/), pick the
   container → Schema → Deploy Schema Changes, check the diff lists only
   `Subscription` and `ArticleState` changes, and deploy.

Production schema changes are add-only: a field or record type can never be
removed or retyped once deployed, so change the schema with care.

Add queryable indexes on `ArticleState.subscriptionID` and `modifiedAt` when
a web client needs to query by them (indexes can be added later).
