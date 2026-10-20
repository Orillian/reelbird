// Reelbird Cloud: hosted share links and view analytics for the Reelbird app.
import { Hono, type Context } from "hono";
import { config, type Plan } from "./config";
import { sql } from "./db";
import * as auth from "./auth";
import { credentials, deleteShare, limits, listShares, measureRecent, ShareRefusal, SHARE_ID, storageInfo, syncShare, usage } from "./shares";
import { serveShare } from "./gateway";
import { ingest, VIEWER_SCRIPT } from "./events";
import { shareStats } from "./stats";
import { billing, hasSubscription, linkOnSignIn, portalURL, upgradeURL, webhook } from "./billing";
import * as pages from "./pages";

export const app = new Hono();

const fail = (c: Context, status: number, error: string, message: string) =>
  c.json({ error, message }, status as 400);

app.use("*", async (c, next) => {
  await next();
  c.header("x-content-type-options", "nosniff");
  c.header("referrer-policy", "strict-origin-when-cross-origin");
  if (!c.req.path.startsWith("/r/")) c.header("x-frame-options", "DENY");
});

app.get("/healthz", (c) => c.text("ok"));

// MARK: Viewer

app.get("/r/:id", (c) => c.redirect(`/r/${c.req.param("id")}/`, 301));
app.get("/r/:id/*", serveShare);
app.get("/e.js", (c) => c.body(VIEWER_SCRIPT, 200, { "content-type": "text/javascript; charset=utf-8", "cache-control": "public, max-age=300" }));
app.post("/e", ingest);

// MARK: Web pages

app.get("/", async (c) => c.html(pages.homePage(await auth.webUser(c))));

const safeNext = (n: unknown) => (typeof n === "string" && n.startsWith("/") && !n.startsWith("//") ? n : "/account");

app.get("/login", async (c) => {
  const next = safeNext(c.req.query("next"));
  if (await auth.webUser(c)) return c.redirect(next);
  return c.html(pages.loginPage(next));
});

app.post("/login", async (c) => {
  if (!auth.sameOrigin(c)) return c.text("Bad origin", 403);
  const form = await c.req.parseBody();
  const next = safeNext(form.next);
  const email = String(form.email ?? "").trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) return c.html(pages.loginPage(next, "Enter a valid email address."), 400);
  if (!config.dev) {
    // Magic-link email is the next step (Tiffin auth + a mail service); until then only DEV can sign in.
    return c.html(pages.loginPage(next, "Email sign-in isn't available yet."), 503);
  }
  const user = await auth.userByEmail(email);
  await linkOnSignIn(user);
  await auth.startWebSession(c, user.id);
  return c.redirect(next);
});

app.post("/logout", async (c) => {
  if (!auth.sameOrigin(c)) return c.text("Bad origin", 403);
  await auth.endWebSession(c);
  return c.redirect("/");
});

app.get("/device", async (c) => {
  const code = auth.normalizeCode(c.req.query("code") ?? "");
  const user = await auth.webUser(c);
  if (!user) return c.redirect(`/login?next=${encodeURIComponent(`/device?code=${code ?? ""}`)}`);
  const info = code ? await auth.deviceInfo(code) : null;
  if (!code || !info || info.approved) return c.html(pages.devicePage(user, code ?? "", null, "invalid"), 404);
  return c.html(pages.devicePage(user, code, info.name, "ask"));
});

app.post("/device", async (c) => {
  if (!auth.sameOrigin(c)) return c.text("Bad origin", 403);
  const user = await auth.webUser(c);
  if (!user) return c.redirect("/login");
  const code = auth.normalizeCode(String((await c.req.parseBody()).code ?? ""));
  const ok = code ? await auth.approveDevice(code, user.id) : false;
  return c.html(pages.devicePage(user, code ?? "", null, ok ? "done" : "invalid"), ok ? 200 : 404);
});

app.get("/account", async (c) => {
  const user = await auth.webUser(c);
  if (!user) return c.redirect("/login?next=/account");
  const billingState = { subscribed: await hasSubscription(user.id), portal: portalURL(user) !== null, welcome: c.req.query("welcome") === "pro" };
  return c.html(pages.accountPage(user, await usage(user.id), limits(user.plan), await listShares(user.id), billingState));
});

// MARK: Billing (Stripe Payment Link + webhook + no-code customer portal)

app.post("/stripe/webhook", webhook);

app.get("/upgrade", async (c) => {
  const user = await auth.webUser(c);
  if (!user) return c.redirect("/login?next=/upgrade");
  if (user.plan === "pro") return c.redirect("/account");
  return c.redirect(upgradeURL(user));
});

app.get("/billing", async (c) => {
  const user = await auth.webUser(c);
  if (!user) return c.redirect("/login?next=/billing");
  const url = portalURL(user);
  return url ? c.redirect(url) : c.redirect("/account");
});

