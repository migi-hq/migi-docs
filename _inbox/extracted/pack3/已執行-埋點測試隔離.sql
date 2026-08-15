-- ============================================================
-- 埋點資料的測試隔離
--
-- 【問題】四個測試帳號的行為事件與真實會員混在同一張表，
--   未來做漏斗、留存、客單價分析時會被灌水，且看不出哪些是假的。
--
-- 【本檔內容】
--   ① app_events 加 is_test，寫入時從 members 繼承
--   ② 既有歷史事件回填標記
--   ③ v_real_app_events / v_real_wallet_txns 乾淨資料 view
--   ④ 測試資料清理函式（隨時可重置測試環境）
--
-- 【外部工具（GA4／Meta）的隔離不在這裡】
--   那些收的是前端事件、不看資料庫旗標，必須在 analytics.js
--   加閘門擋住測試帳號，見同批交付的前端改動。
-- ============================================================


-- ============================================================
-- ① app_events 加 is_test
-- ============================================================
ALTER TABLE app_events
  ADD COLUMN IF NOT EXISTS is_test boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN app_events.is_test IS
  '是否為測試帳號產生的事件。寫入時由 log_app_event_tx 從 members.is_test 繼承；分析一律走 v_real_app_events';

CREATE INDEX IF NOT EXISTS idx_app_events_real
  ON app_events(event, created_at DESC) WHERE is_test = false;


-- ============================================================
-- ② 歷史事件不回填
--    app_events 有 append-only 觸發器，禁止 UPDATE/DELETE。
--    因此不改既有列，改由下方 v_real_app_events 動態 join
--    members.is_test 過濾——新舊資料都能正確排除，不必動原表。
-- ============================================================


