// End-to-end: device sign-in, scoped upload keys against the real dev bucket, the viewer gateway,
// analytics events and plan limits. Needs scripts/db.sh start and cloud/.env (R2 dev bucket).
import { afterAll, beforeAll, expect, test } from "bun:test";
import postgres from "postgres";

const TEST_DB = "postgres://postgres@127.0.0.1:54329/reelbird_cloud_test";

const { migrate } = await import("../src/migrate");
const { app } = await import("../src/index");
const { R2 } = await import("../src/r2");
const { config } = await import("../src/config");
const { signPayload, verifySignature, qualifies } = await import("../src/billing");
const { ShortIDForTest } = { ShortIDForTest: () => {
  const a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  return Array.from(crypto.getRandomValues(new Uint8Array(14)), (b) => a[b % a.length]).join("");
} };

const base = config.publicURL;
const created: string[] = [];

beforeAll(async () => {
  const sql = postgres(TEST_DB, { max: 1, onnotice: () => {} });
  await sql.unsafe("drop schema public cascade; create schema public;");
  await sql.end();
  await migrate(TEST_DB);
});

afterAll(async () => {
  const admin = new R2(config.r2);
  for (const id of created) await admin.deleteShare(`r/${id}`).catch(() => {});
});

const call = (path: string, init: RequestInit & { cookie?: string; bearer?: string } = {}) => {
  const headers = new Headers(init.headers);
  if (init.cookie) headers.set("cookie", init.cookie);
  if (init.bearer) headers.set("authorization", `Bearer ${init.bearer}`);
  return app.fetch(new Request(base + path, { ...init, headers, redirect: "manual" }));
};
const json = (body: unknown) => ({ method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });

async function webLogin(email: string) {
  const r = await call("/login", { method: "POST", body: new URLSearchParams({ email, next: "/account" }) });
  expect(r.status).toBe(302);
  return r.headers.get("set-cookie")!.split(";")[0];
}

async function appLogin(email: string) {
  const start = await (await call("/api/device", json({ name: "Test Mac" }))).json();
  expect(start.userCode).toMatch(/^[A-Z]{4}-[A-Z]{4}$/);
  expect((await call("/api/device/token", json({ deviceCode: start.deviceCode }))).status).toBe(428);
  const cookie = await webLogin(email);
  const page = await call(`/device?code=${start.userCode}`, { cookie });
  expect(await page.text()).toContain("Test Mac");
  const ok = await call("/device", { method: "POST", cookie, body: new URLSearchParams({ code: start.userCode }) });
  expect(ok.status).toBe(200);
  const done = await (await call("/api/device/token", json({ deviceCode: start.deviceCode }))).json();
  expect(done.token).toBeString();
  // The code works once.
  expect((await call("/api/device/token", json({ deviceCode: start.deviceCode }))).status).toBe(410);
  return { token: done.token as string, cookie };
}

/** A client that signs with the temporary keys, like the Mac app. */
function tempClient(k: { accessKeyId: string; secretAccessKey: string; sessionToken: string }) {
  const c = new R2({ ...config.r2, accessKeyId: k.accessKeyId, secretAccessKey: k.secretAccessKey });
  const send = c.send.bind(c);
  c.send = (m, key, o = {}) => send(m, key, { ...o, headers: { ...(o.headers ?? {}), "x-amz-security-token": k.sessionToken } });
  return c;
}

let alice: { token: string; cookie: string };
let bob: { token: string; cookie: string };
let shareId: string;

const backdate = async (id: string) => {
  const db = postgres(TEST_DB, { max: 1, onnotice: () => {} });
  await db`update shares set touched_at = now() - interval '2 days' where id = ${id}`;
  await db.end();
};

test("device sign-in gives the app a token; a new account has no plan", async () => {
  alice = await appLogin("alice@example.com");
  bob = await appLogin("bob@example.com");
  const me = await (await call("/api/me", { bearer: alice.token })).json();
  expect(me).toMatchObject({ email: "alice@example.com", plan: "free", limits: { activeLinks: 0, analytics: false } });
  expect((await call("/api/me", { bearer: "nope" })).status).toBe(401);
});

test("hosted links need Pro", async () => {
  const r = await call(`/api/shares/${ShortIDForTest()}/credentials`, { ...json({}), bearer: alice.token });
  expect(r.status).toBe(402);
  expect(await r.json()).toMatchObject({ error: "ProRequired" });
  expect(await (await call("/account", { cookie: alice.cookie })).text()).toContain("Upgrade to Pro");
});

