-- 【這是什麼】已執行：members 加 is_test 旗標、建立測試01~04 四個測試帳號。
-- 【何時讀】要新增測試帳號、或理解測試資料隔離機制時。
-- ============================================================
-- MIGI 測試帳號隔離（可直接執行，冪等）
-- 目的：測試資料不刪除（帳本 append-only 不可刪），改用 is_test 標記，
--       所有真實統計一律排除 is_test=true。
-- 本版：舊帳號改名為「測試01」沿用，另建測試02~04（共 4 個）
-- ============================================================

-- 1. members 加 is_test 專職旗標
alter table members add column if not exists is_test boolean not null default false;
comment on column members.is_test is
  '內部測試帳號旗標。所有營運統計/報表一律 where is_test=false 排除。';
create index if not exists idx_members_is_test on members(org_id) where is_test = false;

-- 2. 舊帳號 → 改名「測試01」＋打標（id 不變，進度/錢包沿用）
update members
   set is_test = true, display_name = '測試01'
 where id = 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';

-- 3. 另建測試02 ~ 測試04（3 個；冪等，重跑不重複）
insert into members (org_id, display_name, is_test, home_store_id, tier)
select
  '11111111-1111-1111-1111-111111111111'::uuid,
  '測試' || lpad(g::text, 2, '0'),
  true,
  (select id from stores
    where org_id = '11111111-1111-1111-1111-111111111111'
    order by created_at limit 1),
  'bubble_tea'
from generate_series(2, 4) g          -- 從 02 開始（01 是改名的舊帳號）
where not exists (
  select 1 from members
   where org_id = '11111111-1111-1111-1111-111111111111'
     and display_name = '測試' || lpad(g::text, 2, '0')
     and is_test = true
);

-- 4. 確認：列出 4 個測試帳號 id（前端登入用）
select id, display_name, tier, is_test
from members
where org_id = '11111111-1111-1111-1111-111111111111'
  and is_test = true
order by display_name;

-- ============================================================
-- 【統計範本】真實查詢一律套 where is_test=false：
--   select count(*) from members where is_test=false and deleted_at is null;
-- ============================================================
