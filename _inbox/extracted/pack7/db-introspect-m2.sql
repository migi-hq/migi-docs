-- ============================================================
-- MIGI M2 POS · 資料庫現況盤點（唯讀，不會修改任何東西）
-- ------------------------------------------------------------
-- 用途：待辦 1~4 都要動到既有 RPC 與 table_sessions 的欄位／約束，
--       依照「不線上猜欄位」的規矩，先把現況撈回來再寫程式。
-- 用法：Supabase Dashboard → SQL Editor → New query → 整份貼上 → Run
--       只會回傳「一張表、三個欄位（sec / item / detail）」，
--       請整張結果複製回聊天室即可。
-- ============================================================

WITH fns AS (
  SELECT
    '1_function'::text                       AS sec,
    p.proname::text                          AS item,
    pg_get_functiondef(p.oid)::text          AS detail
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'list_tables_tx',        -- 待辦1：桌況卡有沒有帶 session_id／階段
      'get_session_tx',        -- 待辦2：還原座位要看它回什麼結構
      'open_session_tx',       -- 待辦3：session 的初始狀態與時間欄位
      'activate_session_tx',   -- 待辦1：帶桌後狀態怎麼變
      'join_session_tx',       -- 待辦2：paid_by／charged_points 寫入方式
      'calc_session_fee_tx',
      'settle_session_tx',     -- PENDING：確認目前空殼長什麼樣
      'dev_reset_test_data_tx' -- 待辦4：要修 'void' → 'voided'
    )
),
cols AS (
  SELECT
    '2_column'::text,
    (c.table_name || '.' || c.column_name)::text,
    (c.data_type
      || ' | null=' || c.is_nullable
      || ' | default=' || COALESCE(c.column_default, '-'))::text
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name IN ('table_sessions', 'session_players', 'tables')
),
cons AS (
  SELECT
    '3_constraint'::text,
    (rel.relname || '.' || con.conname)::text,
    pg_get_constraintdef(con.oid)::text
  FROM pg_constraint con
  JOIN pg_class rel ON rel.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = rel.relnamespace
  WHERE n.nspname = 'public'
    AND rel.relname IN ('table_sessions', 'session_players', 'tables')
),
ext AS (
  -- 待辦3：pg_cron 有沒有裝（沒裝的話要先在 Database → Extensions 開啟）
  SELECT '4_extension'::text, extname::text, extversion::text
  FROM pg_extension
  WHERE extname IN ('pg_cron', 'pg_net')
)
SELECT * FROM fns
UNION ALL SELECT * FROM cols
UNION ALL SELECT * FROM cons
UNION ALL SELECT * FROM ext
ORDER BY 1, 2;