-- ============================================================
-- ③ log_app_event_tx：寫入時繼承 is_test
--    參數未變動，用 CREATE OR REPLACE 即可（無需 DROP）
-- ============================================================
CREATE OR REPLACE FUNCTION public.log_app_event_tx(
  p_org_id uuid,
  p_member_id uuid,
  p_event text,
  p_props jsonb DEFAULT '{}'::jsonb,
  p_client_ts timestamptz DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_is_test boolean := false;
begin
  -- 測試帳號的事件一律標記，避免污染營運分析
  if p_member_id is not null then
    select coalesce(is_test, false) into v_is_test
      from members where id = p_member_id;
  end if;

  insert into app_events(org_id, member_id, event, props, client_ts, is_test)
  values (p_org_id, p_member_id, p_event, coalesce(p_props, '{}'::jsonb),
          p_client_ts, coalesce(v_is_test, false));
end $function$;


-- ============================================================
-- ④ 乾淨資料 view —— 所有分析查詢一律走這兩張
-- ============================================================
-- 雙重過濾：新事件看自身 is_test 欄位（快），
-- 舊事件（欄位加上去之前寫入的）則 join members 判斷
CREATE OR REPLACE VIEW v_real_app_events AS
  SELECT e.* FROM app_events e
   WHERE e.is_test = false
     AND NOT EXISTS (
       SELECT 1 FROM members m
        WHERE m.id = e.member_id AND m.is_test = true);

COMMENT ON VIEW v_real_app_events IS
  '排除測試帳號的行為事件。做漏斗、留存、轉換分析時用這張，不要直接查 app_events';

-- wallet_txns 為 append-only 且無 is_test 欄位，改用 view 過濾
CREATE OR REPLACE VIEW v_real_wallet_txns AS
  SELECT w.* FROM wallet_txns w
   WHERE NOT EXISTS (
     SELECT 1 FROM members m
      WHERE m.id = w.member_id AND m.is_test = true);

COMMENT ON VIEW v_real_wallet_txns IS
  '排除測試帳號的錢包流水。跨會員的金流統計走這張';


-- ============================================================
-- ⑤ 測試資料清理
--    把四個測試帳號的狀態重置成乾淨起點，可反覆執行。
--    只動 is_test=true 的資料，碰不到任何真實會員。
-- ============================================================
CREATE OR REPLACE FUNCTION public.dev_reset_test_data_tx(
  p_reset_balance bigint DEFAULT 1000)   -- 測試帳號重置後的點數
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_members uuid[];
  v_sessions int := 0; v_orders int := 0;
  v_players int := 0; v_queues int := 0;
begin
  select array_agg(id) into v_members from members where is_test = true;
  if v_members is null or array_length(v_members, 1) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_test_members');
  end if;

  -- 場次與入座：先收掉未結束的桌，避免桌位卡在忙碌狀態
  update table_sessions
     set status = 'void', closed_at = now()
   where status = 'open'
     and id in (select session_id from session_players
                 where member_id = any(v_members));
  get diagnostics v_sessions = row_count;

  delete from session_players where member_id = any(v_members);
  get diagnostics v_players = row_count;

  -- 訂單（含明細、付款、發票草稿由外鍵連動）
  delete from orders where member_id = any(v_members);
  get diagnostics v_orders = row_count;

  -- 配桌房間與報名
  delete from match_queue_members where member_id = any(v_members);
  delete from match_queues where opened_by = any(v_members);
  get diagnostics v_queues = row_count;

  -- 行為事件不刪：app_events 為 append-only（帳務稽核用）。
  -- 測試事件靠 is_test 標記 + v_real_app_events 過濾，不影響分析。

  -- 通知與社交狀態
  delete from app_notifications where member_id = any(v_members);
  delete from buddy_invites
   where from_member = any(v_members) or to_member = any(v_members);

  -- 錢包：append-only 不刪流水，改補一筆調整讓餘額回到起點
  insert into wallet_txns(org_id, member_id, kind, points, note, created_at)
  select m.org_id, m.id, 'adjust',
         p_reset_balance - coalesce(m.points_balance, 0),
         '測試資料重置', now()
    from members m
   where m.id = any(v_members)
     and coalesce(m.points_balance, 0) <> p_reset_balance;

  update members set points_balance = p_reset_balance
   where id = any(v_members);

  -- 釋放桌位
  update tables set status = 'idle'
   where id in (select table_id from table_sessions
                 where status = 'void' and closed_at > now() - interval '1 minute');

  return jsonb_build_object(
    'ok', true,
    'members', array_length(v_members, 1),
    'sessions_voided', v_sessions,
    'players_deleted', v_players,
    'orders_deleted', v_orders,
    'queues_deleted', v_queues,
    'events_note', 'app_events 為 append-only 未刪除，分析走 v_real_app_events',
    'balance_reset_to', p_reset_balance);
end $function$;

COMMENT ON FUNCTION public.dev_reset_test_data_tx IS
  '重置四個測試帳號的所有資料，可反覆執行。正式環境請勿授權給一般角色';


-- ============================================================
-- ⑥ 驗證
-- ============================================================
SELECT '① app_events.is_test 欄位' AS 項目,
       (SELECT CASE WHEN count(*) > 0 THEN '✓' ELSE '✗' END::text
        FROM information_schema.columns
        WHERE table_name = 'app_events' AND column_name = 'is_test') AS 結果
UNION ALL
SELECT '② 測試事件筆數（含歷史，由 view 排除）',
       (SELECT count(*)::text FROM app_events e JOIN members m ON m.id = e.member_id
         WHERE m.is_test = true)
UNION ALL
SELECT '③ 乾淨事件筆數（分析用）',
       (SELECT count(*)::text FROM v_real_app_events)
UNION ALL
SELECT '④ 測試會員數',
       (SELECT count(*)::text FROM members WHERE is_test = true)
UNION ALL
SELECT '⑤ v_real_wallet_txns',
       (SELECT CASE WHEN count(*) > 0 THEN '✓ 已建立' ELSE '✗' END::text
        FROM information_schema.views WHERE table_name = 'v_real_wallet_txns')
UNION ALL
SELECT '⑥ dev_reset_test_data_tx',
       (SELECT CASE WHEN count(*) > 0 THEN '✓ 已建立' ELSE '✗' END::text
        FROM pg_proc WHERE proname = 'dev_reset_test_data_tx');


-- ============================================================
-- 用法
-- ============================================================
-- 重置測試環境（測到一半想從頭來過時執行）：
--   SELECT dev_reset_test_data_tx();
--   SELECT dev_reset_test_data_tx(5000);   -- 順便把點數設成 5000
--
-- 分析查詢一律走 view：
--   SELECT event, count(*) FROM v_real_app_events
--    WHERE created_at > now() - interval '7 days' GROUP BY 1;
-- ============================================================
