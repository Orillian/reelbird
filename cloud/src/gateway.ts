// Serves hosted links from the private bucket at <PUBLIC_URL>/r/<id>/.
//
// The app uploads the same files as for your own bucket. Small text files (page, meta.json,
// playlists, captions) are proxied, so they stay same-origin and the page gets the analytics
// script. Everything else (segments, MP4, images) is a redirect to a signed R2 URL: video bytes go
// straight from R2 to the viewer, never through this server.
import type { Context } from "hono";
import { sql } from "./db";
import { r2, SHARE_ID } from "./shares";
import { notFoundPage } from "./pages";

const PROXIED = /(^|\/)(index\.html|meta\.json)$|\.(m3u8|vtt)$/;
const WINDOW = 3600;

export async function serveShare(c: Context) {
  const id = c.req.param("id") ?? "";
  if (!SHARE_ID.test(id)) return c.html(notFoundPage(), 404);
  const prefix = `/r/${id}/`;
  const path = decodeURIComponent(new URL(c.req.url).pathname.slice(prefix.length)) || "index.html";
  if (path.split("/").some((p) => p === ".." || p === "." || p === "")) return c.html(notFoundPage(), 404);

  const [share] = await sql`select 1 from shares where id = ${id} and deleted_at is null`;
  if (!share) return c.html(notFoundPage(), 404);
  const key = `r/${id}/${path}`;

  if (PROXIED.test(path)) {
    const r = await r2.get(key);
    if (!r) return path === "index.html" ? c.html(notFoundPage("This recording is still starting. Try again in a moment."), 404) : c.body(null, 404);
    const headers: Record<string, string> = {
      "content-type": r.headers.get("content-type") ?? "application/octet-stream",
      "cache-control": "no-cache",
      "x-robots-tag": "noindex",
    };
    if (path === "index.html") {
      const html = (await r.text()).replace("</body>", `<script src="/e.js" data-share="${id}" defer></script>\n</body>`);
      return c.body(html, 200, { ...headers, "content-type": "text/html; charset=utf-8" });
    }
    return new Response(r.body, { status: 200, headers });
  }

  // A click on Download navigates to the MP4 (Sec-Fetch-Dest: document): ask R2 to send it as a file.
  const dest = c.req.header("sec-fetch-dest");
  const download = dest === "document" && path.endsWith(".mp4");
  const url = r2.presignGet(key, {
    window: WINDOW,
    contentDisposition: download ? `attachment; filename="${id}.mp4"` : undefined,
  });
  const left = WINDOW - (Math.floor(Date.now() / 1000) % WINDOW);
  return c.body(null, 302, { location: url, "cache-control": `private, max-age=${Math.min(600, left)}` });
}
