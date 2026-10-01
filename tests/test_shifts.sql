-- Check-in, location pings, check-out, automatic check-out, the live board, the log.
-- Counters sit at 1.3000, 103.8000 with a 50 m radius. 0.0001° of latitude is about 11.1 m.
select t.reset();
select t.user('boss', true) as boss, t.user('amy') as amy, t.user('ben') as ben \gset
select t.counter('North') as north, t.counter('South', 1.2, 103.7) as south, t.counter('Closed') as closed \gset
update cw_counters set active = false where id = :closed;

-- cw_checkin refusals
select t.raises(format('cw_checkin(%L, %s, null, null, null)', :'amy', :north), 'Your location didn''t come through.%', 'checkin: no location');
select t.raises(format('cw_checkin(%L, %s, 95, 103.8, 5)', :'amy', :north), 'That location isn''t valid.', 'checkin: latitude out of range');
select t.raises(format('cw_checkin(%L, %s, 1.3, 103.8, -1)', :'amy', :north), 'That location isn''t valid.', 'checkin: negative accuracy');
select t.raises(format('cw_checkin(%L, %s, 1.3, 103.8, %L)', :'amy', :north, 'NaN'), 'That location isn''t valid.', 'checkin: NaN accuracy');
select t.raises(format('cw_checkin(%L, %s, 1.3, 103.8, 151)', :'amy', :north), 'Your location is only accurate to about 151 m.%', 'checkin: too vague');
select t.raises(format('cw_checkin(%L, %s, 1.3010, 103.8, 20)', :'amy', :north), 'You''re about 111 m from North. You need to be within 50 m to check in.', 'checkin: too far');
select t.raises(format('cw_checkin(%L, %s, 1.3005, 103.8, 5)', :'amy', :north), 'You''re about 56 m from North.%', 'checkin: just outside (small allowance)');
select t.raises(format('cw_checkin(%L, %s, 1.3, 103.8, 5)', :'amy', :closed), 'Pick a counter to check in at.', 'checkin: counter turned off');
select t.raises(format('cw_checkin(%L, 999, 1.3, 103.8, 5)', :'amy'), 'Pick a counter to check in at.', 'checkin: no such counter');
select t.raises(format('cw_checkin(%L, %s, 1.3, 103.8, 5)', 'bad-token', :north), 'Please sign in.', 'checkin: signed out', 'PT401');
select t.eq((select count(*) from cw_shifts), 0::bigint, 'checkin: refusals record nothing');

