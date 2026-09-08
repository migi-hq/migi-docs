/* ============================================================
   場次查詢的游標改成複合鍵（2026-09-08，接續 `後台場次查詢.sql`）

   ── 為什麼 ────────────────────────────────────────────
   前一份的游標是 `where at < p_before`，**時間戳打平就會跳過一筆**。

   🔴 而打平**不是理論上的可能，是會發生的**：
   ```
   sweep_auto_seat_tx   有迴圈，一輪會帶好幾個房
   同一個交易裡的 now() 是同一個值
   ⇒ 那一批場次的 started_at 完全相同
   ```
   而 `started_at` 正是這支函式時間軸的**退回值**
   （帶桌之後、開打之前 `activated_at` 是 null）。

   ⚠ 症狀是**分頁時有一場消失，而且不會報錯** ——
     翻頁的人只會覺得「奇怪，那桌怎麼不見了」。
   📌 今天實測 117 場**零重複**，所以它還沒發生 ——
     但「今天沒有」不是「不會有」，而 `sweep` 一開始跑就會有。

   ── 🎯 現在改是免費的 ─────────────────────────────────
   這支函式**還沒有任何東西呼叫它**（前端還沒做）。
   同 CLAUDE.md 記過的：「趁還沒有東西呼叫它時改簽名是免費的，
   上線後就要走部署順序」（`pos_quick_checkout_tx` 那次）。

   ── 修法：列比較（row-wise comparison）────────────────
   ```sql
   where (at, id) < (p_before, p_before_id)
   ```
   Postgres 的列比較是**字典序**：先比 `at`，相同才比 `id`。
   而排序也是 `order by at desc, id desc` —— **兩者必須用同一組鍵**，
   不然游標會指到排序上不相鄰的位置。

   🔴 **改了簽名 ⇒ 必須先 DROP**（硬規則 2），
     而 **DROP 會把 GRANT 一起丟掉** ⇒ 結尾要補回授權。
   ============================================================ */

drop function if exists public.admin_search_sessions_tx(
  timestamptz, timestamptz, uuid, text, text, int, timestamptz);

