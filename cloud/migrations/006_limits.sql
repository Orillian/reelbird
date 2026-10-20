-- The newest revision and duration a link's page has served, so analytics can ignore reports
-- for versions or lengths that don't exist.
alter table shares add column revision integer not null default 0;
alter table shares add column duration real;
