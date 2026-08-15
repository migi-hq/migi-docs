-- ============================================================
-- ① 重寫 dev_reset_test_data_tx（原版從未成功執行過）
-- ② 新增 cleanup_empty_sessions_tx 空桌自動回收 + pg_cron 排程
--
-- 產生日期：2026-08-14
-- 取代：_inbox 內的「待執行-修正清理函式與空桌回收.sql」（該版仍有多處欄位錯誤）
--
-- 【為什麼要重寫，不是小修】
--   線上現存的 dev_reset_test_data_tx 有六處對不上實際 schema：
--     closed_at            → 實際是 ended_at
--     match_queue_members  → 實際是 match_queue_players
--     buddy_invites.from_member / to_member → 實際是 inviter_id / invitee_id
--     wallet_txns.kind / points             → 實際是 type / amount
--     members.points_balance                → 不存在，餘額在 wallets.balance
--     tables.status = 'idle'                → tables 沒有 status 欄位
--   第一個 UPDATE 就會拋 42703，所以它從建立以來一次都沒跑成功過。
--
-- 【簽名未變更】
--   dev_reset_test_data_tx(bigint) 簽名與線上相同，CREATE OR REPLACE 不會產生多載。
--   cleanup_empty_sessions_tx 為全新函式。故本檔不需要 DROP FUNCTION。
--
-- 【欄位依據】
--   2026-08-14 以 information_schema / pg_constraint 唯讀盤點確認，見 docs/01-資料庫/db-現況快照.md
-- ============================================================


-- ============================================================
-- ① dev_reset_test_data_tx —— 重置測試帳號資料
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
  v_org      uuid;
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

  delete from session_players where member_id = any(v_members);
  get diagnostics v_players = row_count;

  -- 訂單（明細、付款、發票草稿由外鍵連動）
  delete from orders where member_id = any(v_members);
  get diagnostics v_orders = row_count;

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
    v_org := r.org_id;
  end loop;

  -- 桌位不需要另外釋放：tables 沒有 status 欄位，
  -- 桌況是從 table_sessions 動態算出來的，上面把 session 設成 voided 就等於放掉桌位。

  return jsonb_build_object(
    'ok', true,
    'members',          array_length(v_members, 1),
    'sessions_voided',  v_sessions,
    'players_deleted',  v_players,
    'orders_deleted',   v_orders,
    'queues_deleted',   v_queues,
    'wallets_adjusted', v_wallets,
    'balance_reset_to', p_reset_balance,
    'events_note',      'app_events 為 append-only 未刪除，分析走 v_real_app_events');
end $function$;

COMMENT ON FUNCTION public.dev_reset_test_data_tx IS
  '重置 is_test 會員的測試資料。2026-08-14 依實際 schema 重寫，原版有六處欄位錯誤從未執行成功。';


-- ============================================================
-- ② cleanup_empty_sessions_tx —— 空桌自動回收
--
-- 情境：開桌設定按下去就建立 session，店員中途離開（未加任何客人），
--       該桌會卡在「使用中但 0 人」，桌位無法再開。
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
  update table_sessions ts
     set status = 'voided', ended_at = now()
   where ts.status = 'open'
     -- started_at 目前皆有值，但保險起見退回 created_at，
     -- 避免任一為 null 時條件恆為 null 而靜默失效
     and coalesce(ts.started_at, ts.created_at) < now() - make_interval(mins => p_idle_minutes)
     and not exists (
       select 1 from session_players sp
        where sp.session_id = ts.id
          and sp.left_at is null);
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'voided', v_n, 'idle_minutes', p_idle_minutes);
end $function$;

COMMENT ON FUNCTION public.cleanup_empty_sessions_tx IS
  '作廢逾時且無人入座的場次，避免桌位卡在使用中。由 pg_cron 每 10 分鐘呼叫。';


-- ============================================================
-- ③ 排程（pg_cron 已確認啟用）
--    先解除同名排程再建立，讓本檔可重複執行
-- ============================================================
do $$
begin
  perform cron.unschedule('cleanup-empty-sessions');
exception when others then
  null;  -- 尚未建立過，忽略
end $$;

select cron.schedule(
  'cleanup-empty-sessions',
  '*/10 * * * *',
  $$select cleanup_empty_sessions_tx(30)$$
);


-- ============================================================
-- ④ 驗證（跑完看這三列）
-- ============================================================
select '① dev_reset_test_data_tx 已修正' as 項目,
       (select case when prosrc like '%voided%'
                     and prosrc not like '%closed_at%'
                     and prosrc not like '%match_queue_members%'
                    then '✓' else '✗ 仍是舊版' end
          from pg_proc where proname = 'dev_reset_test_data_tx' limit 1) as 結果
union all
select '② cleanup_empty_sessions_tx 已建立',
       (select case when count(*) > 0 then '✓' else '✗' end::text
          from pg_proc where proname = 'cleanup_empty_sessions_tx')
union all
select '③ 排程已註冊',
       (select case when count(*) > 0 then '✓ ' || max(schedule) else '✗' end
          from cron.job where jobname = 'cleanup-empty-sessions')
union all
select '④ 目前卡住的空場次數',
       (select count(*)::text from table_sessions s
         where s.status = 'open'
           and not exists (select 1 from session_players sp
                            where sp.session_id = s.id and sp.left_at is null));


-- ============================================================
-- 手動立即清一次（不等排程）—— 需要時再取消註解
-- ============================================================
-- select cleanup_empty_sessions_tx(0);   -- 0 分鐘 = 立刻清掉所有無人空桌
