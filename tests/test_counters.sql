-- cw_list_counters and cw_counter_save.
select t.reset();
select t.user('boss', true) as boss, t.user('amy') as amy \gset

select t.eq(cw_list_counters(:'boss')->'counters', '[]'::jsonb, 'list: empty');

-- Creating
select t.raises(format('cw_counter_save(%L, p_lat => 1, p_lng => 1)', :'boss'), 'Give the counter a name.', 'create: no name');
select t.raises(format('cw_counter_save(%L, p_name => %L, p_lat => 1, p_lng => 1)', :'boss', '   '), 'Give the counter a name.', 'create: blank name');
select t.raises(format('cw_counter_save(%L, p_name => %L)', :'boss', 'A'), 'Set the counter''s location%', 'create: no location');
select t.raises(format('cw_counter_save(%L, p_name => %L, p_lat => 1)', :'boss', 'A'), 'Set the counter''s location%', 'create: no longitude');
select t.raises(format('cw_counter_save(%L, p_name => %L, p_lat => 91, p_lng => 0)', :'boss', 'A'), 'That location isn''t valid.', 'create: latitude out of range');
select t.raises(format('cw_counter_save(%L, p_name => %L, p_lat => 0, p_lng => -181)', :'boss', 'A'), 'That location isn''t valid.', 'create: longitude out of range');
select t.raises(format('cw_counter_save(%L, p_name => %L, p_lat => %L, p_lng => 0)', :'boss', 'A', 'NaN'), 'That location isn''t valid.', 'create: NaN latitude');
select t.raises(format('cw_counter_save(%L, p_name => %L, p_lat => 0, p_lng => 0, p_radius_m => 9)', :'boss', 'A'), 'Radius must be between 10 and 1000 metres.', 'create: radius too small');
select t.raises(format('cw_counter_save(%L, p_name => %L, p_lat => 0, p_lng => 0, p_radius_m => 1001)', :'boss', 'A'), 'Radius must be between 10 and 1000 metres.', 'create: radius too big');
select t.raises(format('cw_counter_save(%L, p_name => %L, p_lat => 0, p_lng => 0)', :'amy', 'A'), 'Only the admin can do that.', 'create: agent refused', 'PT403');
select t.eq((select count(*) from cw_counters), 0::bigint, 'create: refusals create nothing');

select cw_counter_save(:'boss', p_name => '  Zeta desk  ', p_lat => 1.3, p_lng => 103.8)->'counter' as z \gset
select t.eq((:'z'::jsonb)->>'name', 'Zeta desk', 'create: name trimmed');
select t.eq((:'z'::jsonb)->>'radius_m', '50', 'create: default radius');
select t.eq((:'z'::jsonb)->>'active', 'true', 'create: active');
select cw_counter_save(:'boss', p_name => repeat('x', 100), p_lat => -1, p_lng => -1, p_radius_m => 10)->'counter' as x \gset
select t.eq(length((:'x'::jsonb)->>'name'), 80, 'create: name capped at 80');
select t.eq((:'x'::jsonb)->>'radius_m', '10', 'create: radius kept');

-- Updating: only the fields given change.
select ((:'z'::jsonb)->>'id')::bigint as zid, ((:'x'::jsonb)->>'id')::bigint as xid \gset
select t.raises(format('cw_counter_save(%L, 999, p_name => %L)', :'boss', 'Q'), 'That counter doesn''t exist.', 'update: missing counter', 'PT404');
select t.raises(format('cw_counter_save(%L, %s, p_name => %L)', :'boss', :zid, ''), 'Give the counter a name.', 'update: blank name');
select t.raises(format('cw_counter_save(%L, %s, p_lat => 5)', :'boss', :zid), 'That location isn''t valid.', 'update: latitude without longitude');
select t.raises(format('cw_counter_save(%L, %s, p_lng => 500)', :'boss', :zid), 'That location isn''t valid.', 'update: longitude out of range');
select t.raises(format('cw_counter_save(%L, %s, p_lng => %L)', :'boss', :zid, 'NaN'), 'That location isn''t valid.', 'update: NaN longitude');
select t.raises(format('cw_counter_save(%L, %s, p_lat => 1.3, p_lng => %L)', :'boss', :zid, 'Infinity'), 'That location isn''t valid.', 'update: infinite longitude');
select t.raises(format('cw_counter_save(%L, %s, p_radius_m => 5000)', :'boss', :zid), 'Radius must be between 10 and 1000 metres.', 'update: bad radius');
select t.eq(cw_counter_save(:'boss', :zid, p_name => 'Alpha desk')->'counter',
  jsonb_build_object('id', :zid, 'name', 'Alpha desk', 'lat', 1.3, 'lng', 103.8, 'radius_m', 50, 'active', true), 'update: rename only');
select t.eq(cw_counter_save(:'boss', :zid, p_lat => 1.31, p_lng => 103.81, p_radius_m => 80)->'counter',
  jsonb_build_object('id', :zid, 'name', 'Alpha desk', 'lat', 1.31, 'lng', 103.81, 'radius_m', 80, 'active', true), 'update: move and resize');

-- Turning off / on
select t.eq(cw_counter_save(:'boss', :xid, p_active => false)#>>'{counter,active}', 'false', 'update: turn off');
select t.eq(cw_counter_save(:'boss', :xid, p_active => true)#>>'{counter,active}', 'true', 'update: turn on');
insert into cw_shifts (user_id, counter_id, start_lat, start_lng, start_acc, start_dist) values (t.uid('amy'), :zid, 1.31, 103.81, 5, 0);
select t.raises(format('cw_counter_save(%L, %s, p_active => false)', :'boss', :zid), 'Someone is checked in at this counter.%', 'update: can''t turn off while staffed');
select t.eq(cw_counter_save(:'boss', :zid, p_radius_m => 60)#>>'{counter,radius_m}', '60', 'update: staffed counter can still be edited');
update cw_shifts set end_at = now();
select cw_counter_save(:'boss', :xid, p_active => false) \g /dev/null

-- Listing: admin sees all (active first, then by name); agents see active only.
select t.eq((select jsonb_agg(c->>'name') from jsonb_array_elements(cw_list_counters(:'boss')->'counters') c),
  jsonb_build_array('Alpha desk', repeat('x', 80)), 'list: admin sees all, active first');
select t.eq((select jsonb_agg(c->>'name') from jsonb_array_elements(cw_list_counters(:'amy')->'counters') c),
  jsonb_build_array('Alpha desk'), 'list: agent sees active only');
