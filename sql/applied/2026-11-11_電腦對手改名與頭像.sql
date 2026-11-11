-- 電腦對手改名字與頭像：教練熊、廚師熊、商人熊（2026-11-11 使用者：
--   「3個電腦分別用 教練熊 商人熊 廚師熊頭像」→「應該叫 教練熊 廚師熊 商人熊」）
-- 在 Supabase SQL Editor 執行。
--
-- 做了什麼
--   ① 三個電腦帳號改名字與頭像代號（原本叫電腦一號／二號／三號，頭像是段位熊）：
--        電腦一號 → 教練熊（頭像代號 coach）
--        電腦二號 → 廚師熊（chef）
--        電腦三號 → 商人熊（merchant）
--      頭銜維持「電腦對手」（牌桌名牌上名字上面那一行，讓人一眼知道它是電腦）
--   ② add_friendly_bots_tx：加電腦的先後順序原本是照「電腦一號、二號、三號」這三個名字排的，名字改掉之後會排不出順序
--      ⇒ 改成照頭像代號排（教練熊 → 廚師熊 → 商人熊）。其餘一個字沒動。簽名沒變 ⇒ CREATE OR REPLACE，授權不會掉
--   ③ 電腦只出現在好友練習賽的線上開打：POS 會員搜尋、後台會員查詢、會員清單三支都不列電腦
--   ④ 報表檢視表 v_real_members 補上 is_bot 欄位（錯誤儀表 ⑫ 抓到的：members 加了欄位、檢視表沒跟上）
--
-- 頭像代號存在 members.avatar_bear；會員 App 認得 coach／chef／merchant 這三個代號就會顯示對應的圖。
-- 客人選不到這三個：選頭像的清單裡沒有，set_avatar_tx 也不收。
-- 先後順序：這份先跑、App 還沒更新時，舊版 App 不認得這三個代號 ⇒ 電腦的頭像會暫時顯示成預設小熊（不會壞）。
-- 可以重跑：已經改過名字的那三列，第二次跑時 where 條件對不到舊名字，不會再動。

-- ① 名字與頭像
update public.members
   set avatar_bear   = case display_name when '電腦一號' then 'coach' when '電腦二號' then 'chef' when '電腦三號' then 'merchant' end,
       display_name  = case display_name when '電腦一號' then '教練熊' when '電腦二號' then '廚師熊' when '電腦三號' then '商人熊' end,
       avatar_source = 'bear', updated_at = now()
 where is_bot and display_name in ('電腦一號', '電腦二號', '電腦三號');