test("upload keys work for the share's folder only, and the gateway serves it", async () => {
  expect((await call("/api/dev/plan", { ...json({ plan: "pro" }), bearer: alice.token })).status).toBe(204);
  shareId = ShortIDForTest();
  created.push(shareId);
  const r = await call(`/api/shares/${shareId}/credentials`, { ...json({ title: "Demo" }), bearer: alice.token });
  expect(r.status).toBe(200);
  const k = await r.json();
  expect(k.publicBaseURL).toBe(base);
  const c = tempClient(k);
  const html = `<!doctype html><html><body><video id="v"></video><script type="application/json" id="meta">{"revision":1}</script></body></html>`;
  await c.put(`r/${shareId}/index.html`, html, "text/html; charset=utf-8");
  await c.put(`r/${shareId}/meta.json`, JSON.stringify({ revision: 1, title: "Demo from meta" }), "application/json");
  await c.put(`r/${shareId}/video.1.mp4`, "fake mp4 bytes", "video/mp4");
  // Outside the folder: refused.
  const other = await c.send("PUT", `r/${ShortIDForTest()}/x.txt`, { body: "x", headers: { "content-type": "text/plain" } });
  expect(other.status).toBe(403);

  expect((await call(`/api/shares/${shareId}/sync`, { method: "POST", bearer: alice.token })).status).toBe(204);
  const list = await (await call("/api/shares", { bearer: alice.token })).json();
  expect(list[0]).toMatchObject({ id: shareId, url: `${base}/r/${shareId}/` });
  expect(list[0].bytes).toBeGreaterThan(0);
  const page = await call(`/r/${shareId}/`);
  expect(page.status).toBe(200);
  expect(await page.text()).toContain(`<script src="/e.js" data-share="${shareId}" defer>`);
  expect((await call(`/r/${shareId}`)).status).toBe(301);
  expect((await call(`/r/${shareId}/meta.json`)).status).toBe(200);
  const media = await call(`/r/${shareId}/video.1.mp4`);
  expect(media.status).toBe(302);
  const signed = await fetch(media.headers.get("location")!);
  expect(await signed.text()).toBe("fake mp4 bytes");
  expect((await call(`/r/${shareId}/..%2Fsecret`)).status).toBe(404);
  expect((await call(`/r/${ShortIDForTest()}/`)).status).toBe(404);
});

test("someone else's share ID is refused", async () => {
  const r = await call(`/api/shares/${shareId}/credentials`, { ...json({}), bearer: bob.token });
  expect(r.status).toBe(403);
});

test("views are recorded; Pro sees everything, a lapsed account sees the count", async () => {
  const view = crypto.randomUUID();
  const ua = { "user-agent": "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15", "x-forwarded-for": "203.0.113.7" };
  const beat = (body: object, extra: Record<string, string> = {}) =>
    call("/e", { method: "POST", body: JSON.stringify(body), headers: { ...ua, ...extra } });
  expect((await beat({ s: shareId, t: "open" })).status).toBe(204);
  // Chunks 0-4 watched of a 20 s video (10 chunks): 0b00011111.
  const bits = Buffer.from([0b00011111]).toString("base64");
  expect((await beat({ s: shareId, v: view, t: "beat", rev: 1, d: 20, p: 10, ws: 10, w: bits, c: false, r: "https://app.slack.com/client" })).status).toBe(204);
  // A later beat from the same page load replaces the bitmap.
  const more = Buffer.from([0xff, 0b11]).toString("base64");
  await beat({ s: shareId, v: view, t: "beat", rev: 1, d: 20, p: 20, ws: 20, w: more, c: true });
  // Under 3 seconds isn't a view; bots and the owner don't count.
  await beat({ s: shareId, v: crypto.randomUUID(), t: "beat", rev: 1, d: 20, p: 2, ws: 2, w: bits });
  await beat({ s: shareId, v: crypto.randomUUID(), t: "beat", rev: 1, d: 20, p: 9, ws: 9, w: bits }, { "user-agent": "Slackbot-LinkExpanding 1.0" });
  await beat({ s: shareId, v: crypto.randomUUID(), t: "beat", rev: 1, d: 20, p: 9, ws: 9, w: bits }, { cookie: alice.cookie });

  const pro = await (await call(`/api/shares/${shareId}/stats`, { bearer: alice.token })).json();
  expect(pro).toMatchObject({ views: 1, uniqueViewers: 1, locked: false, completionRate: 100, averagePercent: 100, duration: 20 });
  expect(pro.retention).toEqual(new Array(10).fill(1));
  expect(pro.referrers).toEqual([{ name: "app.slack.com", views: 1 }]);
  expect(pro.devices).toEqual([{ name: "Desktop", views: 1 }]);
  expect((await call(`/account/s/${shareId}`, { cookie: alice.cookie })).status).toBe(200);
  expect((await call(`/api/shares/${shareId}/stats`, { bearer: bob.token })).status).toBe(404);

  await call("/api/dev/plan", { ...json({ plan: "free" }), bearer: alice.token });
  const lapsed = await (await call(`/api/shares/${shareId}/stats`, { bearer: alice.token })).json();
  expect(lapsed).toMatchObject({ views: 1, locked: true, retention: [] });
});

