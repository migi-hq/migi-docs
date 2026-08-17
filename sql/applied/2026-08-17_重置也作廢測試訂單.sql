-- 【待執行】dev_reset_test_data_tx 一併作廢測試會員的訂單與儲值單
-- ============================================================
-- 問題
--   舊版對訂單只做 count，理由寫得很清楚：order_payments 有
--   trg_payments_no_delete，外鍵是 RESTRICT，收過錢的訂單在設計上不可刪。
--   **那個理由是對的，但結論不完整** —— 刪不掉不代表不能作廢。
--
--   後果今天親眼見到：查出「36 張綁了場次的訂單、0 筆入座紀錄」。
--   場次被 voided、入座紀錄被刪，訂單卻留著 —— **半清乾淨的狀態比沒清更難判讀**，
--   我為了搞懂那個矛盾多花了三輪查詢。
--
--   更實際的問題：當日暢打退不掉。
--   has_daypass_tx 認的是「今天有一張 status='paid' 且含 SVC-TBL-DAY 的訂單」，
--   訂單留著，測試帳號買過一次暢打就整天都免費，場地費相關的測試全部做不了。
--
-- 改法
--   訂單與儲值單改成 status = 'void'（兩張表的 CHECK 都允許這個值）。
--   不刪除，所以不會撞到 trg_payments_no_delete 與 RESTRICT 外鍵。
--   作廢之後：
--     has_daypass_tx 查不到（它只認 paid）→ 暢打失效，可以重測
--     get_session_member_orders_tx 也只看 paid → 桌帳不會殘留
--
-- ⚠ 作廢不等於退款
--   不沖銷點數、不退現金，帳面上是不平的。
--   但這支是 dev_* 函式、只跑在 is_test 會員上，而且它本來就會把餘額
--   強制設回固定矩陣（1000/500/150/0）—— 餘額既然是重設的，
--   訂單留著才是不一致的那一邊。
--
-- 簽名未變，不需 DROP。
-- ============================================================

create or replace function public.dev_reset_test_data_tx(p_reset_balance bigint default 1000)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_members     uuid[];
  v_sessions    int := 0;
  v_players     int := 0;
  v_orders      int := 0;
  v_orders_void int := 0;
  v_topup_void  int := 0;
  v_queues      int := 0;
  v_wallets     int := 0;
  r             record;