-- ② 加電腦對手：順序改照頭像代號
create or replace function public.add_friendly_bots_tx(p_game uuid, p_count integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid; g friendly_games; v_n int; v_added int := 0; v_sid uuid; r record;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select * into g from friendly_games where id = p_game for update;
  if g.id is null or not exists (select 1 from friendly_game_players where game_id = p_game and member_id = v_me and left_at is null) then
    raise exception '你不在這一場好友練習賽裡';
  end if;
  if g.opened_by <> v_me then raise exception '只有開這一場的人可以加電腦對手'; end if;
  if g.status <> 'waiting' then raise exception '這一場已經開始了，不能再加電腦對手'; end if;
  if g.play_mode <> 'online' then raise exception '只有線上開打可以加電腦對手'; end if;
  if coalesce(p_count, 0) < 1 or p_count > 3 then raise exception '電腦對手一次加 1 到 3 位'; end if;
  select count(*) into v_n from friendly_game_players where game_id = p_game and left_at is null;
  if p_count > 4 - v_n then raise exception '只剩 % 個空位', 4 - v_n; end if;

  -- 還沒在這一場裡的電腦，照教練熊、廚師熊、商人熊的順序補（看頭像代號，不看名字 —— 名字之後可能再改）
  for r in
    select m.id from members m
     where m.org_id = g.org_id and m.is_bot and m.deleted_at is null
       and not exists (select 1 from friendly_game_players fp where fp.game_id = p_game and fp.member_id = m.id and fp.left_at is null)
     order by array_position(array['coach', 'chef', 'merchant']::text[], m.avatar_bear) nulls last, m.created_at, m.id
     limit p_count
  loop
    insert into friendly_game_players (org_id, game_id, member_id, join_source) values (g.org_id, p_game, r.id, 'bot');
    v_added := v_added + 1;
  end loop;
  if v_added < p_count then raise exception '電腦對手的設定不存在（請找總部）'; end if;   -- 整筆退回，不留半套

  if v_n + v_added = 4 then v_sid := public._friendly_start(p_game); end if;
  return jsonb_build_object('ok', true, 'added', v_added, 'started', v_sid is not null);
end $$;

-- ③ 電腦對手只出現在好友練習賽的線上開打（2026-11-11 使用者：「要過濾掉 他只會出現在 好友練習賽的線上開打 加牌咖限定出現」）
--    會把會員列給店員或總部看的三支：POS 會員搜尋、後台會員查詢、會員清單 —— 各加一個條件「不是電腦」。
--    三支的本體是 2026-11-11 用 pg_get_functiondef 從線上撈的，其餘一個字沒動；簽名沒變 ⇒ CREATE OR REPLACE，授權不會掉。
--    ⚠ 排行、報表、v_real_* 不用改：電腦同時是測試帳號，本來就不會被算到。

-- POS 會員搜尋
create or replace function public.pos_search_members_tx(p_org_id uuid, p_keyword text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_kw text;
begin
  if not public.can('member.lookup') then
    raise exception 'forbidden: 需要店員身分';
  end if;

  /* ⚠ 覆寫而不是驗證相等 —— 驗證相等會讓「送錯 org」變成一個
     可以用來試探「哪個 org 存在」的訊號。直接用自己的就沒有那個面。 */
  p_org_id := public.current_org_id();

  v_kw := trim(coalesce(p_keyword, ''));
  if length(v_kw) = 0 then return '[]'::jsonb; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'phone', m.phone,
      'tier', coalesce(m.tier_override, m.tier), 'rank', m.rank, 'title', m.title,
      'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear, 'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'balance', coalesce(w.balance, 0),
      'is_test', m.is_test
    ) order by m.display_name)
    from members m
    left join wallets w on w.member_id = m.id
    where m.org_id = p_org_id and m.deleted_at is null
      and not m.is_bot                                    -- 電腦對手不是客人，櫃檯搜不到
      and (m.display_name ilike '%' || v_kw || '%' or m.phone like '%' || v_kw || '%')
    limit 20
  ), '[]'::jsonb);
end $function$;

-- 後台會員查詢
create or replace function public.admin_find_members_tx(p_phone text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_q text := btrim(coalesce(p_phone, ''));                       -- 搜尋字（門號或暱稱）
  v_p text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); -- 裡面的數字（比對門號用）
  v_like text;
begin
  if not public.can('member.hide') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以查詢');
  end if;
  if v_q = '' then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  end if;
  -- 暱稱的部分比對：% 與 _ 當一般字元
  v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  /* ⚠ limit 要放在子查詢裡 —— 寫在 jsonb_agg 那一層的話它限制的是
     「聚合完的那一列」，等於沒限制。 */
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', x.id,
             'name', x.name,
             'phone', x.phone,
             'line_bound', x.line_bound,
             'created_at', x.created_at,
             'hidden_at', x.hidden_at,
             'hidden_source', (select l.source from member_hide_log l
                                where l.member_id = x.id and l.action = 'hide'
                                order by l.at desc limit 1),
             'hidden_reason', (select l.reason from member_hide_log l
                                where l.member_id = x.id and l.action = 'hide'
                                order by l.at desc limit 1))
           order by x.created_at)
      from (
        select m.id, coalesce(h.display_name, m.display_name) as name, m.phone,
               m.line_user_id is not null as line_bound, m.created_at, m.hidden_at
          from members m
          left join member_hidden h on h.member_id = m.id
         where m.org_id = (select s.org_id from staff s
                            where s.id = (select staff_id from public.current_staff()))
           and m.deleted_at is null
           and not m.is_bot                               -- 電腦對手不是客人，後台查不到（也就不會被拿去隱藏、發配對碼）
           and ((length(v_p) >= 4 and m.phone like '%' || v_p || '%')
                or coalesce(h.display_name, m.display_name) ilike v_like)
         order by m.created_at
         limit 20
      ) x), '[]'::jsonb));