test("when Pro ends: links keep playing, uploads in progress finish, nothing new", async () => {
  // alice is no longer Pro (previous test).
  expect((await call(`/r/${shareId}/`)).status).toBe(200);
  // Touched in the last day (a recording that was uploading): keys still come.
  expect((await call(`/api/shares/${shareId}/credentials`, { ...json({}), bearer: alice.token })).status).toBe(200);
  // Older than a day: no more updates.
  await backdate(shareId);
  const stale = await call(`/api/shares/${shareId}/credentials`, { ...json({}), bearer: alice.token });
  expect(stale.status).toBe(402);
  expect((await stale.json()).error).toBe("ProRequired");
  // And no new links.
  expect((await call(`/api/shares/${ShortIDForTest()}/credentials`, { ...json({}), bearer: alice.token })).status).toBe(402);
  expect(await (await call("/account", { cookie: alice.cookie })).text()).toContain("Your existing links keep playing");
});

test("deleting a link removes its files and the page (with or without Pro)", async () => {
  expect((await call(`/api/shares/${shareId}`, { method: "DELETE", bearer: alice.token })).status).toBe(204);
  expect((await call(`/r/${shareId}/`)).status).toBe(404);
  expect(await new R2(config.r2).list(`r/${shareId}/`)).toEqual([]);
  // A deleted ID can't be reused.
  await call("/api/dev/plan", { ...json({ plan: "pro" }), bearer: alice.token });
  expect((await call(`/api/shares/${shareId}/credentials`, { ...json({}), bearer: alice.token })).status).toBe(410);
});

test("signing out revokes the app token", async () => {
  expect((await call("/api/logout", { method: "POST", bearer: bob.token })).status).toBe(204);
  expect((await call("/api/me", { bearer: bob.token })).status).toBe(401);
});

// MARK: Billing

const stripeEvent = async (type: string, object: object, id = "evt_" + crypto.randomUUID().replaceAll("-", "")) => {
  const payload = JSON.stringify({ id, type, data: { object } });
  return call("/stripe/webhook", { method: "POST", body: payload, headers: { "stripe-signature": signPayload(payload, process.env.STRIPE_WEBHOOK_SECRET!), "content-type": "application/json" } });
};
const PRO = "prod_VTSee5NkgzYUpl", PRO_LINK = "plink_1USVjtBbj7zje3qW3ZISlMYw", DONATION = "prod_VKMxHgIqwzOiCj";
const sub = (id: string, customer: string, status: string, product = PRO) => ({
  id, object: "subscription", customer, status,
  items: { data: [{ quantity: 1, current_period_end: 1_800_000_000, price: { unit_amount: 500, currency: "usd", product, recurring: { interval: "month" } } }] },
});
const checkout = (customer: string, subscription: string, extra: object = {}) => ({
  object: "checkout.session", mode: "subscription", customer, subscription, payment_link: PRO_LINK,
  payment_status: "paid", amount_total: 500, currency: "usd", ...extra,
});
const plan = async (bearer: string) => (await (await call("/api/me", { bearer })).json()).plan;

test("signatures: Stripe's scheme, within five minutes", () => {
  const body = '{"a":1}';
  const now = Date.now();
  expect(verifySignature(body, signPayload(body, "s", Math.floor(now / 1000)), "s", now)).toBe(true);
  expect(verifySignature(body, signPayload(body, "other"), "s")).toBe(false);
  expect(verifySignature(body + " ", signPayload(body, "s"), "s")).toBe(false);
  expect(verifySignature(body, signPayload(body, "s", Math.floor(now / 1000) - 600), "s", now)).toBe(false);
  expect(verifySignature(body, undefined, "s")).toBe(false);
});