app.get("/account/s/:id", async (c) => {
  const user = await auth.webUser(c);
  const id = c.req.param("id");
  if (!user) return c.redirect(`/login?next=/account/s/${encodeURIComponent(id)}`);
  const [own] = await sql`select 1 from shares where id = ${id} and user_id = ${user.id} and deleted_at is null`;
  const stats = own ? await shareStats(id, limits(user.plan).analytics) : null;
  if (!stats) return c.html(pages.notFoundPage(), 404);
  return c.html(pages.statsPage(user, stats));
});

async function setPlan(userId: string, plan: unknown) {
  if (plan !== "free" && plan !== "pro") return false;
  await sql`update users set plan = ${plan as Plan} where id = ${userId}`;
  return true;
}

if (config.dev) {
  // Stand-in for billing while there is no payment provider.
  app.post("/dev/plan", async (c) => {
    if (!auth.sameOrigin(c)) return c.text("Bad origin", 403);
    const user = await auth.webUser(c);
    if (!user) return c.redirect("/login");
    await setPlan(user.id, (await c.req.parseBody()).plan);
    return c.redirect("/account");
  });
}

// MARK: App API

app.post("/api/device", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  return c.json(await auth.startDevice(typeof body.name === "string" ? body.name : null));
});

app.post("/api/device/token", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  if (typeof body.deviceCode !== "string") return fail(c, 400, "BadRequest", "deviceCode is required.");
  const r = await auth.exchangeDevice(body.deviceCode);
  if (r.status === "pending") return fail(c, 428, "Pending", "Waiting for approval in the browser.");
  if (r.status === "expired") return fail(c, 410, "Expired", "The sign-in code expired. Start again.");
  return c.json({ token: r.token, email: r.user.email, plan: r.user.plan });
});

app.use("/api/*", async (c, next) => {
  if (c.req.path.startsWith("/api/device")) return next();
  const user = await auth.appUser(c);
  if (!user) return fail(c, 401, "SignedOut", "Sign in to Reelbird Cloud again.");
  c.set("user" as never, user as never);
  return next();
});
const me = (c: Context) => c.get("user" as never) as unknown as auth.User;

app.get("/api/me", async (c) => {
  const u = me(c);
  return c.json({ email: u.email, plan: u.plan, limits: limits(u.plan), usage: await usage(u.id), accountURL: `${config.publicURL}/account`,
                 upgradeURL: `${config.publicURL}/upgrade`, storage: storageInfo() });
});

app.post("/api/logout", async (c) => {
  await auth.revokeAppToken(c);
  return c.body(null, 204);
});

app.post("/api/shares/:id/credentials", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const title = typeof body.title === "string" ? body.title.slice(0, 300) : null;
  try {
    return c.json(await credentials(me(c), c.req.param("id"), title));
  } catch (e) {
    if (e instanceof ShareRefusal) return fail(c, e.status, e.code, e.message);
    throw e;
  }
});

app.post("/api/shares/:id/sync", async (c) => {
  const ok = await syncShare(me(c), c.req.param("id"));
  return ok ? c.body(null, 204) : fail(c, 404, "NotFound", "No such link in this account.");
});

app.get("/api/shares", async (c) => {
  const rows = await listShares(me(c).id);
  return c.json(rows.map((s) => ({ id: s.id, title: s.title, url: `${config.publicURL}/r/${s.id}/`, createdAt: s.created_at, bytes: Number(s.bytes), views: s.views })));
});

app.get("/api/shares/:id/stats", async (c) => {
  const u = me(c);
  const id = c.req.param("id");
  const [own] = SHARE_ID.test(id) ? await sql`select 1 from shares where id = ${id} and user_id = ${u.id} and deleted_at is null` : [];
  const stats = own ? await shareStats(id, limits(u.plan).analytics) : null;
  if (!stats) return fail(c, 404, "NotFound", "No such link in this account.");
  return c.json({ ...stats, statsURL: `${config.publicURL}/account/s/${id}` });
});

app.delete("/api/shares/:id", async (c) => {
  const ok = await deleteShare(me(c), c.req.param("id"));
  return ok ? c.body(null, 204) : fail(c, 404, "NotFound", "No such link in this account.");
});

if (config.dev) {
  app.post("/api/dev/plan", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    return (await setPlan(me(c).id, body.plan)) ? c.body(null, 204) : fail(c, 400, "BadPlan", "plan is free or pro.");
  });
}

app.onError((e, c) => {
  console.error(e);
  return c.req.path.startsWith("/api/") ? fail(c, 500, "ServerError", "Something went wrong on our side.") : c.text("Something went wrong.", 500);
});

// MARK: Server

if (import.meta.main) {
  setInterval(() => measureRecent().catch((e) => console.error("measure:", e)), 5 * 60_000);
  const server = Bun.serve({ port: config.port, fetch: (req, srv) => app.fetch(req, { server: srv }) });
  console.log(`Reelbird Cloud on ${config.publicURL} (port ${server.port}${config.dev ? ", DEV" : ""}${billing.webhookSecret ? "" : ", billing off: no STRIPE_WEBHOOK_SECRET"})`);
}
