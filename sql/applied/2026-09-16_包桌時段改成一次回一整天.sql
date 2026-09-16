/* 包桌時段：一次回一整天的半小時格，而且不講剩幾桌
   2026-09-16

   ── 為什麼 ─────────────────────────────────────────
   「可預約的時段」從「填一個時間」改成「**一整天的半小時格，點一格**」
   （使用者 2026-09-16 定案，五案預覽最後那一格）。

   而同一天定了第二件事：**不透露容量**。每一格只有兩種狀態，
   「可約」與「已滿」—— 沒有「剩 N 桌」。

   🔴 那兩件事都要後端配合，而且理由不一樣：
   · 一整天  → 現在 `booking_capacity_tx` 一次只回**一個時段**，
               要畫 30 格就是打 30 次 RPC
   · 不講桌數 → **畫面不顯示它不構成不回傳它的理由**。
               前端拿得到的東西就是已經給出去的東西，
               而那等於公開每一間店每半小時的空桌率
               （打開 devtools 就看得到）。

   ── 這一份做什麼 ───────────────────────────────────
   ① `_booking_slots`      內部：產生一整天的格子（照 `_booking_capacity` 的形狀）
   ② `booking_slots_tx`    對外：身分與參數檢查 ＋ 呼叫 ①
   ③ `create_booking_tx`   約滿時的話術不再講數字，也不再回 `capacity`

   ⚠ **刻意不動 `booking_capacity_tx`**（它還回著 total/booked/free）。
     現行畫面正在讀那三個值（`buddies.jsx` 的 `noTables` / `notEnough`
     與「這個時段 N 桌中還有 M 桌」那一行），現在收掉會當場壞掉。
     ⇒ expand → migrate → contract：前端切到 `booking_slots_tx` 並部署過之後，
       **另一份**再把那三個值收掉。那一份不做，這件事就只做了一半。

   ── 沒有發明的規則 ─────────────────────────────────
   🔴 「開打時間 ＋ 時長要在打烊前打得完」**這條規則今天不存在**，
     `create_booking_tx` 也沒有檢查（24 小時暢打本來就一定跨過打烊）。
     所以這一支**也不加** —— 加了就是兩份定義，而且是前端擋、後端不擋的那種。
     要加請兩支一起加，並先想清楚 24 小時那一格怎麼辦。

   ⚠ 時長一律沿用既有的 **2 / 5 / 24**，不在這裡開第四種。

   ── 效能 ───────────────────────────────────────────
   一天最多 48 格，每格呼叫一次 `_booking_capacity`（掃 `bookings`）。
   今天 `bookings` 筆數是個位數，完全不是問題。
   真的變慢時的正解是**一次聚合算完**，不是減少格數。 */

-- ① ────────────────────────────────────────────────
/* 一整天的半小時格。**照 `_booking_capacity` 的形狀**：SQL、STABLE、
   不檢查身分 —— 身分是外層那一支的工作。
   🎯 這樣切的好處不只是分層：`_booking_capacity` 那一支就是因為
     切開了，驗證段才叫得動它（SQL Editor 是 postgres，
     `current_member_id()` 在那裡永遠是 null）。 */
create or replace function public._booking_slots(
  p_store_id uuid,
  p_day      date,
  p_hours    int
) returns jsonb
language sql
stable
as $$
  with s as (
    select open_time, close_time
      from public.stores
     where id = p_store_id and deleted_at is null
  ),
  win as (
    /* 跨午夜用日常寫法：11:00–02:00 的 02:00 屬於**隔天**。
       ⚠ `close = open` 視為 24 小時營業（今天沒有這種店，但寫法要撐得住）。 */
    select ((p_day + s.open_time) at time zone 'Asia/Taipei') as t0,
           ((case when s.close_time > s.open_time
                  then p_day + s.close_time
                  else (p_day + 1) + s.close_time end) at time zone 'Asia/Taipei') as t1
      from s
     where s.open_time is not null and s.close_time is not null
  ),
  g as (
    /* 最後一格是**打烊前最後一個半小時**。
       `t1 - 30 分鐘` 讓 02:00 打烊的店最後一格是 01:30，不是 02:00。 */
    select generate_series(w.t0, w.t1 - interval '30 minutes', interval '30 minutes') as at
      from win w
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'at',    g.at,
        'label', to_char(g.at at time zone 'Asia/Taipei', 'HH24:MI'),
        /* 🔴 只有布林，**沒有任何數字**。
           後端當然要算桌數才知道滿沒滿，但算完就不要把數字送出去。 */
        'open',  (public._booking_capacity(p_store_id, g.at, p_hours) ->> 'free')::int >= 1
      ) order by g.at
    ),
    '[]'::jsonb)
  from g
  /* 兩道時間牆與 `create_booking_tx` **逐字相同**。
     🔴 太近／太遠的格子**整個不回**，不是回 `open = false` ——
       後者會讓客人讀成「那個時段滿了」，而那是一句錯的話
       （同「已收桌但沒名次」不可以說成「未成桌」）。
       時間過了本來就不在了，不需要解釋。 */
  where g.at >= now() + interval '30 minutes'
    and g.at <= now() + interval '90 days';
