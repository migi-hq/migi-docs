-- 加電腦對手：指定加哪一隻（2026-11-11 使用者：「邀牌咖加入的抽屜 有一區是放電腦對手 直接放頭像+名字」）
-- 在 Supabase SQL Editor 執行。
--
-- 為什麼要多一支
--   抽屜那一區改成三隻熊的頭像＋名字，點哪一隻就加哪一隻。
--   現在那支 add_friendly_bots_tx(場次, 幾位) 只收「幾位」，照教練熊 → 廚師熊 → 商人熊的順序加
--   ⇒ 點商人熊會加到教練熊。所以多一支收「哪一隻」的。
--
-- 做了什麼
--   🆕 add_friendly_bot_tx(p_game, p_bear)：p_bear 是頭像代號（coach 教練熊／chef 廚師熊／merchant 商人熊）。
--      擋的東西跟舊那支一樣（要登入、要在這一場、要是開局的人、還在等人、只有線上開打、要有空位），
--      多兩道：代號不認得、那一隻已經在這一場。湊滿四位直接成桌。
--      身分只認 current_member_id()；開給登入的人（authenticated），沒登入的叫不到。
--   舊的 add_friendly_bots_tx **先留著**：正式站現在的 App 還在叫它，新版 App 上線後才沒有人叫（那時再刪）。
--
-- 先後順序：這份先跑，App 再更新（新版 App 叫的是新的這一支）。

create or replace function public.add_friendly_bot_tx(p_game uuid, p_bear text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid; g friendly_games; v_n int; v_bot uuid; v_sid uuid;
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
  if p_bear is null or p_bear not in ('coach', 'chef', 'merchant') then raise exception '沒有這位電腦對手'; end if;
  select count(*) into v_n from friendly_game_players where game_id = p_game and left_at is null;
  if v_n >= 4 then raise exception '已經沒有空位了'; end if;

  select m.id into v_bot from members m
   where m.org_id = g.org_id and m.is_bot and m.deleted_at is null and m.avatar_bear = p_bear
   order by m.created_at, m.id limit 1;
  if v_bot is null then raise exception '電腦對手的設定不存在（請找總部）'; end if;
  if exists (select 1 from friendly_game_players where game_id = p_game and member_id = v_bot and left_at is null) then
    raise exception '這位電腦對手已經在這一場了';
  end if;

  insert into friendly_game_players (org_id, game_id, member_id, join_source) values (g.org_id, p_game, v_bot, 'bot');
  if v_n + 1 = 4 then v_sid := public._friendly_start(p_game); end if;
  return jsonb_build_object('ok', true, 'bear', p_bear, 'started', v_sid is not null);
end $$;

-- 新建的函式預設誰都叫不到（2026-09-29 起預設全關）；明確開給登入的人。兩行 revoke 是保險：預設哪天被改回去也不會變成公開
revoke execute on function public.add_friendly_bot_tx(uuid, text) from public;
revoke execute on function public.add_friendly_bot_tx(uuid, text) from anon;
grant  execute on function public.add_friendly_bot_tx(uuid, text) to authenticated;

-- ─── 驗證（單一 SELECT）───
select string_agg(case when ok then '✅ ' else '🔴 ' end || item, E'\n' order by ord) as "驗證（應該 5 格全綠）"
  from (
    select 1 as ord,
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'add_friendly_bot_tx') = 1
             and (select prosecdef from pg_proc where oid = 'public.add_friendly_bot_tx(uuid, text)'::regprocedure) as ok,
           '① add_friendly_bot_tx：一個版本' as item
    union all
    select 2,
           has_function_privilege('authenticated', 'public.add_friendly_bot_tx(uuid, text)'::regprocedure, 'execute')
             and not has_function_privilege('anon', 'public.add_friendly_bot_tx(uuid, text)'::regprocedure, 'execute')
             and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                              where p.oid = 'public.add_friendly_bot_tx(uuid, text)'::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
           '② 授權：登入的人叫得動、沒登入的叫不動、沒有開給所有人'
    union all
    select 3,
           pg_get_functiondef('public.add_friendly_bot_tx(uuid, text)'::regprocedure) ~ 'v_me := public\.current_member_id\(\)'
             and pg_get_function_identity_arguments('public.add_friendly_bot_tx(uuid, text)'::regprocedure) !~ 'member',
           '③ 身分從登入取得，參數裡沒有「我是誰」'
    union all
    select 4,
           (select count(*) from public.members where is_bot and deleted_at is null and avatar_bear in ('coach', 'chef', 'merchant'))
             = (select 3 * count(*) from public.orgs),
           '④ 三個代號在每個機構都找得到對應的電腦（' || (select count(*) from public.members where is_bot and deleted_at is null and avatar_bear in ('coach', 'chef', 'merchant')) || ' 個）'
    union all
    select 5,
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'add_friendly_bots_tx') = 1
             and has_function_privilege('authenticated', 'public.add_friendly_bots_tx(uuid, integer)'::regprocedure, 'execute'),
           '⑤ 舊的那支（收幾位）還在、還叫得動 —— 正式站現在的 App 還在用它'
  ) c;
