import { parseFeedDate } from "./dates";
import { FeedError, type ParsedFeed, type ParsedItem } from "./types";
import { resolveURL } from "./url";

/**
 * Parses RSS 2.0, RSS 1.0 (RDF) and Atom with the browser's XML parser. A
 * port of FeedParser.swift: lenient, ignores unknown elements, resolves
 * relative links against the feed URL.
 */
const NS = {
  atom: "http://www.w3.org/2005/Atom",
  rdf: "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
  rss1: "http://purl.org/rss/1.0/",
  content: "http://purl.org/rss/1.0/modules/content/",
  dc: "http://purl.org/dc/elements/1.1/",
  media: "http://search.yahoo.com/mrss/",
} as const;

export function looksLikeHTML(text: string): boolean {
  const head = text.slice(0, 1024).replace(/^[\s﻿]+/, "").toLowerCase();
  return head.startsWith("<!doctype html") || head.startsWith("<html");
}

const nonEmpty = (s: string | null | undefined): string | undefined => {
  const t = s?.trim();
  return t ? t : undefined;
};

const is = (el: Element, name: string, ns: string | null): boolean => el.localName === name && el.namespaceURI === ns;

function childElements(el: Element): Element[] {
  return Array.from(el.children);
}

/** Inner XML of an Atom `type="xhtml"` element, kept as HTML. */
function innerXML(el: Element): string {
  const serializer = new XMLSerializer();
  return Array.from(el.childNodes)
    .map((n) => serializer.serializeToString(n))
    .join("")
    .replace(/ xmlns="http:\/\/www\.w3\.org\/1999\/xhtml"/g, "");
}

function contentOf(el: Element): string | undefined {
  return el.getAttribute("type") === "xhtml" ? nonEmpty(innerXML(el)) : nonEmpty(el.textContent);
}

function parseItem(el: Element, base: string | undefined): ParsedItem {
  const item: ParsedItem = { enclosures: [] };
  let guidIsPermaLink = true;
  const set = <K extends keyof ParsedItem>(key: K, value: ParsedItem[K] | undefined): void => {
    if (value !== undefined) item[key] = value;
  };

  for (const c of childElements(el)) {
    const ns = c.namespaceURI;
    const text = c.textContent;
    if (c.localName === "title" && ns !== NS.media) {
      set("title", nonEmpty(text));
    } else if (is(c, "link", null) || is(c, "link", NS.rss1)) {
      set("link", resolveURL(text, base) ?? item.link);
    } else if (is(c, "link", NS.atom)) {
      const rel = c.getAttribute("rel") ?? "alternate";
      if (rel === "alternate" && item.link === undefined) set("link", resolveURL(c.getAttribute("href"), base));
    } else if (is(c, "guid", null)) {
      guidIsPermaLink = c.getAttribute("isPermaLink")?.toLowerCase() !== "false";
      set("guid", nonEmpty(text));
    } else if (is(c, "id", NS.atom)) {
      set("guid", nonEmpty(text));
    } else if (is(c, "description", null) || is(c, "description", NS.rss1)) {
      set("summaryHTML", nonEmpty(text));
    } else if (is(c, "summary", NS.atom)) {
      set("summaryHTML", contentOf(c));
    } else if (is(c, "encoded", NS.content)) {
      set("contentHTML", nonEmpty(text));
    } else if (is(c, "content", NS.atom)) {
      set("contentHTML", contentOf(c));
    } else if (is(c, "pubDate", null) || is(c, "published", NS.atom) || is(c, "issued", NS.atom)) {
      set("published", parseFeedDate(text) ?? item.published);
    } else if (is(c, "date", NS.dc)) {
      if (item.published === undefined) set("published", parseFeedDate(text));
    } else if (is(c, "updated", NS.atom) || is(c, "modified", NS.atom)) {
      set("updated", parseFeedDate(text));
    } else if (is(c, "creator", NS.dc) || is(c, "author", null)) {
      if (item.author === undefined) set("author", nonEmpty(text));
    } else if (is(c, "author", NS.atom)) {
      const name = childElements(c).find((n) => is(n, "name", NS.atom));
      if (item.author === undefined) set("author", nonEmpty(name?.textContent));
    } else if (is(c, "enclosure", null) || is(c, "content", NS.media)) {
      const url = resolveURL(c.getAttribute("url"), base);
      if (url) {
        const length = Number(c.getAttribute("length") ?? c.getAttribute("fileSize"));
        const mimeType = c.getAttribute("type");
        item.enclosures.push({
          url,
          ...(mimeType ? { mimeType } : {}),
          ...(Number.isFinite(length) && length > 0 ? { length } : {}),
        });
      }
    } else if (is(c, "group", NS.media)) {
      for (const m of childElements(c)) {
        const url = is(m, "content", NS.media) ? resolveURL(m.getAttribute("url"), base) : undefined;
        if (url) item.enclosures.push({ url });
      }
    }
  }
  if (item.link === undefined && guidIsPermaLink && item.guid?.startsWith("http")) {
    set("link", resolveURL(item.guid, base));
  }
  return item;
}

