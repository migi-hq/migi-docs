/* ============================================================
   後台場次查詢（待辦 42 · 2026-09-08）

   ── 為什麼需要 ──────────────────────────────────────────
   今天要回答「**9/3 A3 那桌是誰在打**」**只能開資料庫**：

   | 誰 | 現在有什麼 | 缺什麼 |
   |---|---|---|
   | 客人 | 成績頁對局紀錄，最近 20 場 | 沒有日期篩選、沒有搜尋 |
   | 店員 POS | 配桌列表「已完成」，最多 100 筆 | 那是**配桌房**視角，不是「某天某桌」 |
   | 總部 | 商品、店員兩頁 | **完全沒有場次查詢** |

   🔴 第三種是真的缺口，而且**一定會發生**：客訴、遺失物、
     「那天有人多付了」。

   ── 做在 migi-admin 不是 POS（CLAUDE.md 已拍板的分工）────
   · 前場與後台是兩套 App —— POS 是收銀機，報表與查詢屬後台（同待辦 18）
   · 後台**不輪詢** ⇒ 可以放真正的游標分頁，
     那正是 `pos_list_queues_tx` 留了 `p_before` 卻沒人用的原因

   ── 🔴 這是今天最敏感的一頁 ────────────────────────────
   它看得到**所有會員的消費與同桌關係**。所以：
   · 帶 **`can('ops.read')`**（CLAUDE.md 待辦 42 明寫）
   · **不回傳 `member_id`** —— 同 2026-09-04 排行榜那個決定：
     回 id 等於公開發送一批會員 uuid，而 `get_wallet_tx` 今天仍是
     anon ＋ 前端送 id（待辦 14）⇒ 拿到 id 就能看別人的餘額。
     ⚠ 這一頁**不需要** id：它回答的是「那桌是誰在打」，
       而人名 ＋ 座位 ＋ 名次就足夠。
   · **org 不由呼叫端宣告** —— `current_org_id()`。

   ── ⚠ 搜尋條件用兩個獨立欄位，不要一個萬用搜尋框 ────────
   `p_table_q`（桌號）與 `p_member_q`（暱稱或手機）**分開**。
   合成一個「智慧搜尋」就是一欄兩用 —— 而使用者打「A3」時，
   系統不該去猜他是在找桌號還是找名字裡有 A3 的人。

   ── ⚠ 時間軸用 `coalesce(activated_at, started_at)` ──────
   `started_at` 是**開桌**（店員按下去），`activated_at` 是**真的開打**。
   客訴問的是「那天幾點在打」⇒ 以開打為準，沒有才退回開桌。
   📌 同會員 App 段位走勢圖用 `endedAt || settledAt` 的理由。
   ============================================================ */

create or replace function public.admin_search_sessions_tx(
  p_from      timestamptz default null,   -- null = 今天 00:00（台北）
  p_to        timestamptz default null,   -- null = p_from + 1 天
  p_store     uuid        default null,   -- null = 全部門市
  p_table_q   text        default null,   -- 桌號片段，如 'A3'
  p_member_q  text        default null,   -- 暱稱或手機片段
  p_limit     int         default 50,
  p_before    timestamptz default null    -- 游標：上一頁最後一筆的時間軸
) returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  v_org   uuid;
  v_from  timestamptz;
  v_to    timestamptz;
  v_lim   int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_rows  jsonb;
  v_more  boolean := false;
