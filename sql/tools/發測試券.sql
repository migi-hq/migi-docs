-- 【測試工具】發一張檯費 9 折券給測試01
-- 可重複執行，不是 migration。
-- ============================================================
-- 目的
--   檯費券是唯一會用到 rem_fee 桶的東西 —— 餐飲券、全品項券都碰不到它。
--   2026-08-19～20 的 kind → revenue_type 替換把**前後端的分桶來源都換掉了**，
--   而這條路徑到現在一次都沒被跑過。
--
-- 【discount_value 是折抵百分比，不是折數】
--   9 折要填 **10**，不是 90。這是 2026-08-17 查證時發現的既有慣例：
--   checkout_tx 算的是 `round(cap * discount_value / 100.0)`。
--   （資料庫一律存折抵幅度，畫面一律顯示折數 —— 兩層刻意分開。）
--
-- 【為什麼直接 insert 而不寫發券 RPC】
--   發券規則（grant_rules / grant_log）完全不存在，現在建函式等於猜規則。
--   等後台發券開工時一起設計；在那之前這支就是唯一的參考實作。
--
-- 【可重複執行的方式】
--   券本身用 name 當識別，已存在就不重建。
--   發放則是「該會員沒有**可用**的這張券才發」——
--   所以用掉之後再跑一次就會拿到新的一張，測試可以重複做。
--   ⚠ dev_reset_test_data_tx 不會清 member_coupons，用掉就是用掉了。
--
-- 🔴 順帶發現（本檔不修，只記錄）
--   checkout_tx 核銷時**只檢查 member_coupons**：
--       used_at is null / status <> 'used' / expires_at
--   它**從來不看 coupons.is_active，也不看 coupons.valid_until**。
--   → 把一張券在主檔停用或設過期，已發出去的還是照樣能核銷。
--   單店影響不大（券是自己發的），但活動結束後要能「立刻停掉」是基本需求，
--   而現在做不到。等發券後台時一起處理。
-- ============================================================

-- ① 券主檔（已存在就不動）
insert into public.coupons(
  org_id, name, kind, discount_type, discount_value, applies_to,
  valid_until, is_active, cost_bearer)
select m.org_id,
       '檯費 9 折券（測試）',
       'table_discount',      -- kind 是券的分類，與商品的 revenue_type 無關
       'percent',
       10,                    -- ★ 折抵 10% ＝ 9 折
       'table_fee',           -- 只折檯費桶（rem_fee）
       (current_date + 30),
       true,
       'store'
  from public.members m
 where m.display_name = '測試01' and m.is_test = true
   and not exists (select 1 from public.coupons c
                    where c.org_id = m.org_id
                      and c.name = '檯費 9 折券（測試）'
                      and c.deleted_at is null)
 limit 1;

-- ② 發給測試01（沒有可用的同款券才發）
insert into public.member_coupons(
  org_id, member_id, coupon_id, status, expires_at, code)
select m.org_id, m.id, c.id, 'active',
       now() + interval '30 days',
       -- ⚠ code 上有唯一索引 member_coupons_org_code_uq(org_id, code)，
       --   固定字串只能發一次。帶時間戳讓這支能重複跑。
       --   （2026-08-20 踩到：盤點時查 pg_constraint 沒看到它 ——
       --     唯一索引不在 pg_constraint 裡，要查 pg_indexes。
       --     Postgres 報錯仍稱它 unique constraint，所以名字看起來一樣。）
       'TEST-FEE10-' || to_char(now() at time zone 'Asia/Taipei', 'MMDDHH24MISS')
  from public.members m
  join public.coupons c
    on c.org_id = m.org_id
   and c.name = '檯費 9 折券（測試）'
   and c.deleted_at is null
 where m.display_name = '測試01' and m.is_test = true
   and not exists (
     select 1 from public.member_coupons mc
      where mc.member_id = m.id
        and mc.coupon_id = c.id
        and mc.used_at is null
        and coalesce(mc.status, '') <> 'used'
        and (mc.expires_at is null or mc.expires_at > now()))
 limit 1;

-- ============================================================
-- 驗證（單一 SELECT）
--   券內容 / 該會員目前可用的券 / 已用掉的張數。
--   「可用券」那一欄就是 POS 結帳頁會列出來的東西。
-- ============================================================
select
  (select jsonb_build_object(
            'name', c.name, 'kind', c.kind,
            'discount_type', c.discount_type,
            'discount_value', c.discount_value,
            'folds', (100 - c.discount_value) || ' %（即 '
                     || ((100 - c.discount_value) / 10.0) || ' 折）',
            'applies_to', c.applies_to,
            'max_discount', c.max_discount,
            'cost_bearer', c.cost_bearer,
            'is_active', c.is_active)
     from public.coupons c
     join public.members m on m.org_id = c.org_id
    where m.display_name = '測試01' and m.is_test = true
      and c.name = '檯費 9 折券（測試）' and c.deleted_at is null
    limit 1)                                                              as 券內容,

  (select jsonb_agg(jsonb_build_object(
            'name', c.name, 'code', mc.code,
            'expires_at', mc.expires_at, 'status', mc.status))
     from public.member_coupons mc
     join public.coupons c on c.id = mc.coupon_id
     join public.members m on m.id = mc.member_id
    where m.display_name = '測試01' and m.is_test = true
      and mc.used_at is null
      and coalesce(mc.status, '') <> 'used'
      and (mc.expires_at is null or mc.expires_at > now()))               as 目前可用的券,

  (select count(*)
     from public.member_coupons mc
     join public.members m on m.id = mc.member_id
    where m.display_name = '測試01' and m.is_test = true
      and mc.used_at is not null)                                         as 已用掉張數;
