/* ============================================================
   四個 `v_real_*` 補齊漏掉的欄位
   2026-09-11 · 由 baseline 匯出抓到

   ── 🎯 這是 baseline 第一次跑就抓到的東西 ─────────────
   硬規則 1.65 說 baseline 的價值是「回答**現在**長什麼樣」，
   而它第一次產出就讓一件**完全沒有症狀**的事浮出來：

   | 檢視表 | 漏掉的欄位 | 那個欄位什麼時候加的 |
   |---|---|---|
   | `v_real_order_items`     | `spec`                   | 2026-09-10 |
   | `v_real_session_players` | `final_score`／`rating_after` | 09-06／08-31 |
   | `v_real_members`         | `avatar_bear`／`phone_verified_at`／`rating`／`rating_games` | 08-29～09-01 |
   | `v_real_match_queues`    | `auto_seat`              | 2026-09-06 |

   🔴 **`v_real_*` 是報表唯一該查的東西**（CLAUDE.md 明講：
     直接查原表會把測試資料算進營運數據且不報錯）。
     而它們的欄位是**寫死的清單** —— `create view ... select a, b, c`，
     底層表加欄位**不會**跟著進去。
   ⚠ 症狀是零：查詢不報錯，只是那一欄不存在，
     而寫報表的人會得到「這個系統沒有這筆資料」的結論。
   📌 最貼近的例子就是今天做的那一批：進銷存要算
     「每項每天賣幾份」（《首店餐飲籌備》拿它決定冷凍櫃買幾台），
     而 `v_real_order_items` 查不到 `spec`。

   ── 為什麼用 `x.*` 而不是把欄位一個一個列回去 ──────
   ```
   create or replace view v as select x.* from t x where …
   ```
   ⚠ **Postgres 在建立當下就把 `*` 展開成欄位清單** ——
     所以這仍然**不是**「以後自動跟上」，只是**重建這一刻是對的**。
   🎯 **真正的修法是檢查不是寫法**（同硬規則 11.1 的通則：
     把規則變成不需要人記得的東西）⇒ 同一批把它加進錯誤儀表第 ⑪ 段。

   ⚠ `create or replace view` 只允許**在最後追加**欄位，
     不可以改順序或刪除。四個 view 的既有順序都與底層表一致
     （已逐一比對），所以 `x.*` 展開後前面完全相同、新欄位落在最後。

   🔴 **過濾邏輯一個字都不能動。** `live_from` 那一道是三層防線裡最硬的
     （null ⇒ 每一支 `v_real_*` 都是空的，而那是設計上的空不是 bug）。
     驗證段第 ③④ 格就是在盯這件事。
   ============================================================ */

/* ── ① 品項：進銷存要用的 spec ──────────────────────
   ⚠ 它自己不判斷 is_test，而是**間接繼承** `v_real_orders`
     —— 過濾邏輯只有一份，那是對的設計不是漏掉。 */
create or replace view public.v_real_order_items as
  select x.*
    from order_items x
   where exists (select 1 from v_real_orders ro where ro.id = x.order_id);

/* ── ② 座位：桌上積分與段位分快照 ─────────────────── */
create or replace view public.v_real_session_players as
  select x.*
    from session_players x
   where exists (select 1 from v_real_table_sessions rs where rs.id = x.session_id)
     and not exists (select 1 from members m where m.id = x.member_id and m.is_test);

/* ── ③ 會員：段位那一批 ─────────────────────────── */
create or replace view public.v_real_members as
  select m.*
    from members m
    join orgs o on o.id = m.org_id
   where m.is_test = false
     and m.deleted_at is null
     and m.created_at >= coalesce(o.live_from, 'infinity'::timestamptz);

/* ── ④ 配桌房：取消開桌之後的手動旗標 ──────────────── */
create or replace view public.v_real_match_queues as
  select x.*
    from match_queues x
    join orgs o on o.id = x.org_id
   where x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
     and not exists (select 1 from stores s where s.id = x.store_id and s.is_test);

