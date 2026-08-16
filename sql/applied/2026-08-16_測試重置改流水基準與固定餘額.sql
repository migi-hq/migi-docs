-- ============================================================
-- dev_reset_test_data_tx：改用流水基準 + 各帳號固定起始餘額
-- ------------------------------------------------------------
-- ⚠️ 驗證段會**實際執行一次重置** ——
--    會作廢測試帳號開著的桌、刪掉入座紀錄與配桌報名。
--    跑之前確認不介意清掉目前的測試桌況。
--
-- ============================================================
-- 【改動一：餘額基準改用流水推導】
-- ============================================================
--   原本：p_reset_balance - coalesce(w.balance, 0)
--
--   看起來沒錯，但 **測試04 一直沒有 wallets 記錄**
--   （2026-08-16 才用觸發器修掉的那個 bug）。
--   於是 w.balance 是 null → coalesce 變 0 → delta 永遠 1000-0=1000，
--   跑一次加一千，跑了 19 次變成 19000。
--
--   而且它**看不出來**：fix_wallet_balance_tx 因為沒有 wallets 列所以什麼都沒做，
--   畫面顯示 0、流水卻在後面默默累積。直到錢包被建出來，
--   下一次重置時才終於重算，19 筆一次全部浮現。
--
--   → 改成拿 **wallet_txns 加總** 當基準。
--     這正是 M1 碰錢五條鐵則第 1 條：「餘額一律由流水推導，絕不直接設」。
--     我原本只做到「不直接 UPDATE 餘額」，卻拿快取當基準算差額 ——
--     **規則遵守了一半，另一半正是出事的那半。**
--     改完之後即使快取失準、甚至 wallets 列不存在，delta 仍然算得對。
--
-- ============================================================
-- 【改動二：各帳號固定起始餘額，形成測試矩陣】
-- ============================================================
--   | 帳號   | 餘額 | 這個數字要測什麼                          |
--   |--------|------|-------------------------------------------|
--   | 測試01 | 1000 | 餘額充足 —— 檯費、餐飲都能全額折抵        |
--   | 測試02 |  500 | 中等 —— 折得掉檯費但折不完一整桌消費      |
--   | 測試03 |  150 | **剛好等於一次配桌檯費（3 將）** ——        |
--   |        |      | 測「全折之後歸零」與 ptMax 的邊界         |
--   | 測試04 |    0 | 沒錢 —— 測現場儲值後能不能立刻折抵        |
--
--   名單外的測試帳號沿用參數 p_reset_balance（預設 1000）。
--
--   把名字寫死在函式裡並不漂亮，但這是開發工具，
--   而「每次重置後都回到同一組已知狀態」的價值遠大於那點彈性 ——
--   否則每次測試前都要先確認每個帳號現在有多少錢。
--
-- 【線上版來源】
--   dev_reset_test_data_tx(bigint) DEFINER，2026-08-16 以 pg_get_functiondef
--   撈出（硬規則 3），1 個版本。本檔只改錢包那一段，其餘一字未動。
--   簽名未變，不需 DROP。
-- ============================================================

CREATE OR REPLACE FUNCTION public.dev_reset_test_data_tx(p_reset_balance bigint DEFAULT 1000)
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

  -- ── 錢包 ──────────────────────────────────────────────
  -- 流水 append-only 不刪，補一筆 adjust 讓餘額回到起點，再用既有函式重算。
  -- 不直接 UPDATE wallets.balance —— 那會與 audit_wallet_balance 稽核衝突。
  --
  -- ★ 現況以**流水加總**為準，不是 wallets.balance（後者只是快取，可能失準）。
  -- ★ 目標值依帳號而定，形成固定的測試矩陣（見檔頭說明）。
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
    'orders_kept',      v_orders,
    'queues_deleted',   v_queues,
    'wallets_adjusted', v_wallets,
    'balance_preset',   '測試01=1000 / 測試02=500 / 測試03=150 / 測試04=0',
    'balance_fallback', p_reset_balance,
    'orders_note',      '訂單與付款為帳務資料不刪除，由 is_test 標記隔離',
    'events_note',      'app_events 為 append-only 未刪除，分析走 v_real_app_events');
end $function$;

COMMENT ON FUNCTION public.dev_reset_test_data_tx IS
  '重置測試資料：作廢場次、清入座與配桌、餘額回到固定測試矩陣'
  '（測試01=1000 / 02=500 / 03=150 / 04=0，其餘用參數值）。'
  '餘額差額以 wallet_txns 加總為基準，不看 wallets.balance 快取。';


-- ============================================================
-- 驗證（單一 SELECT）—— 會實際跑一次重置
-- ------------------------------------------------------------
-- 用 CASE 相依強制先跑完重置再查（SQL 不保證欄位求值順序）。
--
-- 期待：
--   各帳號餘額   測試01=1000 / 測試02=500 / 測試03=150 / 測試04=0
--   各帳號流水   與上面完全相同
--   餘額流水相符 true   ← 每次重置都該看這欄
-- ============================================================
with r as (
  select dev_reset_test_data_tx() as res
)
select
  res ->> 'wallets_adjusted'                                          as 調整筆數,

  (case when res is not null then (
     select string_agg(m.display_name || '=' || w.balance, ' / '
                       order by m.display_name)
       from wallets w join members m on m.id = w.member_id
      where m.is_test = true) end)                                    as 各帳號餘額,

  (case when res is not null then (
     select string_agg(m.display_name || '=' ||
              coalesce((select sum(tx.amount) from wallet_txns tx
                         where tx.member_id = m.id and tx.status = 'completed'), 0),
              ' / ' order by m.display_name)
       from members m where m.is_test = true) end)                    as 各帳號流水,

  (case when res is not null then (
     select bool_and(w.balance = coalesce((
              select sum(tx.amount) from wallet_txns tx
               where tx.member_id = w.member_id and tx.status = 'completed'), 0))
       from wallets w join members m on m.id = w.member_id
      where m.is_test = true) end)                                    as 餘額流水相符
from r;