test("only an active Reelbird Pro subscription makes Pro", () => {
  expect(qualifies({ status: "active", product_id: PRO })).toBe(true);
  expect(qualifies({ status: "trialing", product_id: PRO })).toBe(true);
  expect(qualifies({ status: "past_due", product_id: PRO })).toBe(false);
  expect(qualifies({ status: "canceled", product_id: PRO })).toBe(false);
  expect(qualifies({ status: "active", product_id: DONATION })).toBe(false);
  expect(qualifies({ status: "active", product_id: null })).toBe(false);
});

test("paying through the Pro link makes the account Pro; cancelling ends it", async () => {
  const carol = await appLogin("carol@example.com");
  const me = await (await call("/api/me", { bearer: carol.token })).json();
  expect(me.upgradeURL).toBe(`${base}/upgrade`);

  // /upgrade sends the signed-in person to the Pro Payment Link, tagged with their account.
  const up = await call("/upgrade", { cookie: carol.cookie });
  expect(up.status).toBe(302);
  const link = new URL(up.headers.get("location")!);
  expect(link.toString()).toStartWith("https://buy.stripe.com/5kQ8wO88gaXs9h57Yn3ks05?");
  const ref = link.searchParams.get("client_reference_id")!;
  expect(link.searchParams.get("prefilled_email")).toBe("carol@example.com");

  // The subscription event can come first: nothing to link yet.
  expect((await stripeEvent("customer.subscription.created", sub("sub_carol", "cus_carol", "active"))).status).toBe(200);
  expect(await plan(carol.token)).toBe("free");
  // Checkout links the customer to the account → Pro.
  expect((await stripeEvent("checkout.session.completed", checkout("cus_carol", "sub_carol", { client_reference_id: ref, customer_details: { email: "carol@example.com" } }))).status).toBe(200);
  expect(await plan(carol.token)).toBe("pro");
  expect((await call("/upgrade", { cookie: carol.cookie })).headers.get("location")).toBe("/account");
  expect(await (await call("/account", { cookie: carol.cookie })).text()).toContain("Manage subscription");
  expect((await call("/billing", { cookie: carol.cookie })).headers.get("location")).toContain("billing.stripe.com/p/login/test_portal?prefilled_email=carol%40example.com");

  // Payment fails → past_due → no Pro; paid again → Pro; cancelled → no Pro.
  await stripeEvent("customer.subscription.updated", sub("sub_carol", "cus_carol", "past_due"));
  expect(await plan(carol.token)).toBe("free");
  await stripeEvent("customer.subscription.updated", sub("sub_carol", "cus_carol", "active"));
  expect(await plan(carol.token)).toBe("pro");
  await stripeEvent("customer.subscription.deleted", sub("sub_carol", "cus_carol", "canceled"));
  expect(await plan(carol.token)).toBe("free");
});

test("open-source support tiers and other links grant nothing", async () => {
  const dan = await appLogin("dan@example.com");
  // A checkout through a donation link, even with Dan's account reference, links nothing.
  const ref = new URL((await call("/upgrade", { cookie: dan.cookie })).headers.get("location")!).searchParams.get("client_reference_id")!;
  await stripeEvent("checkout.session.completed", checkout("cus_dan", "sub_dan_donation", { payment_link: "plink_1UJiDnBbj7zje3qWA0UXs9Hn", client_reference_id: ref, customer_details: { email: "dan@example.com" } }));
  await stripeEvent("customer.subscription.created", sub("sub_dan_donation", "cus_dan", "active", DONATION));
  expect(await plan(dan.token)).toBe("free");
});

test("a payment made before signing up turns into Pro at sign-in", async () => {
  await stripeEvent("checkout.session.completed", checkout("cus_erin", "sub_erin", { customer_details: { email: "erin@example.com" } }));
  await stripeEvent("customer.subscription.created", sub("sub_erin", "cus_erin", "active"));
  const erin = await appLogin("Erin@Example.com");
  expect(await plan(erin.token)).toBe("pro");
});

test("webhooks: bad signatures are refused, repeats are ignored", async () => {
  const payload = JSON.stringify({ id: "evt_forged", type: "customer.subscription.created", data: { object: sub("sub_f", "cus_f", "active") } });
  const forged = await call("/stripe/webhook", { method: "POST", body: payload, headers: { "stripe-signature": signPayload(payload, "wrong") } });
  expect(forged.status).toBe(400);
  const again = await stripeEvent("customer.subscription.updated", sub("sub_erin", "cus_erin", "active"), "evt_same");
  expect(again.status).toBe(200);
  expect(await (await stripeEvent("customer.subscription.updated", sub("sub_erin", "cus_erin", "canceled"), "evt_same")).json()).toMatchObject({ duplicate: true });
});
