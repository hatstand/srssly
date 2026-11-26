import type { ImageReference } from "../store/model";
import type { CacheMode } from "../store/model";
import { hostOf, resolveURL } from "../feeds/url";

/** Special handling for one site. Port of SiteRules.swift. */
export interface SiteRule {
  name: string;
  /** Hosts without `www.`; subdomains match too. */
  hosts: string[];
  cacheMode?: CacheMode;
  /** Selectors for page images the feed leaves out (SMBC's bonus panel). */
  pageImageSelectors?: string[];
  /** Image `title` text is content (hover text): show it as a caption. */
  showsImageTitles?: boolean;
}

export const builtInRules: SiteRule[] = [
  { name: "xkcd", hosts: ["xkcd.com"], showsImageTitles: true },
  { name: "SMBC", hosts: ["smbc-comics.com"], pageImageSelectors: ["#cc-comic", "#aftercomic img"], showsImageTitles: true },
  { name: "The Oatmeal", hosts: ["theoatmeal.com"], cacheMode: "fullPage" },
  { name: "Looking For Group", hosts: ["lfg.co"], cacheMode: "fullPage" },
  { name: "Penny Arcade", hosts: ["penny-arcade.com"], cacheMode: "fullPage" },
  { name: "Tapas", hosts: ["tapas.io", "tapastic.com"], cacheMode: "fullPage" },
  { name: "Photoshop Phriday", hosts: ["somethingawful.com"], cacheMode: "fullPage" },
];

const matches = (rule: SiteRule, url: string): boolean => {
  const host = hostOf(url);
  return host !== undefined && rule.hosts.some((h) => host === h || host.endsWith(`.${h}`));
};

/** The rule for an article, by its link, else its feed's URL. */
export function ruleFor(link: string | undefined, feedURL: string | undefined, rules = builtInRules): SiteRule | undefined {
  for (const url of [link, feedURL]) {
    if (!url) continue;
    const rule = rules.find((r) => matches(r, url));
    if (rule) return rule;
  }
  return undefined;
}

/** Images on a page that match the selectors, in page order, resolved. */
export function pageImages(html: string, pageURL: string, selectors: string[]): ImageReference[] {
  if (selectors.length === 0) return [];
  const doc = new DOMParser().parseFromString(html, "text/html");
  const seen = new Set<string>();
  const out: ImageReference[] = [];
  for (const el of Array.from(doc.querySelectorAll(selectors.join(", ")))) {
    if (el.localName !== "img") continue;
    const attr = (n: string): string | undefined => el.getAttribute(n)?.trim() || undefined;
    const url = resolveURL(attr("src") ?? attr("data-src"), pageURL);
    if (!url || seen.has(url)) continue;
    seen.add(url);
    const alt = attr("alt");
    const title = attr("title");
    out.push({ url, ...(alt ? { alt } : {}), ...(title ? { title } : {}) });
  }
  return out;
}
