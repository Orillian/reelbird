create table users (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  plan text not null default 'free' check (plan in ('free', 'pro')),
  created_at timestamptz not null default now()
);

-- Browser sessions (cookie) and app tokens (the Mac app and CLI). Only a SHA-256 of the token is kept.
create table sessions (
  token_hash text primary key,
  user_id uuid not null references users on delete cascade,
  kind text not null check (kind in ('web', 'app')),
  name text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index sessions_user on sessions (user_id);

-- Device sign-in for the app and CLI: the app shows a code, the person approves it in the browser.
create table device_codes (
  device_code_hash text primary key,
  user_code text not null unique,
  name text,
  user_id uuid references users on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

-- One row per hosted link. The id is the app's 14-character share ID (bucket key r/<id>).
create table shares (
  id text primary key check (id ~ '^[1-9A-HJ-NP-Za-km-z]{14}$'),
  user_id uuid not null references users on delete cascade,
  title text,
  bytes bigint not null default 0,
  touched_at timestamptz not null default now(),
  sized_at timestamptz,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index shares_user_active on shares (user_id) where deleted_at is null;

-- One row per viewing session (a page load that played). watched: one bit per 2-second chunk.
create table views (
  id uuid primary key,
  share_id text not null references shares on delete cascade,
  viewer text not null,
  started_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  rev integer not null default 0,
  duration real,
  max_pos real not null default 0,
  watched_seconds real not null default 0,
  watched bytea not null default ''::bytea,
  completed boolean not null default false,
  referrer text,
  country text,
  device text,
  browser text
);
create index views_share_time on views (share_id, started_at desc);

-- Page opens (including ones that never pressed play), per share per day.
create table opens (
  share_id text not null references shares on delete cascade,
  day date not null,
  n integer not null default 0,
  primary key (share_id, day)
);
