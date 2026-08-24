-- ════════════════════════════════════════════════════════════════════
-- 儲值方案主檔 topup_plans（待辦 17 第一階段）
-- 2026-08-23
--
-- ═══ 問題 ═══
--
-- 🔴 贈點級距只活在前端：`bonusOf()` 寫死在 migi-pos/src/OpenCheckoutPage.jsx:30
--      >= 3000 → 300 ／ >= 2000 → 150 ／ >= 1000 → 50 ／ 其餘 0
--    前端算完用 p_topup_bonus 送給後端，而 **topup_tx 照收 p_bonus_points 不驗證**。
--    · 與待辦 2（checkout_tx 的價格完全來自前端）是同一個病：能送任意值
--    · **而且它擋住了會員頁的儲值功能** —— 在第二個地方做儲值就是第二份 bonusOf，
--      兩邊必然漂，而「哪一邊的贈點才對」只會在對帳時才發現
--
-- ═══ 這一批做什麼、不做什麼 ═══
--
-- ✅ 做：主檔 + 兩支唯讀函式。前端從此讀主檔畫按鈕與算贈點，只有一份規則。
-- ⏳ 不做：讓 topup_tx 自己算贈點、無視 p_bonus_points。
--    那要先撈 topup_tx 與 pos_checkout_with_topup_tx 的全文（硬規則 3），
--    **本檔驗證段順便撈**，下一批做，不用多跑一次。
--    ⚠ 在那之前，「前端可送任意贈點」這個洞仍然開著 ——
--      這一批解決的是「規則有兩份」，不是「前端說了算」。兩件事不要混。
--
-- ═══ 兩個已拍板的規則 ═══
--
-- ① **自訂金額往下取級距**（2026-08-23 拍板）：儲 1500 → 落在 1000 那一級 → 贈 50。
--    所以主檔存的是**門檻**不是固定清單，查法是
--    「min_amount <= 金額 的那些之中取最大的一筆」。
-- ② **贈點無期限**（2026-08-23 拍板）。所以本表**不放有效期欄位** ——
--    ⚠ 預留一個沒人寫的欄位，下一個人會以為它有作用。
--      真的要做效期時再加，那時還要一起處理 wallets.balance 分不出本金與贈點
--      的問題（待辦 11），不是加一欄就好。
--
-- ═══ 一個設計決定：快捷金額 ≠ 級距門檻 ═══
--
-- 現行快捷是 150 / 500 / 1000 / 2000 / 3000，而級距只有 1000 / 2000 / 3000。
-- 150 與 500 是「可以按但沒有贈點」的金額。
-- → 用同一張表、加一個 is_quick 旗標：
--   `min_amount` + `bonus_points` 是**規則**，`is_quick` 是**畫不畫按鈕**。
-- ⚠ 這樣不會矛盾：150 那一列的 bonus 是 0，而往下取級距查到它也是 0，
--   兩種讀法答案一致。若把快捷另外存一份清單，才會有機會不一致。
-- ════════════════════════════════════════════════════════════════════

begin;

-- ─────────────────────────────────────────────────────────────
-- 一、topup_plans
--     ⚠ 有 org_id 也有 store_id（可為 null = 全集團）——
--       與「商品現階段全集團同價，但表結構已預留 store_id」同一個慣例
--       （docs/08-決策與踩坑/決策紀錄.md 第八節）。
--       目前 7 間門市橫跨不只一個品牌（MIGI / MAYU / 雀藝館…），
--       贈點是定價決策，遲早會分店。
-- ─────────────────────────────────────────────────────────────
create table if not exists public.topup_plans (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid        not null,
  -- null = 這一組適用全集團
  store_id      uuid,
  -- 門檻：金額 >= 這個數就適用這一列（往下取級距）
  min_amount    bigint      not null,
  bonus_points  bigint      not null default 0,
  -- 要不要在畫面上畫成快捷按鈕
  is_quick      boolean     not null default false,
  sort_order    int         not null default 0,
  is_active     boolean     not null default true,
  created_at    timestamptz not null default now(),
  constraint topup_plans_min_amount_chk    check (min_amount >= 0),
  constraint topup_plans_bonus_nonneg_chk  check (bonus_points >= 0)
);

