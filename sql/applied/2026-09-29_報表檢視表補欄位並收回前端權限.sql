/* ============================================================
   報表檢視表：補齊漏掉的欄位 ＋ 收回前端角色的權限
   2026-09-29 · 唯讀 MCP 查證後寫的

   ── ① 五支 v_real_* 漏欄位（結構檢查當場抓到，不只原本以為的兩支）──
   | 檢視表                 | 漏掉的欄位                          | 哪一批加的 |
   |---|---|---|
   | v_real_table_sessions  | score_channel、closed_by_staff_id   | 09-23 電子計分／09-29 收桌記錄 |
   | v_real_match_queues    | credited_staff_id                   | 09-29 獎金歸屬 |
   | v_real_stores          | on_duty_staff_id、on_duty_since     | 09-29 當班 |
   | v_real_members         | hidden_at                           | 09-25 隱藏帳號 |
   | v_real_session_players | device_id                           | 09-23 平板 |
   🔴 獎金報表要的兩欄（closed_by_staff_id／credited_staff_id）就在裡面 ——
     不補的話報表會得到「沒有人收過桌、沒有人配過桌」而且不報錯。
   ⚠ 做法同 2026-09-11：`select x.*` 重建。**Postgres 建立當下就展開 `*`**，
     所以這不是「以後自動跟上」，只是這一刻對了；以後靠錯誤儀表的檢查抓。
   ⚠ `create or replace view` 只能在最後追加欄位：五支現有欄位的順序都已逐一
     比對與底層表一致（members 有一個刪除過的欄位，位置在最後，不影響）。
   🔴 過濾條件一個字都不動 —— 全部照 pg_get_viewdef 的線上版本抄。

   ── ② 🔴 22 支檢視表全部是 anon 讀得到（而且有寫入權），而且繞過 RLS ──
   檢視表預設用擁有者（postgres）的身分查底層表 ⇒ **RLS 完全不作用**。
   而它們在 public schema ⇒ PostgREST 直接開放，anon 金鑰本來就是公開的：
   ```
   curl https://<專案>.supabase.co/rest/v1/v_wallet_balance_check  -H "apikey: <anon>"
   ```
   2026-09-29 當下實際讀得到：
     v_wallet_balance_check   5 位會員的 id、暱稱、餘額
     v_order_settlement       174 張訂單金額
     v_member_wait_stats／v_member_join_hours   會員的配桌行為
     v_real_*（12 支）         今天全空（live_from 未設）—— **上線那天就開始外洩**
   🟢 今天真實客人 0 個 ⇒ 沒有實際損害。**但那是運氣不是設計。**
   ⚠ 權限是 arwdDxtm（全部），單表的檢視表是可以直接寫入的（auto-updatable）
     ⇒ 收的是 all，不只 select。

   ✅ 為什麼收掉不會打壞東西（查證過）：
     · 三個前端 repo 的 src 裡 `v_real_` 一次都沒出現，其他檢視表也沒有
     · 讀這些檢視表的函式只有 3 支（daily_wallet_audit_tx／reconcile_wallets_tx／
       dev_reset_test_data_tx），**全部 DEFINER、擁有者 postgres**；
       排程 daily-wallet-audit 也用 postgres 跑 ⇒ 不經過 anon／authenticated
     · 唯讀 MCP（supabase_read_only_user）靠 pg_read_all_data，不受影響
   ⚠ 日後後台要做報表：走 DEFINER ＋ can() 的 RPC，**不要把這裡收掉的權限加回去**。
   ⚠ 新建的檢視表會再次吃到 Supabase 的 default privileges（anon 全開）——
     錯誤儀表同批加一格盯這件事，不靠記性。

   ── 這份要留下東西 ⇒ 驗證段一個字都不 raise（硬規則 1.8）──
   ============================================================ */

/* ── ① 補欄位（過濾條件照線上原樣）───────────────────────── */
create or replace view public.v_real_table_sessions as
  select x.*
    from table_sessions x
    join orgs o on o.id = x.org_id
   where not coalesce(x.is_test, false)
     and x.deleted_at is null
     and x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
     and not exists (select 1 from stores s where s.id = x.store_id and s.is_test);

create or replace view public.v_real_match_queues as
  select x.*
    from match_queues x
    join orgs o on o.id = x.org_id
   where x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
     and not exists (select 1 from stores s where s.id = x.store_id and s.is_test);

create or replace view public.v_real_stores as
  select s.*
    from stores s
    join orgs o on o.id = s.org_id
   where s.is_test = false
     and s.deleted_at is null
     and s.created_at >= coalesce(o.live_from, 'infinity'::timestamptz);

create or replace view public.v_real_members as
  select m.*
    from members m
    join orgs o on o.id = m.org_id
   where m.is_test = false
     and m.deleted_at is null
     and m.created_at >= coalesce(o.live_from, 'infinity'::timestamptz);