end $function$;

-- 會員清單
create or replace function public.list_members_tx(p_org_id uuid, p_limit integer default 50)
returns table(member_id uuid, display_name text, phone text, created_at timestamp with time zone)
language sql
security definer
set search_path to 'public'
as $function$
  select id, display_name, phone, created_at
  from members
  where org_id = p_org_id and deleted_at is null
    and not is_bot                                        -- 電腦對手不列
  order by created_at desc
  limit greatest(1, least(p_limit, 200));
$function$;

-- ④ 報表檢視表 v_real_members 補上 is_bot 那一欄
--    members 2026-11-11 加了 is_bot，而這支檢視表的欄位是寫死的清單，不會自己跟上（錯誤儀表 ⑫ 當天就紅了）。
--    電腦對手本來就是測試帳號（is_test = true），進不了這支檢視表 —— 補欄位是為了讓儀表那一格不要一直紅著。
--    本體照線上版（pg_get_viewdef 撈的），只在最後面多一欄 ⇒ CREATE OR REPLACE 可以，授權不會動（只有 postgres 與 service_role）。
create or replace view public.v_real_members as
 select m.id, m.org_id, m.line_user_id, m.display_name, m.phone, m.home_store_id, m.tier, m.gender, m.birthday, m.occupation,
        m.district, m.acquisition_source, m.avatar_url, m.last_visit_at, m.visit_count, m.lifecycle, m.primary_staff_id,
        m.deleted_at, m.created_at, m.updated_at, m.created_by, m.updated_by, m.tier_override, m.last_app_active_at,
        m.rank, m.title, m.likes_count, m.is_test, m.about, m.sched, m.style, m.see_score, m.baby_tile,
        m.avatar_source, m.avatar_photo_path, m.avatar_photo_at, m.avatar_blocked, m.avatar_removed_count,
        m.inv_type, m.inv_carrier, m.inv_donate_code, m.inv_tax_id, m.inv_title, m.avatar_bear, m.phone_verified_at,
        m.rating, m.rating_games, m.hidden_at, m.best_rank_tier, m.legend_title,
        m.acquisition_channel, m.acquisition_campaign, m.referred_by_staff_id, m.referred_by_member_id,
        m.acquisition_at, m.acquisition_backfilled,
        m.is_bot
   from members m
   join orgs o on o.id = m.org_id
  where m.is_test = false and m.deleted_at is null and m.created_at >= coalesce(o.live_from, 'infinity'::timestamp with time zone);