-- cw_checkin success: 56 m away but ±10 m gets the benefit of the doubt.
select cw_checkin(:'amy', :north, 1.3005, 103.8, 10, repeat('d', 300))->'shift' as s \gset
select t.eq((:'s'::jsonb)->>'presence', 'present', 'checkin: present');
select t.eq((:'s'::jsonb)->>'counter_name', 'North', 'checkin: counter');
select t.eq((:'s'::jsonb)->>'user_name', 'Amy', 'checkin: user');
select t.eq(round(((:'s'::jsonb)->>'start_dist')::numeric), 56::numeric, 'checkin: distance recorded');
select t.eq(length((:'s'::jsonb)->>'device'), 200, 'checkin: device capped');
select t.eq((:'s'::jsonb)->>'pings', '1', 'checkin: first ping recorded');
select t.ok((:'s'::jsonb)->>'start_at' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$', 'checkin: UTC timestamp');
select ((:'s'::jsonb)->>'id')::bigint as sid \gset
select t.raises(format('cw_checkin(%L, %s, 1.2, 103.7, 5)', :'amy', :south), 'You''re already checked in at North. Check out first.', 'checkin: one counter at a time', 'PT409');
select t.eq(cw_me(:'amy')#>>'{shift,id}', :'sid', 'me: shows open shift');

-- cw_ping
select t.eq(cw_ping(:'ben', 1.3, 103.8, 5)->'shift', 'null'::jsonb, 'ping: not checked in');
select t.raises(format('cw_ping(%L, null, 103.8, 5)', :'amy'), 'Your location didn''t come through.%', 'ping: no location');
select t.raises(format('cw_ping(%L, 1.3, 200, 5)', :'amy'), 'That location isn''t valid.', 'ping: invalid');
update cw_shifts set last_seen_at = now() - interval '2 minutes' where id = :sid;
select cw_ping(:'amy', 1.3010, 103.8, 30)->'shift' as s \gset
select t.eq((:'s'::jsonb)->>'presence', 'away', 'ping: outside -> away');
select t.eq((:'s'::jsonb)->>'last_inside', 'false', 'ping: last_inside');
select t.eq((:'s'::jsonb)->>'pings_outside', '1', 'ping: counted outside');
select t.ok((select last_seen_at > now() - interval '5 seconds' from cw_shifts where id = :sid), 'ping: last seen updated');
select t.eq(cw_ping(:'amy', 1.3, 103.8, 200)#>>'{shift,presence}', 'present', 'ping: vague but inside still counts');
select t.eq(cw_ping(:'amy', 1.3, 103.8, 5)#>>'{shift,pings}', '4', 'ping: every ping kept');

-- cw_list_pings
select t.raises(format('cw_list_pings(%L, %s)', :'amy', :sid), 'Only the admin can do that.', 'pings: agent refused');
select t.eq((select jsonb_agg(p->'inside') from jsonb_array_elements(cw_list_pings(:'boss', :sid)->'pings') p),
  '[true, false, true, true]'::jsonb, 'pings: in order');
select t.eq(cw_list_pings(:'boss', 999)->'pings', '[]'::jsonb, 'pings: unknown shift');

-- cw_status: staffed, check (away / no signal), unmanned
select cw_checkin(:'ben', :south, 1.2, 103.7, 5) \g /dev/null
select cw_status(:'boss') as b \gset
select t.eq((select jsonb_object_agg(c->>'name', c->>'status') from jsonb_array_elements((:'b'::jsonb)->'counters') c),
  '{"North": "staffed", "South": "staffed"}'::jsonb, 'status: both staffed, closed counter hidden');
select cw_ping(:'amy', 1.3010, 103.8, 5) \g /dev/null
update cw_shifts set last_seen_at = now() - interval '4 minutes' where user_id = t.uid('ben');
select cw_status(:'boss') as b \gset
select t.eq((select jsonb_object_agg(c->>'name', (c->>'status') || '/' || (c#>>'{shifts,0,presence}')) from jsonb_array_elements((:'b'::jsonb)->'counters') c),
  '{"North": "check/away", "South": "check/no_signal"}'::jsonb, 'status: away and no signal need checking');
select t.raises(format('cw_status(%L)', :'amy'), 'Only the admin can do that.', 'status: agent refused', 'PT403');

-- cw_checkout
select t.eq(cw_checkout(:'amy')->'shift', 'null'::jsonb, 'checkout: ok');
select t.eq((select end_reason from cw_shifts where id = :sid), 'agent', 'checkout: by agent');
select t.raises(format('cw_checkout(%L)', :'amy'), 'You''re not checked in.', 'checkout: twice');
select cw_status(:'boss') as b \gset
select t.eq((select c->>'status' from jsonb_array_elements((:'b'::jsonb)->'counters') c where c->>'name' = 'North'), 'unmanned', 'status: unmanned after checkout');
select t.ok((select c->>'unmanned_since' is not null from jsonb_array_elements((:'b'::jsonb)->'counters') c where c->>'name' = 'North'), 'status: unmanned since');

-- Automatic check-out after 30 minutes without a location, at the last confirmed moment.
update cw_shifts set last_seen_at = now() - interval '31 minutes' where user_id = t.uid('ben') and end_at is null;
select t.eq(cw_me(:'ben')->'shift', 'null'::jsonb, 'sweep: checked out automatically');
select t.ok((select end_reason = 'no_signal' and end_at = last_seen_at from cw_shifts where user_id = t.uid('ben')), 'sweep: ended when last seen');
select t.eq(cw_ping(:'ben', 1.2, 103.7, 5)->'shift', 'null'::jsonb, 'sweep: page learns from the next ping');
select cw_status(:'boss') as b \gset
select t.ok((select bool_and(c->>'status' = 'unmanned') from jsonb_array_elements((:'b'::jsonb)->'counters') c), 'status: all unmanned');

-- cw_end_shift
select cw_checkin(:'amy', :north, 1.3, 103.8, 5)#>>'{shift,id}' as sid2 \gset
select t.raises(format('cw_end_shift(%L, %s)', :'amy', :sid2), 'Only the admin can do that.', 'end: agent refused');
select t.eq(cw_end_shift(:'boss', :sid2)->>'ok', 'true', 'end: ok');
select t.eq((select end_reason || '/' || ended_by from cw_shifts where id = :sid2), 'admin/' || t.uid('boss'), 'end: recorded who');
select t.raises(format('cw_end_shift(%L, %s)', :'boss', :sid2), 'That person is no longer checked in.', 'end: twice', 'PT404');
select t.eq(cw_ping(:'amy', 1.3, 103.8, 5)->'shift', 'null'::jsonb, 'end: agent learns from the next ping');

-- cw_list_shifts: everything that overlaps the window, newest first.
update cw_shifts set start_at = now() - interval '3 days', end_at = now() - interval '3 days' + interval '1 hour' where id = :sid;
select cw_checkin(:'amy', :north, 1.3, 103.8, 5) \g /dev/null
select t.raises(format('cw_list_shifts(%L, now() - interval ''1 day'', now())', :'amy'), 'Only the admin can do that.', 'log: agent refused');
select t.eq((select count(*) from jsonb_array_elements(cw_list_shifts(:'boss', now() - interval '1 day', now() + interval '1 second')->'shifts')), 3::bigint, 'log: last day');
select t.eq((select count(*) from jsonb_array_elements(cw_list_shifts(:'boss', now() - interval '4 days', now() + interval '1 second')->'shifts')), 4::bigint, 'log: last 4 days');
select t.eq((select jsonb_agg(s->'end_at') from jsonb_array_elements(cw_list_shifts(:'boss', now() - interval '4 days', now() - interval '2 days')->'shifts') s),
  jsonb_build_array(cw_ts(now() - interval '3 days' + interval '1 hour')), 'log: past window');
select t.eq(cw_list_shifts(:'boss', now() - interval '10 days', now() - interval '5 days')->'shifts', '[]'::jsonb, 'log: window before any shift');
select t.eq(cw_list_shifts(:'boss', now() - interval '1 day', now() + interval '1 second')#>>'{shifts,0,presence}', 'present', 'log: newest first, open shift included');