$$;

comment on function public._booking_slots(uuid, date, int) is
  '一整天的包桌半小時格。回 [{at, label, open}]，刻意不回剩餘桌數。內部用，身分檢查在 booking_slots_tx。';

-- ② ────────────────────────────────────────────────
/* 對外那一支。參數檢查逐字照抄 `booking_capacity_tx` ——
   兩支問的是同一件事的兩種粒度，錯誤訊息沒有理由長得不一樣。 */
create or replace function public.booking_slots_tx(
  p_store_id uuid,
  p_day      date,
  p_hours    int
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_open  time;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5, 24) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2、5 或 24 小時');
  end if;
  if p_day is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_day', 'message', '請選一個日期');
  end if;

  select s.open_time into v_open
    from public.stores s
   where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* ⚠ 「沒設營業時間」與「今天沒有時段了」是**兩件事**，
     回同一個空陣列的話，畫面只能對兩者說同一句話。 */
  if v_open is null then
    return jsonb_build_object('ok', false, 'reason', 'no_hours',
                              'message', '這間門市還沒有開放預約，請直接跟門市聯絡');
  end if;

  perform public._booking_expire(p_store_id);

  return jsonb_build_object(
    'ok',    true,
    'day',   p_day,
    'hours', p_hours,
    'slots', public._booking_slots(p_store_id, p_day, p_hours));
end $$;

comment on function public.booking_slots_tx(uuid, date, int) is
  '一整天的包桌可預約時段。回 {ok, day, hours, slots:[{at,label,open}]}。只講可約/已滿，不回剩餘桌數。';

/* 授權照抄同一族的三支（`booking_capacity_tx` / `create_booking_tx` /
   `list_my_bookings_tx`）：DEFINER ＋ 只給 authenticated。
   🔴 兩個方向都要收（硬規則 2.6／2.6b）：
     · 新建的函式吃 default privileges ⇒ anon 是**明確授權**，要 `from anon`
     · 舊的管理函式是 PUBLIC 繼承 ⇒ 要 `from public`
     收錯方向的症狀跟沒收一模一樣。 */
revoke execute on function public._booking_slots(uuid, date, int) from public;
revoke execute on function public._booking_slots(uuid, date, int) from anon, authenticated;
revoke execute on function public.booking_slots_tx(uuid, date, int) from public;
revoke execute on function public.booking_slots_tx(uuid, date, int) from anon;
grant  execute on function public.booking_slots_tx(uuid, date, int) to authenticated;

-- ③ ────────────────────────────────────────────────
/* 約滿時不要講數字。
   ⚠ 簽名沒變 ⇒ `CREATE OR REPLACE`，不用 DROP，GRANT 不會掉（硬規則 2）。
   🔴 原本的話術是「這個時段只剩 N 桌」，而且回傳還附了整個 `capacity`
     物件（total/booked/free）。
     那句話原本的理由寫在註解裡：「話術要給數字，不要只說『滿了』——
     『還剩 1 桌』他可能就改訂 1 桌」。
     ⇒ **那個理由在現在的流程裡不成立**：會員 App 一次只訂一桌
       （`TeamBookingSheet` 的 `tables = 1`），所以走到這一行時
       `free` 必然是 0，那句話會印成「這個時段只剩 0 桌」。
   📌 日後真的開放一次訂多桌時，正確的做法是**讓他改桌數**，
     不是把剩餘桌數印出來。 */