-- ─── 驗證（單一 SELECT）───
select string_agg(case when ok then '✅ ' else '🔴 ' end || item, E'\n' order by ord) as "驗證（應該 9 格全綠）"
  from (
    select 1 as ord,
           (select count(*) from public.members where is_bot and avatar_source = 'bear'
               and (display_name, avatar_bear) in (('教練熊', 'coach'), ('廚師熊', 'chef'), ('商人熊', 'merchant')))
             = (select 3 * count(*) from public.orgs) as ok,
           '① 每個機構的三個電腦：' || coalesce((select string_agg(display_name || '＝' || coalesce(avatar_bear, '沒有'), '、' order by array_position(array['coach', 'chef', 'merchant']::text[], avatar_bear))
                                                 from public.members where is_bot), '一個都沒有') as item
    union all
    select 2,
           not exists (select 1 from public.members where is_bot and (display_name like '電腦%' or coalesce(avatar_bear, '') not in ('coach', 'chef', 'merchant') or title <> '電腦對手' or not is_test)),
           '② 沒有任何一個電腦還留著舊名字或別的頭像代號；頭銜都是「電腦對手」、都還是測試帳號'
    union all
    select 3,
           not exists (select 1 from public.members where not is_bot and (avatar_bear in ('coach', 'chef', 'merchant') or display_name in ('教練熊', '廚師熊', '商人熊'))),
           '③ 負對照：真人沒有人被改到這三個頭像代號，也沒有真人叫這三個名字（'
             || (select count(*) from public.members where not is_bot and (avatar_bear in ('coach', 'chef', 'merchant') or display_name in ('教練熊', '廚師熊', '商人熊'))) || ' 位）'
    union all
    select 4,
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'add_friendly_bots_tx') = 1
             and pg_get_functiondef('public.add_friendly_bots_tx(uuid, integer)'::regprocedure) ~ 'array_position\(array\[''coach'', ''chef'', ''merchant''\]'
             and pg_get_functiondef('public.add_friendly_bots_tx(uuid, integer)'::regprocedure) !~ '電腦一號',
           '④ add_friendly_bots_tx：一個版本、照頭像代號排順序、不再認舊名字'
    union all
    select 5,
           has_function_privilege('authenticated', 'public.add_friendly_bots_tx(uuid, integer)'::regprocedure, 'execute')
             and not has_function_privilege('anon', 'public.add_friendly_bots_tx(uuid, integer)'::regprocedure, 'execute'),
           '⑤ 授權沒掉：登入的人叫得動、沒登入的叫不動'
    union all
    -- ⑥ 三支列會員的函式都排除電腦；各只有一個版本
    select 6,
           (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
               and p.proname in ('pos_search_members_tx', 'admin_find_members_tx', 'list_members_tx')
               and pg_get_functiondef(p.oid) ~ 'and not (m\.)?is_bot') = 3
             and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
                    and p.proname in ('pos_search_members_tx', 'admin_find_members_tx', 'list_members_tx')) = 3,
           '⑥ POS 會員搜尋、後台會員查詢、會員清單都排除電腦（各一個版本）'
    union all
    -- ⑦ 三支的授權跟改之前一樣：POS 與後台那兩支登入的人叫得動，會員清單那支前端叫不到
    select 7,
           has_function_privilege('authenticated', 'public.pos_search_members_tx(uuid, text)'::regprocedure, 'execute')
             and has_function_privilege('authenticated', 'public.admin_find_members_tx(text)'::regprocedure, 'execute')
             and not has_function_privilege('authenticated', 'public.list_members_tx(uuid, integer)'::regprocedure, 'execute')
             and not has_function_privilege('anon', 'public.pos_search_members_tx(uuid, text)'::regprocedure, 'execute')
             and not has_function_privilege('anon', 'public.admin_find_members_tx(text)'::regprocedure, 'execute'),
           '⑦ 三支的授權沒變（POS 搜尋與後台查詢登入的人叫得動；會員清單前端叫不到；沒登入的都叫不到）'
    union all
    -- ⑧ 真的跑一次會員清單：電腦一個都不在裡面；正對照：真人還列得出來（不是整支變成什麼都不回）
    select 8,
           not exists (select 1 from public.orgs o, lateral public.list_members_tx(o.id, 200) l join public.members m on m.id = l.member_id where m.is_bot)
             and exists (select 1 from public.orgs o, lateral public.list_members_tx(o.id, 200) l),
           '⑧ 會員清單實際跑一次：列出 ' || (select count(*) from public.orgs o, lateral public.list_members_tx(o.id, 200) l) || ' 位，其中電腦 '
             || (select count(*) from public.orgs o, lateral public.list_members_tx(o.id, 200) l join public.members m on m.id = l.member_id where m.is_bot) || ' 位'
    union all
    -- ⑨ 報表檢視表的欄位跟 members 一樣多（沒有漏欄位），而且前端還是讀不到
    select 9,
           not exists (select 1 from information_schema.columns t
                        where t.table_schema = 'public' and t.table_name = 'members'
                          and not exists (select 1 from information_schema.columns v
                                           where v.table_schema = 'public' and v.table_name = 'v_real_members' and v.column_name = t.column_name))
             and not has_table_privilege('anon', 'public.v_real_members'::regclass, 'select')
             and not has_table_privilege('authenticated', 'public.v_real_members'::regclass, 'select'),
           '⑨ v_real_members 沒有漏掉 members 的欄位（漏 '
             || (select count(*) from information_schema.columns t
                  where t.table_schema = 'public' and t.table_name = 'members'
                    and not exists (select 1 from information_schema.columns v
                                     where v.table_schema = 'public' and v.table_name = 'v_real_members' and v.column_name = t.column_name))
             || ' 欄），前端還是讀不到'
  ) c;
