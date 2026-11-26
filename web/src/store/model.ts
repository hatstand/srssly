import type { Enclosure } from "../feeds/types";
import type { UUID } from "../core/uuid";

export type CacheMode = "automatic" | "feedContent" | "extractedArticle" | "fullPage";

/** A feed subscription. Synced: field names match the CloudKit record. */
export interface Subscription {
  id: UUID;
  feedURL: string;
  siteURL?: string;
  /** Empty until the first fetch fills it. */
  title: string;
  folder?: string;
  sortKey: string;
  cacheMode: CacheMode;
  /** Milliseconds since the epoch. */
  addedAt: number;
  modifiedAt: number;
}

/** Read/starred state for one article. Synced as `ArticleState`. */
export interface ArticleState {
  articleKey: string;
  isRead: boolean;
  isStarred: boolean;
  modifiedAt: number;
}

export interface ImageReference {
  url: string;
  alt?: string;
  title?: string;
}

/** A feed item cached on this device. Not synced: every client fetches feeds. */
export interface Article {
  key: string;
  subscriptionID: UUID;
  guid?: string;
  title: string;
  link?: string;
  author?: string;
  /** `published ?? updated`, in ms; else when first seen. */
  date: number;
  summaryHTML?: string;
  contentHTML?: string;
  enclosures: Enclosure[];
  firstSeenAt: number;
  /** Images from the linked page that the feed leaves out (site rules). */
  extraImages?: ImageReference[];
}

/** Per-feed fetch bookkeeping on this device. */
export interface FetchState {
  subscriptionID: UUID;
  etag?: string;
  lastModified?: string;
  lastFetchedAt?: number;
  lastError?: string;
}
