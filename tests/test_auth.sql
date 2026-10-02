-- Setup, sign-in, sessions, passwords, throttling, and who may call what.
select t.reset();

-- cw_me before any account exists: tells the page to show setup.
select t.eq(cw_me(null)->'user', 'null'::jsonb, 'me: no token -> no user');
select t.eq(cw_me(null)->>'setup', 'true', 'me: no users yet -> setup');

-- cw_setup
select setup_code as code from cw_settings \gset
select t.returns_error(format('cw_setup(%L, %L, %L, %L)', 'boss', 'Boss', 'password1', 'wrong'),
  'That setup code is wrong.%', 'setup: wrong code');
select t.returns_error(format('cw_setup(%L, %L, %L, null)', 'boss', 'Boss', 'password1'),
  'That setup code is wrong.%', 'setup: missing code');
select t.raises(format('cw_setup(%L, %L, %L, %L)', 'x', 'Boss', 'password1', :'code'), 'Username must be 2–32 characters%', 'setup: short username');
select t.raises(format('cw_setup(%L, %L, %L, %L)', 'boss', '  ', 'password1', :'code'), 'Enter the person''s name.', 'setup: blank name');
select t.raises(format('cw_setup(%L, %L, %L, %L)', 'boss', 'Boss', 'short', :'code'), 'Password must be at least 8 characters.', 'setup: short password');
select t.eq((select count(*) from cw_users), 0::bigint, 'setup: failed attempts create nobody');

