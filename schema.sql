-- Counter Watch database for Supabase.
-- Paste this whole file into Supabase → SQL Editor → New query, then press Run.
--
-- Running it again (e.g. after pulling a new version) keeps your data and:
--   * replaces every cw_* function with the versions in this file. Old versions are dropped
--     first, so a function whose parameters changed can't linger as a second, still-callable copy;
--   * creates any new tables, and applies the column changes listed under "changes to existing
--     tables". `create table if not exists` alone never changes a table that already exists.
-- The whole file runs as one transaction: if anything fails, nothing is changed.
--
-- How it's protected: the web page is public and only holds Supabase's public "anon" key.
-- Every table has row-level security switched on with no policies, so the key cannot read or
-- write any table directly. The page can only call the cw_* functions below, and each of
-- those checks the caller's sign-in and role first. Times come from the database clock.

begin;

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists cw_settings (
  id int primary key default 1 check (id = 1),
  setup_code text not null
);
insert into cw_settings (setup_code)
values (substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
on conflict (id) do nothing;

create table if not exists cw_users (
  id bigint generated always as identity primary key,
  username text unique not null,
  name text not null,
  pw_hash text not null,
  is_admin boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists cw_sessions (
  token_hash text primary key,
  user_id bigint not null references cw_users(id),
  expires_at timestamptz not null
);
create table if not exists cw_counters (
  id bigint generated always as identity primary key,
  name text not null,
  lat double precision not null,
  lng double precision not null,
  radius_m int not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists cw_shifts (
  id bigint generated always as identity primary key,
  user_id bigint not null references cw_users(id),
  counter_id bigint not null references cw_counters(id),
  start_at timestamptz not null default now(),
  start_lat double precision not null, start_lng double precision not null,
  start_acc double precision not null, start_dist double precision not null,
  device text not null default '',
  last_seen_at timestamptz not null default now(),
  last_lat double precision, last_lng double precision, last_acc double precision, last_dist double precision,
  last_inside boolean not null default true,
  end_at timestamptz,
  end_reason text,                 -- agent | admin | no_signal
  ended_by bigint references cw_users(id)
);
create table if not exists cw_pings (
  id bigint generated always as identity primary key,
  shift_id bigint not null references cw_shifts(id),
  at timestamptz not null default now(),
  lat double precision not null, lng double precision not null,
  acc double precision not null, dist double precision not null,
  inside boolean not null
);
create table if not exists cw_login_fails (
  key text not null,
  at timestamptz not null default now()
);
-- Browsers that have signed in successfully before. Only a SHA-256 of each device token is kept.
create table if not exists cw_devices (
  token_hash text primary key,
  user_id bigint not null references cw_users(id),
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);
create index if not exists cw_shifts_open on cw_shifts (end_at);
create index if not exists cw_shifts_start on cw_shifts (start_at);
create index if not exists cw_shifts_user on cw_shifts (user_id) where end_at is null;
create index if not exists cw_pings_shift on cw_pings (shift_id);
create index if not exists cw_login_fails_key on cw_login_fails (key, at);
create index if not exists cw_devices_user on cw_devices (user_id);

-- Lock every table: no direct access through the public API.
do $$
declare t text;
begin
  foreach t in array array['cw_settings','cw_users','cw_sessions','cw_counters','cw_shifts','cw_pings','cw_login_fails','cw_devices'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from anon, authenticated', t);
  end loop;
end $$;

-- ---------- changes to existing tables ----------
-- `create table if not exists` above only shapes brand-new databases. When a later version adds
-- or changes a column, add it here as well, written so it can run any number of times, e.g.
--   alter table cw_shifts add column if not exists note text not null default '';
-- (None yet.)

-- ---------- functions: start from a clean slate ----------
-- Drop every existing cw_* function, whatever its parameters, before (re)creating them below.
-- `create or replace` only replaces a function with the *same* parameter list, so without this an
-- older version would stay behind and be granted to the public key again by the loop at the end.
-- Nothing else in the database depends on these functions, and the transaction means the page
-- never sees them missing.
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'cw\_%' loop
    execute format('drop function %s', f);
  end loop;
end $$;

-- ---------- rules (change the numbers here) ----------
create or replace function cw_config() returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'ping_every_sec', 60,        -- the page sends the location this often while checked in
    'stale_sec', 180,            -- no location for this long -> "No signal"
    'auto_checkout_min', 30,     -- no location for this long -> checked out automatically
    'max_accuracy_m', 150,       -- refuse check-in when the location is vaguer than this
    'accuracy_allowance_m', 50,  -- how much of the stated accuracy gets the benefit of the doubt
    'default_radius_m', 50,
    'session_days', 14,
    -- Wrong passwords within login_window_min. Each limit blocks only what it names:
    'login_max_fails', 5,          -- one account from one address (or one remembered browser)
    'login_max_fails_ip', 30,      -- one address, any accounts (guessing across many usernames)
    'login_max_fails_user', 20,    -- one account from addresses it hasn't signed in from before
    'login_window_min', 15)
$$;

-- ---------- internal helpers (not callable from the page) ----------
create or replace function cw_ts(t timestamptz) returns text language sql immutable as $$
  select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;

create or replace function cw_fail(msg text, code text default 'P0001') returns void language plpgsql as $$
begin
  raise exception using message = msg, errcode = code;
end $$;

create or replace function cw_hash_token(tok text) returns text language sql immutable as $$
  select encode(sha256(convert_to(coalesce(tok, ''), 'UTF8')), 'hex')
$$;

create or replace function cw_ip() returns text language plpgsql stable as $$
declare h json;
begin
  h := nullif(current_setting('request.headers', true), '')::json;
  return coalesce(h->>'cf-connecting-ip', nullif(trim(split_part(h->>'x-forwarded-for', ',', 1)), ''));
exception when others then
  return null;
end $$;

drop function if exists cw_throttled(text[]);  -- replaced by cw_too_many
-- True when `key` has `max_fails` or more failures in the window. Old failures are cleared first.
create or replace function cw_too_many(key text, max_fails int) returns boolean language plpgsql as $$
begin
  delete from cw_login_fails where at < now() - make_interval(mins => (cw_config()->>'login_window_min')::int);
  return key is not null and (select count(*) from cw_login_fails f where f.key = cw_too_many.key) >= max_fails;
end $$;

create or replace function cw_wait_message() returns text language sql immutable as $$
  select format('Too many wrong attempts. Wait %s minutes, or ask your admin to reset your password.', cw_config()->>'login_window_min')
$$;

create or replace function cw_auth(p_token text) returns cw_users language plpgsql as $$
declare u cw_users;
begin
  select u2.* into u from cw_sessions s join cw_users u2 on u2.id = s.user_id
  where s.token_hash = cw_hash_token(p_token) and s.expires_at > now() and u2.active;
  if not found then perform cw_fail('Please sign in.', 'PT401'); end if;
  return u;
end $$;

create or replace function cw_admin(p_token text) returns cw_users language plpgsql as $$
declare u cw_users := cw_auth(p_token);
begin
  if not u.is_admin then perform cw_fail('Only the admin can do that.', 'PT403'); end if;
  return u;
end $$;

create or replace function cw_new_session(p_user bigint) returns text language plpgsql as $$
declare tok text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  delete from cw_sessions where expires_at <= now();
  insert into cw_sessions values (cw_hash_token(tok), p_user, now() + make_interval(days => (cw_config()->>'session_days')::int));
  return tok;
end $$;

create or replace function cw_dist(lat1 float8, lng1 float8, lat2 float8, lng2 float8) returns float8 language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

create or replace function cw_inside(dist float8, acc float8, radius int) returns boolean language sql immutable as $$
  select dist - least(acc, (cw_config()->>'accuracy_allowance_m')::float8) <= radius
$$;

create or replace function cw_check_fix(lat float8, lng float8, acc float8) returns void language plpgsql as $$
begin
  if lat is null or lng is null or acc is null then
    perform cw_fail('Your location didn''t come through. Allow location access and try again.');
  end if;
  if lat not between -90 and 90 or lng not between -180 and 180 or acc < 0 or acc >= 100000 then
    perform cw_fail('That location isn''t valid.');
  end if;
end $$;

create or replace function cw_sweep() returns void language sql as $$
  update cw_shifts set end_at = last_seen_at, end_reason = 'no_signal'
  where end_at is null and last_seen_at < now() - make_interval(mins => (cw_config()->>'auto_checkout_min')::int)
$$;

create or replace function cw_user_json(u cw_users) returns jsonb language sql immutable as $$
  select jsonb_build_object('id', u.id, 'username', u.username, 'name', u.name, 'is_admin', u.is_admin, 'active', u.active)
$$;

create or replace function cw_counter_json(c cw_counters) returns jsonb language sql immutable as $$
  select jsonb_build_object('id', c.id, 'name', c.name, 'lat', c.lat, 'lng', c.lng, 'radius_m', c.radius_m, 'active', c.active)
$$;

create or replace function cw_shift_json(p_id bigint) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', s.id, 'user_id', s.user_id, 'counter_id', s.counter_id,
    'start_at', cw_ts(s.start_at), 'start_lat', s.start_lat, 'start_lng', s.start_lng,
    'start_acc', s.start_acc, 'start_dist', s.start_dist, 'device', s.device,
    'last_seen_at', cw_ts(s.last_seen_at), 'last_lat', s.last_lat, 'last_lng', s.last_lng,
    'last_acc', s.last_acc, 'last_dist', s.last_dist, 'last_inside', s.last_inside,
    'end_at', cw_ts(s.end_at), 'end_reason', s.end_reason, 'ended_by', s.ended_by,
    'user_name', u.name, 'counter_name', c.name, 'radius_m', c.radius_m, 'ended_by_name', e.name,
    'pings', (select count(*) from cw_pings p where p.shift_id = s.id),
    'pings_outside', (select count(*) from cw_pings p where p.shift_id = s.id and not p.inside),
    'presence', case
      when s.end_at is not null then 'ended'
      when s.last_seen_at >= now() - make_interval(secs => (cw_config()->>'stale_sec')::int)
        then case when s.last_inside then 'present' else 'away' end
      else 'no_signal' end)
  from cw_shifts s
  join cw_users u on u.id = s.user_id
  join cw_counters c on c.id = s.counter_id
  left join cw_users e on e.id = s.ended_by
  where s.id = p_id
$$;

create or replace function cw_open_shift(p_user bigint) returns jsonb language sql stable as $$
  select cw_shift_json(id) from cw_shifts where user_id = p_user and end_at is null limit 1
$$;

create or replace function cw_check_user_fields(p_username text, p_name text, p_password text) returns void language plpgsql as $$
begin
  if p_username !~ '^[a-z0-9._-]{2,32}$' then
    perform cw_fail('Username must be 2–32 characters: letters, numbers, dot, dash or underscore.');
  end if;
  if coalesce(trim(p_name), '') = '' then perform cw_fail('Enter the person''s name.'); end if;
  if length(coalesce(p_password, '')) < 8 then perform cw_fail('Password must be at least 8 characters.'); end if;
  if exists (select 1 from cw_users where username = p_username) then perform cw_fail('That username is already taken.'); end if;
end $$;

-- ---------- functions the page calls ----------
-- Errors either raise (message shown to the user; PT401 = sign in again) or, where a record of
-- the failure must be kept, return {"error": ...} so the transaction isn't rolled back.

create or replace function cw_me(p_token text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u cw_users;
begin
  select u2.* into u from cw_sessions s join cw_users u2 on u2.id = s.user_id
  where s.token_hash = cw_hash_token(p_token) and s.expires_at > now() and u2.active;
  if not found then
    return jsonb_build_object('user', null, 'setup', not exists (select 1 from cw_users), 'setup_code', true);
  end if;
  perform cw_sweep();
  return jsonb_build_object('user', cw_user_json(u), 'shift', cw_open_shift(u.id), 'config', cw_config());
end $$;

create or replace function cw_setup(p_username text, p_name text, p_password text, p_setup_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare keys text[] := array_remove(array['setup:' || cw_ip()], null); uname text := lower(trim(coalesce(p_username, ''))); u cw_users;
begin
  if exists (select 1 from cw_users) then perform cw_fail('The admin account already exists.', 'PT403'); end if;
  if cw_too_many(keys[1], (cw_config()->>'login_max_fails')::int) then
    return jsonb_build_object('error', format('Too many wrong attempts. Try again in %s minutes.', cw_config()->>'login_window_min'));
  end if;
  if coalesce(trim(p_setup_code), '') <> (select setup_code from cw_settings) then
    insert into cw_login_fails (key) select unnest(keys);
    return jsonb_build_object('error', 'That setup code is wrong. Find it in Supabase: run  select setup_code from cw_settings;');
  end if;
  perform cw_check_user_fields(uname, p_name, p_password);
  insert into cw_users (username, name, pw_hash, is_admin)
  values (uname, left(trim(p_name), 80), crypt(p_password, gen_salt('bf', 10)), true) returning * into u;
  return jsonb_build_object('token', cw_new_session(u.id), 'user', cw_user_json(u), 'shift', null, 'config', cw_config());
end $$;

-- Wrong passwords are counted per account+address, so an attacker can only block their own
-- address, not the real user. A browser that has signed in before carries a device token and is
-- judged on its own record, so it keeps working even while an account or address is under attack.
drop function if exists cw_login(text, text);  -- older version without p_device
create or replace function cw_login(p_username text, p_password text, p_device text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare uname text := lower(trim(coalesce(p_username, '')));
        ip text := cw_ip();
        cfg jsonb := cw_config();
        dev_hash text := case when coalesce(p_device, '') <> '' then cw_hash_token(p_device) end;
        known_device boolean;
        pair_key text;
        u cw_users;
        new_device text;
begin
  select * into u from cw_users where username = uname;
  known_device := dev_hash is not null and found and exists (select 1 from cw_devices where token_hash = dev_hash and user_id = u.id);
  pair_key := case when known_device then 'dev:' || dev_hash
                   when ip is not null then 'pair:' || uname || '|' || ip end;
  if cw_too_many(pair_key, (cfg->>'login_max_fails')::int)
     or (not known_device and (cw_too_many('ip:' || ip, (cfg->>'login_max_fails_ip')::int)
                               or cw_too_many('user:' || uname, (cfg->>'login_max_fails_user')::int))) then
    return jsonb_build_object('error', cw_wait_message());
  end if;
  -- Compare against a dummy hash when there's no such user, so timing doesn't reveal usernames.
  if u.id is null or not u.active
     or u.pw_hash is distinct from crypt(coalesce(p_password, ''), coalesce(u.pw_hash, '$2a$10$abcdefghijklmnopqrstuuJ6HFzXeqWO1y3ZxAa0bKJm1k7PqK/Rm')) then
    insert into cw_login_fails (key) select k from unnest(array[pair_key, 'ip:' || ip, 'user:' || uname]) k where k is not null;
    return jsonb_build_object('error', 'Wrong username or password.');
  end if;
  -- Clear only this browser's/address's record. The account-wide count isn't reset by a success,
  -- or each real sign-in would hand an attacker a fresh batch of guesses; it expires on its own.
  delete from cw_login_fails where key = pair_key;
  if known_device then
    update cw_devices set last_used_at = now() where token_hash = dev_hash;
  else
    new_device := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    insert into cw_devices (token_hash, user_id) values (cw_hash_token(new_device), u.id);
    delete from cw_devices where user_id = u.id and token_hash not in
      (select token_hash from cw_devices where user_id = u.id order by last_used_at desc limit 10);
  end if;
  perform cw_sweep();
  return jsonb_build_object('token', cw_new_session(u.id), 'device', new_device, 'user', cw_user_json(u),
                            'shift', cw_open_shift(u.id), 'config', cfg);
end $$;

create or replace function cw_logout(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
begin
  delete from cw_sessions where token_hash = cw_hash_token(p_token);
  return jsonb_build_object('ok', true);
end $$;

create or replace function cw_change_password(p_token text, p_current text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_auth(p_token);
begin
  if me.pw_hash is distinct from crypt(coalesce(p_current, ''), me.pw_hash) then perform cw_fail('Your current password is wrong.'); end if;
  if length(coalesce(p_new, '')) < 8 then perform cw_fail('New password must be at least 8 characters.'); end if;
  update cw_users set pw_hash = crypt(p_new, gen_salt('bf', 10)) where id = me.id;
  delete from cw_sessions where user_id = me.id and token_hash <> cw_hash_token(p_token);
  return jsonb_build_object('ok', true);
end $$;

create or replace function cw_list_counters(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_auth(p_token);
begin
  return jsonb_build_object('counters', coalesce((
    select jsonb_agg(cw_counter_json(c) order by c.active desc, c.name) from cw_counters c where me.is_admin or c.active), '[]'));
end $$;

create or replace function cw_counter_save(p_token text, p_id bigint default null, p_name text default null,
  p_lat float8 default null, p_lng float8 default null, p_radius_m int default null, p_active boolean default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_admin(p_token); c cw_counters;
begin
  if p_id is null then
    if coalesce(trim(p_name), '') = '' then perform cw_fail('Give the counter a name.'); end if;
    if p_lat is null or p_lng is null then perform cw_fail('Set the counter''s location: use your current location or click the map.'); end if;
  elsif not exists (select 1 from cw_counters where id = p_id) then
    perform cw_fail('That counter doesn''t exist.', 'PT404');
  end if;
  if p_name is not null and trim(p_name) = '' then perform cw_fail('Give the counter a name.'); end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng is null or p_lng not between -180 and 180) then
    perform cw_fail('That location isn''t valid.');
  end if;
  if p_radius_m is not null and p_radius_m not between 10 and 1000 then perform cw_fail('Radius must be between 10 and 1000 metres.'); end if;
  if p_active = false and exists (select 1 from cw_shifts where counter_id = p_id and end_at is null) then
    perform cw_fail('Someone is checked in at this counter. Check them out first.');
  end if;
  if p_id is null then
    insert into cw_counters (name, lat, lng, radius_m)
    values (left(trim(p_name), 80), p_lat, p_lng, coalesce(p_radius_m, (cw_config()->>'default_radius_m')::int)) returning * into c;
  else
    update cw_counters set
      name = coalesce(left(trim(p_name), 80), name), lat = coalesce(p_lat, lat), lng = coalesce(p_lng, lng),
      radius_m = coalesce(p_radius_m, radius_m), active = coalesce(p_active, active)
    where id = p_id returning * into c;
  end if;
  return jsonb_build_object('counter', cw_counter_json(c));
end $$;

create or replace function cw_checkin(p_token text, p_counter_id bigint, p_lat float8, p_lng float8, p_acc float8, p_device text default '') returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_auth(p_token); c cw_counters; cur jsonb; d float8; sid bigint; cfg jsonb := cw_config();
begin
  perform cw_sweep();
  cur := cw_open_shift(me.id);
  if cur is not null then perform cw_fail(format('You''re already checked in at %s. Check out first.', cur->>'counter_name'), 'PT409'); end if;
  select * into c from cw_counters where id = p_counter_id and active;
  if not found then perform cw_fail('Pick a counter to check in at.'); end if;
  perform cw_check_fix(p_lat, p_lng, p_acc);
  if p_acc > (cfg->>'max_accuracy_m')::float8 then
    perform cw_fail(format('Your location is only accurate to about %s m. Turn on precise location (or GPS), step away from thick walls, and try again.', round(p_acc)));
  end if;
  d := cw_dist(p_lat, p_lng, c.lat, c.lng);
  if not cw_inside(d, p_acc, c.radius_m) then
    perform cw_fail(format('You''re about %s m from %s. You need to be within %s m to check in.', round(d), c.name, c.radius_m));
  end if;
  insert into cw_shifts (user_id, counter_id, start_lat, start_lng, start_acc, start_dist, device, last_lat, last_lng, last_acc, last_dist, last_inside)
  values (me.id, c.id, p_lat, p_lng, p_acc, d, left(coalesce(p_device, ''), 200), p_lat, p_lng, p_acc, d, true) returning id into sid;
  insert into cw_pings (shift_id, lat, lng, acc, dist, inside) values (sid, p_lat, p_lng, p_acc, d, true);
  return jsonb_build_object('shift', cw_shift_json(sid));
end $$;

create or replace function cw_ping(p_token text, p_lat float8, p_lng float8, p_acc float8) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_auth(p_token); s cw_shifts; c cw_counters; d float8; ins boolean;
begin
  perform cw_sweep();
  select * into s from cw_shifts where user_id = me.id and end_at is null for update;
  if not found then return jsonb_build_object('shift', null); end if;  -- checked out by the admin or automatically
  perform cw_check_fix(p_lat, p_lng, p_acc);
  select * into c from cw_counters where id = s.counter_id;
  d := cw_dist(p_lat, p_lng, c.lat, c.lng);
  ins := cw_inside(d, p_acc, c.radius_m);
  insert into cw_pings (shift_id, lat, lng, acc, dist, inside) values (s.id, p_lat, p_lng, p_acc, d, ins);
  update cw_shifts set last_seen_at = now(), last_lat = p_lat, last_lng = p_lng, last_acc = p_acc, last_dist = d, last_inside = ins
  where id = s.id;
  return jsonb_build_object('shift', cw_shift_json(s.id));
end $$;

create or replace function cw_checkout(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_auth(p_token);
begin
  perform cw_sweep();
  update cw_shifts set end_at = now(), end_reason = 'agent' where user_id = me.id and end_at is null;
  if not found then perform cw_fail('You''re not checked in.'); end if;
  return jsonb_build_object('shift', null);
end $$;

create or replace function cw_status(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_admin(p_token);
begin
  perform cw_sweep();
  return jsonb_build_object('now', cw_ts(now()), 'counters', coalesce((
    select jsonb_agg(x.j || jsonb_build_object(
        'status', case when x.j->'shifts' @> '[{"presence":"present"}]' then 'staffed'
                       when jsonb_array_length(x.j->'shifts') > 0 then 'check' else 'unmanned' end,
        'unmanned_since', case when jsonb_array_length(x.j->'shifts') = 0
                       then (select cw_ts(max(end_at)) from cw_shifts where counter_id = x.id) end)
      order by x.name)
    from (
      select c.id, c.name, cw_counter_json(c) || jsonb_build_object('shifts', coalesce((
          select jsonb_agg(cw_shift_json(s.id) order by s.start_at) from cw_shifts s where s.counter_id = c.id and s.end_at is null), '[]')) as j
      from cw_counters c where c.active
    ) x), '[]'));
end $$;

create or replace function cw_list_shifts(p_token text, p_since timestamptz, p_until timestamptz) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_admin(p_token);
begin
  perform cw_sweep();
  return jsonb_build_object('shifts', coalesce((
    select jsonb_agg(cw_shift_json(s.id) order by s.start_at desc) from cw_shifts s
    where s.start_at < p_until and (s.end_at is null or s.end_at >= p_since)), '[]'));
end $$;

create or replace function cw_list_pings(p_token text, p_shift_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_admin(p_token);
begin
  return jsonb_build_object('pings', coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'at', cw_ts(p.at), 'lat', p.lat, 'lng', p.lng, 'acc', p.acc, 'dist', p.dist, 'inside', p.inside) order by p.at, p.id)
    from cw_pings p where p.shift_id = p_shift_id), '[]'));
end $$;

create or replace function cw_end_shift(p_token text, p_shift_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_admin(p_token);
begin
  update cw_shifts set end_at = now(), end_reason = 'admin', ended_by = me.id where id = p_shift_id and end_at is null;
  if not found then perform cw_fail('That person is no longer checked in.', 'PT404'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function cw_list_users(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_admin(p_token);
begin
  return jsonb_build_object('users', coalesce((select jsonb_agg(cw_user_json(u) order by u.active desc, u.name) from cw_users u), '[]'));
end $$;

create or replace function cw_user_add(p_token text, p_username text, p_name text, p_password text, p_is_admin boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_admin(p_token); uname text := lower(trim(coalesce(p_username, ''))); u cw_users;
begin
  perform cw_check_user_fields(uname, p_name, p_password);
  insert into cw_users (username, name, pw_hash, is_admin)
  values (uname, left(trim(p_name), 80), crypt(p_password, gen_salt('bf', 10)), coalesce(p_is_admin, false)) returning * into u;
  return jsonb_build_object('user', cw_user_json(u));
end $$;

create or replace function cw_user_update(p_token text, p_id bigint, p_name text default null, p_password text default null,
  p_active boolean default null, p_is_admin boolean default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me cw_users := cw_admin(p_token); t cw_users;
begin
  select * into t from cw_users where id = p_id;
  if not found then perform cw_fail('That person doesn''t exist.', 'PT404'); end if;
  if p_name is not null then
    if trim(p_name) = '' then perform cw_fail('Name can''t be empty.'); end if;
    update cw_users set name = left(trim(p_name), 80) where id = p_id;
  end if;
  if p_password is not null then
    if length(p_password) < 8 then perform cw_fail('Password must be at least 8 characters.'); end if;
    update cw_users set pw_hash = crypt(p_password, gen_salt('bf', 10)) where id = p_id;
    delete from cw_sessions where user_id = p_id;
    delete from cw_login_fails where key = 'user:' || t.username or key like 'pair:' || t.username || '|%';
  end if;
  if p_active is not null then
    if p_id = me.id then perform cw_fail('You can''t deactivate your own account.'); end if;
    update cw_users set active = p_active where id = p_id;
    if not p_active then
      delete from cw_sessions where user_id = p_id;
      update cw_shifts set end_at = now(), end_reason = 'admin', ended_by = me.id where user_id = p_id and end_at is null;
    end if;
  end if;
  if p_is_admin is not null then
    if p_id = me.id then perform cw_fail('You can''t remove your own admin access.'); end if;
    update cw_users set is_admin = p_is_admin where id = p_id;
  end if;
  return jsonb_build_object('user', (select cw_user_json(u) from cw_users u where id = p_id));
end $$;

-- ---------- who may call what ----------
-- Helpers: nobody from outside. Page functions: the public key (anon) and signed-in Supabase users.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'cw\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname in ('cw_me','cw_setup','cw_login','cw_logout','cw_change_password','cw_list_counters','cw_counter_save',
                     'cw_checkin','cw_ping','cw_checkout','cw_status','cw_list_shifts','cw_list_pings','cw_end_shift',
                     'cw_list_users','cw_user_add','cw_user_update') then
      execute format('grant execute on function %s to anon, authenticated', f.sig);
    end if;
  end loop;
end $$;

commit;

-- Your admin setup code (you'll type it into the app once, to create the admin account):
select setup_code from cw_settings;