-- 同一組（org + store）裡門檻不可重複 —— 重複的話「往下取級距」會有兩個答案。
create unique index if not exists uq_topup_plans_tier
  on public.topup_plans (org_id, coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid), min_amount);

comment on table public.topup_plans is
  '儲值方案主檔。min_amount 是門檻（往下取級距），is_quick 決定要不要畫成快捷按鈕。
   ⚠ store_id 為 null = 全集團適用。**解析是 all-or-nothing**：
     該店若有任何一列就整組用該店的，否則整組用全集團的 ——
     不做逐級合併，那會產生「該店有 1000 級、總部有 3000 級，誰贏」的模糊地帶。
   ⚠ 贈點無期限（2026-08-23 拍板），所以刻意沒有效期欄位。';

-- 現行 bonusOf() 的原樣搬遷（migi-pos/src/OpenCheckoutPage.jsx:30）
insert into public.topup_plans (org_id, store_id, min_amount, bonus_points, is_quick, sort_order)
select o.id, null, v.amt, v.bonus, v.quick, v.ord
  from orgs o
 cross join (values
    (150::bigint,    0::bigint, true, 1),
    (500::bigint,    0::bigint, true, 2),
    (1000::bigint,  50::bigint, true, 3),
    (2000::bigint, 150::bigint, true, 4),
    (3000::bigint, 300::bigint, true, 5)
 ) as v(amt, bonus, quick, ord)
on conflict do nothing;

alter table public.topup_plans enable row level security;
drop policy if exists topup_plans_read on public.topup_plans;
-- 只讀。⚠ 沒有寫入政策 = 誰都不能從前端改，這是刻意的：贈點是錢。
create policy topup_plans_read on public.topup_plans for select using (true);


-- ─────────────────────────────────────────────────────────────
-- 二、list_topup_plans_tx：前端畫快捷按鈕用
-- ─────────────────────────────────────────────────────────────
drop function if exists public.list_topup_plans_tx(uuid, uuid);

create or replace function public.list_topup_plans_tx(p_org_id uuid, p_store_id uuid default null)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'amount', t.min_amount,
           'bonus',  t.bonus_points,
           'quick',  t.is_quick
         ) order by t.sort_order, t.min_amount), '[]'::jsonb)
    from topup_plans t
   where t.org_id = p_org_id
     and t.is_active
     -- all-or-nothing：該店有自己的方案就整組用該店的，否則用全集團的
     and t.store_id is not distinct from (
       case when exists (
         select 1 from topup_plans x
          where x.org_id = p_org_id and x.store_id = p_store_id and x.is_active
       ) then p_store_id else null end
     );
$function$;


-- ─────────────────────────────────────────────────────────────
-- 三、calc_topup_bonus_tx：**唯一**算贈點的地方
--     ⚠ 這支存在的意義就是讓「贈點怎麼算」只有一個答案。
--       前端拿它算顯示、下一批讓 topup_tx 拿它算實際入帳，兩邊同源。
-- ─────────────────────────────────────────────────────────────
drop function if exists public.calc_topup_bonus_tx(uuid, uuid, bigint);

create or replace function public.calc_topup_bonus_tx(
  p_org_id uuid, p_store_id uuid, p_amount_twd bigint)
