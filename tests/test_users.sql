-- cw_list_users, cw_user_add, cw_user_update.
select t.reset();
select t.user('boss', true) as boss, t.user('amy') as amy \gset

-- cw_user_add
select t.raises(format('cw_user_add(%L, %L, %L, %L)', :'amy', 'bob', 'Bob', 'password1'), 'Only the admin can do that.', 'add: agent refused', 'PT403');
select t.raises(format('cw_user_add(%L, %L, %L, %L)', :'boss', 'Bob Smith', 'Bob', 'password1'), 'Username must be 2–32 characters%', 'add: space in username');
select t.raises(format('cw_user_add(%L, %L, %L, %L)', :'boss', repeat('b', 33), 'Bob', 'password1'), 'Username must be 2–32 characters%', 'add: username too long');
select t.raises(format('cw_user_add(%L, null, %L, %L)', :'boss', 'Bob', 'password1'), 'Username must be 2–32 characters%', 'add: null username');
select t.raises(format('cw_user_add(%L, %L, null, %L)', :'boss', 'bob', 'password1'), 'Enter the person''s name.', 'add: null name');
select t.raises(format('cw_user_add(%L, %L, %L, %L)', :'boss', 'bob', 'Bob', '1234567'), 'Password must be at least 8 characters.', 'add: short password');
select t.raises(format('cw_user_add(%L, %L, %L, %L)', :'boss', ' AMY ', 'Amy 2', 'password1'), 'That username is already taken.', 'add: duplicate (case-insensitive)');

select cw_user_add(:'boss', ' Mei.Lin ', ' Mei Lin ', 'password1')->'user' as u \gset
select t.eq((:'u'::jsonb) - 'id', '{"username": "mei.lin", "name": "Mei Lin", "is_admin": false, "active": true}'::jsonb, 'add: agent by default');
select t.ok(cw_login('mei.lin', 'password1') ? 'token', 'add: can sign in');
select t.eq(cw_user_add(:'boss', 'deputy', 'Deputy', 'password1', true)#>>'{user,is_admin}', 'true', 'add: admin');
select t.eq(cw_user_add(:'boss', 'agent2', 'Agent 2', 'password1', null)#>>'{user,is_admin}', 'false', 'add: null admin flag -> agent');
select t.ok((select pw_hash like '$2a$10$%' from cw_users where username = 'mei.lin'), 'add: bcrypt hash stored');

-- cw_list_users: active first, then by name.
update cw_users set active = false where username = 'agent2';
select t.eq((select jsonb_agg(u->>'username') from jsonb_array_elements(cw_list_users(:'boss')->'users') u),
  '["amy", "boss", "deputy", "mei.lin", "agent2"]'::jsonb, 'list: ordering');
select t.raises(format('cw_list_users(%L)', :'amy'), 'Only the admin can do that.', 'list: agent refused');
select t.ok(not (cw_list_users(:'boss')->'users'->0 ? 'pw_hash'), 'list: no password hashes');

-- cw_user_update
select t.uid('amy') as amy_id, t.uid('boss') as boss_id \gset
select t.raises(format('cw_user_update(%L, 999, p_name => %L)', :'boss', 'X'), 'That person doesn''t exist.', 'update: missing person', 'PT404');
select t.raises(format('cw_user_update(%L, %s, p_name => %L)', :'amy', :amy_id, 'X'), 'Only the admin can do that.', 'update: agent refused');
select t.raises(format('cw_user_update(%L, %s, p_name => %L)', :'boss', :amy_id, ' '), 'Name can''t be empty.', 'update: blank name');
select t.eq(cw_user_update(:'boss', :amy_id, p_name => '  Amy Tan ')#>>'{user,name}', 'Amy Tan', 'update: rename');

select t.raises(format('cw_user_update(%L, %s, p_password => %L)', :'boss', :amy_id, 'short'), 'Password must be at least 8 characters.', 'update: short password');
select cw_login('amy', 'bad') from generate_series(1, 5) \g /dev/null
select t.returns_error('cw_login(''amy'', ''password1'')', 'Too many wrong attempts.%', 'update: (amy locked out)');
select cw_user_update(:'boss', :amy_id, p_password => 'resetpass1') \g /dev/null
select t.raises(format('cw_list_counters(%L)', :'amy'), 'Please sign in.', 'update: password reset signs them out');
select t.ok(cw_login('amy', 'resetpass1') ? 'token', 'update: password reset clears the lockout');

select t.raises(format('cw_user_update(%L, %s, p_active => false)', :'boss', :boss_id), 'You can''t deactivate your own account.', 'update: no self-deactivation');
select t.raises(format('cw_user_update(%L, %s, p_is_admin => false)', :'boss', :boss_id), 'You can''t remove your own admin access.', 'update: no self-demotion');
select t.eq(cw_user_update(:'boss', :amy_id, p_is_admin => true)#>>'{user,is_admin}', 'true', 'update: promote');
select t.eq(cw_user_update(:'boss', :amy_id, p_is_admin => false)#>>'{user,is_admin}', 'false', 'update: demote');

-- Deactivating signs them out and checks them out; reactivating lets them back in.
select (cw_login('amy', 'resetpass1'))->>'token' as amy \gset
insert into cw_counters (name, lat, lng, radius_m) values ('Desk', 1.3, 103.8, 50);
select cw_checkin(:'amy', 1, 1.3, 103.8, 5) \g /dev/null
select t.eq(cw_user_update(:'boss', :amy_id, p_active => false)#>>'{user,active}', 'false', 'update: deactivate');
select t.eq((select count(*) from cw_sessions where user_id = :amy_id), 0::bigint, 'update: deactivated -> sessions gone');
select t.eq((select end_reason || '/' || (ended_by = :boss_id) from cw_shifts where user_id = :amy_id), 'admin/true', 'update: deactivated -> checked out by admin');
select t.returns_error('cw_login(''amy'', ''resetpass1'')', 'Wrong username or password.', 'update: deactivated can''t sign in');
select t.eq(cw_user_update(:'boss', :amy_id, p_active => true)#>>'{user,active}', 'true', 'update: reactivate');
select t.ok(cw_login('amy', 'resetpass1') ? 'token', 'update: reactivated can sign in');
select t.eq(cw_user_update(:'boss', :amy_id)->'user'->>'username', 'amy', 'update: nothing to change is a no-op');
