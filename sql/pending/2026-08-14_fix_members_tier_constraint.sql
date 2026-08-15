-- ============================================================
-- 修正 members.tier 兩條 CHECK 互相打架的問題
-- 產生日期：2026-08-14
--
-- 背景：
--   members 表上同時存在兩條針對 tier 的 CHECK：
--     members_tier_check → bubble_tea / caramel_pudding / tiramisu        （舊，較嚴）
--     members_tier_chk   → 上述三種 + chef_special + NULL                  （新，較寬）
--   兩條同時生效等於取交集，導致 chef_special 永遠寫不進 members.tier。
--   但 members_tier_override_chk 允許 tier_override = 'chef_special'，
--   只要有邏輯把 override 套用回 tier 就會失敗。
--
-- 處置：
--   刪掉較嚴的舊版 members_tier_check，保留較寬的 members_tier_chk。
--
-- 安全性：
--   保留的約束是被刪除者的超集 —— 現有資料只要通過舊約束就必然通過新約束，
--   不可能有資料因此變成違規。刪除 CHECK 本身也不會動到任何資料列。
--
-- 影響範圍：
--   前端目前完全沒有使用 chef_special（migi-web / migi-pos / migi-admin 皆無引用），
--   屬潛伏問題，現在修是為了避免後台做會員分級時踩到 ——
--   屆時錯誤訊息會指向 members_tier_check，很難聯想到是兩條約束打架。
-- ============================================================

ALTER TABLE public.members DROP CONSTRAINT IF EXISTS members_tier_check;

-- ---------- 驗證：跑完應只剩 members_tier_chk（含 chef_special） ----------
select conname as 約束名稱, pg_get_constraintdef(oid) as 定義
from pg_constraint
where conrelid = 'public.members'::regclass
  and contype = 'c'
  and conname like '%tier%'
order by conname;
