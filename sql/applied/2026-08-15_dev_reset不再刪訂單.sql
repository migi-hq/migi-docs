-- ============================================================
-- dev_reset_test_data_tx：不再刪除訂單，改為保留 + 靠 is_test 隔離
-- 產生日期：2026-08-15
--
-- 【錯誤現象】
--   ERROR 23503: update or delete on table "orders" violates foreign key
--   constraint "order_items_order_id_fkey" on table "order_items"
--   CONTEXT: SQL statement "delete from orders where member_id = any(v_members)"
--
-- 【根因：刪訂單這個動作本身就是錯的方向】
--   查證外鍵與觸發器（2026-08-15）：
--     order_items    → orders   on delete RESTRICT
--     order_payments → orders   on delete RESTRICT
--     order_payments 另有觸發器 trg_payments_no_delete 禁止刪除
--     member_coupons → orders   on delete NO ACTION
--   付款記錄不能刪、外鍵又是 RESTRICT，**只要那張訂單收過錢就永遠刪不掉**。
--   這不是缺陷，是刻意的財務設計，與 wallet_txns 的 append-only 同一套原則。
--
--   而且刪訂單對「清桌況」根本沒必要 —— 桌況只看 table_sessions.status，
--   把場次設成 voided 就已經放掉桌位了。
--
-- 【為什麼原版寫了刪訂單】
--   原版註解寫「訂單（含明細、付款、發票草稿由外鍵連動）」，
--   假設外鍵是 CASCADE。這個假設從來沒被驗證過 ——
--   原版在更前面就會拋 42703（closed_at 欄位不存在），根本走不到這一行。
--   2026-08-14 重寫時我修好了欄位名，卻把這個未經驗證的假設照抄了。
--
--   這是硬規則 7 的第二個實例：函式從未成功執行過，
--   代表它的每一行邏輯都從未被驗證，不能因為「看起來合理」就沿用。
--
-- 【處置】
--   拿掉刪除訂單那一段。訂單與付款保留，由 trg_orders_is_test 自動標記
--   （orders 觸發器清單已確認有這支），統計時靠 is_test 與 v_real_* 排除。
--   回傳值把 orders_deleted 換成 orders_kept，明確說明保留了幾張，
--   避免日後有人以為「重置」會清帳。
--
-- 簽名不變（p_reset_balance bigint），CREATE OR REPLACE 即可，不需要 DROP。
-- ============================================================

CREATE OR REPLACE FUNCTION public.dev_reset_test_data_tx(
  p_reset_balance bigint DEFAULT 1000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_members  uuid[];
  v_sessions int := 0;
  v_players  int := 0;
  v_orders   int := 0;
  v_queues   int := 0;
  v_wallets  int := 0;
  r          record;
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

  -- 訂單：**不刪**。order_payments 有 trg_payments_no_delete 禁止刪除，
  -- 且 order_items / order_payments 的外鍵是 RESTRICT ——
  -- 收過錢的訂單在設計上就不可刪。改為統計保留張數，靠 is_test 隔離。
  select count(*) into v_orders
    from orders where member_id = any(v_members);

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

  -- 錢包：流水 append-only 不刪，補一筆 adjust 讓餘額回到起點，再用既有函式重算。
  -- 不直接 UPDATE wallets.balance —— 那會與 audit_wallet_balance 稽核衝突。
  for r in
    select m.id as member_id, m.org_id,
           p_reset_balance - coalesce(w.balance, 0) as delta
      from members m
      left join wallets w on w.member_id = m.id
     where m.id = any(v_members)
       and coalesce(w.balance, 0) <> p_reset_balance
  loop
    insert into wallet_txns(org_id, member_id, type, amount, note)
    values (r.org_id, r.member_id, 'adjust'::txn_type, r.delta, '測試資料重置');

    perform fix_wallet_balance_tx(r.org_id, r.member_id);
    v_wallets := v_wallets + 1;
  end loop;

  -- 桌位不需要另外釋放：tables 沒有 status 欄位，
  -- 桌況是從 table_sessions 動態算出來的，上面把 session 設成 voided 就等於放掉桌位。

  return jsonb_build_object(
    'ok', true,
    'members',          array_length(v_members, 1),
    'sessions_voided',  v_sessions,
    'players_deleted',  v_players,
    'orders_kept',      v_orders,
    'queues_deleted',   v_queues,
    'wallets_adjusted', v_wallets,
    'balance_reset_to', p_reset_balance,
    'orders_note',      '訂單與付款為帳務資料不刪除，由 is_test 標記隔離',
    'events_note',      'app_events 為 append-only 未刪除，分析走 v_real_app_events');
end $function$;

COMMENT ON FUNCTION public.dev_reset_test_data_tx IS
  '重置 is_test 會員的測試資料。2026-08-15 修正：不再刪除訂單（order_payments 禁止刪除且外鍵為 RESTRICT），改為保留並靠 is_test 隔離。';


-- ---------- 驗證（單一 SELECT）----------
select '函式已更新' as 項目,
       case when prosrc like '%orders_kept%'
                 and prosrc not like '%delete from orders%'
            then '✓' else '✗ 仍是舊版' end as 結果
from pg_proc where proname = 'dev_reset_test_data_tx'
union all
select '版本數', count(*)::text
from pg_proc where proname = 'dev_reset_test_data_tx';

-- 跑完期待：函式已更新 = ✓、版本數 = 1
-- 之後即可執行 sql/tools/清空測試桌況.sql
