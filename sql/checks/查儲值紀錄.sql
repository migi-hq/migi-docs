-- ============================================================
-- 查儲值紀錄（唯讀）
-- ------------------------------------------------------------
-- 用途：驗證 POS 的「儲值 + 結帳一次完成」有沒有真的進資料庫。
--       重點不只是「有沒有多一筆」，而是**四個地方要對得起來**：
--         ① topup_orders  儲值單本身
--         ② wallet_txns   本金那筆（type='topup'、counter_account='liability'）
--         ③ wallet_txns   贈點那筆（type='adjust'、counter_account='promo_expense'）
--         ④ wallets       餘額快取
--       只看①會漏掉「單建了但點沒進去」這種最難查的狀況。
--
-- 依踩過的坑第 19 條：SQL Editor 一次跑多個 SELECT 只顯示最後一個，
-- 所以本檔只有一個 SELECT。
-- ============================================================

select
  t.created_at                                  as 時間,
  m.display_name                                as 會員,
  t.topup_no                                    as 儲值單號,
  t.points                                      as 本金點,
  t.bonus_points                                as 贈點,
  t.amount_twd                                  as 實收元,
  t.pay_method                                  as 付款方式,
  t.status                                      as 狀態,

  -- ② 本金流水：金額應等於 points
  (select tx.amount from wallet_txns tx
    where tx.ref_table = 'topup_orders' and tx.ref_id = t.id
      and tx.type = 'topup')                    as 本金流水,

  -- ③ 贈點流水：應等於 bonus_points（沒贈點時為 null）
  (select tx.amount from wallet_txns tx
    where tx.ref_table = 'topup_orders' and tx.ref_id = t.id
      and tx.type = 'adjust')                   as 贈點流水,

  -- ④ 目前餘額快取
  (select w.balance from wallets w
    where w.member_id = t.member_id)            as 目前餘額,

  -- ⑤ 該會員所有流水加總。與「目前餘額」不符就是快取失準
  --   （wallet_txns 是 append-only，餘額一律由流水推導）
  (select coalesce(sum(tx.amount), 0) from wallet_txns tx
    where tx.member_id = t.member_id
      and tx.status = 'completed')              as 流水加總,

  t.idempotency_key                             as 冪等鍵

from topup_orders t
left join members m on m.id = t.member_id
order by t.created_at desc
limit 20;