returns bigint
language sql
stable security definer
set search_path to 'public'
as $function$
  -- 往下取級距：門檻 <= 金額的那些之中取最大的一筆。
  -- ⚠ 一筆都沒有時回 0（例如儲 100，低於最低門檻 150）——
  --   coalesce 在最外層，不要讓它回 null：
  --   null 進到金額計算會讓整個結果變 null 而不報錯。
  select coalesce((
    select t.bonus_points
      from topup_plans t
     where t.org_id = p_org_id
       and t.is_active
       and t.min_amount <= coalesce(p_amount_twd, 0)
       and t.store_id is not distinct from (
         case when exists (
           select 1 from topup_plans x
            where x.org_id = p_org_id and x.store_id = p_store_id and x.is_active
         ) then p_store_id else null end
       )
     order by t.min_amount desc
     limit 1
  ), 0);
$function$;

commit;


-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT）
-- ════════════════════════════════════════════════════════════════════
with o as (select id from orgs limit 1)
select 項目, 結果
from (
  select 1 as ord, '① topup_plans 內容' as 項目,
    coalesce((select string_agg('滿 ' || min_amount || ' → 贈 ' || bonus_points ||
                                case when is_quick then '（快捷）' else '' end,
                                chr(10) order by sort_order)
                from topup_plans where is_active), '❌ 空的') as 結果

  union all select 2, '② list_topup_plans_tx 回傳（全集團）',
    coalesce((select list_topup_plans_tx(o.id, null)::text from o), '❌ null')

  -- 🔴 這一組是重點：必須與 bonusOf() 逐一相符
  union all select 10, '🔴 ⑩ 贈點對照（必須完全等於前端 bonusOf）',
    coalesce((select string_agg(
                lpad(v.amt::text, 5) || ' → ' ||
                lpad(calc_topup_bonus_tx(o.id, null, v.amt)::text, 4) ||
                '　（前端 bonusOf = ' || v.expect || '）' ||
                case when calc_topup_bonus_tx(o.id, null, v.amt) = v.expect
                     then '  ✅' else '  ❌ 不一致' end,
                chr(10) order by v.amt)
                from o cross join (values
                  (0::bigint,      0::bigint),
                  (100::bigint,    0::bigint),
                  (150::bigint,    0::bigint),
                  (500::bigint,    0::bigint),
                  (999::bigint,    0::bigint),
                  (1000::bigint,  50::bigint),
                  (1500::bigint,  50::bigint),   -- ← 拍板：往下取級距
                  (1999::bigint,  50::bigint),
                  (2000::bigint, 150::bigint),
                  (2999::bigint, 150::bigint),
                  (3000::bigint, 300::bigint),
                  (99999::bigint,300::bigint)    -- ← 3000 以上一律 300
                ) as v(amt, expect)), '—')

  union all select 11, '⑪ 邊界：null 金額（應回 0 不是 null）',
    coalesce((select calc_topup_bonus_tx(o.id, null, null)::text from o), '❌ 回了 null')

  union all select 12, '⑫ 門檻唯一索引在不在（重複門檻會讓級距有兩個答案）',
    coalesce((select indexname from pg_indexes
               where schemaname='public' and indexname='uq_topup_plans_tier'),
             '❌ 沒有')

  -- ⏳ 下一批要用：讓 topup_tx 自己算贈點、無視前端送的值
  union all select 20, '⑳ topup_tx 全文（下一批要改它）',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='topup_tx' limit 1),
             '❌ 不存在')

  union all select 21, '㉑ pos_checkout_with_topup_tx 全文（它把前端的贈點傳下去）',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_checkout_with_topup_tx' limit 1),
             '❌ 不存在')
) x
order by ord;

-- ── 怎麼看 ────────────────────────────────────────────────
-- ⑩ 是這支唯一真正重要的一項：**十二個金額全部 ✅** 才代表主檔搬對了。
--    任何一個 ❌ 就是規則被搬歪了 —— 那比沒有主檔更糟，
--    因為前端改讀主檔之後，客人拿到的贈點會跟以前不一樣而沒有人發現。
-- ⑪ 回 0 不是 null：null 進到金額計算會讓整串變 null 而不報錯。
-- ⑳㉑ 是下一批的材料，這次不動它們。
