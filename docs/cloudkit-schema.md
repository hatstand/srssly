# CloudKit schema

Srssly syncs through CloudKit with its own record types (not SwiftData's
automatic mirroring), so other clients, such as a web app using
[CloudKit JS](https://developer.apple.com/documentation/cloudkitjs) or the
CloudKit Web Services, can read and write the same data.

- **Container:** `iCloud.com.purplehatstands.srssly`
- **Database:** private
- **Zone:** `Srssly` (custom zone)
- **Conflicts:** last writer wins, by each record's `modifiedAt`. A client
  must set `modifiedAt` to the current time whenever it changes a record.
- **Booleans** are `Int64` 0 or 1.

Only user-authored state syncs. Articles aren't synced: every client fetches
the feeds itself.

## `Subscription`

Record name: the subscription's UUID, lowercase (e.g. `6f1c2d3e-…`).

| Field | Type | Notes |
|---|---|---|
| `feedURL` | String | The URL to fetch. Updated when the feed moves permanently. |
| `siteURL` | String? | The site's home page. |
| `title` | String | Display name. Empty until the first fetch fills it. |
| `folder` | String? | Folder name, or none. |
| `sortIndex` | Int64 | Order within the list. |
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

The development schema is created automatically when a signed debug build
first saves records. Before a TestFlight or App Store release, deploy it to
production in the CloudKit Console (Schema → Deploy Schema Changes). Add
queryable indexes on `ArticleState.subscriptionID` and `modifiedAt` if a web
client needs to query by them.
