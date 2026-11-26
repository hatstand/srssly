import { useState } from "react";
import type { Article } from "../store/model";
import { useLibrary } from "./LibraryContext";

interface Props {
  title: string;
  articles: Article[];
  selected: string | undefined;
  unreadOnly: boolean;
  onToggleUnreadOnly: () => void;
  onSelect: (key: string) => void;
  onBack: () => void;
}

const dateFormat = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

export function formatDate(ms: number): string {
  const d = new Date(ms);
  return d.toDateString() === new Date().toDateString() ? timeFormat.format(d) : dateFormat.format(d);
}

const snippets = new WeakMap<Article, string>();

/** Plain-text preview. DOMParser documents are inert: nothing loads or runs. */
function snippet(a: Article): string {
  let text = snippets.get(a);
  if (text === undefined) {
    const html = a.summaryHTML ?? a.contentHTML ?? "";
    text = (new DOMParser().parseFromString(html, "text/html").body.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 160);
    snippets.set(a, text);
  }
  return text;
}

const pageSize = 300;

export function ArticleList({ title, articles, selected, unreadOnly, onToggleUnreadOnly, onSelect, onBack }: Props) {
  const lib = useLibrary();
  const [limit, setLimit] = useState(pageSize);
  const unreadKeys = articles.filter((a) => !lib.isRead(a.key)).map((a) => a.key);
  return (
    <section className="list" aria-label="Articles">
      <header className="pane-header">
        <button type="button" className="icon back" onClick={onBack} aria-label="Back to subscriptions">
          ‹
        </button>
        <h2>{title}</h2>
        <button type="button" className="link" onClick={onToggleUnreadOnly}>
          {unreadOnly ? "Show all" : "Unread only"}
        </button>
        <button
          type="button"
          className="link"
          disabled={unreadKeys.length === 0}
          onClick={() => void lib.setState(unreadKeys, { isRead: true })}
        >
          Mark all read
        </button>
      </header>
      {articles.length === 0 ? <p className="hint">{lib.loaded ? "Nothing here." : ""}</p> : null}
      <ol>
        {articles.slice(0, limit).map((a) => {
          const sub = lib.subscriptions.get(a.subscriptionID);
          return (
            <li key={a.key}>
              <button
                type="button"
                className={`row ${a.key === selected ? "selected" : ""} ${lib.isRead(a.key) ? "read" : ""}`}
                onClick={() => onSelect(a.key)}
              >
                <span className="meta">
                  <span className="feed">{sub?.title}</span>
                  {lib.isStarred(a.key) ? <span className="star">★</span> : null}
                  <time>{formatDate(a.date)}</time>
                </span>
                <span className="title">{a.title}</span>
                <span className="snippet">{snippet(a)}</span>
              </button>
            </li>
          );
        })}
      </ol>
      {articles.length > limit ? (
        <button type="button" className="link more" onClick={() => setLimit((n) => n + pageSize)}>
          Show more
        </button>
      ) : null}
    </section>
  );
}
