import { articleKey } from "../core/articleKey";
import { subscriptionID } from "../core/feedURL";
import { compareKeys, keyBetween, keysBetween } from "../core/sortKey";
import type { UUID } from "../core/uuid";
import { type FetchResult, fetchFeed } from "../feeds/fetch";
import type { OPMLFeed } from "../feeds/opml";
import { type ParsedFeed, itemDate } from "../feeds/types";
import type { DB } from "./db";
import type { Article, ArticleState, FetchState, Subscription } from "./model";

/** A local edit that sync needs to send. */
export type LocalChange =
  | { kind: "subscription"; id: UUID }
  | { kind: "subscriptionDeleted"; id: UUID }
  | { kind: "state"; key: string };

export type FeedFetcher = typeof fetchFeed;

const keepDays = 30;
const refreshAfterMs = 10 * 60_000;
const concurrency = 6;

/**
 * Everything the UI shows, held in memory and written through to
 * IndexedDB. The UI renders from memory straight away and never waits on
 * the network; refreshes and sync update it in the background.
 */
export class Library {
  readonly subscriptions = new Map<UUID, Subscription>();
  readonly articles = new Map<string, Article>();
  readonly states = new Map<string, ArticleState>();
  readonly fetchStates = new Map<UUID, FetchState>();
  /** Feeds being fetched right now. */
  readonly refreshing = new Set<UUID>();
  loaded = false;

  private version = 0;
  private readonly listeners = new Set<() => void>();
  private readonly changeListeners = new Set<(c: LocalChange) => void>();

  protected readonly db: Promise<DB>;
  private readonly fetcher: FeedFetcher;
  protected readonly now: () => number;

  constructor(db: DB | Promise<DB>, fetcher: FeedFetcher = fetchFeed, now: () => number = Date.now) {
    this.db = Promise.resolve(db);
    this.fetcher = fetcher;
    this.now = now;
  }

  // MARK: React glue

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  /** Sync listens here for edits to upload. */
  onLocalChange(listener: (c: LocalChange) => void): () => void {
    this.changeListeners.add(listener);
    return () => this.changeListeners.delete(listener);
  }

  protected changed(...local: LocalChange[]): void {
    this.version++;
    for (const l of this.listeners) l();
    for (const c of local) for (const l of this.changeListeners) l(c);
  }

  // MARK: Loading

  async load(): Promise<void> {
    const tx = (await this.db).transaction(["subscriptions", "articles", "states", "fetchState"]);
    const [subs, articles, states, fetchStates] = await Promise.all([
      tx.objectStore("subscriptions").getAll(),
      tx.objectStore("articles").getAll(),
      tx.objectStore("states").getAll(),
      tx.objectStore("fetchState").getAll(),
    ]);
    for (const s of subs) this.subscriptions.set(s.id, s);
    for (const a of articles) this.articles.set(a.key, a);
    for (const s of states) this.states.set(s.articleKey, s);
    for (const f of fetchStates) this.fetchStates.set(f.subscriptionID, f);
    this.loaded = true;
    this.changed();
  }

  // MARK: Queries

  sortedSubscriptions(): Subscription[] {
    return [...this.subscriptions.values()].sort((a, b) => compareKeys(a.sortKey, b.sortKey) || compareKeys(a.id, b.id));
  }

  isRead(key: string): boolean {
    return this.states.get(key)?.isRead ?? false;
  }

  isStarred(key: string): boolean {
    return this.states.get(key)?.isStarred ?? false;
  }

  unreadCount(id: UUID): number {
    let n = 0;
    for (const a of this.articles.values()) if (a.subscriptionID === id && !this.isRead(a.key)) n++;
    return n;
  }

  // MARK: Subscriptions

  /** Adds a feed by its URL or its site's URL. Returns the new subscription. */
  async addSubscription(url: string, folder?: string): Promise<Subscription> {
    const { result, feed, feedURL } = await this.fetcher(url.trim());
    const id = await subscriptionID(feedURL);
    const existing = this.subscriptions.get(id);
    if (existing) return existing;
    const last = this.sortedSubscriptions().at(-1);
    const now = this.now();
    const sub: Subscription = {
      id,
      feedURL,
      title: feed?.title ?? "",
      sortKey: keyBetween(last?.sortKey, undefined),
      cacheMode: "automatic",
      addedAt: now,
      modifiedAt: now,
      ...(feed?.siteURL ? { siteURL: feed.siteURL } : {}),
      ...(folder ? { folder } : {}),
    };
    await this.putSubscription(sub);
    if (feed) await this.storeFeed(sub, feed, result);
    return sub;
  }

