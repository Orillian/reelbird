-- Stripe: a customer is linked to a Reelbird account at checkout (client_reference_id, or email).
alter table users add column stripe_customer_id text unique;

-- Every Stripe subscription we hear about, linked or not yet. The plan is derived from these.
create table subscriptions (
  id text primary key,
  customer_id text not null,
  status text not null,
  amount integer not null default 0,     -- smallest currency unit, per interval, quantity included
  currency text not null default 'usd',
  interval text not null default 'month',
  current_period_end timestamptz,
  updated_at timestamptz not null default now()
);
create index subscriptions_customer on subscriptions (customer_id);

-- Webhook deliveries already handled (Stripe retries and can send an event more than once).
create table stripe_events (
  id text primary key,
  received_at timestamptz not null default now()
);
