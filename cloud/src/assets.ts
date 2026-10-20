// Fonts and icons for the server's own pages (pages.ts), served from cloud/assets with a content hash
// in the URL, so they can be cached for a year.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import type { Context } from "hono";

const TYPES: Record<string, string> = {
  "fraunces.woff2": "font/woff2",
  "instrument-sans.woff2": "font/woff2",
  "commit-mono.woff2": "font/woff2",
  "favicon.svg": "image/svg+xml",
  "favicon.ico": "image/x-icon",
  "apple-touch-icon.png": "image/png",
  "icon-512.png": "image/png",
};

const files = new Map(Object.keys(TYPES).map((name) => {
  const body = readFileSync(new URL(`../assets/${name}`, import.meta.url));
  return [name, { body, hash: createHash("sha256").update(body).digest("hex").slice(0, 10) }];
}));

/** The URL of an asset, versioned by its content. */
export function asset(name: keyof typeof TYPES & string) {
  const f = files.get(name);
  if (!f) throw new Error(`Unknown asset ${name}`);
  return `/assets/${name}?v=${f.hash}`;
}

export function serveAsset(c: Context) {
  const name = c.req.param("file") ?? "";
  const f = files.get(name);
  if (!f) return c.body(null, 404);
  return c.body(f.body, 200, {
    "content-type": TYPES[name]!,
    "cache-control": "public, max-age=31536000, immutable",
    "access-control-allow-origin": "*",
  });
}
