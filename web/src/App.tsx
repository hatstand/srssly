import { useCallback, useEffect, useMemo, useState } from "react";
import { openSrsslyDB } from "./store/db";
import { Library } from "./store/library";
import type { Article } from "./store/model";
import { ArticleList } from "./ui/ArticleList";
import { LibraryContext, useLibrary } from "./ui/LibraryContext";
import { Reader } from "./ui/Reader";
import { Sidebar } from "./ui/Sidebar";
import { SyncPanel } from "./ui/SyncPanel";
import { cloudKitConfig } from "./sync/cloudkit";
import { SyncController } from "./sync/controller";
import type { Source } from "./ui/selection";

// Created at module load so IndexedDB opens while React renders the shell.
const library = new Library(openSrsslyDB());
void library.load().then(() => library.refreshAll());
const sync = new SyncController(library, cloudKitConfig());

export function App() {
  return (
    <LibraryContext.Provider value={library}>
      <Shell />
    </LibraryContext.Provider>
  );
}

type Pane = "sidebar" | "list" | "reader";

function Shell() {
  const lib = useLibrary();
  const [source, setSource] = useState<Source>({ kind: "all" });
  const [selected, setSelected] = useState<string>();
  const [unreadOnly, setUnreadOnly] = useState(true);
  // On narrow screens one pane shows at a time.
  const [pane, setPane] = useState<Pane>("list");
  // Articles read in this view stay listed until the view changes.
  const [keep, setKeep] = useState<Set<string>>(new Set());

  const { title, articles } = useMemo(() => selectArticles(lib, source, unreadOnly, keep), [lib, lib.getVersion(), source, unreadOnly, keep]);
  const article = selected ? lib.articles.get(selected) : undefined;

  const open = useCallback(
    (key: string) => {
      setSelected(key);
      setKeep((k) => new Set(k).add(key));
      setPane("reader");
      void lib.setState([key], { isRead: true });
    },
    [lib],
  );

  const choose = (s: Source) => {
    setSource(s);
    setKeep(new Set());
    setPane("list");
  };

  // j/k move, s stars, m toggles read, o opens the original.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.metaKey || e.ctrlKey || e.altKey) return;
      const i = articles.findIndex((a) => a.key === selected);
      const at = (n: number) => articles[Math.max(0, Math.min(articles.length - 1, n))];
      if (e.key === "j") {
        const next = at(i + 1);
        if (next) open(next.key);
      } else if (e.key === "k") {
        const prev = at(i - 1);
        if (prev) open(prev.key);
      } else if (e.key === "s" && selected) {
        void lib.setState([selected], { isStarred: !lib.isStarred(selected) });
      } else if (e.key === "m" && selected) {
        void lib.setState([selected], { isRead: !lib.isRead(selected) });
      } else if (e.key === "o" && article?.link) {
        window.open(article.link, "_blank", "noopener");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [articles, selected, open, lib, article]);

  return (
    <div className={`app pane-${pane}`}>
      <Sidebar source={source} onSelect={choose} syncSlot={<SyncPanel controller={sync} />} />
      <ArticleList
        title={title}
        articles={articles}
        selected={selected}
        unreadOnly={unreadOnly}
        onToggleUnreadOnly={() => setUnreadOnly((u) => !u)}
        onSelect={open}
        onBack={() => setPane("sidebar")}
      />
      <Reader article={article} onBack={() => setPane("list")} />
    </div>
  );
}

function selectArticles(lib: Library, source: Source, unreadOnly: boolean, keep: Set<string>): { title: string; articles: Article[] } {
  let title = "All unread";
  let filter: (a: Article) => boolean = () => true;
  let onlyUnread = unreadOnly;
  switch (source.kind) {
    case "all":
      onlyUnread = true;
      break;
    case "starred":
      title = "Starred";
      onlyUnread = false;
      filter = (a) => lib.isStarred(a.key);
      break;
    case "feed": {
      const sub = lib.subscriptions.get(source.id);
      title = sub?.title || sub?.feedURL || "";
      filter = (a) => a.subscriptionID === source.id;
      break;
    }
    case "folder": {
      title = source.name;
      const ids = new Set(lib.sortedSubscriptions().filter((s) => s.folder === source.name).map((s) => s.id));
      filter = (a) => ids.has(a.subscriptionID);
      break;
    }
  }
  const articles = [...lib.articles.values()]
    .filter((a) => filter(a) && (!onlyUnread || !lib.isRead(a.key) || keep.has(a.key)))
    .sort((a, b) => b.date - a.date);
  return { title, articles };
}