begin
  select array_agg(id) into v_members from members where is_test = true;
  if v_members is null or array_length(v_members, 1) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_test_members');
  end if;

  -- 場次：收掉測試帳號還開著的桌
  -- status 允許值僅 open / completed / voided（注意不是 'void'），時間欄位是 ended_at
  update table_sessions
     set status = 'voided', ended_at = now()
   where status = 'open'
     and id in (select session_id from session_players
                 where member_id = any(v_members));
  get diagnostics v_sessions = row_count;

  -- 入座記錄：不是帳本，可以刪。
  -- 必須在此處刪除，否則 session_players.order_id 會擋住後續操作。
  delete from session_players where member_id = any(v_members);
  get diagnostics v_players = row_count;

  -- ★ 訂單：不刪，但作廢（2026-08-17）。
  --   order_payments 有 trg_payments_no_delete、外鍵是 RESTRICT，
  --   收過錢的訂單在設計上不可刪 —— 但**刪不掉不代表不能作廢**。
  --   舊版只 count 不處理，留下「場次被清、訂單還在」的半清狀態：
  --   最直接的後果是當日暢打退不掉（has_daypass_tx 只認 status='paid'），
  --   測試帳號買過一次就整天免場地費，場地費測試全部做不了。
  select count(*) into v_orders
    from orders where member_id = any(v_members);

  update orders
     set status = 'void'
   where member_id = any(v_members)
     and status <> 'void';
  get diagnostics v_orders_void = row_count;

  -- 儲值單同理：留著 paid 的儲值單，桌帳與對帳都會看到不該存在的東西
  update topup_orders
     set status = 'void'
   where member_id = any(v_members)
     and status <> 'void';
  get diagnostics v_topup_void = row_count;

  -- 配桌：報名紀錄表為 match_queue_players，房主欄位為 opened_by
  delete from match_queue_players where member_id = any(v_members);
  delete from match_queues        where opened_by = any(v_members);
  get diagnostics v_queues = row_count;

  -- 通知與社交
  delete from app_notifications where member_id = any(v_members);
  delete from buddy_invites
   where inviter_id = any(v_members) or invitee_id = any(v_members);

  -- 行為事件不刪：app_events 為 append-only（帳務稽核用）。
  -- 測試事件靠 is_test 標記 + v_real_app_events 過濾，不影響分析。

  -- ── 錢包 ──────────────────────────────────────────────
  -- 流水 append-only 不刪，補一筆 adjust 讓餘額回到起點，再用既有函式重算。
  -- 不直接 UPDATE wallets.balance —— 那會與 audit_wallet_balance 稽核衝突。
  --
  -- ★ 現況以**流水加總**為準，不是 wallets.balance（後者只是快取，可能失準）。
  -- ★ 目標值依帳號而定，形成固定的測試矩陣。
  for r in
    select m.id as member_id, m.org_id, m.display_name,
           case m.display_name
             when '測試01' then 1000
             when '測試02' then  500
             when '測試03' then  150
             when '測試04' then    0
             else p_reset_balance
           end
           - coalesce((
               select sum(tx.amount) from wallet_txns tx
                where tx.member_id = m.id
                  and tx.status = 'completed'), 0) as delta
      from members m
     where m.id = any(v_members)
  loop
    if r.delta <> 0 then
      insert into wallet_txns(org_id, member_id, type, amount, note)
      values (r.org_id, r.member_id, 'adjust'::txn_type, r.delta, '測試資料重置');
      v_wallets := v_wallets + 1;
    end if;

    -- 不論有沒有調整都重算一次快取 —— fix_wallet_balance_tx 是冪等的，
    -- 讓這支工具順便修復先前累積的快取失準。
    perform fix_wallet_balance_tx(r.org_id, r.member_id);
  end loop;

  -- 桌位不需要另外釋放：tables 沒有 status 欄位，
  -- 桌況是從 table_sessions 動態算出來的，上面把 session 設成 voided 就等於放掉桌位。

  return jsonb_build_object(
    'ok', true,
    'members',          array_length(v_members, 1),
    'sessions_voided',  v_sessions,
    'players_deleted',  v_players,
    'orders_total',     v_orders,
    'orders_voided',    v_orders_void,
    'topups_voided',    v_topup_void,
    'queues_deleted',   v_queues,
    'wallets_adjusted', v_wallets,
    'balance_preset',   '測試01=1000 / 測試02=500 / 測試03=150 / 測試04=0',
    'balance_fallback', p_reset_balance,
    'orders_note',      '訂單與儲值單不刪除（收過錢的不可刪），改為作廢；當日暢打因此會一併失效',
    'events_note',      'app_events 為 append-only 未刪除，分析走 v_real_app_events');
end $function$;

comment on function public.dev_reset_test_data_tx(bigint) is
  '測試資料重置（僅作用於 is_test 會員）。場次作廢、入座紀錄刪除、訂單與儲值單改為 void（不可刪但可作廢，當日暢打因此一併失效）、餘額重設為固定矩陣。⚠ 作廢不等於退款：不沖銷點數、不退現金。';

-- ============================================================
-- 驗證（單一 SELECT）
--   版本數 1、已含作廢訂單 true、已含作廢儲值單 true。
--   後三欄是**執行前**的現況，跑完重置腳本後應該都變 0。
-- ============================================================
select
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'dev_reset_test_data_tx')     as 版本數,
  (select pg_get_functiondef(p.oid) like '%update orders%set status = ''void''%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'dev_reset_test_data_tx'
      and p.prokind = 'f' limit 1)                                           as 已含作廢訂單,
  (select pg_get_functiondef(p.oid) like '%update topup_orders%set status = ''void''%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'dev_reset_test_data_tx'
      and p.prokind = 'f' limit 1)                                           as 已含作廢儲值單,
  (select count(*) from orders o join members m on m.id = o.member_id
    where m.is_test and o.status = 'paid')                                   as 執行前未作廢訂單,
  (select count(*) from topup_orders t join members m on m.id = t.member_id
    where m.is_test and t.status = 'paid')                                   as 執行前未作廢儲值單,
  (select count(*) from orders o
     join order_items oi on oi.order_id = o.id
     join products pr on pr.id = oi.product_id
     join members m on m.id = o.member_id
    where m.is_test and o.status = 'paid' and pr.sku = 'SVC-TBL-DAY'
      and (o.created_at at time zone 'Asia/Taipei')::date
        = (now() at time zone 'Asia/Taipei')::date)                          as 執行前有效暢打數;
