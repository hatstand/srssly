import DOMPurify from "dompurify";
import type { ImageReference } from "../store/model";
import { resolveURL } from "../feeds/url";

export interface RenderOptions {
  /** The article's URL, for resolving relative links and images. */
  base: string | undefined;
  showsImageTitles: boolean;
  extraImages: ImageReference[];
}

const forbidTags = ["script", "style", "iframe", "frame", "frameset", "object", "embed", "form", "input", "button",
  "textarea", "select", "link", "meta", "base"];

/**
 * Feed HTML made safe to inject: DOMPurify strips scripts, handlers and
 * styles, then links open in a new tab, URLs are resolved against the
 * article, images lazy-load without a referrer, and (for xkcd and SMBC)
 * image title text becomes a visible caption since touch screens have no
 * hover.
 */
export function renderArticleHTML(html: string, opts: RenderOptions): string {
  const fragment = DOMPurify.sanitize(html, {
    RETURN_DOM_FRAGMENT: true,
    FORBID_TAGS: forbidTags,
    FORBID_ATTR: ["style", "class", "id", "width", "height"],
    ALLOW_DATA_ATTR: false,
  });

  for (const a of Array.from(fragment.querySelectorAll("a[href]"))) {
    const href = resolveURL(a.getAttribute("href"), opts.base);
    if (href && /^https?:/i.test(href)) {
      a.setAttribute("href", href);
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", "noopener noreferrer");
    } else {
      a.removeAttribute("href");
    }
  }

  const present = new Set<string>();
  for (const img of Array.from(fragment.querySelectorAll("img"))) {
    const src = resolveURL(img.getAttribute("src") ?? img.getAttribute("data-src"), opts.base);
    if (!src) {
      img.remove();
      continue;
    }
    present.add(src);
    img.setAttribute("src", src);
    img.removeAttribute("srcset");
    img.setAttribute("loading", "lazy");
    img.setAttribute("decoding", "async");
    img.setAttribute("referrerpolicy", "no-referrer");
    if (opts.showsImageTitles) {
      const title = img.getAttribute("title")?.trim() ||
        opts.extraImages.find((x) => x.url === src)?.title;
      if (title) img.after(caption(fragment.ownerDocument, title));
    }
  }

  for (const extra of opts.extraImages) {
    if (present.has(extra.url)) continue;
    const doc = fragment.ownerDocument;
    const figure = doc.createElement("figure");
    figure.className = "srssly-extra";
    const img = doc.createElement("img");
    img.src = extra.url;
    img.alt = extra.alt ?? "";
    img.setAttribute("loading", "lazy");
    img.setAttribute("referrerpolicy", "no-referrer");
    figure.append(img);
    if (extra.title && opts.showsImageTitles) figure.append(caption(doc, extra.title));
    fragment.append(figure);
  }

  const container = fragment.ownerDocument.createElement("div");
  container.append(fragment);
  return container.innerHTML;
}

function caption(doc: Document, text: string): HTMLElement {
  const p = doc.createElement("p");
  p.className = "srssly-hover-text";
  p.textContent = text;
  return p;
}
