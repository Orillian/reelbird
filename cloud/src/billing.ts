// Stripe billing without an SDK or a secret key. People pay through the one "Reelbird Pro" Payment
// Link ($5/month); Stripe's webhooks tell us who pays, and Stripe's no-code customer portal handles
// cancelling. The only secret is the webhook signing secret.
//
// Pro = an active (or trialing) subscription to the Reelbird Pro product. Nothing else on the Stripe
// account (the open-source support tiers, other apps) grants or changes anything here.
import { createHmac, timingSafeEqual } from "node:crypto";
import type { Context } from "hono";
import { sql } from "./db";

export const billing = {
  webhookSecret: process.env.STRIPE_WEBHOOK_SECRET?.trim() || null,
  /** Payment Link for Pro. Gets ?client_reference_id=<account id>&prefilled_email=… appended. */
  proLink: process.env.STRIPE_PRO_LINK?.trim() || "https://buy.stripe.com/5kQ8wO88gaXs9h57Yn3ks05",
  /** The same link's ID: only its checkouts link a Stripe customer to an account. */
  proLinkId: process.env.STRIPE_PRO_LINK_ID?.trim() || "plink_1USVjtBbj7zje3qW3ZISlMYw",
  /** The Reelbird Pro product: only subscriptions to it count. */
  proProduct: process.env.STRIPE_PRO_PRODUCT?.trim() || "prod_VTSee5NkgzYUpl",
  /** Stripe's no-code customer portal login link (Settings › Billing › Customer portal). */
  portalLink: process.env.STRIPE_PORTAL_LINK?.trim() || "https://billing.stripe.com/p/login/9B68wOewEaXsgJxdiH3ks01",
};

const PAYING = new Set(["active", "trialing"]);

/** Verifies a `Stripe-Signature` header (v1 = HMAC-SHA256 of "<t>.<payload>"), within 5 minutes. */
export function verifySignature(payload: string, header: string | undefined, secret: string, now = Date.now()) {
  if (!header) return false;
  const parts = header.split(",").map((p) => p.split("=") as [string, string]);
  const t = Number(parts.find(([k]) => k === "t")?.[1]);
  if (!Number.isFinite(t) || Math.abs(now / 1000 - t) > 300) return false;
  const expected = createHmac("sha256", secret).update(`${t}.${payload}`).digest();
  return parts.some(([k, v]) => {
    if (k !== "v1" || !v) return false;
    const got = Buffer.from(v, "hex");
    return got.length === expected.length && timingSafeEqual(got, expected);
  });
}

/** Signs a payload like Stripe does (tests and local tooling). */
export function signPayload(payload: string, secret: string, t = Math.floor(Date.now() / 1000)) {
  return `t=${t},v1=${createHmac("sha256", secret).update(`${t}.${payload}`).digest("hex")}`;
}

export function qualifies(s: { status: string; product_id: string | null }) {
  return PAYING.has(s.status) && s.product_id === billing.proProduct;
}

/** Sets the plan of whoever owns this Stripe customer from their subscriptions. */
async function recompute(customerId: string) {
  const subs = await sql<{ status: string; product_id: string | null }[]>`
    select status, product_id from subscriptions where customer_id = ${customerId}`;
  const pro = subs.some(qualifies);
  await sql`update users set plan = ${pro ? "pro" : "free"} where stripe_customer_id = ${customerId}`;
}

type Obj = Record<string, any>;

async function upsertSubscription(s: Obj) {
  const items: Obj[] = s.items?.data ?? [];
  const item = items.find((i) => (i.price?.product ?? i.plan?.product) === billing.proProduct);
  if (!item) return; // not Reelbird Pro (a donation tier, another app): none of our business
  const price = item.price ?? item.plan ?? {};
  const amount = Number(price.unit_amount ?? price.amount ?? 0) * Number(item.quantity ?? s.quantity ?? 1);
  // API 2025-03-31 moved current_period_end onto subscription items.
  const end = item.current_period_end ?? s.current_period_end;
  await sql`
    insert into subscriptions (id, customer_id, product_id, status, amount, currency, interval, current_period_end, updated_at)
    values (${s.id}, ${s.customer}, ${billing.proProduct}, ${s.status}, ${amount}, ${price.currency ?? "usd"},
            ${price.recurring?.interval ?? price.interval ?? "month"}, ${end ? new Date(end * 1000) : null}, now())
    on conflict (id) do update set customer_id = excluded.customer_id, product_id = excluded.product_id, status = excluded.status,
      amount = excluded.amount, currency = excluded.currency, interval = excluded.interval,
      current_period_end = excluded.current_period_end, updated_at = now()`;
  await recompute(s.customer);
}

