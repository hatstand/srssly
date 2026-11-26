import { type FormEvent, useRef, useState } from "react";
import { parseOPML } from "../feeds/opml";
import type { Subscription } from "../store/model";
import { useLibrary } from "./LibraryContext";
import { type Source, sameSource } from "./selection";

interface Props {
  source: Source;
  onSelect: (s: Source) => void;
  syncSlot?: React.ReactNode;
}

export function Sidebar({ source, onSelect, syncSlot }: Props) {
  const lib = useLibrary();
  const [adding, setAdding] = useState(false);
  const [url, setURL] = useState("");
  const [error, setError] = useState<string>();
  const fileInput = useRef<HTMLInputElement>(null);

  const subs = lib.sortedSubscriptions();
  const groups = new Map<string | undefined, Subscription[]>();
  for (const s of subs) groups.set(s.folder, [...(groups.get(s.folder) ?? []), s]);
  const totalUnread = subs.reduce((n, s) => n + lib.unreadCount(s.id), 0);

  async function add(e: FormEvent): Promise<void> {
    e.preventDefault();
    setError(undefined);
    setAdding(true);
    try {
      const sub = await lib.addSubscription(url);
      setURL("");
      onSelect({ kind: "feed", id: sub.id });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setAdding(false);
    }
  }

  async function importFile(file: File): Promise<void> {
    setError(undefined);
    try {
      const n = await lib.importOPML(parseOPML(await file.text()));
      setError(n === 0 ? "No new feeds in that file." : undefined);
      void lib.refreshAll();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  const item = (s: Source, label: string, count?: number, extra?: string) => (
    <li>
      <button
        type="button"
        className={`source ${sameSource(s, source) ? "selected" : ""} ${extra ?? ""}`}
        onClick={() => onSelect(s)}
      >
        <span className="label">{label}</span>
        {count ? <span className="count">{count}</span> : null}
      </button>
    </li>
  );

  const feedItem = (s: Subscription) => {
    const state = lib.fetchStates.get(s.id);
    const extra = lib.refreshing.has(s.id) ? "refreshing" : state?.lastError ? "failing" : "";
    return <ul key={s.id}>{item({ kind: "feed", id: s.id }, s.title || s.feedURL, lib.unreadCount(s.id), extra)}</ul>;
  };

  return (
    <nav className="sidebar" aria-label="Subscriptions">
      <header className="pane-header">
        <h1>Srssly</h1>
        <button type="button" className="icon" title="Refresh all" onClick={() => void lib.refreshAll(true)}>
          ↻
        </button>
      </header>
      <ul className="sources">
        {item({ kind: "all" }, "All unread", totalUnread)}
        {item({ kind: "starred" }, "Starred")}
      </ul>
      {[...groups.entries()].map(([folder, list]) => (
        <section key={folder ?? ""} className="folder">
          {folder ? <ul>{item({ kind: "folder", name: folder }, folder, list.reduce((n, s) => n + lib.unreadCount(s.id), 0), "folder-name")}</ul> : null}
          {list.map(feedItem)}
        </section>
      ))}
      {lib.loaded && subs.length === 0 ? (
        <p className="hint">Add a feed or import an OPML file (Feedly: Organize → Export OPML).</p>
      ) : null}
      <form className="add-feed" onSubmit={(e) => void add(e)}>
        <input
          type="url"
          required
          placeholder="Feed or site URL"
          value={url}
          onChange={(e) => setURL(e.target.value)}
          aria-label="Feed or site URL"
        />
        <button type="submit" disabled={adding}>
          {adding ? "Adding…" : "Add"}
        </button>
      </form>
      <button type="button" className="link" onClick={() => fileInput.current?.click()}>
        Import OPML…
      </button>
      <input
        ref={fileInput}
        type="file"
        accept=".opml,.xml,text/xml,text/x-opml"
        hidden
        onChange={(e) => {
          const f = e.target.files?.[0];
          if (f) void importFile(f);
          e.target.value = "";
        }}
      />
      {error ? <p className="error">{error}</p> : null}
      {syncSlot}
    </nav>
  );
}
