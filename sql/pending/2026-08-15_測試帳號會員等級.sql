-- ============================================================
-- 測試帳號會員等級：測試01 → 提拉米蘇、測試02 → 焦糖布丁
-- ------------------------------------------------------------
-- 用途：驗證 checkout_tx 的等級折扣（右欄「會員折扣」那一列）。
--       目前兩個測試帳號都是 bubble_tea，折扣率 1.000，
--       所以那一列永遠不會出現，等於這條路徑從沒被實機驗證過。
--
-- 【折數不需要另外設定】
--   對照表寫在 checkout_tx 裡（sql/applied/02_結帳函式改用新欄位.sql:159-163）：
--     caramel_pudding → 0.950（95 折）
--     tiramisu        → 0.900（ 9 折）
--     chef_special    → 0.900
--     其餘（bubble_tea）→ 1.000
--   與 docs/03-會員App與社交/會員分級制度規格.md 一致。改 tier 即生效。
--
-- 【為什麼要一併清 tier_override】
--   checkout_tx 讀的是 coalesce(tier_override, tier)。
--   tier_override 若有值會蓋掉 tier，改了 tier 卻沒反應，很難查。
--
-- 【只動測試帳號】
--   條件帶 is_test = true，避免誤傷真實會員。
--   用 display_name 比對而非寫死 uuid —— 帳號重建過 id 會變，名字不會。
--
-- 【欄位依據】
--   members.tier check (tier in ('bubble_tea','caramel_pudding','tiramisu'))
--   見 sql/applied/00a_M0建表_資料骨架.sql:109-110。
--   注意線上另有一條較寬的 members_tier_chk 與它並存（兩條打架，
--   chef_special 永遠寫不進去，修法見 pending/2026-08-14_fix_members_tier_constraint.sql）。
--   本檔用的 tiramisu / caramel_pudding 兩條約束都允許，不受影響。
-- ============================================================

update members
   set tier          = 'tiramisu',
       tier_override = null,
       updated_at    = now()
 where is_test = true
   and display_name = '測試01';

update members
   set tier          = 'caramel_pudding',
       tier_override = null,
       updated_at    = now()
 where is_test = true
   and display_name = '測試02';


-- ============================================================
-- 驗證（單一 SELECT）
-- ------------------------------------------------------------
-- 期待：
--   測試01  tiramisu         0.900   9 折
--   測試02  caramel_pudding  0.950  95 折
-- 「實際生效等級」欄位是照 checkout_tx 的 coalesce 邏輯算的，
-- 若它與「等級」不同，代表 tier_override 還有值 —— 那才是結帳時真正會用的。
-- ============================================================
select
  m.display_name                              as 帳號,
  m.tier                                      as 等級,
  m.tier_override                             as 覆寫,
  coalesce(m.tier_override, m.tier)           as 實際生效等級,
  case coalesce(m.tier_override, m.tier)
    when 'caramel_pudding' then 0.950
    when 'tiramisu'        then 0.900
    when 'chef_special'    then 0.900
    else 1.000
  end                                         as 折扣率,
  case coalesce(m.tier_override, m.tier)
    when 'caramel_pudding' then '95 折'
    when 'tiramisu'        then '9 折'
    when 'chef_special'    then '9 折'
    else '無折扣'
  end                                         as 折數
from members m
where m.is_test = true
  and m.display_name in ('測試01', '測試02', '測試03', '測試04')
order by m.display_name;
