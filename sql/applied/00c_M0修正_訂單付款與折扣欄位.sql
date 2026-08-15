-- 【M0・已執行】orders 表補上付款與折扣相關欄位。
-- ============================================================
-- MIGI M0 修正：orders 付款方式與折扣分欄  v1.0
-- Supabase Dashboard → SQL Editor（整段貼上執行，冪等）
--
-- 【為什麼不是一個 pay_method 欄】
--   結帳頁的預設行為就是混合付款：扣 80 點 ＋ 收現 70 元。
--   單一欄位表達不了「一單多種付款」，也記不下實收/找零。
--   → orders 記「金額怎麼組成」，order_payments 記「錢實際怎麼進來」。
--
-- 【鐵則沿用】
--   ① 有幾個科目進，就有幾個科目出（券成本 / 等級折扣成本分欄）
--   ② append-only：單據凍結當下的等級與折扣率，日後降級不影響舊單
--   ③ 點數只付場地費與商品，現金收銀是正常零售，兩者分開記
-- ============================================================


-- ------------------------------------------------------------
-- PART A：orders 加金額分解欄位
-- ------------------------------------------------------------
alter table orders
  add column if not exists subtotal          bigint  not null default 0,   -- 商品小計（未折）
  add column if not exists coupon_discount   bigint  not null default 0,   -- 優惠券折抵
  add column if not exists tier_discount     bigint  not null default 0,   -- 會員等級折扣
  add column if not exists payable           bigint  not null default 0,   -- 應付＝小計−券−等級折
  add column if not exists points_used       bigint  not null default 0,   -- 點數折抵
  add column if not exists cash_due          bigint  not null default 0,   -- 尚需支付（走 order_payments）
  -- ★ 凍結當下等級與折扣率：日後降級不影響舊單
  add column if not exists tier_at_order     text,
  add column if not exists tier_rate         numeric(4,3);

comment on column orders.subtotal        is '商品小計（含檯費、加購，未扣任何折扣）';
comment on column orders.coupon_discount is '優惠券折抵金額（行銷成本科目）';
comment on column orders.tier_discount   is '會員等級折扣金額（收入減項，與券成本分開）';
comment on column orders.payable         is 'subtotal - coupon_discount - tier_discount';
comment on column orders.points_used     is '本單使用點數（對應 wallet_txns 一筆 spend）';
comment on column orders.cash_due        is 'payable - points_used，由 order_payments 收齊';
comment on column orders.tier_at_order   is '結帳當下等級（凍結，不隨會員升降級變動）';
comment on column orders.tier_rate       is '結帳當下折扣率：1.000 / 0.950 / 0.900';

-- 金額恆等式（防呆：任一欄算錯直接擋下）
alter table orders drop constraint if exists orders_amount_balance;
alter table orders add constraint orders_amount_balance check (
  payable  = subtotal - coupon_discount - tier_discount
  and cash_due = payable - points_used
  and subtotal        >= 0
  and coupon_discount >= 0
  and tier_discount   >= 0
  and points_used     >= 0
  and cash_due        >= 0
);


-- ------------------------------------------------------------
-- PART B：order_payments — 錢實際怎麼進來（一單可多筆）
-- ------------------------------------------------------------
create table if not exists order_payments (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  store_id     uuid not null references stores(id),
  order_id     uuid not null references orders(id) on delete restrict,

  method       text not null check (method in ('cash','credit_card','line_pay')),
  amount       bigint not null check (amount > 0),   -- 這筆收了多少（不含找零）

  -- 現金專用：實收與找零。★結帳頁目前不記錄實收，故允許 null。
  -- 未來若做「結帳後收銀確認視窗」，直接填入即可，不需改表。
  cash_received bigint,
  change_given  bigint,

  ref_no       text,        -- 刷卡授權碼 / LINE Pay 交易序號
  staff_id     uuid,
  created_at   timestamptz not null default now(),

  -- 非現金一律不得有實收/找零；現金可不填（未記錄），一旦填了就必須自洽
  constraint cash_fields_only_for_cash check (
    (method <> 'cash' and cash_received is null and change_given is null)
    or
    (method = 'cash' and cash_received is null and change_given is null)
    or
    (method = 'cash' and cash_received is not null
       and cash_received >= amount
       and change_given = cash_received - amount)
  )
);

create index if not exists idx_order_payments_order on order_payments(order_id);
create index if not exists idx_order_payments_store_day on order_payments(store_id, created_at);

comment on table order_payments is
  '一張 orders 的實際收款明細。點數不在此表（點數走 wallet_txns），此表只記非點數收款。
   cash_received / change_given 可為 null：結帳頁目前不記實收，未來做收銀確認視窗時再填。';

comment on column order_payments.cash_received is '實收現金。null = 未記錄（結帳頁未提供輸入）';
comment on column order_payments.change_given  is '找零。有 cash_received 時必須等於 cash_received - amount';

-- append-only：不可刪改
create or replace function payments_no_mutate() returns trigger
language plpgsql as $$
begin
  raise exception '收款紀錄不可刪改，請開立退款單沖正';
end $$;

drop trigger if exists trg_payments_no_delete on order_payments;
create trigger trg_payments_no_delete before delete or update on order_payments
  for each row execute function payments_no_mutate();


-- ------------------------------------------------------------
-- PART C：RLS
-- ------------------------------------------------------------
alter table order_payments enable row level security;

drop policy if exists order_payments_org on order_payments;
create policy order_payments_org on order_payments
  for all to authenticated
  using (org_id = current_org_id())
  with check (org_id = current_org_id());

revoke all on order_payments from anon;


-- ------------------------------------------------------------
-- PART D：對帳視圖 — 一單收齊了沒
-- ------------------------------------------------------------
create or replace view v_order_settlement as
select
  o.id,
  o.order_no,
  o.store_id,
  o.subtotal,
  o.coupon_discount,
  o.tier_discount,
  o.payable,
  o.points_used,
  o.cash_due,
  coalesce(sum(p.amount), 0)                as paid_amount,
  o.cash_due - coalesce(sum(p.amount), 0)   as unpaid,     -- 應為 0
  coalesce(sum(p.change_given), 0)          as change_total
from orders o
left join order_payments p on p.order_id = o.id
group by o.id;

comment on view v_order_settlement is
  '結帳對帳：unpaid 必須為 0。班末交班（SH- 單）用此視圖比對現金抽屜。
   change_total 只在有記錄實收時才有意義（目前結帳頁不記實收，故多為 0）。';


-- ------------------------------------------------------------
-- 驗證
-- ------------------------------------------------------------
select column_name, data_type
  from information_schema.columns
 where table_name='orders'
   and column_name in ('subtotal','coupon_discount','tier_discount','payable',
                       'points_used','cash_due','tier_at_order','tier_rate')
 order by column_name;

select count(*) as order_payments_exists
  from information_schema.tables where table_name='order_payments';
