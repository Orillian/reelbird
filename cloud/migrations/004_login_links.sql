-- Emailed sign-in links: one use, 15 minutes. Only a SHA-256 of the token is kept.
create table login_links (
  token_hash text primary key,
  email text not null,
  next text not null default '/account',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
create index login_links_email on login_links (email, created_at desc);
