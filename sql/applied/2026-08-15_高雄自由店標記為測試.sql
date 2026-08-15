-- ============================================================
-- 把 MIGI 高雄自由店標記為測試門市，並回填既有資料
-- 產生日期：2026-08-15
--
-- 【依據：2026-08-15 的裁決】
--   兩份文件原本互相矛盾：
--     A. sql/applied/門市真實資料.sql —— 高雄自由店是「第一家真門市」，
--        id 維持 seed 的 22222222-…（因為已有 9 張表以 on delete restrict 綁著它）
--     B. 決策紀錄「上線前必做」#2 —— 砍掉測試 org（11111111-…），
--        走正式建店流程生正式 org
--   砍掉 org 的話 A 那間「真門市」跟著陪葬，兩者不可能同時成立。
--
--   **已裁決採用 B**：整個 org 11111111 都是測試資料，
--   底下沒有任何正式門市。高雄自由店是 M0 seed 的示範店，
--   後來被改成寫實的名稱與地址，但性質仍是測試資料。
--   → A 的「第一家真門市」說法作廢，該檔僅保留為歷史紀錄。
--
-- 【為什麼現在就要標】
--   所有開發測試都在這間店進行（14 張 A/B/C 桌）。
--   is_test 由觸發器 set_is_test_from_store() 依門市帶入，
--   門市標 false → 測試產生的訂單與場次全部標成非測試，
--   混進營運數據且事後難以辨識。
--
--   目前的實際效果是反向的：六間標了 test 的示範店被 v_real_* 濾掉，
--   唯一沒標的高雄自由店反而被當成真實數據留下 ——
--   剛好把最不真實的那一份當成真的。
--
-- 【安全性確認（2026-08-15 以 pg_get_functiondef 查證）】
--   list_stores_tx 直接查 stores 表，只過濾 org_id / is_active / deleted_at，
--   不看 is_test、也不用 v_real_stores。
--   → 改這個旗標不會讓 POS 的門市選單變空，POS 照常可用。
--
-- 【觸發器不會追溯】
--   set_is_test_from_store() 只在寫入當下帶值，
--   所以旗標改完必須回填既有資料，否則之前的測試記錄仍標成非測試。
-- ============================================================


-- ---------- ① 門市旗標（七間全部視為測試）----------
update stores
   set is_test = true
 where id = '22222222-2222-2222-2222-222222222222'
   and is_test = false;


-- ---------- ② 回填既有資料 ----------
-- 只需回填這間；其餘六間寫入時就已由觸發器標對。
--
-- 不含 session_players —— 那張表沒有 is_test 欄位
--   （文件寫「orders、table_sessions、session_players 有 is_test」是錯的，
--     2026-08-14 盤點確認只有前兩者）。
-- 不含 wallet_txns —— 它也沒有 is_test 欄位，
--   v_real_wallet_txns 是靠 member 是否為測試帳號過濾。

update table_sessions
   set is_test = true
 where store_id = '22222222-2222-2222-2222-222222222222'
   and is_test = false;

update orders
   set is_test = true
 where store_id = '22222222-2222-2222-2222-222222222222'
   and is_test = false;


-- ---------- ③ 驗證（單一 SELECT）----------
select '門市' as 類別, s.name as 項目,
       case when s.is_test then '★測試' else '⚠ 仍是正式' end as 結果
from stores s
union all
select '場次未標記數', '全庫', count(*)::text
from table_sessions where is_test = false
union all
select '訂單未標記數', '全庫', count(*)::text
from orders where is_test = false
order by 1, 2;

-- 跑完期待：七間門市全部「★測試」，場次與訂單的未標記數皆為 0。
-- 若不為 0，代表還有其他門市以外來源的資料，貼回來我看。


-- ============================================================
-- 【連帶待辦，本檔不處理】
--
-- 1. members 只有四個測試帳號標了 is_test，其餘會員仍是 false。
--    既然整個 org 都要砍，這些會員也不是真實客戶。
--    要不要一併標記？影響 v_real_members 變成空 ——
--    以「尚未開始營運」的現況而言那才是正確狀態。
--    但若裡面有預先建檔的真實名單就不能動，需要你確認。
--
-- 2. 沒有 v_real_orders / v_real_table_sessions 檢視表。
--    CLAUDE.md 寫「做報表一律查 v_real_*」，但訂單類無 view 可查。
--    要補的話另開一份 SQL。
--
-- 3. 其他表可能也有 is_test 欄位（topup_orders 未確認）。
--    需要時先跑：
--      select table_name from information_schema.columns
--       where table_schema='public' and column_name='is_test' order by 1;
-- ============================================================
