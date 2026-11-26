import { type DBSchema, type IDBPDatabase, openDB } from "idb";
import type { Article, ArticleState, FetchState, Subscription } from "./model";

export interface SrsslyDB extends DBSchema {
  subscriptions: { key: string; value: Subscription };
  articles: { key: string; value: Article; indexes: { bySubscription: string } };
  states: { key: string; value: ArticleState };
  fetchState: { key: string; value: FetchState };
  /** Per record: the server's change tag and fields as last seen (the merge base). */
  syncMeta: { key: string; value: SyncMeta };
  /** Zone sync token and record names deleted locally but not yet on the server. */
  syncState: { key: string; value: unknown };
}

export interface SyncMeta {
  recordName: string;
  recordChangeTag?: string;
  /** JSON of the synced fields as last seen on the server. */
  base?: string;
}

export type DB = IDBPDatabase<SrsslyDB>;

export function openSrsslyDB(name = "srssly"): Promise<DB> {
  return openDB<SrsslyDB>(name, 2, {
    upgrade(db, oldVersion) {
      if (oldVersion < 1) {
        db.createObjectStore("subscriptions", { keyPath: "id" });
        db.createObjectStore("articles", { keyPath: "key" }).createIndex("bySubscription", "subscriptionID");
        db.createObjectStore("states", { keyPath: "articleKey" });
        db.createObjectStore("fetchState", { keyPath: "subscriptionID" });
      }
      if (oldVersion < 2) {
        db.createObjectStore("syncMeta", { keyPath: "recordName" });
        db.createObjectStore("syncState");
      }
    },
  });
}
