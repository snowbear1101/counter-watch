-- Coverage of the page API, measured from inside the database:
--   functions: each cw_* function the page may call (granted to anon) that ran at least once
--              (pg_stat_user_functions, which run.sh switches on with track_functions);
--   branches:  each distinct error message in a cw_* function body, raised through cw_fail(...)
--              or returned as {"error": ...}, that a test actually provoked (t.hits).
-- A message used in several places counts once.
select pg_stat_force_next_flush() \g /dev/null
create temp view cov_fn as
  select p.proname as item, coalesce(s.calls, 0) > 0 as hit
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  left join pg_stat_user_functions s on s.funcid = p.oid
  where n.nspname = 'public' and p.proname like 'cw\_%' and has_function_privilege('anon', p.oid, 'execute');
create temp view cov_br as
  with msgs as (
    select distinct replace(m[1], '''''', '''') as msg
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
         regexp_matches(p.prosrc, $re$(?:cw_fail\((?:format\()?|'error', )'((?:[^']|'')*)'$re$, 'g') as m
    where n.nspname = 'public' and p.proname like 'cw\_%')
  select msg as item, exists (select 1 from t.hits h where h.msg like replace(msgs.msg, '%s', '%')) as hit from msgs;

\echo
\echo 'Not covered:'
select 'function' as kind, item from cov_fn where not hit
union all select 'branch', item from cov_br where not hit order by 1, 2;

select (select count(*) filter (where hit) || '/' || count(*) from cov_fn) as functions,
       (select count(*) filter (where hit) || '/' || count(*) from cov_br) as branches,
       round(100.0 * ((select count(*) filter (where hit) from cov_fn) + (select count(*) filter (where hit) from cov_br))
             / ((select count(*) from cov_fn) + (select count(*) from cov_br)), 1) as coverage_pct
\gset
\echo
\echo 'Functions: ' :functions '   Branches: ' :branches '   Coverage: ' :coverage_pct '%'
