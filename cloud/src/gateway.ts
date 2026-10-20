// Serves hosted links from the private bucket at <PUBLIC_URL>/r/<id>/.
//
// The app uploads the same files as for your own bucket. Small text files (page, meta.json,
// playlists, captions) are proxied, so they stay same-origin and the page gets the analytics
// script. Everything else (segments, MP4, images) is a redirect to a signed R2 URL: video bytes go
// straight from R2 to the viewer, never through this server.
//
// The page itself is never the uploaded index.html: see viewer.ts. Proxied text files get a fixed
// content type by extension (never the one the uploader chose) and a CSP that runs nothing.
import { randomBytes } from "node:crypto";
import type { Context } from "hono";
import { sql } from "./db";
import { r2, SHARE_ID } from "./shares";
import { notFoundPage } from "./pages";
import { renderViewer, sanitizeMeta, viewerCSP } from "./viewer";

// Only the page, its meta and the text files the player reads go through this server, each capped;
// media is a redirect to R2, and only for the file types a share has, served with our content type.
const PROXIED = /^(index\.html|meta\.json)$|\.(m3u8|vtt)$/;
const MAX_META = 256 * 1024, MAX_TEXT = 4 * 1024 * 1024;
const MEDIA: Record<string, string> = {
  mp4: "video/mp4", m4s: "video/iso.segment", m4a: "audio/mp4", aac: "audio/aac",
  jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp",
};
const WINDOW = 3600;
const TYPES: [RegExp, string][] = [[/\.m3u8$/, "application/vnd.apple.mpegurl"], [/\.vtt$/, "text/vtt; charset=utf-8"]];
const INERT = "default-src 'none'; sandbox";

async function readMeta(id: string) {
  const text = await r2.getText(`r/${id}/meta.json`, MAX_META);
  if (text === null) return null;
  let meta;
  try { meta = sanitizeMeta(JSON.parse(text), id); } catch { return null; }
  // Remember what's published, so view reports for other versions or lengths can be ignored (events.ts).
  if (meta) await sql`update shares set revision = ${meta.revision}, duration = ${meta.duration ?? null}
                      where id = ${id} and (revision is distinct from ${meta.revision} or duration is distinct from ${meta.duration ?? null})`;
  return meta;
}

export async function serveShare(c: Context) {
  const id = c.req.param("id") ?? "";
  if (!SHARE_ID.test(id)) return c.html(notFoundPage(), 404);
  const prefix = `/r/${id}/`;
  let path: string;
  try { path = decodeURIComponent(new URL(c.req.url).pathname.slice(prefix.length)) || "index.html"; } catch { return c.html(notFoundPage(), 404); }
  if (path.split("/").some((p) => p === ".." || p === "." || p === "")) return c.html(notFoundPage(), 404);

  const [share] = await sql`select 1 from shares where id = ${id} and deleted_at is null`;
  if (!share) return c.html(notFoundPage(), 404);
  const key = `r/${id}/${path}`;

  if (PROXIED.test(path)) {
    const base = { "cache-control": "no-cache", "x-robots-tag": "noindex" };
    if (path === "index.html" || path === "meta.json") {
      const meta = await readMeta(id);
      if (!meta) return path === "index.html" ? c.html(notFoundPage("This recording is still starting. Try again in a moment."), 404) : c.body(null, 404);
      if (path === "meta.json") return c.json(meta, 200, { ...base, "content-security-policy": INERT });
      const nonce = randomBytes(16).toString("base64");
      return c.body(renderViewer(meta, nonce), 200, {
        ...base, "content-type": "text/html; charset=utf-8", "content-security-policy": viewerCSP(nonce, r2.endpoint),
      });
    }
    const text = await r2.getText(key, MAX_TEXT);
    if (text === null) return c.body(null, 404);
    const type = TYPES.find(([re]) => re.test(path))?.[1] ?? "application/octet-stream";
    return c.body(text, 200, { ...base, "content-type": type, "content-security-policy": INERT });
  }

  // A click on Download navigates to the MP4 (Sec-Fetch-Dest: document): ask R2 to send it as a file.
  const type = MEDIA[path.split(".").pop()!.toLowerCase()];
  if (!type) return c.body(null, 404);
  const dest = c.req.header("sec-fetch-dest");
  const download = dest === "document" && path.endsWith(".mp4");
  const url = r2.presignGet(key, {
    window: WINDOW,
    contentDisposition: download ? `attachment; filename="${id}.mp4"` : undefined,
    contentType: type,
  });
  const left = WINDOW - (Math.floor(Date.now() / 1000) % WINDOW);
  return c.body(null, 302, { location: url, "cache-control": `private, max-age=${Math.min(600, left)}` });
}
