import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { subscriptionID } from "../core/feedURL";
import type { FeedFetcher } from "./library";
import { Library } from "./library";
import { openSrsslyDB } from "./db";

let dbCount = 0;

const rss = (items: string) => `<rss version="2.0"><channel><title>xkcd</title><link>https://xkcd.com/</link>${items}</channel></rss>`;

function fakeFetcher(feeds: Record<string, string>): FeedFetcher & { calls: string[] } {
  const calls: string[] = [];
  const fn = (async (url: string, validators = {}) => {
    calls.push(url);
    const { parseFeed } = await import("../feeds/parse");
    const text = feeds[url];
    if (text === undefined) throw new Error(`404 ${url}`);
    if (text === "304") return { result: { status: "notModified", validators }, feedURL: url };
    return {
      result: { status: "ok", text, contentType: "text/xml", finalURL: url, validators: { etag: '"e"' } },
      feed: parseFeed(text, url),
      feedURL: url,
    };
  }) as FeedFetcher;
  return Object.assign(fn, { calls });
}

async function makeLibrary(feeds: Record<string, string>, now = () => 1_800_000_000_000) {
  const db = await openSrsslyDB(`test-${dbCount++}`);
  const fetcher = fakeFetcher(feeds);
  return { lib: new Library(db, fetcher, now), db, fetcher };
}

describe("Library", () => {
  it("adds a feed with a deterministic ID and stores its items", async () => {
    const { lib } = await makeLibrary({
      "https://xkcd.com/rss.xml": rss(`<item><title>A</title><guid>https://xkcd.com/1/</guid></item>`),
    });
    const changes: string[] = [];
    lib.onLocalChange((c) => changes.push(c.kind));
    const sub = await lib.addSubscription("https://xkcd.com/rss.xml");
    expect(sub.id).toBe(await subscriptionID("https://xkcd.com/rss.xml"));
    expect(lib.subscriptions.get(sub.id)?.title).toBe("xkcd");
    expect(lib.unreadCount(sub.id)).toBe(1);
    expect(changes).toContain("subscription");
  });

  it("survives a reload from IndexedDB", async () => {
    const { lib, db } = await makeLibrary({
      "https://xkcd.com/rss.xml": rss(`<item><title>A</title><guid>1</guid></item>`),
    });
    const sub = await lib.addSubscription("https://xkcd.com/rss.xml");
    const [key] = lib.articles.keys();
    await lib.setState([key ?? ""], { isRead: true });

    const again = new Library(db);
    await again.load();
    expect(again.subscriptions.get(sub.id)?.feedURL).toBe("https://xkcd.com/rss.xml");
    expect(again.unreadCount(sub.id)).toBe(0);
  });

  it("imports OPML in order with fresh sort keys and skips duplicates", async () => {
    const { lib } = await makeLibrary({});
    const n = await lib.importOPML([
      { title: "B", feedURL: "https://b.example/feed" },
      { title: "A", feedURL: "https://a.example/feed", folder: "Comics" },
      { title: "B again", feedURL: "http://www.b.example/feed/" },
    ]);
    expect(n).toBe(2);
    expect(lib.sortedSubscriptions().map((s) => s.title)).toEqual(["B", "A"]);
    expect(await lib.importOPML([{ title: "A", feedURL: "https://a.example/feed" }])).toBe(0);
  });

  it("only sends state changes that change something", async () => {
    const { lib } = await makeLibrary({});
    const changes: string[] = [];
    lib.onLocalChange((c) => changes.push(c.kind));
    await lib.setState(["s:1"], { isStarred: true });
    await lib.setState(["s:1"], { isStarred: true });
    expect(changes).toEqual(["state"]);
    expect(lib.isStarred("s:1")).toBe(true);
  });

  it("keeps validators, records errors and skips feeds fetched recently", async () => {
    let t = 1_800_000_000_000;
    const { lib, fetcher } = await makeLibrary({ "https://ok.example/feed": rss("") }, () => t);
    await lib.importOPML([
      { title: "ok", feedURL: "https://ok.example/feed" },
      { title: "gone", feedURL: "https://gone.example/feed" },
    ]);
    await lib.refreshAll();
    const [ok, gone] = lib.sortedSubscriptions();
    expect(lib.fetchStates.get(ok!.id)?.etag).toBe('"e"');
    expect(lib.fetchStates.get(gone!.id)?.lastError).toContain("404");
    fetcher.calls.length = 0;
    t += 60_000;
    await lib.refreshAll();
    expect(fetcher.calls).toEqual([]);
  });
});