begin
  if not public.can('ops.read') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限查詢場次');
  end if;
  v_org := public.current_org_id();

  /* 預設「今天」＝台北時區的日曆日（同當日暢打的判準，不要另立一套）。 */
  v_from := coalesce(p_from,
              ((now() at time zone 'Asia/Taipei')::date)::timestamp at time zone 'Asia/Taipei');
  v_to   := coalesce(p_to, v_from + interval '1 day');

  with base as (
    select s.id,
           coalesce(s.activated_at, s.started_at) as at,
           s.ended_at, s.status, s.mode, s.game_type, s.flower,
           s.planned_rounds, s.fee_points,
           t.label as table_label, t.area,
           st.name as store_name,
           coalesce(sl.label, '未設定') as stake_label,
           coalesce(sl.is_hygiene, false) as hygiene
      from table_sessions s
      left join tables t        on t.id  = s.table_id
      left join stores st       on st.id = s.store_id
      left join stake_levels sl on sl.id = s.stake_level_id
     where s.org_id = v_org
       and s.deleted_at is null
       and coalesce(s.activated_at, s.started_at) >= v_from
       and coalesce(s.activated_at, s.started_at) <  v_to
       and (p_store   is null or s.store_id = p_store)
       and (p_table_q is null or t.label ilike '%' || btrim(p_table_q) || '%')
       /* 會員條件：**這一桌有沒有人符合**。⚠ 用 exists 不用 join ——
          join 會讓「兩個人都符合」的桌出現兩次。

          🔴 **手機那一半一定要先確認真的有數字。**
            `regexp_replace('阿明', '\D', '', 'g')` 回**空字串**
            ⇒ `phone like '%%'` ⇒ **每個有手機的會員都符合**
            ⇒ OR 恆真 ⇒ **篩選完全失效，而且畫面看起來像「這個人打過很多場」**。
            ⚠ 這是那種「不會報錯、只會回傳太多」的錯 —— 最難發現的一類。 */
       and (p_member_q is null or exists (
              select 1 from session_players sp
                join members m on m.id = sp.member_id
               where sp.session_id = s.id
                 and (m.display_name ilike '%' || btrim(p_member_q) || '%'
                      or (regexp_replace(p_member_q, '\D', '', 'g') <> ''
                          and m.phone like '%' || regexp_replace(p_member_q, '\D', '', 'g') || '%'))))
       /* 游標：只取比它更早的（時間軸新到舊） */
       and (p_before is null or coalesce(s.activated_at, s.started_at) < p_before)
     order by coalesce(s.activated_at, s.started_at) desc, s.id desc
     limit v_lim + 1                       -- 多撈一筆用來判斷 has_more
  )
  /* 🔴 `has_more` 要從**多撈的那一筆**判斷，而且判斷要發生在**還沒截斷之前**。
     第一版寫成「內層先 `limit v_lim` 再 `count(*) > v_lim`」——
     那個 count 永遠 ≤ v_lim ⇒ **`has_more` 恆為 false，下一頁永遠按不到**，
     而且**不會報錯**（頁面只是看起來「就這些了」）。
     ⇒ 改成 `row_number()` ＋ `filter`：count 數全部（含多撈的那筆），
       但只有前 v_lim 筆進 JSON。 */
  select coalesce(jsonb_agg(x.j order by x.at desc) filter (where x.rn <= v_lim), '[]'::jsonb),
         count(*) > v_lim
    into v_rows, v_more
    from (
      select b.at,
             row_number() over (order by b.at desc, b.id desc) as rn,
             jsonb_build_object(
               'id', b.id,
               'at', b.at,                       -- 開打（沒有就退回開桌）
               'ended_at', b.ended_at,
               'status', b.status,               -- open / completed / voided
               'mode', b.mode,
               'game_type', b.game_type,
               'flower', b.flower,
               'rounds', b.planned_rounds,
               'store', b.store_name,
               'table', b.table_label,
               'area', b.area,
               'stake', b.stake_label,
               'hygiene', b.hygiene,             -- 純娛樂 ⇒ 積分欄要顯示「不計積分」
               'fee_points', b.fee_points,
               /* 🔴 **刻意不回 member_id** —— 見檔頭。人名足夠回答「誰在打」。 */
               'players', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'name', coalesce(m.display_name, '（已刪除）'),
                           'seat', sp.seat,
                           'rank', sp.finish_rank,
                           'charged', sp.charged_points,
                           'waived', sp.fee_waived_amount,
                           'waived_reason', sp.fee_waived_reason,
                           'paid_for_by_other', sp.paid_by is not null,
                           'score', sp.final_score,
                           'left_at', sp.left_at
                         ) order by sp.seat nulls last, sp.joined_at)
                    from session_players sp
                    left join members m on m.id = sp.member_id
                   where sp.session_id = b.id), '[]'::jsonb)
             ) as j
        from base b
    ) x;   -- ⚠ 這裡**不可以再 limit** —— 截斷交給上面的 `filter (rn <= v_lim)`，
           --   否則 count(*) 就數不到多撈的那一筆，has_more 又會恆為 false。

  return jsonb_build_object(
    'ok', true,
    'rows', coalesce(v_rows, '[]'::jsonb),
    'has_more', v_more,
    'from', v_from,
    'to', v_to,
    /* 游標給前端下一頁用 —— 後台不輪詢，所以真的游標分頁是安全的
       （POS 那邊刻意用成長式分頁，因為它每 8 秒重載，見待辦 42 的討論）。 */
    'next_before', case when v_more
      then (select min((e ->> 'at')::timestamptz) from jsonb_array_elements(coalesce(v_rows,'[]'::jsonb)) e)
      end
  );
