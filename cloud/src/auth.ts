// Accounts, browser sessions, app tokens and device sign-in.
//
// The app and CLI sign in with a device code: they show a short code and open /device, the person
// approves it in the browser, and the app receives a long-lived token. Only SHA-256 hashes of
// tokens and device codes are stored.
//
// Browsers sign in with an emailed link (one use, 15 minutes). In development (DEV=1) /login signs you
// in straight away.
import { createHash, randomBytes } from "node:crypto";
import type { Context } from "hono";
import { getCookie, setCookie, deleteCookie } from "hono/cookie";
import { config, type Plan } from "./config";
import { sql } from "./db";

export type User = { id: string; email: string; plan: Plan };

export const hash = (s: string) => createHash("sha256").update(s).digest("hex");
export const token = (bytes = 32) => randomBytes(bytes).toString("base64url");

const WEB_COOKIE = "rb_session";
const WEB_DAYS = 30;
const APP_DAYS = 365;

export async function userByEmail(email: string): Promise<User> {
  const clean = email.trim().toLowerCase();
  const [u] = await sql<User[]>`
    insert into users (email) values (${clean})
    on conflict (email) do update set email = excluded.email
    returning id, email, plan`;
  return u;
}

async function createSession(userId: string, kind: "web" | "app", name: string | null, days: number) {
  const t = token();
  await sql`insert into sessions (token_hash, user_id, kind, name, expires_at)
            values (${hash(t)}, ${userId}, ${kind}, ${name}, now() + make_interval(days => ${days}))`;
  return t;
}

async function userForToken(t: string | undefined, kind: "web" | "app"): Promise<User | null> {
  if (!t) return null;
  const [u] = await sql<User[]>`
    update sessions s set last_used_at = now()
    from users u
    where s.token_hash = ${hash(t)} and s.kind = ${kind} and s.expires_at > now() and u.id = s.user_id
    returning u.id, u.email, u.plan`;
  return u ?? null;
}

// MARK: Browser

export async function startWebSession(c: Context, userId: string) {
  const t = await createSession(userId, "web", null, WEB_DAYS);
  setCookie(c, WEB_COOKIE, t, {
    httpOnly: true,
    sameSite: "Lax",
    secure: config.publicURL.startsWith("https://"),
    path: "/",
    maxAge: WEB_DAYS * 86400,
  });
}

export const webUser = (c: Context) => userForToken(getCookie(c, WEB_COOKIE), "web");

export async function endWebSession(c: Context) {
  const t = getCookie(c, WEB_COOKIE);
  if (t) await sql`delete from sessions where token_hash = ${hash(t)}`;
  deleteCookie(c, WEB_COOKIE, { path: "/" });
}

/** Form posts must come from our own pages (SameSite=Lax covers most of this; this covers the rest). */
export function sameOrigin(c: Context) {
  const origin = c.req.header("origin");
  return !origin || origin === config.publicURL || (config.dev && new URL(origin).hostname === "127.0.0.1");
}

/** Drops expired sessions, device codes and sign-in links (a day late, so limits can still count them). */
export async function cleanUp() {
  await sql`delete from sessions where expires_at < now()`;
  await sql`delete from device_codes where expires_at < now() - interval '1 day'`;
  await sql`delete from login_links where expires_at < now() - interval '1 day'`;
}

// MARK: App tokens

export const appUser = (c: Context) => userForToken(c.req.header("authorization")?.replace(/^Bearer\s+/i, ""), "app");

export async function revokeAppToken(c: Context) {
  const t = c.req.header("authorization")?.replace(/^Bearer\s+/i, "");
  if (t) await sql`delete from sessions where token_hash = ${hash(t)} and kind = 'app'`;
}

// MARK: Device sign-in

const CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ"; // no vowels (no words), no lookalikes

function userCode() {
  const b = randomBytes(8);
  const s = [...b].map((x) => CODE_ALPHABET[x % CODE_ALPHABET.length]).join("");
  return `${s.slice(0, 4)}-${s.slice(4)}`;
}

export async function startDevice(name: string | null) {
  const deviceCode = token();
  for (let i = 0; i < 5; i++) {
    const code = userCode();
    const rows = await sql`
      insert into device_codes (device_code_hash, user_code, name, expires_at)
      values (${hash(deviceCode)}, ${code}, ${name?.slice(0, 80) ?? null}, now() + interval '10 minutes')
      on conflict (user_code) do nothing returning 1`;
    if (rows.length) {
      return {
        deviceCode,
        userCode: code,
        verifyURL: `${config.publicURL}/device?code=${code}`,
        interval: 2,
        expiresIn: 600,
      };
    }
  }
  throw new Error("could not allocate a device code");
}

export function normalizeCode(code: string) {
  const s = code.toUpperCase().replace(/[^A-Z]/g, "");
  return s.length === 8 ? `${s.slice(0, 4)}-${s.slice(4)}` : null;
}

export async function deviceInfo(code: string) {
  const [d] = await sql<{ name: string | null; approved: boolean }[]>`
    select name, user_id is not null as approved from device_codes where user_code = ${code} and expires_at > now()`;
  return d ?? null;
}

export async function approveDevice(code: string, userId: string) {
  const rows = await sql`update device_codes set user_id = ${userId}
                         where user_code = ${code} and expires_at > now() and user_id is null returning 1`;
  return rows.length > 0;
}

/** Polled by the app. Returns the app token once, after approval. */
export async function exchangeDevice(deviceCode: string): Promise<{ status: "pending" } | { status: "expired" } | { status: "ok"; token: string; user: User }> {
  const [d] = await sql<{ user_id: string | null; name: string | null; expired: boolean }[]>`
    select user_id, name, expires_at <= now() as expired from device_codes where device_code_hash = ${hash(deviceCode)}`;
  if (!d || d.expired) return { status: "expired" };
  if (!d.user_id) return { status: "pending" };
  const deleted = await sql`delete from device_codes where device_code_hash = ${hash(deviceCode)} returning 1`;
  if (!deleted.length) return { status: "expired" }; // another poll won the race
  const t = await createSession(d.user_id, "app", d.name, APP_DAYS);
  const [u] = await sql<User[]>`select id, email, plan from users where id = ${d.user_id}`;
  return { status: "ok", token: t, user: u };
}

// MARK: Emailed sign-in links

const LINK_MINUTES = 15;

/** A sign-in link for this address, or null when too many were asked for recently. */
export async function createLoginLink(email: string, next: string) {
  const clean = email.trim().toLowerCase();
  const [recent] = await sql<{ n: number }[]>`
    select count(*)::int as n from login_links where email = ${clean} and created_at > now() - interval '15 minutes'`;
  if (recent.n >= 5) return null;
  const t = token();
  await sql`insert into login_links (token_hash, email, next, expires_at)
            values (${hash(t)}, ${clean}, ${next}, now() + make_interval(mins => ${LINK_MINUTES}))`;
  return { token: t, minutes: LINK_MINUTES };
}

/** Whether a link is still good (the page shows a button; only the button spends it). */
export async function loginLinkValid(t: string) {
  const [r] = await sql`select 1 from login_links where token_hash = ${hash(t)} and used_at is null and expires_at > now()`;
  return !!r;
}

/** Spends a link: the account (made on first sign-in) and where to go next. */
export async function useLoginLink(t: string): Promise<{ user: User; next: string } | null> {
  const [l] = await sql<{ email: string; next: string }[]>`
    update login_links set used_at = now()
    where token_hash = ${hash(t)} and used_at is null and expires_at > now()
    returning email, next`;
  if (!l) return null;
  return { user: await userByEmail(l.email), next: l.next };
}
