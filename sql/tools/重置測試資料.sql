-- ============================================================
-- 【日常重置】測試完就跑這一段
-- 維護指令，可重複執行，不是 migration。更新：2026-08-16
-- ------------------------------------------------------------
-- 做兩件事：
--   ① dev_reset_test_data_tx()
--      作廢測試會員入座的場次、刪除 session_players 與配桌報名、
--      餘額回到固定測試矩陣：
--          測試01=1000  餘額充足
--          測試02= 500  中等
--          測試03= 150  剛好一次配桌檯費（3將）—— 測邊界
--          測試04=   0  沒錢 —— 測現場儲值後折抵
--      **訂單不刪**：order_payments 有 trg_payments_no_delete，
--      外鍵是 RESTRICT，收過錢的訂單設計上就不可刪，靠 is_test 隔離。
--
--   ② cleanup_empty_sessions_tx(0)
--      作廢「開了但沒人入座」的場次。0 = 不管開多久立刻清
--      （排程平常跑 30 分鐘）。
--
-- 【順序不能反】
--   要先刪掉入座記錄，那些桌才會變成「無人入座」，②才清得到。
--   用 CASE 建立資料相依：CASE 的條件讀了①的回傳，
--   PostgreSQL 必須先算完①才能算②。
--   （兩個函式並列在 SELECT 裡，求值順序沒有保證。）
--
-- 【最後一欄每次都要看】
--   餘額流水相符：逐一比對每個測試帳號的 wallets.balance
--   是否等於它的 wallet_txns 加總。只要有一個對不上就是 false。
--   2026-08-16 就是靠這個發現測試04 累積到 19000 ——
--   當時餘額差額拿快取當基準算，而那個帳號根本沒有 wallets 列，
--   於是每跑一次加 1000，連續兩天沒人發現。
--
-- 【要臨時改單一帳號】
--   select dev_set_test_balance_tx('測試03', 0);
--
-- 【注意】
--   ② 不分門市，會清掉所有沒人入座的 open 場次。
--   目前七間店全是測試店所以無妨；日後有正式營運門市時不能再這樣無差別清。
-- ============================================================

with r1 as (
  select dev_reset_test_data_tx() as res
)
select
  res ->> 'ok'                        as 重置成功,
  res ->> 'members'                   as 測試會員數,
  res ->> 'sessions_voided'           as 作廢場次,
  res ->> 'players_deleted'           as 刪除入座記錄,
  res ->> 'orders_kept'               as 保留訂單數,
  res ->> 'wallets_adjusted'          as 調整錢包,

  (case when res is not null
        then cleanup_empty_sessions_tx(0) ->> 'voided' end)   as 回收空桌數,

  (case when res is not null then (
     select string_agg(m.display_name || '=' || w.balance, ' / '
                       order by m.display_name)
       from wallets w join members m on m.id = w.member_id
      where m.is_test = true) end)                            as 各帳號餘額,

  -- ★ 健康檢查：快取與流水對不上就是 false
  (case when res is not null then (
     select bool_and(w.balance = coalesce((
              select sum(tx.amount) from wallet_txns tx
               where tx.member_id = w.member_id
                 and tx.status = 'completed'), 0))
       from wallets w join members m on m.id = w.member_id
      where m.is_test = true) end)                            as 餘額流水相符
from r1;


-- ---------- 確認桌況（另外跑，上面那個查詢的快照看不到自己的異動）----------
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
