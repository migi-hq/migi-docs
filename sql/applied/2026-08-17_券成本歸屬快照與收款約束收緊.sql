-- 【待執行】券成本歸屬快照 + 現金收款必記實收找零
-- ============================================================
-- 出自 2026-08-17 的碰錢結構盤點（docs/01-資料庫/資料模型設計說明.md 三之三節）。
-- 兩件事都是「現在做零成本、晚做就回不去」。
--
-- ① coupons.cost_bearer 從來沒被讀過
--   cost_bearer ∈ store / hq，是加盟成本歸屬 —— 總部發的券由誰吸收。
--   連鎖體系（Subway / 7-11 / 麥當勞 POS）都必須追這件事：
--   總部出資的促銷是總部的行銷費用、門市要獲得補償。
--   不套用的後果是門市永遠自己吃掉每一筆折扣。單店無所謂，加盟一開就是帳務爭議核心。
--
--   **本檔只做一件事：核銷時把 cost_bearer 快照下來。**
--   分潤邏輯可以晚點寫，但事實必須當下記 ——
--   券的 cost_bearer 日後會被改，改了就再也回推不出
--   「這筆折扣當時該由誰吸收」。member_coupons 已經有 discounted_amount，
--   旁邊多一欄即可。
--
-- ② order_payments 允許現金不記實收找零
--   舊約束中間那條讓「method='cash' 且兩欄皆 null」合法。
--   後果是抽屜對帳算不準：
--       抽屜應有現金 = sum(cash_received) - sum(change_given)
--   有 null 的列會被 sum 跳過，**少算而且不報錯** —— 不是錯誤訊息，是數字默默對不上。
--   業界 POS 一律強制記 tender，現金抽屜對帳就是靠它。
--   客人給剛好時也記得起來：cash_received = amount、change_given = 0。
--
--   ⚠ 前端必須先修好才能跑這支。
--     舊版把「整筆實收與找零」記在 order_payments，但那張的 amount 只有訂單那份，
--     而約束要求 change_given = cash_received - amount（單張自洽）——
--     只有沒有儲值時兩者才相等。
--     所以「儲值 + 消費付現金」同時發生會違反 CHECK、結帳直接失敗（現在就是壞的）。
--     migi-pos 已於 2026-08-17 改成按單拆：訂單記自己的份額、找零歸儲值那張。
--
-- ③ wallet_txns.type 不動
--   盤點的第三項是「一欄裝兩個維度」，但改 enum 要處理歷史列、收益只是整齊。
--   結論是立規矩不改結構：新寫入只用性質值、消費類別從 ref_table/ref_id 追訂單。
--   已寫進文件與 CLAUDE.md 待辦 12，本檔不動它。
-- ============================================================

-- ① 券成本歸屬快照
alter table public.member_coupons
  add column if not exists cost_bearer text;

comment on column public.member_coupons.cost_bearer is
  '核銷當下的成本歸屬快照（store / hq），來自 coupons.cost_bearer。券的設定日後會改，不快照就再也回推不出這筆折扣當時該由誰吸收。';

alter table public.member_coupons
  drop constraint if exists member_coupons_cost_bearer_chk;

alter table public.member_coupons
  add constraint member_coupons_cost_bearer_chk
  check (cost_bearer is null or cost_bearer in ('store', 'hq'));

-- 既有已核銷的券補上快照（目前為測試資料，直接沿用券的現值）
update public.member_coupons mc
   set cost_bearer = c.cost_bearer
  from public.coupons c
 where c.id = mc.coupon_id
   and mc.cost_bearer is null
   and mc.used_at is not null;

-- checkout_tx：核銷時一併寫入快照
--   只改兩處 —— 券查詢加選 c.cost_bearer、update 加寫一欄。
--   長函式只改幾行時用 DO 區塊對線上定義做單點替換，
--   不貼整份 CREATE OR REPLACE（那等於用本機副本覆蓋線上版）。
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'checkout_tx' and p.prokind = 'f';
  if v_old is null then raise exception 'checkout_tx 不存在'; end if;

  v_new := replace(v_old,
    'c.min_spend, c.max_discount, c.free_product_id',
    'c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer');

  v_new := replace(v_new,
    'update member_coupons set discounted_amount = cut where id = cp.mc_id;',
    'update member_coupons set discounted_amount = cut, cost_bearer = cp.cost_bearer where id = cp.mc_id;');

  if v_new = v_old then
    raise exception '找不到目標字串，線上版可能已改過 —— 先撈 pg_get_functiondef 確認';
  end if;

  execute v_new;
end $$;

-- ② 現金收款必記實收找零
--   先補既有列：測試資料裡沒記 tender 的現金收款，一律視為「收剛好」。
--   （真實營運不會有這種列 —— 前端會擋，補這段只是為了讓約束加得上去。）
update public.order_payments
   set cash_received = amount,
       change_given  = 0
 where method = 'cash'
   and cash_received is null;

alter table public.order_payments
  drop constraint if exists cash_fields_only_for_cash;

alter table public.order_payments
  add constraint cash_fields_only_for_cash
  check (
       (method <> 'cash' and cash_received is null and change_given is null)
    or (method =  'cash' and cash_received is not null
        and cash_received >= amount
        and change_given = cash_received - amount)
  );

-- ============================================================
-- 驗證（單一 SELECT）
--   cost_bearer 欄位存在 true、checkout_tx 已寫快照 true、
--   現金無 tender 的列 0、舊約束已收緊 true。
--   後段列出最近 5 筆現金收款，驗算欄位應全為 true。
-- ============================================================
select
  (select count(*) = 1 from information_schema.columns
    where table_schema='public' and table_name='member_coupons'
      and column_name='cost_bearer')                                    as 快照欄位存在,
  (select pg_get_functiondef(p.oid) like '%cost_bearer = cp.cost_bearer%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname='checkout_tx'
      and p.prokind='f' limit 1)                                        as 核銷已寫快照,
  (select count(*) from public.order_payments
    where method = 'cash' and cash_received is null)                    as 現金無實收的列,
  (select pg_get_constraintdef(c.oid) not like '%cash_received IS NULL) OR ((method = ''cash''%'
     from pg_constraint c join pg_class t on t.oid = c.conrelid
    where t.relname='order_payments' and c.conname='cash_fields_only_for_cash')
                                                                        as 約束已收緊,
  p.id                                                                  as 收款,
  p.method                                                              as 方式,
  p.amount                                                              as 金額,
  p.cash_received                                                       as 實收,
  p.change_given                                                        as 找零,
  (p.change_given = p.cash_received - p.amount)                         as 找零驗算
from public.order_payments p
where p.method = 'cash'
order by p.created_at desc
limit 5;
