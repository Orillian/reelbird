// View analytics without cookies. The viewer page loads /e.js, which reports:
//   "open": the page loaded (counted per share per day)
//   "beat": playback progress, once 3 seconds (or most of a shorter video) have been watched, then every ~10 s and when
//           the tab is hidden. Each beat carries the whole bitmap of 2-second chunks watched so far
//           in this page load, so the server only ever replaces it.
// A viewer is a daily hash of IP + browser + share (like Plausible): unique per day, never stored raw.
import { createHash } from "node:crypto";
import type { Context } from "hono";
import { config } from "./config";
import { sql } from "./db";
import { webUser } from "./auth";

const BOT = /bot|crawl|spider|slurp|facebookexternalhit|embedly|preview|whatsapp|telegram|discord|slack|curl|wget|python|headless/i;
const MAX_BITMAP = 2048; // bytes: 4.5 hours of 2-second chunks

export const VIEWER_SCRIPT = String.raw`(() => {
  "use strict";
  const el = document.currentScript, s = el && el.dataset.share, v = document.getElementById("v");
  if (!s || !v) return;
  let rev = 0;
  try { rev = JSON.parse(document.getElementById("meta").textContent).revision || 0; } catch (e) {}
  const id = crypto.randomUUID ? crypto.randomUUID() : "10000000-1000-4000-8000-100000000000".replace(/[018]/g, c => (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16));
  const CHUNK = 2;
  let bits = new Uint8Array(64), maxPos = 0, watched = 0, last = null, sentAt = 0, completed = false, dirty = false;
  const mark = c => {
    if (c < 0 || c >= ${MAX_BITMAP} * 8) return;
    if ((c >> 3) >= bits.length) { const n = new Uint8Array(Math.max(bits.length * 2, (c >> 3) + 1)); n.set(bits); bits = n; }
    bits[c >> 3] |= 1 << (c & 7);
  };
  const b64 = () => {
    let end = bits.length; while (end > 0 && !bits[end - 1]) end--;
    let str = ""; for (let i = 0; i < end; i++) str += String.fromCharCode(bits[i]);
    return btoa(str);
  };
  const send = (t, beacon) => {
    const body = JSON.stringify({ s, v: id, t, rev, d: isFinite(v.duration) ? v.duration : null, p: maxPos, ws: watched, w: b64(), c: completed, r: document.referrer || null });
    if (beacon && navigator.sendBeacon) navigator.sendBeacon("/e", body);
    else fetch("/e", { method: "POST", body, keepalive: true }).catch(() => {});
  };
  // A view is 3 seconds of playing, or most of a video shorter than that.
  const enough = () => watched >= Math.min(3, isFinite(v.duration) && v.duration > 0 ? v.duration * 0.8 : 3);
  const flush = beacon => { if (!dirty || !enough()) return; dirty = false; sentAt = Date.now(); send("beat", beacon); };
  send("open");
  v.addEventListener("timeupdate", () => {
    const t = v.currentTime;
    if (!v.paused && !v.seeking && last !== null && t > last && t - last < 1.5) {
      watched += t - last;
      for (let c = Math.floor(last / CHUNK); c <= Math.floor(t / CHUNK); c++) mark(c);
      dirty = true;
    }
    last = t;
    if (t > maxPos) maxPos = t;
    if (v.duration && isFinite(v.duration) && t >= v.duration - 1) completed = true;
    if (dirty && enough() && Date.now() - sentAt > 10000) flush(false);
  });
  v.addEventListener("seeking", () => { last = null; });
  v.addEventListener("pause", () => flush(false));
  v.addEventListener("ended", () => { completed = true; dirty = true; flush(false); });
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") flush(true); });
  addEventListener("pagehide", () => flush(true));
})();
`;

// A small in-memory limiter per IP. (On Tiffin: Valkey's rateLimit, shared across instances.)
/** Counts per IP (an IPv6 address counts per /64: one home or server has the whole block). */
export function limiter(limit: number, windowMs: number) {
  const hits = new Map<string, number[]>();
  return (ip: string) => {
    const key = ip.includes(":") ? ip.split(":").slice(0, 4).join(":") : ip;
    const now = Date.now();
    const recent = (hits.get(key) ?? []).filter((t) => now - t < windowMs);
    if (recent.length >= limit) return false;
    recent.push(now);
    hits.delete(key);
    hits.set(key, recent);
    // Forget the oldest keys, not everyone's counts at once.
    if (hits.size > 50_000) for (const k of [...hits.keys()].slice(0, 10_000)) hits.delete(k);
    return true;
  };
}
const allowed = limiter(120, 60_000);

/**
 * The visitor's IP. Behind the box's proxy, the last X-Forwarded-For entry is the one the proxy
 * added; earlier entries come from the client and can say anything.
 */
