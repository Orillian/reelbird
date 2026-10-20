-- Deletion is two steps: deleted_at stops serving the link at once; purged_at records that its files
-- are gone from R2 (retried until they are, and once more after any upload keys have expired).
alter table shares add column purged_at timestamptz;
update shares set purged_at = deleted_at where deleted_at is not null;
create index shares_purge on shares (deleted_at) where deleted_at is not null;

-- Stripe can deliver events out of order: keep the time of the event a subscription row came from,
-- and never let an older event overwrite a newer one.
alter table subscriptions add column event_at timestamptz;
