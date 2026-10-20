// Per-share analytics. Pro sees everything; an account without Pro sees the view count.
import { sql } from "./db";

export const CHUNK_SECONDS = 2;

export type Stats = {
  id: string;
  title: string | null;
  views: number;
  opens: number;
  uniqueViewers: number;
  watchSeconds: number;
  averagePercent: number | null;
  completionRate: number | null;
  /** Share of played views that watched each 2-second chunk of the current version (0...1). */
  retention: number[];
  chunkSeconds: number;
  duration: number | null;
  byDay: { day: string; views: number }[];
  referrers: { name: string; views: number }[];
  countries: { name: string; views: number }[];
  devices: { name: string; views: number }[];
  recent: { at: string; percent: number | null; seconds: number; device: string | null; browser: string | null; country: string | null; referrer: string | null }[];
  locked: boolean;
};

const top = (rows: { name: string | null; views: number }[]) =>
  rows.map((r) => ({ name: r.name ?? "Direct", views: r.views }));

export async function shareStats(id: string, full: boolean): Promise<Stats | null> {
  const [s] = await sql<{ id: string; title: string | null }[]>`select id, title from shares where id = ${id} and deleted_at is null`;
  if (!s) return null;
  const [t] = await sql<{ views: number; uniques: number; secs: number; completed: number }[]>`
    select count(*)::int as views, count(distinct viewer)::int as uniques,
           coalesce(sum(watched_seconds), 0)::float as secs, count(*) filter (where completed)::int as completed
    from views where share_id = ${id}`;
  const [o] = await sql<{ n: number }[]>`select coalesce(sum(n), 0)::int as n from opens where share_id = ${id}`;
  const base = {
    id: s.id, title: s.title, views: t.views, opens: Math.max(o.n, t.views), uniqueViewers: t.uniques,
    chunkSeconds: CHUNK_SECONDS,
  };
  if (!full) {
    return { ...base, watchSeconds: 0, averagePercent: null, completionRate: null, retention: [], duration: null,
             byDay: [], referrers: [], countries: [], devices: [], recent: [], locked: true };
  }

  // Retention uses the newest version only: an edit changes the timeline.
  const [latest] = await sql<{ rev: number; duration: number | null }[]>`
    select rev, max(duration)::float as duration from views where share_id = ${id}
    group by rev order by rev desc limit 1`;
  let retention: number[] = [];
  let averagePercent: number | null = null;
  if (latest) {
    const rows = await sql<{ watched: Buffer; max_pos: number; duration: number | null }[]>`
      select watched, max_pos, duration from views where share_id = ${id} and rev = ${latest.rev}
      order by started_at desc limit 5000`;
    const chunks = latest.duration ? Math.max(1, Math.ceil(latest.duration / CHUNK_SECONDS)) : 0;
    const counts = new Array(chunks).fill(0);
    let pctSum = 0, pctN = 0;
    for (const r of rows) {
      let seen = 0;
      for (let c = 0; c < chunks; c++) {
        if ((c >> 3) < r.watched.length && r.watched[c >> 3] & (1 << (c & 7))) { counts[c]++; seen++; }
      }
      if (chunks) { pctSum += seen / chunks; pctN++; }
    }
    retention = counts.map((n) => (rows.length ? n / rows.length : 0));
    averagePercent = pctN ? Math.round((pctSum / pctN) * 1000) / 10 : null;
  }

  const byDay = await sql<{ day: string; views: number }[]>`
    select to_char(d, 'YYYY-MM-DD') as day, coalesce(v.n, 0)::int as views
    from generate_series(current_date - 29, current_date, interval '1 day') d
    left join (select started_at::date as day, count(*) as n from views where share_id = ${id} group by 1) v on v.day = d::date
    order by d`;
  const referrers = await sql<{ name: string | null; views: number }[]>`
    select referrer as name, count(*)::int as views from views where share_id = ${id} group by 1 order by 2 desc limit 8`;
  const countries = await sql<{ name: string | null; views: number }[]>`
    select country as name, count(*)::int as views from views where share_id = ${id} and country is not null group by 1 order by 2 desc limit 8`;
  const devices = await sql<{ name: string | null; views: number }[]>`
    select device as name, count(*)::int as views from views where share_id = ${id} group by 1 order by 2 desc`;
  const recent = await sql<{ at: Date; max_pos: number; duration: number | null; watched_seconds: number; device: string | null; browser: string | null; country: string | null; referrer: string | null }[]>`
    select started_at as at, max_pos, duration, watched_seconds, device, browser, country, referrer
    from views where share_id = ${id} order by started_at desc limit 25`;

  return {
    ...base,
    watchSeconds: Math.round(t.secs),
    averagePercent,
    completionRate: t.views ? Math.round((t.completed / t.views) * 1000) / 10 : null,
    retention,
    duration: latest?.duration ?? null,
    byDay,
    referrers: top(referrers),
    countries: top(countries),
    devices: top(devices),
    recent: recent.map((r) => ({
      at: r.at.toISOString(),
      percent: r.duration ? Math.min(100, Math.round((r.max_pos / r.duration) * 100)) : null,
      seconds: Math.round(r.watched_seconds),
      device: r.device, browser: r.browser, country: r.country, referrer: r.referrer,
    })),
    locked: false,
  };
}
