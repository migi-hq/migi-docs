-- 2026-09-29 打完自動結算成績、收桌記錄是誰按的 —— 套用「前」先跑這份（唯讀，一支 SELECT）
-- 📄 要套用的：sql/pending/2026-09-29_打完自動結算成績_收桌記錄是誰按的.sql
--
-- 為什麼要先跑：那份 migration 是對「線上現在的函式全文」做字串替換（硬規則 3：不拿本機檔案當基準），
-- 替換不到就整份回滾。這裡先把每一個錨點印出來，紅的就先別套用、把結果貼回來。
-- 每一格的樣式必須與 migration 逐字相同。

with defs as (
  select p.proname,
         pg_get_functiondef(p.oid) as def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('_score_settle_tx', 'settle_session_tx', 'tbl_state_tx')
), anchors as (
  select 1 as n, '① _score_settle_tx 有「放掉平板」那段（要搬走）' as 項目,
         (select count(*) from defs d, regexp_matches(d.def,
            '[[:blank:]]*-- ⑤[^[:cntrl:]]*\s+update session_players set device_id = null\s+where session_id = p_session_id and device_id is not null;', 'g')
           where d.proname = '_score_settle_tx')::text as 命中,
         '要剛好 1' as 期望
  union all
  select 2, '② settle_session_tx 有「update table_sessions set status = completed」',
         (select count(*) from defs d, regexp_matches(d.def,
            '(update table_sessions\s+set\s+status\s*=\s*''completed'',)', 'g')
           where d.proname = 'settle_session_tx')::text, '要剛好 1'
  union all
  select 3, '③ settle_session_tx 有「v_score := _score_settle_tx(p_session_id);」',
         (select count(*) from defs d, regexp_matches(d.def,
            'v_score := public\._score_settle_tx\(p_session_id\);', 'g')
           where d.proname = 'settle_session_tx')::text, '要剛好 1'
  union all
  select 4, '④ tbl_state_tx 結尾是「''log'', …, ''patterns'', v_catalog)」',
         (select count(*) from defs d, regexp_matches(d.def,
            '(''log'',\s*coalesce\(v_log,\s*''\[\]''::jsonb\),\s*''patterns'',\s*v_catalog)\)', 'g')
           where d.proname = 'tbl_state_tx')::text, '要剛好 1'
  union all
  select 5, '⑤ 還沒套用過（三支函式裡都沒有 _session_scored）',
         (select count(*) from defs where def like '%_session_scored%')::text, '要是 0'
  union all
  select 6, '⑥ table_sessions 還沒有 closed_by_staff_id 欄位',
         (select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'table_sessions' and column_name = 'closed_by_staff_id')::text, '要是 0'
  union all
  select 7, '⑦ session_rounds 現有觸發器（名單）',
         coalesce((select string_agg(tgname, '、') from pg_trigger
                    where tgrelid = 'public.session_rounds'::regclass and not tgisinternal), '（沒有）'), '看名單，不能已經有 trg_session_rounds_*'
  union all
  select 8, '⑧ 還有哪些函式會把場次寫成 completed（除了收桌）',
         coalesce((select string_agg(p.proname, '、')
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and p.proname <> 'settle_session_tx'
                      and pg_get_functiondef(p.oid) ~ 'table_sessions\s+set\s+status\s*=\s*''completed'''), '（沒有）'),
         '有名字的要逐一看：它們收桌時不會記 closed_by_staff_id'
  union all
  select 9, '⑨ v_real_table_sessions 有沒有（新欄位進不去它，獎金報表要查它）',
         coalesce((select count(*)::text || ' 欄' from information_schema.columns
                    where table_schema = 'public' and table_name = 'v_real_table_sessions'), '0 欄'), '記下來；套用後要補'
  union all
  -- 診斷：①②沒命中時，直接看線上那幾行實際長怎樣（空白壓成一格）
  select 10, '⑩ 線上 _score_settle_tx 裡「⑤」附近',
         -- ⚠ 不用正則截：Postgres 正則的 {m,n} 上限是 255，寫 {0,260} 會直接報 invalid repetition count
         coalesce((select regexp_replace(substr(d.def, strpos(d.def, '-- ⑤'), 300), '\s+', ' ', 'g')
                     from defs d where d.proname = '_score_settle_tx' and strpos(d.def, '-- ⑤') > 0), '（找不到 -- ⑤）'),
         '診斷用'
  union all
  select 11, '⑪ 線上 settle_session_tx 裡第一個「update … table_sessions」附近',
         -- ⚠ 分組要用 (?:…)：substring(… from 樣式) 有括號時只回傳括號裡那一段（09-29 第一次跑回「找不到」就是這個）
         coalesce((select regexp_replace(substring(d.def from 'update[[:space:]]+(?:public\.)?table_sessions.{0,200}'), '\s+', ' ', 'g') from defs d where d.proname = 'settle_session_tx'), '（找不到）'),
         '診斷用'
)
select n as "#", 項目, 命中, 期望,
       case when n in (1,2,3,4) then case when 命中 = '1' then '✅' else '🔴' end
            when n in (5,6)     then case when 命中 = '0' then '✅' else '🔴' end
            else '👀' end as 判定
  from anchors order by n;