select cw_setup('  Boss ', ' The Boss ', 'password1', ' ' || :'code' || ' ') as r \gset
select t.ok((:'r'::jsonb)->>'token' ~ '^[0-9a-f]{64}$', 'setup: returns a token');
select t.eq((:'r'::jsonb)#>>'{user,username}', 'boss', 'setup: username lowercased and trimmed');
select t.eq((:'r'::jsonb)#>>'{user,name}', 'The Boss', 'setup: name trimmed');
select t.eq((:'r'::jsonb)#>>'{user,is_admin}', 'true', 'setup: first account is admin');
select t.ok((:'r'::jsonb) ? 'config', 'setup: returns config');
select t.raises(format('cw_setup(%L, %L, %L, %L)', 'boss2', 'B', 'password1', :'code'), 'The admin account already exists.', 'setup: only once', 'PT403');

-- Tokens are stored only as hashes.
select (:'r'::jsonb)->>'token' as boss \gset
select t.eq((select count(*) from cw_sessions where token_hash = :'boss'), 0::bigint, 'session: raw token not stored');
select t.eq((select count(*) from cw_sessions where token_hash = cw_hash_token(:'boss')), 1::bigint, 'session: hash stored');

-- cw_me with a token
select t.eq(cw_me(:'boss')#>>'{user,username}', 'boss', 'me: valid token');
select t.eq(cw_me(:'boss')->'shift', 'null'::jsonb, 'me: not checked in');
select t.eq(cw_me('garbage')->'user', 'null'::jsonb, 'me: bad token -> no user');
select t.eq(cw_me('garbage')->>'setup', 'false', 'me: users exist -> no setup');

-- cw_auth: bad, expired, and deactivated sessions.
select t.raises('cw_list_counters(''nope'')', 'Please sign in.', 'auth: bad token', 'PT401');
select t.raises('cw_list_counters(null)', 'Please sign in.', 'auth: null token', 'PT401');
select t.user('amy') as amy \gset
update cw_sessions set expires_at = now() - interval '1 second' where user_id = t.uid('amy');
select t.raises(format('cw_list_counters(%L)', :'amy'), 'Please sign in.', 'auth: expired token', 'PT401');
select t.user('ben') as ben \gset
update cw_users set active = false where username = 'ben';
select t.raises(format('cw_list_counters(%L)', :'ben'), 'Please sign in.', 'auth: deactivated user', 'PT401');
select t.eq(cw_me(:'ben')->'user', 'null'::jsonb, 'me: deactivated user');

-- cw_admin
select t.user('cat') as cat \gset
select t.raises(format('cw_list_users(%L)', :'cat'), 'Only the admin can do that.', 'admin: agent refused', 'PT403');

-- cw_login
select t.returns_error('cw_login(''cat'', ''wrongpass'')', 'Wrong username or password.', 'login: wrong password');
select t.returns_error('cw_login(''nobody'', ''password1'')', 'Wrong username or password.', 'login: unknown user');
select t.returns_error('cw_login(''ben'', ''password1'')', 'Wrong username or password.', 'login: deactivated user');
select t.returns_error('cw_login(null, null)', 'Wrong username or password.', 'login: nulls');
select cw_login(' CAT ', 'password1') as r \gset
select t.ok((:'r'::jsonb)->>'token' ~ '^[0-9a-f]{64}$', 'login: username case/space-insensitive');
select t.eq((:'r'::jsonb)#>>'{user,is_admin}', 'false', 'login: agent');
select t.eq((select count(*) from cw_login_fails where key = 'user:cat'), 0::bigint, 'login: success clears the user''s failures');

-- Throttling by username: 5 failures lock the account for everyone, even with the right password.
select t.reset();
select t.user('dan') as dan \gset
select cw_login('dan', 'bad') from generate_series(1, 4);
select t.ok(cw_login('dan', 'password1') ? 'token', 'throttle: 4 failures still allowed');
select cw_login('dan', 'bad') from generate_series(1, 5);
select t.returns_error('cw_login(''dan'', ''password1'')', 'Too many wrong attempts.%', 'throttle: locked after 5');
update cw_login_fails set at = now() - interval '16 minutes';
select t.ok(cw_login('dan', 'password1') ? 'token', 'throttle: lifts after the window');
select t.eq((select count(*) from cw_login_fails), 0::bigint, 'throttle: old failures purged');

-- Throttling by address (taken from the proxy headers), across usernames.
select set_config('request.headers', '{"x-forwarded-for": "203.0.113.9, 10.0.0.1"}', false);
select cw_login('user' || i, 'bad') from generate_series(1, 5) i;
select t.eq((select count(*) from cw_login_fails where key = 'ip:203.0.113.9'), 5::bigint, 'throttle: first forwarded address used');
select t.returns_error('cw_login(''dan'', ''password1'')', 'Too many wrong attempts.%', 'throttle: locked by address');
select set_config('request.headers', '{"cf-connecting-ip": "198.51.100.1", "x-forwarded-for": "203.0.113.9"}', false);
select t.ok(cw_login('dan', 'password1') ? 'token', 'throttle: cf-connecting-ip preferred');
select set_config('request.headers', 'not json', false);
select t.eq(cw_ip(), null, 'ip: unreadable headers -> null');
select set_config('request.headers', '', false);

-- Setup is throttled by address too.
select t.reset();
delete from cw_users;
select set_config('request.headers', '{"x-forwarded-for": "203.0.113.50"}', false);
select cw_setup('boss', 'Boss', 'password1', 'wrong') from generate_series(1, 5);
select t.returns_error(format('cw_setup(%L, %L, %L, %L)', 'boss', 'Boss', 'password1', :'code'), 'Too many wrong attempts.%', 'setup: throttled');
select set_config('request.headers', '', false);

-- cw_logout
select t.reset();
select t.user('eve') as eve \gset
select t.eq(cw_logout(:'eve')->>'ok', 'true', 'logout: ok');
select t.raises(format('cw_list_counters(%L)', :'eve'), 'Please sign in.', 'logout: token no longer works');
select t.eq(cw_logout('never-existed')->>'ok', 'true', 'logout: unknown token is harmless');

-- cw_change_password
select t.user('fay') as fay \gset
select (cw_login('fay', 'password1'))->>'token' as fay2 \gset
select t.raises(format('cw_change_password(%L, %L, %L)', :'fay', 'nope', 'newpassword'), 'Your current password is wrong.', 'password: wrong current');
select t.raises(format('cw_change_password(%L, %L, %L)', :'fay', 'password1', 'short'), 'New password must be at least 8 characters.', 'password: too short');
select t.raises(format('cw_change_password(%L, %L, null)', :'fay', 'password1'), 'New password must be at least 8 characters.', 'password: null');
select t.eq(cw_change_password(:'fay', 'password1', 'newpassword')->>'ok', 'true', 'password: changed');
select t.ok(cw_login('fay', 'newpassword') ? 'token', 'password: new one works');
select t.returns_error('cw_login(''fay'', ''password1'')', 'Wrong username or password.', 'password: old one doesn''t');
select t.ok(cw_me(:'fay')->'user' <> 'null'::jsonb, 'password: this session kept');
select t.eq(cw_me(:'fay2')->'user', 'null'::jsonb, 'password: other sessions signed out');

-- Expired sessions are cleaned up when a new one starts.
update cw_sessions set expires_at = now() - interval '1 day';
select t.user('gus') as gus \gset
select t.eq((select count(*) from cw_sessions), 1::bigint, 'session: expired ones purged');

-- Who may call what: the public key reaches page functions only, never tables or helpers.
select t.ok(has_function_privilege('anon', 'cw_login(text,text)', 'execute'), 'grants: anon may call cw_login');
select t.ok(has_function_privilege('authenticated', 'cw_status(text)', 'execute'), 'grants: authenticated may call cw_status');
select t.ok(not has_function_privilege('anon', 'cw_new_session(bigint)', 'execute'), 'grants: anon may not mint sessions');
select t.ok(not has_function_privilege('anon', 'cw_auth(text)', 'execute'), 'grants: anon may not call helpers');
select t.ok(not has_function_privilege('anon', 'cw_sweep()', 'execute'), 'grants: anon may not sweep');
select t.ok(not has_table_privilege('anon', 'cw_users', 'select'), 'grants: anon can''t read users');
select t.ok(not has_table_privilege('anon', 'cw_settings', 'select'), 'grants: anon can''t read the setup code');
select t.ok(not has_table_privilege('authenticated', 'cw_sessions', 'insert'), 'grants: authenticated can''t write sessions');
select t.ok((select bool_and(relrowsecurity) from pg_class where relname like 'cw\_%' and relkind = 'r'), 'grants: RLS on every table');
select t.ok((select bool_and(prosecdef) from pg_proc where has_function_privilege('anon', oid, 'execute') and proname like 'cw\_%'),
  'grants: every page function is security definer');