create or replace view public.v_real_session_players as
  select x.*
    from session_players x
   where exists (select 1 from v_real_table_sessions rs where rs.id = x.session_id)
     and not exists (select 1 from members m where m.id = x.member_id and m.is_test);

/* ── ② 收回前端角色對所有檢視表的權限（結構性：掃全部，不列名單）── */
do $$
declare r record;
begin
  for r in select c.relname from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind in ('v', 'm')
  loop
    execute format('revoke all on public.%I from public, anon, authenticated', r.relname);
  end loop;
end $$;

/* ── 驗證段（單一 SELECT，不 raise）────────────────────────── */
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  /* ① 全部 v_real_* 一起檢查：沒有一支漏掉底層表的欄位 */
  select string_agg(distinct v.table_name || '.' || t.column_name, '、') into v_t
    from information_schema.views v
    join information_schema.columns t
      on t.table_schema = 'public' and t.table_name = replace(v.table_name, 'v_real_', '')
   where v.table_schema = 'public' and v.table_name like 'v\_real\_%'
     and not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public' and c.table_name = v.table_name
                        and c.column_name = t.column_name);
  v_msg := v_msg || case when v_t is null then '✅ ① 所有 v_real_* 都沒有漏欄位'
                         else '🔴 ① 還有漏的：' || v_t end;

  /* ② 正對照：這次補的欄位真的在（view 被誤刪的話 ① 也會綠） */
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public'
     and ((table_name = 'v_real_table_sessions'  and column_name in ('score_channel', 'closed_by_staff_id'))
       or (table_name = 'v_real_match_queues'    and column_name = 'credited_staff_id')
       or (table_name = 'v_real_stores'          and column_name in ('on_duty_staff_id', 'on_duty_since'))
       or (table_name = 'v_real_members'         and column_name = 'hidden_at')
       or (table_name = 'v_real_session_players' and column_name = 'device_id'));
  v_msg := v_msg || E'\n' || case when v_n = 7 then '✅ ② 補進去的 7 個欄位都在（7/7）'
                                   else '🔴 ② 只有 ' || v_n || '/7' end;

  /* ③ 過濾條件沒被弄丟：五支直接判斷的都還有時間下限、session_players 還繼承父表 */
  select count(*) into v_n from pg_views
   where schemaname = 'public'
     and viewname in ('v_real_table_sessions', 'v_real_match_queues', 'v_real_stores', 'v_real_members')
     and definition like '%live_from%';
  select v_n + count(*) into v_n from pg_views
   where schemaname = 'public' and viewname = 'v_real_session_players'
     and definition like '%v_real_table_sessions%';
  v_msg := v_msg || E'\n' || case when v_n = 5 then '✅ ③ 過濾條件都在（4 支時間下限 ＋ 1 支繼承）'
                                   else '🔴 ③ 過濾條件不見了（' || v_n || '/5）—— 測試資料會流進報表' end;

  /* ④ live_from 還是 null ⇒ 五支都該是 0 列（設計上的空） */
  select (select count(*) from v_real_table_sessions) + (select count(*) from v_real_match_queues)
       + (select count(*) from v_real_stores) + (select count(*) from v_real_members)
       + (select count(*) from v_real_session_players) into v_n;
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ④ 五支都是 0 列（live_from 還沒設）'
                                   else '🔴 ④ 冒出 ' || v_n || ' 列 —— 過濾被改壞了' end;

  /* ⑤ 前端角色碰不到任何檢視表 —— 兩種來源都看（明確授權 ＋ PUBLIC） */
  select string_agg(c.relname, '、') into v_t
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('v', 'm')
     and (c.relacl is null
          or exists (select 1 from aclexplode(c.relacl) a
                      where a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid)));
  v_msg := v_msg || E'\n' || case when v_t is null then '✅ ⑤ 所有檢視表 anon／authenticated／PUBLIC 都沒有任何權限'
                                   else '🔴 ⑤ 還有：' || v_t end;

  /* ⑥ 正對照：擁有者 postgres 與 service_role 還在（不是整個鎖死）；
        讀它們的 DEFINER 函式照樣能用 */
  select count(*) into v_n from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
     and has_table_privilege('service_role', c.oid, 'SELECT');
  select count(*) into v_t from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'v';
  v_msg := v_msg || E'\n' || case when v_n::text = v_t then '✅ ⑥ service_role 仍讀得到全部 ' || v_t || ' 支（正對照）'
                                   else '🔴 ⑥ service_role 只剩 ' || v_n || '/' || v_t end;

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('daily_wallet_audit_tx', 'reconcile_wallets_tx', 'dev_reset_test_data_tx')
     and p.prosecdef and pg_get_userbyid(p.proowner) = 'postgres';
  v_msg := v_msg || E'\n' || case when v_n = 3 then '✅ ⑦ 讀檢視表的 3 支函式都是 postgres 擁有的 DEFINER，不受影響'
                                   else '🔴 ⑦ 只有 ' || v_n || '/3 —— 有函式會因為收權限而壞掉' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
