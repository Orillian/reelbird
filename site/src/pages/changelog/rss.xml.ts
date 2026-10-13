import type { APIRoute } from "astro";
import { RELEASES } from "../../data/changelog";
import { SITE_URL } from "../../config/site";

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

export const GET: APIRoute = () => {
  const items = RELEASES.map((r) => {
    const link = `${SITE_URL}/changelog/#v${r.version}`;
    const html = `<p>${esc(r.summary)}</p><ul>${r.notes.map((n) => `<li>${esc(n)}</li>`).join("")}</ul>`;
    return `<item><title>Reelbird ${r.version}: ${esc(r.title)}</title><link>${link}</link><guid isPermaLink="true">${link}</guid><pubDate>${new Date(r.date + "T12:00:00Z").toUTCString()}</pubDate><description><![CDATA[${html}]]></description></item>`;
  }).join("");
  const xml = `<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Reelbird changelog</title><link>${SITE_URL}/changelog/</link><atom:link href="${SITE_URL}/changelog/rss.xml" rel="self" type="application/rss+xml"/><description>Release notes for Reelbird, the free, open-source screen recorder for Mac.</description><language>en</language>${items}</channel></rss>`;
  return new Response(xml, { headers: { "Content-Type": "application/rss+xml; charset=utf-8" } });
};
