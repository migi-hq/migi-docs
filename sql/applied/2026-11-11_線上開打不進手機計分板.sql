-- 線上開打的牌局不進手機計分板（2026-11-11 使用者：「好友線上練習賽 手機計分版應該要顯示 正在線上對戰中」）
-- 在 Supabase SQL Editor 執行。
--
-- 出了什麼事
--   好友練習賽的線上開打，牌是在會員 App 裡打的、電腦算台。但它在資料上也是一場開著的牌局，
--   而手機計分板是「綁人不綁桌」：這個人坐在哪一場就把那一場的計分板拿出來
--   ⇒ 線上打到一半打開手機計分板，會看到同一場的計分板，還按得了自摸、放槍 —— 兩邊會寫同一場的分數。
--
-- 做了什麼
--   ① 🆕 _is_online_session(場次)：這一場是不是線上開打。全系統只有這一份定義（前端叫不到）
--   ② _tbl_device：手機找「這個人現在坐在哪一場」時，跳過線上開打的場次 ⇒ 計分板當成沒有牌局。
--      計分板每一支函式（讀狀態、送出一局、確認、回溯…）都先經過這一支認裝置，所以**改這一處就全部擋住**，
--      不用一支一支加。本體照線上版，只多一個條件。
--   ③ _tbl_state_for_device：沒有牌局時多回一個 online_playing（這支手機的主人正在線上開打）
--      ⇒ 計分板畫面才分得出「真的沒有牌局」與「正在線上對戰中」。只換一行，其餘一個字沒動。
--
-- 先後順序：這份先跑就已經擋住了（舊版計分板會顯示「目前沒有在計分」），計分板更新後才會寫「正在線上對戰中」。
-- 可以重跑。

-- ① 這一場是不是線上開打
create or replace function public._is_online_session(p_session uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from friendly_games fg where fg.session_id = p_session and fg.play_mode = 'online');
$$;
revoke execute on function public._is_online_session(uuid) from public;
revoke execute on function public._is_online_session(uuid) from anon, authenticated;

-- ② 認裝置：手機不帶到線上開打的場次（本體照線上版 pg_get_functiondef，只多標了 🆕 的那一行）
create or replace function public._tbl_device(p_token text)
returns table_devices language plpgsql security definer set search_path = public as $function$
declare d public.table_devices; v_table uuid; v_store uuid;
begin
  if p_token is null or length(p_token) < 32 then
    raise exception '這台平板還沒配對，請找店員' using errcode = '28000';
  end if;
  select * into d from table_devices
   where token_hash = public._tbl_hash(p_token) and is_active;
  if not found then
    raise exception '這台平板還沒配對或已停用，請找店員' using errcode = '28000';
  end if;
  /* 最後上線時間：15 秒寫一次（平板每 5 秒拿一次狀態）。
     「斷線接手」看它：45 秒沒更新就算斷線（_tbl_device_stale）。原本一分鐘一次，判斷不了 45 秒 */
  if d.last_seen_at is null or d.last_seen_at < now() - interval '15 seconds' then
    update table_devices set last_seen_at = now() where id = d.id;
  end if;

  if d.kind = 'phone' then
    /* 平板發的配對碼只限那一場：那一場收了，這支手機就不能再用 */
    if d.bound_session_id is not null and not exists (
         select 1 from table_sessions where id = d.bound_session_id and status = 'open' and deleted_at is null) then
      raise exception '這一場已經結束，手機計分已失效' using errcode = '28000';
    end if;
    /* 這位會員現在坐在哪一桌（沒有就是 null ⇒ 狀態回「目前沒有牌局」） */
    select ts.table_id, ts.store_id into v_table, v_store
      from session_players sp join table_sessions ts on ts.id = sp.session_id
     where sp.member_id = d.member_id and sp.left_at is null
       and ts.status = 'open' and ts.deleted_at is null
       and (d.bound_session_id is null or ts.id = d.bound_session_id)
       and not public._is_online_session(ts.id)   -- 🆕 2026-11-11：線上開打的那一場在會員 App 裡打，不進計分板
     order by ts.created_at desc limit 1;
    /* 後台照門市列手機（2026-10-13）：記下這支手機最後在哪間店用 —— 桌不寫回，桌每一場都不同 */
    if v_store is not null and d.store_id is distinct from v_store then
      update table_devices set store_id = v_store where id = d.id;
    end if;
    d.table_id := v_table;   -- 只改回傳值，不寫回資料表
    d.store_id := v_store;
  elsif d.bound_session_id is not null then
    /* 借來的平板（2026-10-30）：用換機代碼接了別桌的位置 ⇒ 那一場還開著、而且它還坐在那個位置上，就算那一桌。
       否則（收桌、讓出位置、被別人接手）清掉綁定，回到它原本那一桌 */
    select ts.table_id into v_table
      from session_players sp join table_sessions ts on ts.id = sp.session_id
     where ts.id = d.bound_session_id and ts.status = 'open' and ts.deleted_at is null
       and sp.device_id = d.id and sp.left_at is null
     limit 1;
    if v_table is not null then
      d.table_id := v_table;   -- 只改回傳值；table_devices.table_id 永遠是它原本那一桌
    else
      update table_devices set bound_session_id = null where id = d.id;
      d.bound_session_id := null;
    end if;
  end if;
  return d;