export function parseFeed(text: string, url?: string): ParsedFeed {
  if (looksLikeHTML(text)) throw new FeedError({ kind: "htmlPage" });
  const doc = new DOMParser().parseFromString(text, "application/xml");
  const root = doc.documentElement;
  // Browsers report errors as a <parsererror> element: as the root when
  // nothing parsed, or inside the document when it broke part way through
  // (keep what parsed, like the Swift parser).
  if (!root || root.localName === "parsererror") {
    throw new FeedError({ kind: "malformed", message: nonEmpty(root?.textContent) ?? "unknown error" });
  }
  for (const err of Array.from(doc.getElementsByTagName("parsererror"))) err.remove();

  let feed: ParsedFeed;
  if (root.localName === "rss") feed = { format: "rss2", items: [] };
  else if (is(root, "RDF", NS.rdf)) feed = { format: "rss1", items: [] };
  else if (is(root, "feed", NS.atom)) feed = { format: "atom", items: [] };
  else if (root.localName.toLowerCase() === "html") throw new FeedError({ kind: "htmlPage" });
  else throw new FeedError({ kind: "unrecognizedFormat", rootElement: root.localName });

  const walk = (parent: Element): void => {
    for (const c of childElements(parent)) {
      const ns = c.namespaceURI;
      if (is(c, "item", null) || is(c, "item", NS.rss1) || is(c, "entry", NS.atom)) {
        feed.items.push(parseItem(c, url));
      } else if (is(c, "channel", null) || is(c, "channel", NS.rss1)) {
        walk(c);
      } else if (c.localName === "title" && (ns === null || ns === NS.rss1 || ns === NS.atom)) {
        const title = feed.title ?? nonEmpty(c.textContent);
        if (title) feed.title = title;
      } else if (is(c, "link", null) || is(c, "link", NS.rss1)) {
        const site = feed.siteURL ?? resolveURL(c.textContent, url);
        if (site) feed.siteURL = site;
      } else if (is(c, "link", NS.atom) && (c.getAttribute("rel") ?? "alternate") === "alternate") {
        const site = feed.siteURL ?? resolveURL(c.getAttribute("href"), url);
        if (site) feed.siteURL = site;
      }
    }
  };
  walk(root);
  return feed;
}

/**
 * Feed URLs advertised by an HTML page's `<link rel="alternate">` tags, for
 * adding a feed by its site address (FeedDiscovery.swift).
 */
export function discoverFeeds(html: string, baseURL: string): string[] {
  const types = new Set([
    "application/rss+xml", "application/atom+xml", "application/rdf+xml",
    "application/feed+json", "application/json", "text/xml", "application/xml",
  ]);
  const doc = new DOMParser().parseFromString(html, "text/html");
  const out: string[] = [];
  for (const link of Array.from(doc.querySelectorAll("link[rel][href][type]"))) {
    const rel = (link.getAttribute("rel") ?? "").toLowerCase().split(/\s+/);
    const type = (link.getAttribute("type") ?? "").toLowerCase();
    if (!rel.includes("alternate") || !types.has(type)) continue;
    const url = resolveURL(link.getAttribute("href"), baseURL);
    if (url && !out.includes(url)) out.push(url);
  }
  return out;
}
