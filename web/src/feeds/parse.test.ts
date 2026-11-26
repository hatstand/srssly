import { describe, expect, it } from "vitest";
import { parseFeedDate } from "./dates";
import { parseOPML } from "./opml";
import { discoverFeeds, looksLikeHTML, parseFeed } from "./parse";
import { FeedError, itemDate } from "./types";

// Ported from FeedParserTests.swift so both parsers agree.

describe("parseFeed", () => {
  it("parses an RSS 2 comic with hover text in escaped HTML", () => {
    const feed = parseFeed(
      `<?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0"><channel>
        <title>xkcd.com</title><link>https://xkcd.com/</link>
        <item>
          <title>Orbital Mechanics</title>
          <link>https://xkcd.com/3001/</link>
          <description>&lt;img src="https://imgs.xkcd.com/comics/orbital.png" title="Hover &amp;amp; text" alt="Orbital" /&gt;</description>
          <pubDate>Mon, 23 Nov 2026 05:00:00 -0000</pubDate>
          <guid>https://xkcd.com/3001/</guid>
        </item>
      </channel></rss>`,
      "https://xkcd.com/rss.xml",
    );
    expect(feed.format).toBe("rss2");
    expect(feed.title).toBe("xkcd.com");
    expect(feed.siteURL).toBe("https://xkcd.com/");
    const item = feed.items[0];
    expect(item?.title).toBe("Orbital Mechanics");
    expect(item?.link).toBe("https://xkcd.com/3001/");
    expect(item?.guid).toBe("https://xkcd.com/3001/");
    expect(item?.summaryHTML).toContain('title="Hover &amp; text"');
    expect(item?.published?.getTime()).toBe(1_795_410_000_000);
  });

  it("reads content:encoded, dc:creator and enclosures, and skips <image>", () => {
    const feed = parseFeed(
      `<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
           xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom">
      <channel>
        <title>The Old New Thing</title>
        <atom:link href="https://devblogs.microsoft.com/oldnewthing/feed/" rel="self" type="application/rss+xml"/>
        <link>https://devblogs.microsoft.com/oldnewthing</link>
        <image><title>Image title</title><url>https://x/logo.png</url><link>https://x</link></image>
        <item>
          <title>Why is the sky blue?</title>
          <link>/oldnewthing/20261120-00/?p=1</link>
          <dc:creator><![CDATA[Raymond Chen]]></dc:creator>
          <guid isPermaLink="false">https://devblogs.microsoft.com/oldnewthing/?p=111</guid>
          <description><![CDATA[<p>Short summary</p>]]></description>
          <content:encoded><![CDATA[<p>The whole <b>post</b>.</p>]]></content:encoded>
          <enclosure url="https://x/audio.mp3" length="1234" type="audio/mpeg"/>
        </item>
      </channel></rss>`,
      "https://devblogs.microsoft.com/oldnewthing/feed/",
    );
    expect(feed.title).toBe("The Old New Thing");
    expect(feed.siteURL).toBe("https://devblogs.microsoft.com/oldnewthing");
    const item = feed.items[0];
    expect(item?.author).toBe("Raymond Chen");
    expect(item?.summaryHTML).toBe("<p>Short summary</p>");
    expect(item?.contentHTML).toBe("<p>The whole <b>post</b>.</p>");
    expect(item?.link).toBe("https://devblogs.microsoft.com/oldnewthing/20261120-00/?p=1");
    expect(item?.enclosures).toEqual([{ url: "https://x/audio.mp3", mimeType: "audio/mpeg", length: 1234 }]);
  });

  it("does not use a non-permalink guid as the link", () => {
    const feed = parseFeed(`<rss version="2.0"><channel><title>T</title>
      <item><title>A</title><guid isPermaLink="false">https://example.com/tag/123</guid></item>
      <item><title>B</title><guid>https://example.com/posts/b</guid></item>
    </channel></rss>`);
    expect(feed.items[0]?.link).toBeUndefined();
    expect(feed.items[1]?.link).toBe("https://example.com/posts/b");
  });

  it("parses Atom with HTML and XHTML content", () => {
    const feed = parseFeed(
      `<?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title type="text">Project Zero</title>
        <link rel="self" href="https://googleprojectzero.blogspot.com/feeds/posts/default"/>
        <link rel="alternate" type="text/html" href="https://googleprojectzero.blogspot.com/"/>
        <entry>
          <id>tag:blogger.com,1999:blog-1.post-2</id>
          <published>2026-11-10T09:30:00.000-08:00</published>
          <updated>2026-11-11T10:00:00Z</updated>
          <title type="text">A bug</title>
          <content type="html">&lt;p&gt;Exploit &lt;i&gt;details&lt;/i&gt;&lt;/p&gt;</content>
          <link rel="replies" href="https://x/comments"/>
          <link rel="alternate" type="text/html" href="https://googleprojectzero.blogspot.com/2026/11/a-bug.html"/>
          <author><name>Jann</name></author>
        </entry>
        <entry>
          <id>urn:uuid:2</id>
          <updated>2026-11-12T00:00:00Z</updated>
          <title>Inline</title>
          <link href="/2026/11/inline.html"/>
          <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Hello <a href="https://x">world</a> &amp; co</p></div></summary>
        </entry>
      </feed>`,
      "https://googleprojectzero.blogspot.com/feeds/posts/default",
    );
    expect(feed.format).toBe("atom");
    expect(feed.title).toBe("Project Zero");
    expect(feed.siteURL).toBe("https://googleprojectzero.blogspot.com/");
    const [first, second] = feed.items;
    expect(first?.guid).toBe("tag:blogger.com,1999:blog-1.post-2");
    expect(first?.link).toBe("https://googleprojectzero.blogspot.com/2026/11/a-bug.html");
    expect(first?.contentHTML).toBe("<p>Exploit <i>details</i></p>");
    expect(first?.author).toBe("Jann");
    expect(first?.published?.getTime()).toBe(1_794_331_800_000);
    expect(second?.link).toBe("https://googleprojectzero.blogspot.com/2026/11/inline.html");
    expect(second?.published).toBeUndefined();
    expect(second && itemDate(second)).toEqual(second?.updated);
    expect(second?.summaryHTML).toBe('<div><p>Hello <a href="https://x">world</a> &amp; co</p></div>');
  });

  it("parses RSS 1.0 with Dublin Core dates", () => {
    const feed = parseFeed(
      `<?xml version="1.0"?>
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
               xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <channel rdf:about="http://www.vgcats.com/">
          <title>VG Cats</title><link>http://www.vgcats.com/</link>
        </channel>
        <item rdf:about="http://www.vgcats.com/comics/?strip_id=400">
          <title>Strip 400</title>
          <link>http://www.vgcats.com/comics/?strip_id=400</link>
          <dc:date>2026-10-01T12:00:00+00:00</dc:date>
          <dc:creator>Scott</dc:creator>
        </item>
      </rdf:RDF>`,
      "http://www.vgcats.com/vgcats.rdf.xml",
    );
    expect(feed.format).toBe("rss1");
    expect(feed.title).toBe("VG Cats");
    expect(feed.items[0]?.link).toBe("http://www.vgcats.com/comics/?strip_id=400");
    expect(feed.items[0]?.published?.getTime()).toBe(1_790_856_000_000);
    expect(feed.items[0]?.author).toBe("Scott");
  });

  it("recognises HTML pages and non-feed XML", () => {
    const kind = (text: string): string | undefined => {
      try {
        parseFeed(text);
      } catch (e) {
        return e instanceof FeedError ? e.detail.kind : "other";
      }
      return undefined;
    };
    expect(kind("<!DOCTYPE html><html><head></head><body></body></html>")).toBe("htmlPage");
    expect(kind(`<?xml version="1.0"?><urlset><url><loc>x</loc></url></urlset>`)).toBe("unrecognizedFormat");
    expect(kind("this is not xml at all")).toBe("malformed");
  });
});