create or replace function public.create_booking_tx(
  p_store_id uuid, p_play_at timestamptz, p_hours integer,
  p_table_count integer default 1, p_team_id uuid default null,
  p_party_size integer default null, p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_cap  jsonb;
  v_id   uuid;
  v_name text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5, 24) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2、5 或 24 小時');
  end if;
  if coalesce(p_table_count, 1) < 1 or p_table_count > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_count', 'message', '桌數請填 1 到 10');
  end if;

  /* 🔴 兩道時間牆，兩個不同的理由：
     · 太近 —— 店員來不及看到那筆預約，客人到了櫃檯還是要現場處理，
       而畫面已經跟他說「預約成功」了。**那是一個做不到的承諾。**
     · 太遠 —— 三個月後的事誰都說不準，而它會一路佔著容量。 */
  if p_play_at is null or p_play_at < now() + interval '30 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
                              'message', '請至少提前 30 分鐘預約，現在要用請直接到櫃檯');
  end if;
  if p_play_at > now() + interval '90 days' then
    return jsonb_build_object('ok', false, 'reason', 'too_far', 'message', '最多只能預約 90 天內');
  end if;

  select s.name into v_name from public.stores s
   where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null;
  if v_name is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* 掛團的話，**我必須在那個團裡** —— 不然任何人都能用別人的團名訂位，
     而帳算在那個團頭上。 */
  if p_team_id is not null and not exists (
       select 1 from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
       where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在那個牌咖團裡');
  end if;

  perform public._booking_expire(p_store_id);

  /* 🔴 同一組人同一個時段不要重複訂。
     判準是「同一個團」，沒有團就退回「同一個人」——
     而那正是 `team_id` 可空所帶來的兩種身分。 */
  if exists (
       select 1 from public.bookings k
        where k.store_id = p_store_id and k.status = 'booked'
          and (case when p_team_id is not null then k.team_id = p_team_id
                    else k.team_id is null and k.member_id = v_me end)
          and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
          and k.play_at < p_play_at + make_interval(hours => p_hours)) then
    return jsonb_build_object('ok', false, 'reason', 'already_booked',
                              'message', '這個時段你已經有一筆預約了');
  end if;

  v_cap := public._booking_capacity(p_store_id, p_play_at, p_hours);
  if (v_cap->>'free')::int < p_table_count then
    /* 🔴 2026-09-16：不講剩幾桌，也不回 `capacity`。
       ⚠ 這一句與畫面上那一行**逐字相同**，是刻意的：
         後端說一句、前端自己再寫一句，那兩句一定會漂。 */
    return jsonb_build_object('ok', false, 'reason', 'no_capacity',
                              'message', '這個時段已經約滿了，換個時間試試');
  end if;

  insert into public.bookings (org_id, store_id, team_id, member_id,
                               play_at, planned_hours, table_count, party_size, note)
  values (v_org, p_store_id, p_team_id, v_me,
          p_play_at, p_hours, coalesce(p_table_count, 1), p_party_size,
          nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'booking_id', v_id, 'store_name', v_name,
                            'message', '已預約 ' || v_name);
end $$;

-- ── 驗證（硬規則 1.8：這一份要留下 DDL ⇒ 一個字都不准 raise）─────
do $$
declare
  v_msg   text := '';
  v_store uuid;
  v_n     int;
  v_slots jsonb;
  v_txt   text;
begin
  -- ① 版本數與屬性
  select count(*) into v_n from pg_proc
   where pronamespace='public'::regnamespace and proname='booking_slots_tx';
  v_msg := v_msg || coalesce(
    (select case when v_n = 1 and p.prosecdef
                      and array_to_string(p.proconfig,',') like '%search_path=public%'
                 then '✅ ① 版本數 1 · DEFINER · search_path 有設'
                 else '🔴 ① 版本數 ' || v_n || ' · secdef=' || p.prosecdef
                      || ' · config=' || coalesce(array_to_string(p.proconfig,','),'(無)') end
       from pg_proc p
      where p.pronamespace='public'::regnamespace and p.proname='booking_slots_tx' limit 1),
    '🔴 ① 函式不存在');

  -- ② 授權：兩個方向都要對（硬規則 2.6／2.6b）
  v_msg := v_msg || E'\n' || coalesce(
    (select case when authed and not anon_x and not pub
                 then '✅ ② 授權 authenticated ✓ · anon ✗ · PUBLIC ✗'
                 else '🔴 ② authenticated=' || authed || ' anon=' || anon_x || ' PUBLIC=' || pub end
       from (
         select exists (select 1 from aclexplode(p.proacl) a
                         where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE') as authed,
                exists (select 1 from aclexplode(p.proacl) a
                         where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') as anon_x,
                (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                         where a.grantee=0 and a.privilege_type='EXECUTE')) as pub
           from pg_proc p
          where p.pronamespace='public'::regnamespace and p.proname='booking_slots_tx') q),
    '🔴 ② 查不到授權');

  -- ③ 真的跑一次（走內部那一支，SQL Editor 沒有會員身分）
  select id into v_store from public.stores where code='S01' and deleted_at is null;
  v_slots := public._booking_slots(v_store, (now() at time zone 'Asia/Taipei')::date + 1, 2);
  v_msg := v_msg || E'\n' || coalesce(
    '✅ ③ 高雄自由店 明天 打 2 小時 → ' || jsonb_array_length(v_slots) || ' 格'
    || '（第一格 ' || (v_slots->0->>'label') || '、最後一格 '
    || (v_slots->(jsonb_array_length(v_slots)-1)->>'label') || '）',
    '🔴 ③ 算不出時段');

  -- ④ 🔴 正對照：回傳裡不可以有任何容量數字
  select string_agg(distinct k, ', ') into v_txt
    from jsonb_array_elements(v_slots) e, jsonb_object_keys(e) k;
  v_msg := v_msg || E'\n' || coalesce(
    case when v_txt = 'at, label, open'
         then '✅ ④ 每一格只有 at / label / open，沒有桌數'
         else '🔴 ④ 多了不該有的鍵：' || v_txt end,
    '⚪ ④ 沒有格子可以檢查');

  -- ⑤ 負對照：不營業的日期與沒有桌的門市
  select id into v_store from public.stores where code='S03' and deleted_at is null;
  v_msg := v_msg || E'\n' || coalesce(
    (select case when count(*) filter (where (e->>'open')::boolean) = 0
                 then '✅ ⑤ 0 桌的門市（MAYU 苓雅館）每一格都是已滿'
                 else '🔴 ⑤ 0 桌的門市竟然有可約的格子' end
       from jsonb_array_elements(
              public._booking_slots(v_store, (now() at time zone 'Asia/Taipei')::date + 1, 2)) e),
    '⚪ ⑤ 那間店算不出格子');

  -- ⑥ 時間牆：今天早上的格子不該出現
  select id into v_store from public.stores where code='S01' and deleted_at is null;
  select count(*) into v_n
    from jsonb_array_elements(
           public._booking_slots(v_store, (now() at time zone 'Asia/Taipei')::date, 2)) e
   where (e->>'at')::timestamptz < now() + interval '30 minutes';
  v_msg := v_msg || E'\n' ||
    case when v_n = 0 then '✅ ⑥ 太近的格子一個都沒有回'
         else '🔴 ⑥ 回了 ' || v_n || ' 個已經來不及的格子' end;

  -- ⑦ create_booking_tx 的話術：逐行印出來讓人判讀（硬規則 3.5）
  v_msg := v_msg || E'\n' || coalesce(
    (select '📋 ⑦ 約滿時的話術 → ' ||
            substring(pg_get_functiondef(p.oid) from 'no_capacity''[^)]*?''message'', ''([^'']*)''')
       from pg_proc p
      where p.pronamespace='public'::regnamespace and p.proname='create_booking_tx' limit 1),
    '⚪ ⑦ 抓不到那一句');

  -- ⑧ 還沒收的那一支（下一份要做的 contract）
  v_msg := v_msg || E'\n' || coalesce(
    (select case when pg_get_functiondef(p.oid) like '%_booking_capacity%'
                 then '⏳ ⑧ booking_capacity_tx 仍然回著 total/booked/free —— '
                      || '前端切過去並部署之後，另一份再收（expand → migrate → contract）'
                 else '✅ ⑧ booking_capacity_tx 已經不回桌數了' end
       from pg_proc p
      where p.pronamespace='public'::regnamespace and p.proname='booking_capacity_tx' limit 1),
    '⚪ ⑧ 查不到那一支');

  perform set_config('migi.booking_slots', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.booking_slots', true), ''), '🔴 沒有訊息') as "驗證";
