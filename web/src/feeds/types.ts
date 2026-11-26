export type FeedFormat = "rss2" | "rss1" | "atom";

export interface Enclosure {
  url: string;
  mimeType?: string;
  length?: number;
}

export interface ParsedItem {
  guid?: string;
  title?: string;
  link?: string;
  author?: string;
  published?: Date;
  updated?: Date;
  /** RSS `description` or Atom `summary`. Often HTML. */
  summaryHTML?: string;
  /** RSS `content:encoded` or Atom `content`. Usually the full post. */
  contentHTML?: string;
  enclosures: Enclosure[];
}

export interface ParsedFeed {
  format: FeedFormat;
  title?: string;
  siteURL?: string;
  items: ParsedItem[];
}

export type FeedParseError =
  | { kind: "htmlPage" }
  | { kind: "unrecognizedFormat"; rootElement: string }
  | { kind: "malformed"; message: string };

export class FeedError extends Error {
  readonly detail: FeedParseError;
  constructor(detail: FeedParseError) {
    super(detail.kind === "malformed" ? `Malformed feed: ${detail.message}` : detail.kind);
    this.detail = detail;
  }
}

/** The best date to sort by. */
export const itemDate = (item: ParsedItem): Date | undefined => item.published ?? item.updated;