/** Links the paying customer to the account that started checkout. */
async function checkoutCompleted(session: Obj) {
  if (session.mode !== "subscription" || typeof session.customer !== "string") return;
  if (session.payment_link !== billing.proLinkId) return; // only the Reelbird Pro link
  const ref = typeof session.client_reference_id === "string" && /^[0-9a-f-]{36}$/i.test(session.client_reference_id)
    ? session.client_reference_id : null;
  const email = (session.customer_details?.email ?? session.customer_email ?? "").toLowerCase() || null;
  await sql`insert into stripe_customers (customer_id, email) values (${session.customer}, ${email})
            on conflict (customer_id) do update set email = coalesce(excluded.email, stripe_customers.email)`;
  const [user] = ref
    ? await sql<{ id: string }[]>`select id from users where id = ${ref}`
    : email ? await sql<{ id: string }[]>`select id from users where email = ${email}` : [];
  if (!user) return; // paid before having an account: linkOnSignIn() picks it up
  await sql`update users set stripe_customer_id = null where stripe_customer_id = ${session.customer} and id <> ${user.id}`;
  await sql`update users set stripe_customer_id = ${session.customer} where id = ${user.id}`;
  // The subscription event can arrive before or after this one. If it hasn't yet, count the paid
  // checkout for now (a 100%-off code is paid too: "no_payment_required"); the subscription event replaces it.
  if (typeof session.subscription === "string") {
    await sql`
      insert into subscriptions (id, customer_id, product_id, status, amount, currency, interval)
      values (${session.subscription}, ${session.customer}, ${billing.proProduct}, ${session.payment_status === "paid" || session.payment_status === "no_payment_required" ? "active" : "incomplete"},
              ${Number(session.amount_total ?? 0)}, ${session.currency ?? "usd"}, 'month')
      on conflict (id) do nothing`;
  }
  await recompute(session.customer);
}

export async function webhook(c: Context) {
  if (!billing.webhookSecret) return c.text("Billing isn't configured.", 503);
  const payload = await c.req.text();
  if (!verifySignature(payload, c.req.header("stripe-signature"), billing.webhookSecret)) return c.text("Bad signature", 400);
  const event = JSON.parse(payload) as { id: string; type: string; data: { object: Obj } };
  const fresh = await sql`insert into stripe_events (id) values (${event.id}) on conflict do nothing returning 1`;
  if (!fresh.length) return c.json({ received: true, duplicate: true });
  try {
    const o = event.data.object;
    switch (event.type) {
      case "checkout.session.completed":
        await checkoutCompleted(o);
        break;
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
      case "customer.subscription.paused":
      case "customer.subscription.resumed":
        await upsertSubscription(o);
        break;
    }
  } catch (e) {
    // Let Stripe retry: forget that we saw it.
    await sql`delete from stripe_events where id = ${event.id}`;
    throw e;
  }
  return c.json({ received: true });
}

/** Links a Pro payment made with this email before the account existed (or before it was linked). */
export async function linkOnSignIn(user: { id: string; email: string }) {
  const [c] = await sql<{ customer_id: string }[]>`
    select sc.customer_id from stripe_customers sc
    where sc.email = ${user.email} and not exists (select 1 from users u where u.stripe_customer_id = sc.customer_id)
    order by sc.created_at desc limit 1`;
  if (!c) return;
  await sql`update users set stripe_customer_id = ${c.customer_id} where id = ${user.id} and stripe_customer_id is null`;
  await recompute(c.customer_id);
}

/** The Payment Link for an account, so the payment is linked to it. */
export function upgradeURL(user: { id: string; email: string }) {
  const u = new URL(billing.proLink);
  u.searchParams.set("client_reference_id", user.id);
  u.searchParams.set("prefilled_email", user.email);
  return u.toString();
}

export function portalURL(user: { email: string }) {
  if (!billing.portalLink) return null;
  const u = new URL(billing.portalLink);
  u.searchParams.set("prefilled_email", user.email);
  return u.toString();
}

/** Whether this account pays through Stripe (vs. a plan set by hand in development). */
export async function hasSubscription(userId: string) {
  const [r] = await sql<{ n: number }[]>`
    select count(*)::int as n from subscriptions s join users u on u.stripe_customer_id = s.customer_id
    where u.id = ${userId} and s.status in ('active', 'trialing', 'past_due')`;
  return r.n > 0;
}
