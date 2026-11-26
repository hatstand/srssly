import { type DBSchema, type IDBPDatabase, openDB } from "idb";
import type { Article, ArticleState, FetchState, Subscription } from "./model";

export interface SrsslyDB extends DBSchema {
  subscriptions: { key: string; value: Subscription };
  articles: { key: string; value: Article; indexes: { bySubscription: string } };
  states: { key: string; value: ArticleState };
  fetchState: { key: string; value: FetchState };
}

export type DB = IDBPDatabase<SrsslyDB>;

export function openSrsslyDB(name = "srssly"): Promise<DB> {
  return openDB<SrsslyDB>(name, 1, {
    upgrade(db, oldVersion) {
      if (oldVersion < 1) {
        db.createObjectStore("subscriptions", { keyPath: "id" });
        db.createObjectStore("articles", { keyPath: "key" }).createIndex("bySubscription", "subscriptionID");
        db.createObjectStore("states", { keyPath: "articleKey" });
        db.createObjectStore("fetchState", { keyPath: "subscriptionID" });
      }
    },
  });
}
