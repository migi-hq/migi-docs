-- ============================================================
-- 修正測試清理函式 + 空桌自動回收
--
-- 【尚未執行】
--
-- 【① 修正 dev_reset_test_data_tx】
--   先前版本把場次狀態寫成 'void'，但 constraint 只允許
--   open / completed / voided，執行時會拋 23514。
--
-- 【② 新增空桌自動回收】
--   開桌設定按下去就建立 session，店員若中途離開（未加任何客人），
--   該桌會卡在「使用中但 0 人」，桌位無法再開。
--   由排程定期作廢逾時且無人入座的場次。
-- ============================================================


-- ============================================================
-- ① 修正 dev_reset_test_data_tx
-- ============================================================
CREATE OR REPLACE FUNCTION public.dev_reset_test_data_tx(
  p_reset_balance bigint DEFAULT 1000)
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

  -- 先收掉未結束的桌，避免桌位卡在忙碌狀態
  -- status 允許值僅 open / completed / voided
  update table_sessions
     set status = 'voided', ended_at = now()
   where status = 'open'
     and id in (select session_id from session_players
                 where member_id = any(v_members));
  get diagnostics v_sessions = row_count;

  delete from session_players where member_id = any(v_members);
  get diagnostics v_players = row_count;

  delete from orders where member_id = any(v_members);
  get diagnostics v_orders = row_count;

  delete from match_queue_members where member_id = any(v_members);
  delete from match_queues where opened_by = any(v_members);
  get diagnostics v_queues = row_count;

  delete from app_notifications where member_id = any(v_members);
  delete from buddy_invites
   where from_member = any(v_members) or to_member = any(v_members);

  -- 行為事件不刪：app_events 為 append-only。
  -- 測試事件靠 is_test 標記 + v_real_app_events 過濾。

  -- 錢包：append-only 不刪流水，補一筆調整讓餘額回到起點
  insert into wallet_txns(org_id, member_id, kind, points, note, created_at)
  select m.org_id, m.id, 'adjust',
         p_reset_balance - coalesce(m.points_balance, 0),
         '測試資料重置', now()
    from members m
   where m.id = any(v_members)
     and coalesce(m.points_balance, 0) <> p_reset_balance;

  update members set points_balance = p_reset_balance
   where id = any(v_members);

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


-- ============================================================
-- ② 空桌自動回收
-- ============================================================
CREATE OR REPLACE FUNCTION public.cleanup_empty_sessions_tx(
  p_idle_minutes int DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int := 0;
begin
  -- 開桌後逾時仍無任何人入座 → 視為店員誤開或中途離開，作廢並釋放桌位
  update table_sessions
     set status = 'voided', ended_at = now()
   where status = 'open'
     and started_at < now() - make_interval(mins => p_idle_minutes)
     and not exists (
       select 1 from session_players sp
        where sp.session_id = table_sessions.id
          and sp.left_at is null);
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'voided', v_n,
                            'idle_minutes', p_idle_minutes);
end $function$;

COMMENT ON FUNCTION public.cleanup_empty_sessions_tx IS
  '作廢逾時且無人入座的場次，避免桌位卡在使用中。由 pg_cron 每 10 分鐘呼叫';


-- ============================================================
-- ③ 排程（需先啟用 pg_cron 擴充）
-- ============================================================
-- CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'cleanup-empty-sessions',
  '*/10 * * * *',
  $$SELECT cleanup_empty_sessions_tx(30)$$
);


-- ============================================================
-- ④ 驗證
-- ============================================================
SELECT '① dev_reset_test_data_tx' AS 項目,
       (SELECT CASE WHEN prosrc LIKE '%voided%' AND prosrc NOT LIKE '%''void''%'
               THEN '✓ 已修正' ELSE '✗ 仍有 void' END
          FROM pg_proc WHERE proname = 'dev_reset_test_data_tx' LIMIT 1) AS 結果
UNION ALL
SELECT '② cleanup_empty_sessions_tx',
       (SELECT CASE WHEN count(*) > 0 THEN '✓ 已建立' ELSE '✗' END::text
          FROM pg_proc WHERE proname = 'cleanup_empty_sessions_tx')
UNION ALL
SELECT '③ 目前卡住的空場次數',
       (SELECT count(*)::text FROM table_sessions s
         WHERE s.status = 'open'
           AND NOT EXISTS (SELECT 1 FROM session_players sp
                            WHERE sp.session_id = s.id AND sp.left_at IS NULL));


-- ============================================================
-- 手動立即清一次（不等排程）
-- ============================================================
-- SELECT cleanup_empty_sessions_tx(0);   -- 0 分鐘 = 立刻清掉所有無人空桌
