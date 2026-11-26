import { middleKey } from "../core/sortKey";
import { parseUUID } from "../core/uuid";
import type { ArticleState, CacheMode, Subscription } from "../store/model";

/**
 * The CloudKit schema shared with iOS (docs/cloudkit-schema.md and
 * CloudRecords.swift): private database, zone `Srssly`, plain field types,
 * booleans as Int64 0/1, dates as TIMESTAMP (ms since the epoch on the web).
 */
export const zoneName = "Srssly";
export const containerIdentifier = "iCloud.com.purplehatstands.srssly";

export type FieldValue = string | number | null;

/** A record as CloudKit JS and the web services represent it. */
export interface CKRecord {
  recordName: string;
  recordType: "Subscription" | "ArticleState" | string;
  recordChangeTag?: string;
  fields: Record<string, { value: FieldValue; type?: string } | undefined>;
  deleted?: boolean;
}

/** The synced values of a subscription, for comparing and merging. */
export interface SubscriptionFields {
  feedURL: string;
  siteURL: string | null;
  title: string;
  folder: string | null;
  sortKey: string;
  cacheMode: string;
  addedAt: number;
}

export interface ArticleStateFields {
  isRead: boolean;
  isStarred: boolean;
}

const cacheModes: readonly CacheMode[] = ["automatic", "feedContent", "extractedArticle", "fullPage"];

const str = (r: CKRecord, k: string): string | null => {
  const v = r.fields[k]?.value;
  return typeof v === "string" ? v : null;
};
const num = (r: CKRecord, k: string): number | null => {
  const v = r.fields[k]?.value;
  return typeof v === "number" ? v : typeof v === "string" && v !== "" && !Number.isNaN(Number(v)) ? Number(v) : null;
};

export function subscriptionFields(s: Subscription): SubscriptionFields {
  return {
    feedURL: s.feedURL,
    siteURL: s.siteURL ?? null,
    title: s.title,
    folder: s.folder ?? null,
    sortKey: s.sortKey,
    cacheMode: s.cacheMode,
    addedAt: s.addedAt,
  };
}

export function subscriptionFieldsFromRecord(r: CKRecord): SubscriptionFields | undefined {
  const feedURL = str(r, "feedURL");
  if (feedURL === null) return undefined;
  return {
    feedURL,
    siteURL: str(r, "siteURL"),
    title: str(r, "title") ?? "",
    folder: str(r, "folder"),
    sortKey: str(r, "sortKey") ?? middleKey,
    cacheMode: str(r, "cacheMode") ?? "automatic",
    addedAt: num(r, "addedAt") ?? 0,
  };
}

/** Applies synced fields to a subscription (or creates one). */
export function withSubscriptionFields(id: string, f: SubscriptionFields, modifiedAt: number, old?: Subscription): Subscription | undefined {
  const uuid = parseUUID(id);
  if (!uuid) return undefined;
  const sub: Subscription = {
    ...(old ?? {}),
    id: uuid,
    feedURL: f.feedURL,
    title: f.title,
    sortKey: f.sortKey,
    cacheMode: (cacheModes as readonly string[]).includes(f.cacheMode) ? (f.cacheMode as CacheMode) : "automatic",
    addedAt: f.addedAt,
    modifiedAt,
  };
  if (f.siteURL !== null) sub.siteURL = f.siteURL;
  else delete sub.siteURL;
  if (f.folder !== null) sub.folder = f.folder;
  else delete sub.folder;
  return sub;
}

export function subscriptionRecord(s: Subscription, recordChangeTag?: string): CKRecord {
  const f = subscriptionFields(s);
  return {
    recordName: s.id,
    recordType: "Subscription",
    ...(recordChangeTag ? { recordChangeTag } : {}),
    fields: {
      feedURL: { value: f.feedURL },
      siteURL: { value: f.siteURL },
      title: { value: f.title },
      folder: { value: f.folder },
      sortKey: { value: f.sortKey },
      cacheMode: { value: f.cacheMode },
      addedAt: { value: f.addedAt, type: "TIMESTAMP" },
      modifiedAt: { value: s.modifiedAt, type: "TIMESTAMP" },
    },
  };
}

export const stateFields = (s: ArticleState): ArticleStateFields => ({ isRead: s.isRead, isStarred: s.isStarred });

export function stateFieldsFromRecord(r: CKRecord): ArticleStateFields {
  return { isRead: (num(r, "isRead") ?? 0) !== 0, isStarred: (num(r, "isStarred") ?? 0) !== 0 };
}

export function stateRecord(s: ArticleState, recordChangeTag?: string): CKRecord {
  return {
    recordName: s.articleKey,
    recordType: "ArticleState",
    ...(recordChangeTag ? { recordChangeTag } : {}),
    fields: {
      articleKey: { value: s.articleKey },
      // The subscription's ID on its own, so clients can query by it.
      subscriptionID: { value: s.articleKey.split(":", 1)[0] ?? "" },
      isRead: { value: s.isRead ? 1 : 0, type: "INT64" },
      isStarred: { value: s.isStarred ? 1 : 0, type: "INT64" },
      modifiedAt: { value: s.modifiedAt, type: "TIMESTAMP" },
    },
  };
}

export const modifiedAtOf = (r: CKRecord): number | null => num(r, "modifiedAt");

/**
 * Three-way pick for one field, as `ThreeWay.pick` on iOS: each side keeps
 * what it changed since the base; a same-field clash goes to `localWinsTies`.
 */
function pick<T>(base: T, local: T, remote: T, localWinsTies: boolean): T {
  const eq = (a: T, b: T): boolean => a === b;
  if (eq(local, base)) return remote;
  if (eq(remote, base)) return local;
  if (eq(local, remote)) return local;
  return localWinsTies ? local : remote;
}

/** Field-by-field merge. Without a base, the whole record goes to the tie winner. */
export function mergeFields<T extends object>(base: T | undefined, local: T, remote: T, localWinsTies: boolean): T {
  if (!base) return localWinsTies ? local : remote;
  const out = { ...remote };
  for (const k of Object.keys(remote) as (keyof T)[]) {
    out[k] = pick(base[k], local[k], remote[k], localWinsTies);
  }
  return out;
}

/** The later `modifiedAt` wins a same-field clash; the server wins exact ties. */
export const remoteWins = (local: number, remote: number | null): boolean => remote !== null && remote >= local;

export function sameFields<T extends object>(a: T | undefined, b: T | undefined): boolean {
  if (!a || !b) return a === b;
  return (Object.keys(a) as (keyof T)[]).every((k) => a[k] === b[k]) && Object.keys(a).length === Object.keys(b).length;
}