  /** Adds OPML feeds without fetching them first (refresh fills them in). */
  async importOPML(feeds: OPMLFeed[]): Promise<number> {
    const last = this.sortedSubscriptions().at(-1);
    const fresh: Subscription[] = [];
    const seen = new Set<UUID>();
    for (const f of feeds) {
      const id = await subscriptionID(f.feedURL);
      if (this.subscriptions.has(id) || seen.has(id)) continue;
      seen.add(id);
      const now = this.now();
      fresh.push({
        id, feedURL: f.feedURL, title: f.title, sortKey: "", cacheMode: "automatic", addedAt: now, modifiedAt: now,
        ...(f.siteURL ? { siteURL: f.siteURL } : {}),
        ...(f.folder ? { folder: f.folder } : {}),
      });
    }
    const keys = keysBetween(last?.sortKey, undefined, fresh.length);
    fresh.forEach((s, i) => (s.sortKey = keys[i] ?? s.sortKey));
    const tx = (await this.db).transaction("subscriptions", "readwrite");
    await Promise.all([...fresh.map((s) => tx.store.put(s)), tx.done]);
    for (const s of fresh) this.subscriptions.set(s.id, s);
    this.changed(...fresh.map((s) => ({ kind: "subscription", id: s.id }) as const));
    return fresh.length;
  }

  async updateSubscription(id: UUID, edit: (s: Subscription) => Subscription): Promise<void> {
    const old = this.subscriptions.get(id);
    if (!old) return;
    await this.putSubscription({ ...edit(old), id, modifiedAt: this.now() });
  }

  async removeSubscription(id: UUID, local = true): Promise<void> {
    const keys = [...this.articles.values()].filter((a) => a.subscriptionID === id).map((a) => a.key);
    const stateKeys = [...this.states.keys()].filter((k) => k.startsWith(`${id}:`));
    const tx = (await this.db).transaction(["subscriptions", "articles", "states", "fetchState"], "readwrite");
    await Promise.all([
      tx.objectStore("subscriptions").delete(id),
      tx.objectStore("fetchState").delete(id),
      ...keys.map((k) => tx.objectStore("articles").delete(k)),
      ...stateKeys.map((k) => tx.objectStore("states").delete(k)),
      tx.done,
    ]);
    this.subscriptions.delete(id);
    this.fetchStates.delete(id);
    for (const k of keys) this.articles.delete(k);
    for (const k of stateKeys) this.states.delete(k);
    if (local) this.changed({ kind: "subscriptionDeleted", id });
    else this.changed();
  }

  protected async putSubscription(sub: Subscription, local = true): Promise<void> {
    await (await this.db).put("subscriptions", sub);
    this.subscriptions.set(sub.id, sub);
    if (local) this.changed({ kind: "subscription", id: sub.id });
    else this.changed();
  }

  // MARK: Changes from sync (not echoed back as local changes)

  async applyRemoteSubscription(sub: Subscription): Promise<void> {
    await this.putSubscription(sub, false);
  }

  async applyRemoteStates(states: ArticleState[]): Promise<void> {
    if (states.length === 0) return;
    const tx = (await this.db).transaction("states", "readwrite");
    await Promise.all([...states.map((s) => tx.store.put(s)), tx.done]);
    for (const s of states) this.states.set(s.articleKey, s);
    this.changed();
  }

  async removeRemoteState(key: string): Promise<void> {
    await (await this.db).delete("states", key);
    this.states.delete(key);
    this.changed();
  }

  /** Writes sync's bookkeeping in the same database. */
  database(): Promise<DB> {
    return this.db;
  }

  // MARK: Read and starred

  async setState(keys: string[], edit: Partial<Pick<ArticleState, "isRead" | "isStarred">>): Promise<void> {
    const now = this.now();
    const updated: ArticleState[] = [];
    for (const key of keys) {
      const old = this.states.get(key) ?? { articleKey: key, isRead: false, isStarred: false, modifiedAt: 0 };
      const next = { ...old, ...edit };
      if (next.isRead === old.isRead && next.isStarred === old.isStarred) continue;
      updated.push({ ...next, modifiedAt: now });
    }
    if (updated.length === 0) return;
    const tx = (await this.db).transaction("states", "readwrite");
    await Promise.all([...updated.map((s) => tx.store.put(s)), tx.done]);
    for (const s of updated) this.states.set(s.articleKey, s);
    this.changed(...updated.map((s) => ({ kind: "state", key: s.articleKey }) as const));
  }

  // MARK: Refreshing