export function clientIP(c: Context): string {
  const fwd = c.req.header("x-forwarded-for")?.split(",").pop()?.trim();
  if (fwd) return fwd;
  const server = (c.env as { server?: { requestIP(r: Request): { address: string } | null } } | undefined)?.server;
  return server?.requestIP(c.req.raw)?.address ?? "0.0.0.0";
}

export function device(ua: string) {
  const kind = /iPad|Tablet/i.test(ua) ? "Tablet" : /Mobi|iPhone|Android/i.test(ua) ? "Mobile" : "Desktop";
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Other";
  return { kind, browser };
}

export function referrerHost(r: unknown, own: string): string | null {
  if (typeof r !== "string" || !r) return null;
  try {
    const h = new URL(r).hostname.replace(/^www\./, "");
    return h && h !== new URL(own).hostname ? h.slice(0, 120) : null;
  } catch {
    return null;
  }
}

const num = (x: unknown, max: number) => (typeof x === "number" && Number.isFinite(x) && x >= 0 ? Math.min(x, max) : null);

export async function ingest(c: Context) {
  const ua = c.req.header("user-agent") ?? "";
  if (BOT.test(ua)) return c.body(null, 204);
  const ip = clientIP(c);
  if (!allowed(ip)) return c.body(null, 429);

  let e: Record<string, unknown>;
  try {
    const text = await c.req.text();
    if (text.length > 8192) return c.body(null, 413);
    e = JSON.parse(text);
  } catch {
    return c.body(null, 400);
  }
  const shareId = typeof e.s === "string" ? e.s : "";
  const [share] = await sql<{ user_id: string; revision: number; duration: number | null }[]>`
    select user_id, revision, duration from shares where id = ${shareId} and deleted_at is null`;
  if (!share) return c.body(null, 204);
  // The owner watching their own link isn't a view.
  const me = await webUser(c);
  if (me?.id === share.user_id) return c.body(null, 204);

  if (e.t === "open") {
    await sql`insert into opens (share_id, day, n) values (${shareId}, current_date, 1)
              on conflict (share_id, day) do update set n = opens.n + 1`;
    return c.body(null, 204);
  }
  if (e.t !== "beat" || typeof e.v !== "string" || !/^[0-9a-f-]{36}$/i.test(e.v)) return c.body(null, 400);
  // Reports must match what the page actually serves: no future versions, no longer videos.
  const rev = Math.trunc(num(e.rev, 1e6) ?? 0);
  if (rev > share.revision) return c.body(null, 204);
  const maxSecs = share.duration ? share.duration + 2 : 6 * 3600;
  const watchedSeconds = num(e.ws, 6 * 3600) ?? 0;
  if (watchedSeconds > maxSecs * 4) return c.body(null, 204);
  if (watchedSeconds < Math.min(3, share.duration ? share.duration * 0.8 : 3)) return c.body(null, 204);
  let bitmap: Buffer;
  try {
    bitmap = Buffer.from(typeof e.w === "string" ? e.w : "", "base64");
  } catch {
    return c.body(null, 400);
  }
  if (bitmap.length > MAX_BITMAP) return c.body(null, 413);

  const day = new Date().toISOString().slice(0, 10);
  const viewer = createHash("sha256").update(`${config.statsSecret}|${day}|${ip}|${ua}|${shareId}`).digest("hex").slice(0, 32);
  const d = device(ua);
  const country = config.trustCountryHeader ? c.req.header("cf-ipcountry") ?? null : null;
  // One viewer can't fill a link's stats: at most 20 views of a link per viewer per day.
  const [seen] = await sql<{ n: number; mine: number }[]>`
    select count(*)::int as n, count(*) filter (where id = ${e.v})::int as mine
    from views where share_id = ${shareId} and viewer = ${viewer} and started_at > now() - interval '1 day'`;
  if (!seen!.mine && seen!.n >= 20) return c.body(null, 204);
  await sql`
    insert into views (id, share_id, viewer, rev, duration, max_pos, watched_seconds, watched, completed, referrer, country, device, browser)
    values (${e.v}, ${shareId}, ${viewer}, ${rev}, ${num(e.d, maxSecs)}, ${num(e.p, maxSecs) ?? 0},
            ${watchedSeconds}, ${bitmap}, ${e.c === true}, ${referrerHost(e.r, config.publicURL)},
            ${country?.slice(0, 2) ?? null}, ${d.kind}, ${d.browser})
    on conflict (id) do update set
      last_at = now(),
      duration = coalesce(excluded.duration, views.duration),
      max_pos = greatest(views.max_pos, excluded.max_pos),
      watched_seconds = greatest(views.watched_seconds, excluded.watched_seconds),
      watched = case when length(excluded.watched) >= length(views.watched) then excluded.watched else views.watched end,
      completed = views.completed or excluded.completed
    where views.share_id = excluded.share_id`;
  return c.body(null, 204);
}
