import { useEffect, useMemo } from "react";
import { FetchError, fetchViaProxy } from "../feeds/fetch";
import { renderArticleHTML } from "../reader/render";
import { pageImages, ruleFor } from "../reader/siteRules";
import type { Article } from "../store/model";
import { formatDate } from "./ArticleList";
import { useLibrary } from "./LibraryContext";

interface Props {
  article: Article | undefined;
  onBack: () => void;
}

export function Reader({ article, onBack }: Props) {
  const lib = useLibrary();
  const sub = article ? lib.subscriptions.get(article.subscriptionID) : undefined;
  const rule = article ? ruleFor(article.link, sub?.feedURL) : undefined;

  // Site rules: fetch the page once for images the feed leaves out.
  const selectors = rule?.pageImageSelectors;
  useEffect(() => {
    if (!article?.link || !selectors || article.extraImages) return;
    const controller = new AbortController();
    const link = article.link;
    fetchViaProxy(link, {}, controller.signal)
      .then((r) => (r.status === "ok" ? r.text : undefined))
      // SMBC answers every page with a 500 status and the full page.
      .catch((e: unknown) => (e instanceof FetchError && e.status >= 500 ? e.body : undefined))
      .then((html) => (html ? lib.saveExtraImages(article.key, pageImages(html, link, selectors)) : undefined))
      .catch((e: unknown) => console.warn("Page images failed", e));
    return () => controller.abort();
  }, [article, selectors, lib]);

  const html = useMemo(() => {
    if (!article) return "";
    const source = article.contentHTML ?? article.summaryHTML ?? "";
    return renderArticleHTML(source, {
      base: article.link,
      showsImageTitles: rule?.showsImageTitles ?? false,
      extraImages: article.extraImages ?? [],
    });
  }, [article, rule]);

  if (!article) {
    return (
      <section className="reader empty" aria-label="Reader">
        <p className="hint">Pick an article.</p>
      </section>
    );
  }
  const starred = lib.isStarred(article.key);
  const summaryOnly = !article.contentHTML;
  return (
    <section className="reader" aria-label="Reader">
      <header className="pane-header">
        <button type="button" className="icon back" onClick={onBack} aria-label="Back to articles">
          ‹
        </button>
        <span className="spacer" />
        <button
          type="button"
          className="link"
          onClick={() => void lib.setState([article.key], { isRead: !lib.isRead(article.key) })}
        >
          {lib.isRead(article.key) ? "Mark unread" : "Mark read"}
        </button>
        <button
          type="button"
          className={`icon ${starred ? "on" : ""}`}
          aria-pressed={starred}
          title={starred ? "Unstar (s)" : "Star (s)"}
          onClick={() => void lib.setState([article.key], { isStarred: !starred })}
        >
          {starred ? "★" : "☆"}
        </button>
      </header>
      <article>
        <h1>
          {article.link ? (
            <a href={article.link} target="_blank" rel="noopener noreferrer">
              {article.title}
            </a>
          ) : (
            article.title
          )}
        </h1>
        <p className="byline">
          {[sub?.title, article.author, formatDate(article.date)].filter(Boolean).join(" · ")}
        </p>
        <div className="content" dangerouslySetInnerHTML={{ __html: html }} />
        {summaryOnly && article.link ? (
          <p className="read-more">
            <a href={article.link} target="_blank" rel="noopener noreferrer">
              Read the full article on the site →
            </a>
          </p>
        ) : null}
      </article>
    </section>
  );
}