  /** Refreshes feeds not fetched in the last few minutes (or all, if forced). */
  async refreshAll(force = false): Promise<void> {
    const due = this.sortedSubscriptions().filter((s) => {
      if (this.refreshing.has(s.id)) return false;
      const last = this.fetchStates.get(s.id)?.lastFetchedAt ?? 0;
      return force || this.now() - last > refreshAfterMs;
    });
    const queue = [...due];
    const worker = async (): Promise<void> => {
      for (let s = queue.shift(); s; s = queue.shift()) await this.refresh(s.id);
    };
    await Promise.all(Array.from({ length: Math.min(concurrency, queue.length) }, worker));
  }

  async refresh(id: UUID): Promise<void> {
    const sub = this.subscriptions.get(id);
    if (!sub || this.refreshing.has(id)) return;
    this.refreshing.add(id);
    this.changed();
    const prior = this.fetchStates.get(id) ?? { subscriptionID: id };
    try {
      const validators = {
        ...(prior.etag ? { etag: prior.etag } : {}),
        ...(prior.lastModified ? { lastModified: prior.lastModified } : {}),
      };
      const { result, feed, feedURL } = await this.fetcher(sub.feedURL, validators);
      const current = this.subscriptions.get(id);
      if (!current) return;
      if (feed) await this.storeFeed(current, feed, result);
      if (feedURL !== current.feedURL) await this.updateSubscription(id, (s) => ({ ...s, feedURL }));
      await this.putFetchState({
        subscriptionID: id,
        lastFetchedAt: this.now(),
        ...result.validators,
      });
    } catch (e) {
      await this.putFetchState({ ...prior, lastFetchedAt: this.now(), lastError: e instanceof Error ? e.message : String(e) });
    } finally {
      this.refreshing.delete(id);
      this.changed();
    }
  }

  private async putFetchState(state: FetchState): Promise<void> {
    await (await this.db).put("fetchState", state);
    this.fetchStates.set(state.subscriptionID, state);
  }

  private async storeFeed(sub: Subscription, feed: ParsedFeed, _result: FetchResult): Promise<void> {
    const now = this.now();
    if (!sub.title && feed.title) await this.updateSubscription(sub.id, (s) => ({ ...s, title: feed.title ?? s.title }));
    if (!sub.siteURL && feed.siteURL) {
      const siteURL = feed.siteURL;
      await this.updateSubscription(sub.id, (s) => ({ ...s, siteURL }));
    }

    const inFeed = new Set<string>();
    const put: Article[] = [];
    for (const item of feed.items) {
      const date = itemDate(item);
      const key = await articleKey(sub.id, { guid: item.guid, link: item.link, title: item.title, date });
      if (inFeed.has(key)) continue;
      inFeed.add(key);
      const old = this.articles.get(key);
      const firstSeenAt = old?.firstSeenAt ?? now;
      const article: Article = {
        key,
        subscriptionID: sub.id,
        title: item.title ?? "(untitled)",
        date: date?.getTime() ?? firstSeenAt,
        enclosures: item.enclosures,
        firstSeenAt,
        ...(item.guid ? { guid: item.guid } : {}),
        ...(item.link ? { link: item.link } : {}),
        ...(item.author ? { author: item.author } : {}),
        ...(item.summaryHTML ? { summaryHTML: item.summaryHTML } : {}),
        ...(item.contentHTML ? { contentHTML: item.contentHTML } : {}),
        ...(old?.extraImages ? { extraImages: old.extraImages } : {}),
      };
      put.push(article);
    }

    // Drop old articles that left the feed, unless starred.
    const cutoff = now - keepDays * 86_400_000;
    const drop = [...this.articles.values()]
      .filter((a) => a.subscriptionID === sub.id && !inFeed.has(a.key) && a.date < cutoff && !this.isStarred(a.key))
      .map((a) => a.key);

    const tx = (await this.db).transaction("articles", "readwrite");
    await Promise.all([...put.map((a) => tx.store.put(a)), ...drop.map((k) => tx.store.delete(k)), tx.done]);
    for (const a of put) this.articles.set(a.key, a);
    for (const k of drop) this.articles.delete(k);
    this.changed();
  }

  async saveExtraImages(key: string, images: Article["extraImages"]): Promise<void> {
    const a = this.articles.get(key);
    if (!a || !images) return;
    const next = { ...a, extraImages: images };
    await (await this.db).put("articles", next);
    this.articles.set(key, next);
    this.changed();
  }

  /** Whether a subscription is due a fetch (used on launch). */
  static readonly refreshAfterMs = refreshAfterMs;
}