end $fn$;


/* ── 授權（硬規則 2.6b：兩個方向都要收）──────────────────── */
revoke execute on function public.admin_search_sessions_tx(timestamptz,timestamptz,uuid,text,text,int,timestamptz) from public;
revoke execute on function public.admin_search_sessions_tx(timestamptz,timestamptz,uuid,text,text,int,timestamptz) from anon;
grant  execute on function public.admin_search_sessions_tx(timestamptz,timestamptz,uuid,text,text,int,timestamptz) to authenticated;


/* ============================================================
   驗證（單一 SELECT）
   ⚠ 硬規則 3.55：每一道擋牆都要有正對照 ——
     只驗「非總部被擋」的話，一支永遠回 forbidden 的實作也會全綠。
   ============================================================ */
do $$
declare v_uid uuid; v_r jsonb; v_msg text := ''; v_n int; v_day date;
begin
  select s.auth_uid into v_uid from staff s
   where s.auth_uid is not null and s.deleted_at is null
     and s.role in ('hq','owner') limit 1;
  if v_uid is null then
    perform set_config('migi.p', '🔴 找不到總部 staff', true); return;
  end if;

  /* 🎯 取樣**當場查**（硬規則 3.56／3.57）：挑一天真的有場次的日期，
     不要寫死 —— 寫死的日期會在資料變動時讓驗證段紅得莫名其妙。 */
  select (coalesce(activated_at, started_at) at time zone 'Asia/Taipei')::date
    into v_day
    from table_sessions
   where deleted_at is null and coalesce(activated_at, started_at) is not null
   order by coalesce(activated_at, started_at) desc limit 1;

  /* 🔴 **找不到樣本要出聲，不要安靜跳過**（硬規則 3.57）——
     2026-09-04 那次兩格沒出現，我以為全過了。 */
  if v_day is null then
    perform set_config('migi.p',
      '🔴 找不到任何有開打時間的場次 —— 下面幾格全部沒跑，不算通過', true);
    return;
  end if;

  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
    set local role authenticated;

    -- ① 正對照：總部查得到那一天
    v_r := public.admin_search_sessions_tx(
             (v_day::timestamp at time zone 'Asia/Taipei'),
             ((v_day + 1)::timestamp at time zone 'Asia/Taipei'));
    v_n := jsonb_array_length(v_r -> 'rows');
    v_msg := case when (v_r ->> 'ok')::boolean and v_n > 0
      then '✅ ① ' || v_day || ' 查到 ' || v_n || ' 場'
      else '🔴 ① 查不到：' || left(v_r::text, 150) end;

    -- ② 每一場都要有玩家清單與桌號（不是空殼）
    v_msg := v_msg || E'\n' || (
      select case when count(*) filter (where jsonb_array_length(e -> 'players') > 0) = count(*)
                   and count(*) filter (where e ->> 'table' is not null) = count(*)
        then '✅ ② 每一場都有玩家與桌號'
        else '🔴 ② 有場次缺玩家或桌號' end
      from jsonb_array_elements(v_r -> 'rows') e);

    -- ③ 🔴 不可以回傳 member_id（這一頁最敏感的那一條）
    v_msg := v_msg || E'\n' || case
      when v_r::text ~ '"member_id"' then '🔴 ③ 竟然回傳了 member_id'
      else '✅ ③ 沒有回傳 member_id' end;

    -- ④ 桌號篩選：拿第一場的桌號回頭查，要查得到
    v_msg := v_msg || E'\n' || (
      select case when jsonb_array_length(
               public.admin_search_sessions_tx(
                 (v_day::timestamp at time zone 'Asia/Taipei'),
                 ((v_day + 1)::timestamp at time zone 'Asia/Taipei'),
                 null, (v_r -> 'rows' -> 0 ->> 'table')) -> 'rows') > 0
        then '✅ ④ 桌號篩選有效（' || (v_r -> 'rows' -> 0 ->> 'table') || '）'
        else '🔴 ④ 桌號篩選查不到自己' end);

    -- ⑤ 負對照：不存在的桌號要回 0 場（不是「篩選被忽略」）
    v_msg := v_msg || E'\n' || case when jsonb_array_length(
        public.admin_search_sessions_tx(
          (v_day::timestamp at time zone 'Asia/Taipei'),
          ((v_day + 1)::timestamp at time zone 'Asia/Taipei'),
          null, 'ZZ99') -> 'rows') = 0
      then '✅ ⑤ 不存在的桌號回 0（篩選真的有作用）'
      else '🔴 ⑤ 篩選被忽略了' end;

    -- ⑥ 分頁：limit 1 時 has_more 要是 true（那一天不只一場的話）
    v_msg := v_msg || E'\n' || (
      select case
        when v_n < 2 then '⚪ ⑥ 那天只有 ' || v_n || ' 場，分頁測不了（不算失敗）'
        when (r ->> 'has_more')::boolean and jsonb_array_length(r -> 'rows') = 1
             and (r ->> 'next_before') is not null
        then '✅ ⑥ 分頁正確（limit 1 → has_more=true ＋ 有游標）'
        else '🔴 ⑥ 分頁壞了：' || left(r::text, 200) end
      from (select public.admin_search_sessions_tx(
              (v_day::timestamp at time zone 'Asia/Taipei'),
              ((v_day + 1)::timestamp at time zone 'Asia/Taipei'),
              null, null, null, 1) as r) t);

    -- ⑦ 會員搜尋：用真的暱稱查得到；⚠ 這一格在防「篩選恆真」那個 bug
    v_msg := v_msg || E'\n' || (
      select case when nm is null then '⚪ ⑦ 那天沒有玩家，跳過'
        when jsonb_array_length(public.admin_search_sessions_tx(
               (v_day::timestamp at time zone 'Asia/Taipei'),
               ((v_day + 1)::timestamp at time zone 'Asia/Taipei'),
               null, null, nm) -> 'rows') > 0
        then '✅ ⑦ 用暱稱「' || nm || '」查得到'
        else '🔴 ⑦ 用真的暱稱反而查不到' end
      from (select v_r -> 'rows' -> 0 -> 'players' -> 0 ->> 'name' as nm) t);

    -- ⑧ 🔴 負對照：不存在的暱稱要回 0 —— 這一格才抓得到「篩選恆真」
    v_msg := v_msg || E'\n' || case when jsonb_array_length(
        public.admin_search_sessions_tx(
          (v_day::timestamp at time zone 'Asia/Taipei'),
          ((v_day + 1)::timestamp at time zone 'Asia/Taipei'),
          null, null, '不可能存在的暱稱ZZ') -> 'rows') = 0
      then '✅ ⑧ 不存在的暱稱回 0（篩選沒有恆真）'
      else '🔴 ⑧ 篩選恆真 —— 手機那一半可能把空字串當成 like ''%%''' end;

    -- ⑨ 負對照：非總部一律 forbidden
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
    v_msg := v_msg || E'\n' || case
      when (public.admin_search_sessions_tx() ->> 'reason') = 'forbidden'
      then '✅ ⑨ 非總部被擋' else '🔴 ⑨ 竟然查得到' end;

    reset role;
    raise exception 'migi_rollback';
  exception when others then
    begin reset role; exception when others then null; end;
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途拋錯：' || sqlerrm; end if;
    perform set_config('migi.p', v_msg, true);
  end;
end $$;

select
  '① 版本數 ' || (select count(*)::text from pg_proc
     where pronamespace='public'::regnamespace and proname='admin_search_sessions_tx')
    || '（應為 1）'                                                        as "①建立",
  (select case p.provolatile when 's' then 'STABLE' else '🔴 ' || p.provolatile::text end
            || case when p.prosecdef then ' · DEFINER' else ' · 🔴 INVOKER' end
     from pg_proc p where p.pronamespace='public'::regnamespace
       and p.proname='admin_search_sessions_tx')                           as "②易變性",
  (select 'auth=' ||
     case when exists (select 1 from aclexplode(p.proacl) a
            where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE')
          then '✅' else '🔴' end ||
     '  anon=' ||
     case when exists (select 1 from aclexplode(p.proacl) a
            where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
          then '🔴有' else '✅無' end ||
     '  PUBLIC=' ||
     case when p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
            where a.grantee=0 and a.privilege_type='EXECUTE')
          then '🔴有' else '✅無' end
     from pg_proc p where p.pronamespace='public'::regnamespace
       and p.proname='admin_search_sessions_tx')                           as "③授權",
  coalesce(nullif(current_setting('migi.p', true), ''), '🔴 沒有測試訊息')  as "④～⑨行為";