create or replace function public.admin_search_sessions_tx(
  p_from      timestamptz default null,
  p_to        timestamptz default null,
  p_store     uuid        default null,
  p_table_q   text        default null,
  p_member_q  text        default null,
  p_limit     int         default 50,
  p_before    timestamptz default null,   -- 游標：時間
  p_before_id uuid        default null    -- ★ 游標：同一時間時的第二把鑰匙
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
       /* 🔴 手機那一半一定要先確認真的有數字 ——
          `regexp_replace('阿明','\D','','g')` 回空字串 ⇒ `like '%%'`
          ⇒ 每個有手機的會員都符合 ⇒ **篩選完全失效而且不報錯**。 */
       and (p_member_q is null or exists (
              select 1 from session_players sp
                join members m on m.id = sp.member_id
               where sp.session_id = s.id
                 and (m.display_name ilike '%' || btrim(p_member_q) || '%'
                      or (regexp_replace(p_member_q, '\D', '', 'g') <> ''
                          and m.phone like '%' || regexp_replace(p_member_q, '\D', '', 'g') || '%'))))
       /* ★ 複合游標：`(at, id)` 的列比較是字典序 —— 先比時間，打平才比 id。
          ⚠ **必須與 `order by` 用同一組鍵**，否則游標會指到排序上不相鄰的位置。
          ⚠ 只給 `p_before` 沒給 id 時退回單鍵（前端第一版就是這樣叫的）。 */
       and (p_before is null
            or (p_before_id is null and coalesce(s.activated_at, s.started_at) < p_before)
            or (p_before_id is not null
                and (coalesce(s.activated_at, s.started_at), s.id) < (p_before, p_before_id)))
     order by coalesce(s.activated_at, s.started_at) desc, s.id desc
     limit v_lim + 1
  )
  /* `has_more` 從**多撈的那一筆**判斷，而且要在截斷之前數 ——
     內層先 limit 再 count 的話，count 永遠 ≤ v_lim，
     `has_more` 恆為 false 而且不報錯（下一頁永遠按不到）。 */
  select coalesce(jsonb_agg(x.j order by x.at desc, x.id desc)
                    filter (where x.rn <= v_lim), '[]'::jsonb),
         count(*) > v_lim
    into v_rows, v_more
    from (
      select b.at, b.id,
             row_number() over (order by b.at desc, b.id desc) as rn,
             jsonb_build_object(
               'id', b.id,
               'at', b.at,
               'ended_at', b.ended_at,
               'status', b.status,
               'mode', b.mode,
               'game_type', b.game_type,
               'flower', b.flower,
               'rounds', b.planned_rounds,
               'store', b.store_name,
               'table', b.table_label,
               'area', b.area,
               'stake', b.stake_label,
               'hygiene', b.hygiene,
               'fee_points', b.fee_points,
               /* 🔴 刻意不回 member_id —— 這一頁看得到所有人的消費與同桌關係，
                  而回 id 等於公開發送一批會員 uuid（`get_wallet_tx` today 仍是
                  anon ＋ 前端送 id）。人名 ＋ 座位 ＋ 名次就回答得了「誰在打」。 */
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
    ) x;

  return jsonb_build_object(
    'ok', true,
    'rows', coalesce(v_rows, '[]'::jsonb),
    'has_more', v_more,
    'from', v_from,
    'to', v_to,
    /* ★ 游標現在是**一對** —— 前端要把兩個都帶回來。
       ⚠ 取的是「給出去那批裡最後一筆」，不是最小時間 ——
         打平的時候「最小時間」有兩筆，指哪一筆是未定義的。 */
    'next_before', case when v_more then (v_rows -> (jsonb_array_length(v_rows) - 1) ->> 'at') end,
    'next_before_id', case when v_more then (v_rows -> (jsonb_array_length(v_rows) - 1) ->> 'id') end
  );
end $fn$;

/* 🔴 DROP 把 GRANT 一起丟掉了，補回來（硬規則 2）。
   ⚠ 兩個方向都要收（硬規則 2.6b）：新建的函式一建立就是 anon **明確**授權。 */
revoke execute on function public.admin_search_sessions_tx(timestamptz,timestamptz,uuid,text,text,int,timestamptz,uuid) from public;
revoke execute on function public.admin_search_sessions_tx(timestamptz,timestamptz,uuid,text,text,int,timestamptz,uuid) from anon;
grant  execute on function public.admin_search_sessions_tx(timestamptz,timestamptz,uuid,text,text,int,timestamptz,uuid) to authenticated;


/* ============================================================
   驗證（單一 SELECT）
   🎯 這一份的重點是**分頁真的翻得動而且不漏不重** ——
     前一份那一格因為「那天只有 1 場」而是 ⚪，沒有驗到。
   ============================================================ */
do $$
declare
  v_uid uuid; v_msg text := ''; v_day date; v_n int;
  p1 jsonb; p2 jsonb; ids1 text[]; ids2 text[]; all_ids text[];
begin
  select s.auth_uid into v_uid from staff s
   where s.auth_uid is not null and s.deleted_at is null
     and s.role in ('hq','owner') limit 1;
  if v_uid is null then
    perform set_config('migi.p', '🔴 找不到總部 staff', true); return;
  end if;

  /* 🎯 取樣當場查：挑**場次最多**的那一天（前一份挑「最近」，
     結果那天只有 1 場，分頁測不了）。同硬規則 3.57：取樣條件
     要包含「這個測試需要什麼」，不是隨手拿最新的。 */
  select (coalesce(activated_at, started_at) at time zone 'Asia/Taipei')::date, count(*)
    into v_day, v_n
    from table_sessions
   where deleted_at is null and coalesce(activated_at, started_at) is not null
   group by 1 order by count(*) desc, 1 desc limit 1;

  if v_day is null or v_n < 3 then
    perform set_config('migi.p',
      '🔴 找不到「同一天 ≥3 場」的樣本（最多 ' || coalesce(v_n, 0) ||
      ' 場）—— 分頁沒驗到，不算通過', true);
    return;
  end if;

  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
    set local role authenticated;

    -- 第一頁（limit 2）
    p1 := public.admin_search_sessions_tx(
            (v_day::timestamp at time zone 'Asia/Taipei'),
            ((v_day + 1)::timestamp at time zone 'Asia/Taipei'), null, null, null, 2);
    -- 第二頁：帶**兩個**游標回來
    p2 := public.admin_search_sessions_tx(
            (v_day::timestamp at time zone 'Asia/Taipei'),
            ((v_day + 1)::timestamp at time zone 'Asia/Taipei'), null, null, null, 2,
            (p1 ->> 'next_before')::timestamptz, (p1 ->> 'next_before_id')::uuid);

    select array_agg(e ->> 'id') into ids1 from jsonb_array_elements(p1 -> 'rows') e;
    select array_agg(e ->> 'id') into ids2 from jsonb_array_elements(p2 -> 'rows') e;
    all_ids := ids1 || ids2;

    v_msg := '樣本：' || v_day || '（' || v_n || ' 場）';
    v_msg := v_msg || E'\n' || case when (p1 ->> 'has_more')::boolean
        and array_length(ids1, 1) = 2 and (p1 ->> 'next_before_id') is not null
      then '✅ ① 第一頁 2 筆 · has_more · 游標成對'
      else '🔴 ① ' || left(p1::text, 180) end;
    v_msg := v_msg || E'\n' || case when array_length(ids2, 1) >= 1
      then '✅ ② 第二頁拿到 ' || array_length(ids2, 1) || ' 筆'
      else '🔴 ② 第二頁是空的 —— 游標把後面全吃掉了' end;
    /* 🔴 **不重**：兩頁的 id 不可以有交集 */
    v_msg := v_msg || E'\n' || case
      when array_length(all_ids, 1) = array_length(array(select distinct unnest(all_ids)), 1)
      then '✅ ③ 兩頁沒有重複' else '🔴 ③ 有重複 —— 游標用了 <= 而不是 <' end;
    /* 🔴 **不漏**：兩頁合起來要等於「直接抓前 4 筆」 */
    v_msg := v_msg || E'\n' || (
      select case when all_ids = arr then '✅ ④ 兩頁 = 直接抓前 4 筆（不漏不亂序）'
                  else '🔴 ④ 順序或內容對不上' end
        from (select array_agg(e ->> 'id') as arr
                from jsonb_array_elements(
                       public.admin_search_sessions_tx(
                         (v_day::timestamp at time zone 'Asia/Taipei'),
                         ((v_day + 1)::timestamp at time zone 'Asia/Taipei'),
                         null, null, null, 4) -> 'rows') e) t);
    /* ⑤ 正對照：舊的單鍵呼叫（不給 p_before_id）仍然要能動 —— 前端第一版就這樣叫 */
    v_msg := v_msg || E'\n' || case when jsonb_array_length(
        public.admin_search_sessions_tx(
          (v_day::timestamp at time zone 'Asia/Taipei'),
          ((v_day + 1)::timestamp at time zone 'Asia/Taipei'), null, null, null, 2,
          (p1 ->> 'next_before')::timestamptz) -> 'rows') >= 1
      then '✅ ⑤ 只給時間游標（不給 id）也還能翻'
      else '🔴 ⑤ 單鍵游標壞了' end;
    /* ⑥ 負對照：非總部一律 forbidden */
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
    v_msg := v_msg || E'\n' || case
      when (public.admin_search_sessions_tx() ->> 'reason') = 'forbidden'
      then '✅ ⑥ 非總部被擋' else '🔴 ⑥ 竟然查得到' end;

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
    || '（應為 1 —— DROP 沒做乾淨的話會是 2）'                             as "①沒有多載",
  (select 'auth=' ||
     case when exists (select 1 from aclexplode(p.proacl) a
            where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE')
          then '✅' else '🔴 DROP 之後忘了補 GRANT' end ||
     '  anon=' ||
     case when exists (select 1 from aclexplode(p.proacl) a
            where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
          then '🔴有' else '✅無' end ||
     '  PUBLIC=' ||
     case when p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
            where a.grantee=0 and a.privilege_type='EXECUTE')
          then '🔴有' else '✅無' end
     from pg_proc p where p.pronamespace='public'::regnamespace
       and p.proname='admin_search_sessions_tx')                           as "②授權補回來了嗎",
  coalesce(nullif(current_setting('migi.p', true), ''), '🔴 沒有測試訊息')  as "③分頁";