/* ── 驗證段（唯讀，一個字都不 raise —— 硬規則 1.8）────── */
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  /* ① 全部 12 支一起檢查，不只這次改的四支。
        🎯 讓涵蓋範圍是**結構性的** —— 下一次有人加欄位時，
          這一格會自己抓到，不需要有人記得回來加檢查。 */
  select string_agg(distinct z.vname, ' · ' order by z.vname) into v_t
    from (
      select v.table_name as vname
        from information_schema.columns v
        join information_schema.columns t
          on t.table_schema = 'public'
         and t.table_name   = replace(v.table_name, 'v_real_', '')
       where v.table_schema = 'public'
         and v.table_name like 'v\_real\_%'
         and not exists (
           select 1 from information_schema.columns v2
            where v2.table_schema='public' and v2.table_name = v.table_name
              and v2.column_name = t.column_name)
    ) z;
  v_msg := v_msg || case when v_t is null
    then '① ✅ 12 支 v_real_* 沒有一支漏掉底層表的欄位'
    else '① 🔴 還有漏的：' || v_t end;

  /* ② 這次補的四個欄位真的在。
        只驗「沒有漏」的話，一支被誤刪的 view 也會讓 ① 變綠
        （不存在的 view 不會出現在漏的清單裡）。 */
  select count(*) into v_n from information_schema.columns
   where table_schema='public'
     and ((table_name='v_real_order_items'     and column_name='spec')
       or (table_name='v_real_session_players' and column_name='final_score')
       or (table_name='v_real_members'         and column_name='rating')
       or (table_name='v_real_match_queues'    and column_name='auto_seat'));
  v_msg := v_msg || E'\n' || case when v_n=4
    then '② ✅ 四個代表性欄位都補進去了（spec／final_score／rating／auto_seat）'
    else '② 🔴 只有 ' || v_n || ' 個' end;

  /* ③ 🔴 正對照：過濾邏輯一個字都不能少。
        `live_from` 是三層防線裡最硬的那一層，改 view 時最容易順手弄丟。 */
  select count(*) into v_n from pg_views
   where schemaname='public'
     and viewname in ('v_real_members','v_real_match_queues')
     and definition like '%live_from%';
  v_msg := v_msg || E'\n' || case when v_n=2
    then '③ ✅ 兩支直接判斷的 view 都還有時間下限'
    else '③ 🔴 時間下限不見了 —— 測試資料會流進報表' end;

  select count(*) into v_n from pg_views
   where schemaname='public'
     and ((viewname='v_real_order_items'     and definition like '%v_real_orders%')
       or (viewname='v_real_session_players' and definition like '%v_real_table_sessions%'));
  v_msg := v_msg || E'\n' || case when v_n=2
    then '④ ✅ 兩支間接繼承的 view 還是查父表的 view（過濾只有一份）'
    else '④ 🔴 繼承斷了 —— 那兩支會變成沒有過濾' end;

  /* ⑤ 🔴 真的查一次，四支都要是 0 列。
        `orgs.live_from` 還是 null ⇒ 每一支 v_real_* 都該是空的，
        **而那是設計上的空不是 bug**。
        ⚠ 這一格若冒出資料，代表過濾被改壞了 —— 那比欄位漏掉嚴重得多。 */
  select (select count(*) from v_real_order_items)
       + (select count(*) from v_real_session_players)
       + (select count(*) from v_real_members)
       + (select count(*) from v_real_match_queues)
    into v_n;
  v_msg := v_msg || E'\n' || case when v_n=0
    then '⑤ ✅ 四支都是 0 列（live_from 還沒設，那是設計上的空）'
    else '⑤ 🔴 冒出 ' || v_n || ' 列 —— 過濾被改壞了' end;

  /* ⑥ 正對照之二：把時間下限換掉，資料要真的冒出來。
        🔴 只驗「應該是 0」等於沒驗 —— 一支寫壞的 view 也回 0
        （硬規則 3.55，那正是 2026-08-28 把 2847 講成漏出去的那次）。 */
  select count(*) into v_n from order_items x
   where exists (select 1 from orders o
                  where o.id = x.order_id and o.deleted_at is null
                    and not coalesce(o.is_test, false));
  v_msg := v_msg || E'\n' || case when v_n > 0
    then '⑥ ✅ 正對照：拿掉時間下限的話有 ' || v_n || ' 筆會冒出來（掃描器是活的）'
    else '⑥ ⚪ 連正對照都是 0 —— 這一格今天測不出東西' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
