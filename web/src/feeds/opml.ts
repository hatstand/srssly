export interface OPMLFeed {
  title: string;
  feedURL: string;
  siteURL?: string;
  /** The outermost folder it was in (Feedly only uses one level). */
  folder?: string;
}

/** Feeds in document order. Outlines without an `xmlUrl` are folders. */
export function parseOPML(text: string): OPMLFeed[] {
  const doc = new DOMParser().parseFromString(text, "application/xml");
  const root = doc.documentElement;
  if (!root || root.localName.toLowerCase() !== "opml") throw new Error("Not an OPML file");
  const feeds: OPMLFeed[] = [];
  const visit = (el: Element, folder: string | undefined): void => {
    for (const o of Array.from(el.children)) {
      if (o.localName !== "outline") {
        visit(o, folder);
        continue;
      }
      const title = (o.getAttribute("title") ?? o.getAttribute("text"))?.trim() || undefined;
      const xml = (o.getAttribute("xmlUrl") ?? o.getAttribute("xmlurl"))?.trim();
      if (xml && /^https?:\/\//i.test(xml)) {
        const site = o.getAttribute("htmlUrl") ?? o.getAttribute("htmlurl");
        let fallback = xml;
        try {
          fallback = new URL(xml).host;
        } catch {
          // keep the raw URL
        }
        feeds.push({
          title: title ?? fallback,
          feedURL: xml,
          ...(site ? { siteURL: site } : {}),
          ...(folder ? { folder } : {}),
        });
      } else {
        visit(o, folder ?? title);
      }
    }
  };
  visit(root, undefined);
  return feeds;
}
