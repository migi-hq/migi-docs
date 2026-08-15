-- 【這是什麼】已執行：把 M0 seed 假店「MIGI 旗艦店」改成第一家真門市。
-- 【何時讀】要新增分店、或想知道門市 id 從哪來時。
--
-- 決策紀錄：id 維持 seed 的 22222222-...（不換隨機 uuid）。
--   理由：已有 9 張表以 on delete restrict 綁著它，換 id 要做搬遷手術、風險高；
--   而 id 只是內部識別碼，使用者永遠看不到，不影響它是真店。
--   未來新分店 / 新加盟 org 由 gen_random_uuid() 自動產生，不再用好記假 id。

update stores
   set name = 'MIGI 高雄自由店',
       address = '高雄市左營區自由三路410號',
       is_active = true,
       updated_at = now()
 where id = '22222222-2222-2222-2222-222222222222';

-- 確認
select id, name, address, is_active
from stores
where org_id = '11111111-1111-1111-1111-111111111111' and deleted_at is null;

-- ============================================================
-- 未來新增分店範本（org 相同、store 用自動 uuid）
-- ============================================================
-- insert into stores (org_id, name, address)
-- values ('11111111-1111-1111-1111-111111111111', 'MIGI 三民店', '高雄市三民區...');
--
-- 名詞區分：
--   org   = 品牌 / 加盟主（MIGI 是一個 org），資料互相隔離
--   store = 實體分店（自由店、三民店），同 org 下會員與錢包共通
