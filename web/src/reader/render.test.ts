import { describe, expect, it } from "vitest";
import { renderArticleHTML } from "./render";
import { pageImages, ruleFor } from "./siteRules";

describe("renderArticleHTML", () => {
  const base = "https://example.com/posts/1";
  it("strips scripts and handlers and resolves URLs", () => {
    const out = renderArticleHTML(
      `<p onclick="x()">Hi <a href="/about">me</a> <a href="javascript:alert(1)">bad</a></p><script>alert(1)</script><img src="a.png" onerror="x()">`,
      { base, showsImageTitles: false, extraImages: [] },
    );
    expect(out).not.toMatch(/script|onclick|onerror|javascript/);
    expect(out).toContain('href="https://example.com/about"');
    expect(out).toContain('target="_blank"');
    expect(out).toContain('src="https://example.com/posts/a.png"');
  });

  it("shows hover text and appends page-only images", () => {
    const out = renderArticleHTML(`<img src="https://imgs.xkcd.com/c.png" title="Hover &amp; text">`, {
      base: "https://xkcd.com/1/",
      showsImageTitles: true,
      extraImages: [{ url: "https://smbc.example/bonus.png", title: "Bonus" }],
    });
    expect(out).toContain('<p class="srssly-hover-text">Hover &amp; text</p>');
    expect(out).toContain('src="https://smbc.example/bonus.png"');
    expect(out).toContain("Bonus");
  });
});

describe("site rules", () => {
  it("matches by article link, then feed URL", () => {
    expect(ruleFor("https://www.smbc-comics.com/comic/x", undefined)?.name).toBe("SMBC");
    expect(ruleFor("https://feedproxy.google.com/x", "https://xkcd.com/rss.xml")?.name).toBe("xkcd");
    expect(ruleFor("https://example.com/", undefined)).toBeUndefined();
  });
  it("finds SMBC's comic and red-button bonus panel", () => {
    const html = `<div id="cc-comicbody"><img id="cc-comic" src="/comics/main.png" title="Hover"></div>
      <div id="aftercomic" style="display:none"><img src="/comics/after.png"></div>`;
    expect(pageImages(html, "https://www.smbc-comics.com/comic/x", ["#cc-comic", "#aftercomic img"])).toEqual([
      { url: "https://www.smbc-comics.com/comics/main.png", title: "Hover" },
      { url: "https://www.smbc-comics.com/comics/after.png" },
    ]);
  });
});
