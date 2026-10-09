-- ════════════════════════════════════════════════════════════════════
-- 2026-10-09 創辦人的舊牌局從他自己的紀錄裡藏起來（清單從零開始）
-- ════════════════════════════════════════════════════════════════════
-- 使用者：段位重來之後，舊牌局「從你的紀錄裡藏起來，讓清單也從零開始」
--   （接 2026-10-09_創辦人段位重來.sql：那一份清了名次但留著牌局紀錄）
--
-- 新欄位 session_players.hidden_from_history_at
--   有值 ＝ 這一場不出現在「這個人自己的」牌局紀錄與麻將足跡裡。
--   · 牌局本身、同桌其他人的紀錄、計分板每一局都不動
--   · 要救回來：把這個欄位清成 null
--
-- 改的兩支（簽名不變，create or replace 不丟權限）
--   get_my_games_tx      牌局紀錄清單略過藏起來的場次
--   _member_stats_core   「麻將足跡」（打牌時間／去過幾間店／遇過幾位對手）略過藏起來的場次
--                        ⚠ 其餘統計本來就只算「有名次」的場次，創辦人的名次已清空，不用改
--     這支很長，只動 mysess 那一段：用 regexp 插一個條件，插不到就整份不提交（下面 guard）
--
-- 順帶：那幾場還有 1 則「給同桌評價」沒按完成，配桌頁會一直提示 ⇒ 標成已完成、已讀。
-- ════════════════════════════════════════════════════════════════════

alter table public.session_players
  add column if not exists hidden_from_history_at timestamptz;
comment on column public.session_players.hidden_from_history_at is
  '有值＝這一場不出現在這個人自己的牌局紀錄與麻將足跡（2026-10-09 起；清成 null 就回來）。牌局本身與同桌其他人不受影響';

-- ① 創辦人（手機 0910768736）目前所有牌局都藏起來
update session_players sp
   set hidden_from_history_at = now()
  from members m
 where m.id = sp.member_id
   and m.phone = '0910768736'
   and sp.hidden_from_history_at is null;

-- ② 那幾場的「給同桌評價」通知標成完成、已讀
update app_notifications n
   set done_at = coalesce(n.done_at, now()),
       read_at = coalesce(n.read_at, now())
  from members m
 where m.id = n.member_id
   and m.phone = '0910768736'
   and n.type = 'settle'
   and n.ref_id in (select sp.session_id from session_players sp where sp.member_id = m.id)
   and (n.done_at is null or n.read_at is null);

-- ③ 牌局紀錄清單
create or replace function public.get_my_games_tx(p_org_id uuid, p_member_id uuid, p_limit integer default 20)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  /* 只認登入身分（2026-10-02）：沒登入就拒絕，前端傳的會員 id 一律忽略 */
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  p_member_id := v_me;

  return (
    with mine as (
      -- 從「我坐過的位子」反查場次 —— 不需要知道那桌是怎麼開的。
      select s.id, coalesce(s.ended_at, sp.settled_at) as ended_at
        from session_players sp
        join table_sessions s on s.id = sp.session_id
       where sp.member_id = p_member_id
         and sp.org_id    = p_org_id
         and s.org_id     = p_org_id
         and s.deleted_at is null
         -- 已收桌，或成績已經算好（打完最後一將就自動結算，不等店員收桌，2026-10-02）
         and (s.status = 'completed' or sp.finish_rank is not null)
         -- 從本人紀錄藏起來的場次不列（2026-10-09）
         and sp.hidden_from_history_at is null
       order by coalesce(s.ended_at, sp.settled_at) desc nulls last
       limit greatest(coalesce(p_limit, 20), 1)
    )
    select coalesce(
      jsonb_agg(public._game_row(p_org_id, m.id, p_member_id) order by m.ended_at desc nulls last),
      '[]'::jsonb)
    from mine m
  );
end $function$;

-- ④ 麻將足跡：只在 mysess 那一段插條件
do $$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef('public._member_stats_core(uuid, uuid)'::regprocedure);
  if v_old ~ 'hidden_from_history_at' then
    return;   -- 已經改過（重跑）
  end if;
  v_new := regexp_replace(v_old,
             '(with mysess as \(.*?and s\.status\s*=\s*''completed'')',
             '\1' || E'\n       and sp.hidden_from_history_at is null   -- 從本人紀錄藏起來的場次不算（2026-10-09）');
  /* guard：一定要剛好插進 mysess 那一段，否則整份不提交（這是「故意不要提交」的 raise，不是驗證段） */
  if v_new = v_old or v_new !~ 'with mysess as \([^;]*hidden_from_history_at' then
    raise exception 'mysess 那一段沒有插到條件，整份不提交';
  end if;
  execute v_new;
end $$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
with f as (select id from members where phone = '0910768736' and deleted_at is null)
select concat_ws(E'\n',
  -- ① 欄位在
  case when exists (select 1 from information_schema.columns where table_schema='public'
                     and table_name='session_players' and column_name='hidden_from_history_at')
       then '✅ ① 新欄位在' else '🔴 ① 沒有新欄位' end,
  -- ② 創辦人全部藏起來
  (select case when count(*) > 0 and count(*) filter (where sp.hidden_from_history_at is null) = 0
               then '✅ ② 創辦人 ' || count(*) || ' 場都藏起來了'
               else '🔴 ② 還有 ' || count(*) filter (where sp.hidden_from_history_at is null) || ' 場沒藏' end
     from session_players sp join f on f.id = sp.member_id),
  -- ③ 負對照：別人一筆都沒被藏
  (select case when count(*) = 0 then '✅ ③ 其他人的紀錄沒被動到'
               else '🔴 ③ 有 ' || count(*) || ' 筆別人的紀錄被藏了' end
     from session_players sp where sp.hidden_from_history_at is not null
      and sp.member_id not in (select id from f)),
  -- ④ 牌局紀錄清單有條件、登入的人仍然叫得到
  (select case when pg_get_functiondef(p.oid) like '%sp.hidden_from_history_at is null%'
                and has_function_privilege('authenticated', p.oid, 'execute')
                and not has_function_privilege('anon', p.oid, 'execute')
               then '✅ ④ 牌局紀錄清單會略過藏起來的場次，權限沒變' else '🔴 ④ 清單沒改到或權限變了' end
     from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_my_games_tx'),
  -- ⑤ 麻將足跡有條件，而且只有一個版本、權限沒變（只給內部）
  (select case when count(*) = 1
                and bool_and(pg_get_functiondef(p.oid) ~ 'with mysess as \([^;]*hidden_from_history_at')
                and bool_and(not has_function_privilege('authenticated', p.oid, 'execute'))
               then '✅ ⑤ 麻將足跡會略過藏起來的場次' else '🔴 ⑤ 麻將足跡沒改到或權限變了' end
     from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='_member_stats_core'),
  -- ⑥ 沒有還沒評完的提示
  (select case when count(*) = 0 then '✅ ⑥ 舊牌局的「給同桌評價」都標成完成'
               else '🔴 ⑥ 還有 ' || count(*) || ' 則沒完成' end
     from app_notifications n join f on f.id = n.member_id
    where n.type = 'settle' and n.done_at is null
      and n.ref_id in (select sp.session_id from session_players sp join f on f.id = sp.member_id))
) as "驗證";