describe("parseFeedDate (FeedDatesTests)", () => {
  it.each([
    ["Mon, 23 Nov 2026 05:00:00 -0000", 1_795_410_000],
    ["Mon, 23 Nov 2026 05:00:00 GMT", 1_795_410_000],
    ["Mon, 23 Nov 2026 05:00:00 UT", 1_795_410_000],
    ["Mon, 23 Nov 2026 00:00:00 EST", 1_795_410_000],
    ["Mon, 23 Nov 2026 05:00 +0000", 1_795_410_000],
    ["23 Nov 2026 05:00:00 +0000", 1_795_410_000],
    ["2026-11-23T05:00:00Z", 1_795_410_000],
    ["2026-11-23T05:00:00.123Z", 1_795_410_000.123],
    ["2026-11-23T06:00:00+01:00", 1_795_410_000],
    ["2026-11-23T05:00:00", 1_795_410_000],
    ["  2026-11-23T05:00:00Z \n", 1_795_410_000],
  ])("parses %j", (raw, seconds) => {
    expect(parseFeedDate(raw)?.getTime()).toBeCloseTo(seconds * 1000, -1);
  });
  it("rejects nonsense", () => {
    expect(parseFeedDate("")).toBeUndefined();
    expect(parseFeedDate("yesterday")).toBeUndefined();
  });
});

describe("discovery and OPML", () => {
  it("finds alternate feed links", () => {
    const html = `<html><head>
      <link rel="stylesheet" href="/style.css">
      <link rel="alternate" type="application/rss+xml" title="RSS" href="/rss.xml">
      <LINK REL='alternate' TYPE='application/atom+xml' HREF='https://www.happyassassin.net/atom.xml?a=1&amp;b=2'>
      <link type="application/rss+xml" rel="alternate home" href="/rss.xml">
      <link rel="alternate" hreflang="fr" type="text/html" href="/fr/">
      </head></html>`;
    expect(discoverFeeds(html, "https://www.happyassassin.net/feed/")).toEqual([
      "https://www.happyassassin.net/rss.xml",
      "https://www.happyassassin.net/atom.xml?a=1&b=2",
    ]);
    expect(looksLikeHTML("\n  <!DOCTYPE html>\n<html>")).toBe(true);
    expect(looksLikeHTML(`<?xml version="1.0"?><rss>`)).toBe(false);
  });

  it("reads OPML folders like Feedly exports them", () => {
    const feeds = parseOPML(`<?xml version="1.0"?><opml version="1.0"><body>
      <outline text="Comics" title="Comics">
        <outline type="rss" text="xkcd" title="xkcd" xmlUrl="https://xkcd.com/rss.xml" htmlUrl="https://xkcd.com/"/>
      </outline>
      <outline type="rss" text="Popehat" xmlUrl="https://popehat.com/feed/"/>
    </body></opml>`);
    expect(feeds).toEqual([
      { title: "xkcd", feedURL: "https://xkcd.com/rss.xml", siteURL: "https://xkcd.com/", folder: "Comics" },
      { title: "Popehat", feedURL: "https://popehat.com/feed/" },
    ]);
  });
});
