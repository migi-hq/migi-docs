-- 【已執行】把 HQ 管理員加進 staff 表 + 補 products 寫入 policy。未來新增 POS 店員帳號時照這個模式做。
-- ============================================================
-- ① 把 admin@migi.tw 加進 staff 表（總部管理員，綁 MIGI org）
-- ② 補 products 的寫入 policy（現在只有讀取 r，INSERT/UPDATE 被擋）
-- Supabase SQL Editor 執行
-- ============================================================

-- ① 建立 HQ 管理員 staff 紀錄
--    auth_uid = admin@migi.tw 的 auth id（前面查到的 2485579b-...）
--    org_id   = MIGI（11111111-...）
--    role     = 'hq'（總部）
--    store_id 留 null（總部人員不綁單店）
insert into public.staff (org_id, auth_uid, name, role)
values (
  '11111111-1111-1111-1111-111111111111',
  '2485579b-966f-4da6-8ccd-d3adb7ba084b',
  'MIGI 總部管理員',
  'hq'
)
on conflict do nothing;   -- 已存在就不重複建

-- ② products 補寫入 policy
--    現有 products_org 只有 USING（讀取 r）。需要 INSERT/UPDATE/DELETE 的 WITH CHECK。
--    邏輯：只能寫入自己 org 的商品（org_id = current_org_id()）
drop policy if exists products_org_write on public.products;
create policy products_org_write on public.products
  for all                                      -- insert/update/delete
  using (org_id = current_org_id())            -- 讀/改/刪：限自己 org
  with check (org_id = current_org_id());      -- 寫入：org_id 必須是自己 org

-- ③ 確認結果
--    staff 應有一筆 hq；products 應有兩條 policy
select 'staff' as tbl, name, role, org_id::text from public.staff
union all
select 'policy', polname, polcmd::text, '' from pg_policy where polrelid='public.products'::regclass;
