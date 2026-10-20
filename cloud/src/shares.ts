// Hosted links: who owns which share, upload keys limited to one share's folder, plan limits.
import { config, plans, type Plan } from "./config";
import { sql } from "./db";
import { R2 } from "./r2";
import type { User } from "./auth";

export const r2 = new R2(config.r2);

export const SHARE_ID = /^[1-9A-HJ-NP-Za-km-z]{14}$/;
const KEY_TTL = 3600;

export type Usage = { activeLinks: number; storageBytes: number };

export async function usage(userId: string): Promise<Usage> {
  const [u] = await sql<{ n: number; bytes: string }[]>`
    select count(*)::int as n, coalesce(sum(bytes), 0)::bigint as bytes
    from shares where user_id = ${userId} and deleted_at is null`;
  return { activeLinks: u.n, storageBytes: Number(u.bytes) };
}

export function limits(plan: Plan) {
  const p = plans[plan];
  return {
    activeLinks: Number.isFinite(p.activeLinks) ? p.activeLinks : null,
    storageBytes: p.storageBytes,
    analytics: p.analytics,
  };
}

export class ShareRefusal extends Error {
  constructor(readonly status: 402 | 403 | 404 | 410, readonly code: string, message: string) {
    super(message);
  }
}

/**
 * Upload keys for one share. The first request for a new ID creates the share (if the plan has
 * room); later requests renew the keys. The app makes the ID, as it does for your own bucket.
 */
export async function credentials(user: User, id: string, title: string | null) {
  if (!SHARE_ID.test(id)) throw new ShareRefusal(404, "BadShareID", "That isn't a Reelbird share ID.");
  await sql.begin(async (tx) => {
    // One owner at a time: lock the user's row so two new shares can't both squeeze past the limit.
    await tx`select 1 from users where id = ${user.id} for update`;
    const [s] = await tx<{ user_id: string; deleted: boolean }[]>`
      select user_id, deleted_at is not null as deleted from shares where id = ${id}`;
    if (s) {
      if (s.user_id !== user.id) throw new ShareRefusal(403, "NotYours", "This share belongs to another account.");
      if (s.deleted) throw new ShareRefusal(410, "Deleted", "This link was deleted.");
      // Without Pro, uploads to an existing link may finish (a recording in progress when the
      // subscription ended), but only within a day of its last upload: no new work on old links.
      if (user.plan !== "pro") {
        const [recent] = await tx`select 1 from shares where id = ${id} and touched_at > now() - interval '1 day'`;
        if (!recent) throw new ShareRefusal(402, "ProRequired", `Updating hosted links needs Reelbird Pro ($5/month): ${config.publicURL}/upgrade`);
      }
      await tx`update shares set touched_at = now(), title = coalesce(${title}, title) where id = ${id}`;
      return;
    }
    if (user.plan !== "pro") {
      throw new ShareRefusal(402, "ProRequired",
        `Hosted links are part of Reelbird Pro ($5/month): ${config.publicURL}/upgrade. Or share to your own bucket for free.`);
    }
    const p = plans[user.plan];
    const [u] = await tx<{ n: number; bytes: string }[]>`
      select count(*)::int as n, coalesce(sum(bytes), 0)::bigint as bytes
      from shares where user_id = ${user.id} and deleted_at is null`;
    if (u.n >= p.activeLinks) {
      throw new ShareRefusal(402, "LinkLimit", "You've reached the link limit. Delete a link to make room.");
    }
    if (Number(u.bytes) >= p.storageBytes) {
      throw new ShareRefusal(402, "StorageLimit", "Your hosted storage is full. Delete some links to make room.");
    }
    await tx`insert into shares (id, user_id, title) values (${id}, ${user.id}, ${title})`;
  });
  const key = `r/${id}`;
  return { ...r2.tempCredentials({ prefixes: [key + "/"], objects: [key], ttlSeconds: KEY_TTL }), ...storageInfo() };
}

export async function deleteShare(user: User, id: string) {
  const [s] = await sql<{ id: string }[]>`
    update shares set deleted_at = now() where id = ${id} and user_id = ${user.id} and deleted_at is null returning id`;
  if (!s) return false;
  await r2.deleteShare(`r/${id}`);
  await sql`update shares set bytes = 0, sized_at = now() where id = ${id}`;
  return true;
}

export async function listShares(userId: string) {
  return sql<{ id: string; title: string | null; created_at: Date; bytes: string; views: number; opens: number }[]>`
    select s.id, s.title, s.created_at, s.bytes,
      (select count(*)::int from views v where v.share_id = s.id) as views,
      (select coalesce(sum(n), 0)::int from opens o where o.share_id = s.id) as opens
    from shares s where s.user_id = ${userId} and s.deleted_at is null
    order by s.created_at desc`;
}

/** Re-reads a share's title and duration from meta.json and measures it. Called after the app uploads meta.json. */
export async function syncShare(user: User, id: string) {
  const [s] = await sql`select 1 from shares where id = ${id} and user_id = ${user.id} and deleted_at is null`;
  if (!s) return false;
  const r = await r2.get(`r/${id}/meta.json`);
  const meta = r ? ((await r.json().catch(() => null)) as { title?: unknown } | null) : null;
  const title = typeof meta?.title === "string" ? meta.title.slice(0, 300) : null;
  const bytes = await r2.size(`r/${id}/`);
  await sql`update shares set title = coalesce(${title}, title), bytes = ${bytes}, sized_at = now(), touched_at = now() where id = ${id}`;
  return true;
}

export function storageInfo() {
  return { endpoint: r2.endpoint, bucket: config.r2.bucket, region: "auto", prefix: "r", publicBaseURL: config.publicURL };
}

/**
 * Re-measures storage for shares that had keys handed out recently. Keys last an hour, so a share
 * can only grow while it has been touched in the last hour (plus a margin).
 */
export async function measureRecent() {
  const rows = await sql<{ id: string }[]>`
    select id from shares where deleted_at is null
    and (sized_at is null or touched_at > now() - interval '2 hours') order by touched_at desc limit 200`;
  for (const { id } of rows) {
    try {
      const bytes = await r2.size(`r/${id}/`);
      await sql`update shares set bytes = ${bytes}, sized_at = now() where id = ${id}`;
    } catch (e) {
      console.error(`sizing ${id}:`, e);
    }
  }
  return rows.length;
}