end $function$;

-- ③ 狀態：沒有牌局時多回 online_playing。只換一行；找不到那一行（或不只一處）就整份退回，不留半套
do $do$
declare
  v_def text;
  v_old constant text := $q$'session', null,$q$;
  v_add constant text := $q$
      'online_playing', d.kind = 'phone' and exists (
          select 1 from session_players sp join table_sessions ts on ts.id = sp.session_id
           where sp.member_id = d.member_id and sp.left_at is null and ts.status = 'open' and ts.deleted_at is null
             and public._is_online_session(ts.id)),   -- 🆕 2026-11-11：這支手機的主人正在線上開打（牌在會員 App 裡打）$q$;
begin
  v_def := pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure);
  if position('online_playing' in v_def) > 0 then return; end if;   -- 已經改過，重跑時不再插一次
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception '在 _tbl_state_for_device 裡找不到要換的那一行（或不只一處）—— 整份退回，線上沒有任何改動';
  end if;
  execute replace(v_def, v_old, v_old || v_add);
end $do$;

-- ─── 驗證（單一 SELECT）───
select string_agg(case when ok then '✅ ' else '🔴 ' end || item, E'\n' order by ord) as "驗證（應該 6 格全綠）"
  from (
    select 1 as ord,
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_is_online_session') = 1
             and not has_function_privilege('anon', 'public._is_online_session(uuid)'::regprocedure, 'execute')
             and not has_function_privilege('authenticated', 'public._is_online_session(uuid)'::regprocedure, 'execute') as ok,
           '① _is_online_session：一個版本、前端叫不到' as item
    union all
    select 2,
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_tbl_device') = 1
             and pg_get_functiondef('public._tbl_device(text)'::regprocedure) ~ 'and not public\._is_online_session\(ts\.id\)'
             and not has_function_privilege('anon', 'public._tbl_device(text)'::regprocedure, 'execute')
             and not has_function_privilege('authenticated', 'public._tbl_device(text)'::regprocedure, 'execute'),
           '② _tbl_device：一個版本、會跳過線上開打的場次、授權沒變（前端叫不到）'
    union all
    select 3,
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_tbl_state_for_device') = 1
             and (select count(*) from regexp_matches(pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure), '''online_playing'',', 'g')) = 1
             and not has_function_privilege('anon', 'public._tbl_state_for_device(table_devices)'::regprocedure, 'execute')
             and not has_function_privilege('authenticated', 'public._tbl_state_for_device(table_devices)'::regprocedure, 'execute'),
           '③ _tbl_state_for_device：一個版本、多回 online_playing（只有一處）、授權沒變'
    union all
    -- ④ 正對照：每一場線上開打、已經成桌的，都認得出來
    select 4,
           (select count(*) from public.friendly_games fg where fg.play_mode = 'online' and fg.session_id is not null and public._is_online_session(fg.session_id))
             = (select count(*) from public.friendly_games fg where fg.play_mode = 'online' and fg.session_id is not null),
           '④ 線上開打而且成桌過的 ' || (select count(*) from public.friendly_games fg where fg.play_mode = 'online' and fg.session_id is not null) || ' 場，全部認得出來'
    union all
    -- ⑤ 負對照：店裡的牌局、「我有麻將桌」的好友練習賽，一場都不可以被當成線上開打（那樣手機計分板會進不去）
    select 5,
           not exists (select 1 from public.table_sessions ts where public._is_online_session(ts.id)
                          and (ts.mode <> 'friendly' or exists (select 1 from public.friendly_games fg where fg.session_id = ts.id and fg.play_mode <> 'online'))),
           '⑤ 其他 ' || (select count(*) from public.table_sessions ts where not public._is_online_session(ts.id)) || ' 場牌局（店裡的、我有麻將桌的）沒有一場被誤認成線上開打'
    union all
    -- ⑥ 現在正在線上開打的人，他的手機計分板拿到的是「沒有牌局 ＋ 正在線上對戰」（現在沒有人在打的話這一格沒有樣本）
    select 6,
           (select count(*) filter (where (st -> 'session') = 'null'::jsonb and (st ->> 'online_playing')::boolean) = count(*)
              from (select public._tbl_state_for_device(td) as st
                      from public.table_devices td
                     where td.kind = 'phone' and td.is_active
                       and exists (select 1 from public.session_players sp join public.table_sessions ts on ts.id = sp.session_id
                                    where sp.member_id = td.member_id and sp.left_at is null and ts.status = 'open' and ts.deleted_at is null
                                      and public._is_online_session(ts.id))) x),
           '⑥ 現在正在線上開打、而且有配對手機的 '
             || (select count(*) from public.table_devices td
                  where td.kind = 'phone' and td.is_active
                    and exists (select 1 from public.session_players sp join public.table_sessions ts on ts.id = sp.session_id
                                 where sp.member_id = td.member_id and sp.left_at is null and ts.status = 'open' and ts.deleted_at is null
                                   and public._is_online_session(ts.id)))
             || ' 支手機：計分板都回「沒有牌局、正在線上對戰」（0 支 ＝ 現在沒有人在打，這一格沒有樣本）'
  ) c;
