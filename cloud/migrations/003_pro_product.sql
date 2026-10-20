-- Only the Reelbird Pro product grants Pro; keep the product of each subscription.
alter table subscriptions add column product_id text;

-- Who paid through the Pro link, by email, so a payment made before signing up links on sign-in.
create table stripe_customers (
  customer_id text primary key,
  email text,
  created_at timestamptz not null default now()
);
create index stripe_customers_email on stripe_customers (email);
