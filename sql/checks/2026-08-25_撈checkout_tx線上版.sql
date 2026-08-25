/* ============================================================
   撈 checkout_tx 的線上定義
   2026-08-25 · 唯讀

   為什麼要整份：
     2026-08-25 查出 checkout_tx 完全不碰桌次，
     所以快速結帳只需要一層 DEFINER 包裝，不必重寫結帳邏輯。
     但寫包裝之前必須確定三件事，而這三件事只有內文看得出來：

     ① 失敗時是 raise exception 還是回 { ok:false, reason }
        → 決定包裝層能不能靠 EXCEPTION 回滾儲值。
          猜錯的後果是「儲值成功、商品沒賣成」留下半筆帳
          （2026-08-16 在 pos_checkout_with_topup_tx 上踩過同一個坑）。
     ② 回傳的 JSON 有哪些鍵（前端要吃 new_balance / order_id / 單號）
     ③ orders.channel 由誰決定 —— 快速結帳應該是 'counter'

   ⚠ 硬規則 3：改既有函式一律先撈線上版，
     sql/applied/ 只是「當時交付的版本」，不是鏡像。
   ============================================================ */

select pg_get_functiondef(p.oid) as 定義
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'checkout_tx';
