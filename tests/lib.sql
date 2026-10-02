-- Test helpers. Loaded after schema.sql, before the test files. Lives in schema "t" so the
-- grant loop in schema.sql (which only touches public.cw_*) never sees it.
create schema if not exists t;

-- Every error message a test provoked, so coverage.sql can tell which branches ran.
create table if not exists t.hits (msg text not null);
create table if not exists t.failures (label text not null, detail text);

create or replace function t.fail(label text, detail text) returns void language plpgsql as $$
begin
  insert into t.failures values (label, detail);
  raise warning 'FAIL: % (%)', label, detail;
end $$;

create or replace function t.ok(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then perform t.fail(label, 'expected true, got ' || coalesce(cond::text, 'null')); end if;
end $$;

create or replace function t.eq(actual anyelement, expected anyelement, label text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    perform t.fail(label, format('expected %s, got %s', coalesce(expected::text, 'null'), coalesce(actual::text, 'null')));
  end if;
end $$;

-- Run sql (a single statement) and return its jsonb result.
create or replace function t.call(sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'select (' || sql || ')::jsonb' into r;
  return r;
end $$;

-- Assert sql raises with a message matching msg_like (and sqlstate, if given).
-- The statement's own changes are rolled back, as they are for the page.
create or replace function t.raises(sql text, msg_like text, label text, code text default null) returns void language plpgsql as $$
declare m text; st text;
begin
  begin
    perform t.call(sql);
  exception when others then
    get stacked diagnostics m = message_text, st = returned_sqlstate;
    insert into t.hits values (m);
    if m not like msg_like then perform t.fail(label, format('raised %L, expected like %L', m, msg_like)); end if;
    if code is not null and st <> code then perform t.fail(label, format('sqlstate %s, expected %s', st, code)); end if;
    return;
  end;
  perform t.fail(label, 'did not raise; expected ' || msg_like);
end $$;

-- Assert sql returns {"error": ...} matching msg_like. These calls commit (that's the point).
create or replace function t.returns_error(sql text, msg_like text, label text) returns void language plpgsql as $$
declare m text := t.call(sql)->>'error';
begin
  if m is null then perform t.fail(label, 'no error returned; expected ' || msg_like); return; end if;
  insert into t.hits values (m);
  if m not like msg_like then perform t.fail(label, format('returned %L, expected like %L', m, msg_like)); end if;
end $$;

-- Empty every data table; keeps cw_settings (the setup code) and the test bookkeeping.
create or replace function t.reset() returns void language plpgsql as $$
begin
  truncate cw_pings, cw_shifts, cw_sessions, cw_login_fails, cw_counters, cw_users restart identity cascade;
  perform set_config('request.headers', '', false);
end $$;

-- Fixtures: create a user directly and return a sign-in token for them.
create or replace function t.user(uname text, admin boolean default false, pw text default 'password1') returns text language plpgsql as $$
declare uid bigint;
begin
  insert into cw_users (username, name, pw_hash, is_admin)
  values (uname, initcap(uname), extensions.crypt(pw, extensions.gen_salt('bf', 4)), admin) returning id into uid;
  return cw_new_session(uid);
end $$;

create or replace function t.uid(uname text) returns bigint language sql as $$
  select id from cw_users where username = uname
$$;

create or replace function t.counter(cname text, lat float8 default 1.3000, lng float8 default 103.8000, radius int default 50)
returns bigint language sql as $$
  insert into cw_counters (name, lat, lng, radius_m) values (cname, lat, lng, radius) returning id
$$;
