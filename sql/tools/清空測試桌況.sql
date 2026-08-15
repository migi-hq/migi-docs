-- ============================================================
-- 一次清空測試桌況（可重複執行的維護指令，不是 migration）
-- 產生日期：2026-08-15
--
-- 用途：測試完把桌況清乾淨，讓所有桌回到 idle。
--       兩步驟合成單一 SELECT，SQL Editor 一次就能看到完整結果。
--
--   ① dev_reset_test_data_tx(1000)
--      作廢有測試會員入座的場次、刪除 session_players 與 orders、
--      補一筆 adjust 讓測試帳號餘額回到 1000 點。
--      （錢包是 append-only，用沖正而非刪除）
--
--   ② cleanup_empty_sessions_tx(0)
--      作廢「開了但沒人入座」的場次。參數 0 = 不管開多久立刻清
--      （排程平常跑的是 30 分鐘）。
--
-- 【順序不能反】
--   要先刪掉入座記錄，那些桌才會變成「無人入座」，②才清得到。
--   這裡用 CASE 建立資料相依：CASE 的條件讀了 ①的回傳，
--   所以 PostgreSQL 必須先算完①才能算②，順序有保證。
--   （直接把兩個函式並列在 SELECT 的參數裡，求值順序沒有保證。）
--
-- 【注意】
--   ② 不分門市，會清掉所有沒人入座的 open 場次。
--   目前七間店全是測試店所以無妨；日後有正式營運的門市時，
--   不能再這樣無差別清 —— 那時要加門市參數，或只靠排程的 30 分鐘門檻。
-- ============================================================

with r1 as (
  select dev_reset_test_data_tx(1000) as reset_result
)
select
  reset_result ->> 'ok'               as 重置成功,
  reset_result ->> 'members'          as 測試會員數,
  reset_result ->> 'sessions_voided'  as 重置作廢場次,
  reset_result ->> 'players_deleted'  as 刪除入座記錄,
  reset_result ->> 'orders_deleted'   as 刪除訂單,
  reset_result ->> 'wallets_adjusted' as 調整錢包,
  reset_result ->> 'balance_reset_to' as 餘額歸位至,
  -- 條件讀了 reset_result，藉此強制①先執行
  (case when reset_result is not null
        then cleanup_empty_sessions_tx(0) ->> 'voided'
   end)                               as 回收空桌數
from r1;


-- ---------- 確認（另外跑，本查詢的快照看不到上面的異動）----------
-- select st.name as 門市, t.label as 桌號, s.status as 狀態,
--        (select count(*) from session_players sp
--          where sp.session_id = s.id and sp.left_at is null) as 在座人數
-- from table_sessions s
-- join tables t  on t.id = s.table_id
-- join stores st on st.id = s.store_id
-- where s.status = 'open'
-- order by st.name, t.label;
--
-- 回 0 列 = 全部清乾淨，桌況頁重新整理後所有桌變回 idle。
