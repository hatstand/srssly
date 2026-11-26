import { describe, expect, it } from "vitest";
import { articleKey } from "./articleKey";
import { canonicalKey, subscriptionID } from "./feedURL";
import { compareKeys, keyBetween, keysBetween, middleKey } from "./sortKey";
import { type UUID, uuidV5 } from "./uuid";

// Expected values come from Python's uuid/hashlib, an implementation
// independent of both this port and the Swift original.

describe("canonicalKey (FeedURLTests.swift)", () => {
  it("ignores scheme, www and trailing slash", () => {
    expect(canonicalKey("http://www.popehat.com/feed/")).toBe("popehat.com/feed");
    expect(canonicalKey("https://popehat.com/feed")).toBe("popehat.com/feed");
  });
  it("lowercases the host but not the path", () => {
    expect(canonicalKey("https://XKCD.com/rss.xml")).toBe("xkcd.com/rss.xml");
    expect(canonicalKey("https://xkcd.com/RSS.xml")).toBe("xkcd.com/RSS.xml");
  });
  it("keeps the query and drops the fragment", () => {
    expect(canonicalKey("http://feeds.feedburner.com/LookingForGroup?format=xml#top")).toBe(
      "feeds.feedburner.com/LookingForGroup?format=xml",
    );
  });
  it("keeps non-default ports only", () => {
    expect(canonicalKey("https://example.com:443/feed")).toBe("example.com/feed");
    expect(canonicalKey("https://example.com:8443/feed")).toBe("example.com:8443/feed");
  });
  it("drops user info and a bare root path", () => {
    expect(canonicalKey("https://me@example.com/")).toBe("example.com");
  });
  it("does not normalize percent-encoding or dot segments", () => {
    expect(canonicalKey("https://example.com/a/../b%2f")).toBe("example.com/a/../b%2f");
  });
});

describe("subscriptionID", () => {
  it("matches the RFC 4122 vector", async () => {
    expect(await uuidV5("6ba7b810-9dad-11d1-80b4-00c04fd430c8" as UUID, "python.org")).toBe(
      "886313e1-3b8a-5372-9b90-0c9aee199e5d",
    );
  });
  it("is the same for equivalent URLs", async () => {
    expect(await subscriptionID("http://www.popehat.com/feed/")).toBe("98c02a8c-206e-5d1f-afeb-fd1e77f47571");
    expect(await subscriptionID("https://popehat.com/feed")).toBe("98c02a8c-206e-5d1f-afeb-fd1e77f47571");
    expect(await subscriptionID("https://xkcd.com/rss.xml")).toBe("67d38c12-4766-5d4e-814a-3470d796e2f8");
  });
});

describe("articleKey (ArticleKey.swift)", () => {
  const sub = "6f1c2d3e-0000-4000-8000-000000000001" as UUID;
  const p = `${sub}:`;
  it("prefers the guid", async () => {
    expect(await articleKey(sub, { guid: "https://xkcd.com/3000/", link: "ignored", title: "x", date: new Date() })).toBe(
      `${p}4c3d343156a0b4beb78e1a628fda44a6`,
    );
  });
  it("falls back to the link, then title and date", async () => {
    expect(await articleKey(sub, { guid: "  ", link: "https://a/1" })).toBe(`${p}9467b6ae8857646d04b2ba1831c0d079`);
    expect(await articleKey(sub, { title: "Hi", date: new Date(1_700_000_000_900) })).toBe(
      `${p}0cf78089cbfb8e6e67e9be1b06217923`,
    );
    expect(await articleKey(sub, {})).toBe(`${p}26cdccb151976a829fe1d91b377e5fb5`);
  });
  it("hashes UTF-8", async () => {
    expect(await articleKey(sub, { guid: "café ☕" })).toBe(`${p}e98fadf82b94ab9f5bcae9750e3206e3`);
  });
});

describe("sortKey (SortKeyTests.swift)", () => {
  it("fits between the ends and adjacent keys", () => {
    expect(keyBetween(undefined, undefined)).toBe(middleKey);
    let lo = "b";
    for (let i = 0; i < 50; i++) {
      const mid = keyBetween(lo, "c");
      expect(lo < mid && mid < "c").toBe(true);
      expect(mid.endsWith("a")).toBe(false);
      lo = mid;
    }
    const k = keyBetween("b", "bb");
    expect("b" < k && k < "bb").toBe(true);
  });
  it("appends and bulk-creates ordered, short keys", () => {
    const keys: string[] = [];
    for (let i = 0; i < 200; i++) keys.push(keyBetween(keys.at(-1), undefined));
    expect([...keys].sort(compareKeys)).toEqual(keys);
    expect(new Set(keys).size).toBe(200);
    const bulk = keysBetween(undefined, undefined, 60);
    expect(bulk.every((x) => x.length <= 3 && /^[a-z]+$/.test(x))).toBe(true);
    expect([...bulk].sort(compareKeys)).toEqual(bulk);
  });
  it("matches Swift's output exactly", () => {
    // Same algorithm, so the same keys: spot-check a few by hand.
    expect(keyBetween("n", undefined)).toBe("u");
    expect(keyBetween(undefined, "n")).toBe("h");
    expect(keyBetween("b", "c")).toBe("bn");
  });
});
