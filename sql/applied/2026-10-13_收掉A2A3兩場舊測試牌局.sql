-- ============================================================================
-- 2026-10-13 收掉高雄自由店 A2、A3 兩場舊測試牌局（使用者：「POS A2 跟 A3 有人，先全部淨空」）
--
-- 查過（2026-10-13）：兩場都是測試牌局、只有「測試02」一個人、沒有開過將、沒有記過任何一局
--   A2  c0e55ea4-e000-4e40-b951-07c7b1f93819   2026-08-25 開的
--   A3  99a64e28-569f-40e6-ab58-7428234b41ed   2026-09-09 開的
-- ⇒ 走正常的收桌（settle_session_tx，跟 POS 按「收桌」同一支），不直接改資料表：
--   關場次、放桌、放掉平板、把在座的人寫 left_at 都由它做。
-- ⚠ 多一道保險：只收「還開著、而且是測試牌局」的這兩場；ID 對不上或狀態變了就不動。
-- ⚠ 驗證段不用 raise 印訊息（硬規則 1.8）
-- ============================================================================
do $$
declare r jsonb; v_msg text := ''; v_id uuid;
begin
  foreach v_id in array array['c0e55ea4-e000-4e40-b951-07c7b1f93819', '99a64e28-569f-40e6-ab58-7428234b41ed']::uuid[] loop
    if exists (select 1 from table_sessions where id = v_id and status = 'open' and is_test and deleted_at is null) then
      r := public.settle_session_tx(v_id, null, false);
      v_msg := v_msg || E'\n' || v_id || ' → ' || coalesce(r ->> 'ok', '?') || coalesce(' ' || (r ->> 'message'), '');
    else
      v_msg := v_msg || E'\n' || v_id || ' → 沒動（已經不是開著的測試牌局）';
    end if;
  end loop;
  perform set_config('migi.clear_a2a3', ltrim(v_msg, E'\n'), true);
end $$;

-- ============================================================================
-- 驗證（單一 SELECT）
-- ============================================================================
select concat_ws(E'\n',
  coalesce(nullif(current_setting('migi.clear_a2a3', true), ''), '（沒有執行訊息）'),
  case when not exists (select 1 from table_sessions s join tables t on t.id = s.table_id join stores st on st.id = s.store_id
                         where s.status = 'open' and s.deleted_at is null and t.label in ('A2', 'A3') and st.name = 'MIGI 高雄自由店')
       then '✅ 高雄自由店 A2、A3 都空了' else '🔴 A2 或 A3 還有開著的牌局' end,
  case when (select count(*) from table_sessions where id in ('c0e55ea4-e000-4e40-b951-07c7b1f93819', '99a64e28-569f-40e6-ab58-7428234b41ed')
              and status = 'completed' and ended_at is not null) = 2
       then '✅ 兩場都是「已收桌」、有結束時間' else '🔴 有一場沒收好' end,
  case when not exists (select 1 from session_players where session_id in ('c0e55ea4-e000-4e40-b951-07c7b1f93819', '99a64e28-569f-40e6-ab58-7428234b41ed') and left_at is null)
       then '✅ 測試02 已經離座（不再掛在任何一桌）' else '🔴 還有人在座' end,
  '目前還開著的牌局：' || coalesce((select string_agg(st.name || ' ' || t.label, '、') from table_sessions s join tables t on t.id = s.table_id join stores st on st.id = s.store_id
                                   where s.status = 'open' and s.deleted_at is null), '沒有')
) as "驗證";
