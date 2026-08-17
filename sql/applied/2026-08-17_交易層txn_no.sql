-- 【待執行】加交易層：同一次收款的單據共用一個 txn_no
-- ============================================================
-- 問題
--   客人一次付清 $715，系統開出兩張單：消費 MG-（$215）+ 儲值 TP-（$500）。
--   分開是會計上的必須（已實現收入 vs 預收負債，科目不同），
--   但客人只做了一件事，收據上卻要印兩個號碼。
--   缺的是「交易」這一層 —— 成熟系統一律三層：
--       Transaction（一次收款事件）
--          ├─ Document：消費單 orders
--          └─ Document：儲值單 topup_orders
--   Starbucks（飲料 + 儲值卡）、Square（Order 含 gift card activation）、
--   超市賣禮券都是這個形狀：客人看到交易，會計看到單據。
--
-- 定義刻意取最窄
--   txn_no 標識「**一次收款事件**」，不是「一個帳務生命週期」。
--   加購 = 另一次收款 = 另一個號；不綁 session；
--   退款沖銷單掛哪裡由日後的退款流程決定，本欄位不預先押注。
--   欄位只記事實（哪些單據是同一次收的），不記語意。
--
-- 為什麼不改任何金流函式的簽名
--   產生兩張單的是 checkout_tx 與 topup_tx 兩支不同函式，中間隔著 wrapper。
--   把 txn_no 傳下去要動 checkout_tx / join_session_tx /
--   pos_addon_checkout_tx / topup_tx 四支，全部 DROP 重建 ——
--   碰錢的核心一次動四支，風險遠大於收益。
--
--   改成由 trigger 互相尋找「同一次收款的另一張單」：
--       idempotency_key like 'pos-%' 且 split_part(key, ':', 1) 相同
--   這正是 get_session_member_orders_tx 現在配對兩張單用的同一條規則。
--   `pos-%` 這個守門很重要 —— 純 join 路徑的 fallback key 是
--   `sessionId:memberId:seq`，切出來會是 sessionId，
--   沒有守門的話**整場所有玩家的訂單會被歸成同一筆交易**。
--
--   wrapper 是先 topup_tx 再結帳，所以儲值單先拿到號、消費單再沿用。
--   但兩張表的 trigger 都做雙向查找，順序反過來一樣正確。
--
-- 為什麼不回填舊資料
--   next_doc_no 的流水是**依當日日期**計數的，回填會讓 8/16 的訂單
--   拿到 TX-...-260817- 的號碼，看起來像那天開的。
--   訂單全是測試資料且每天會被 dev_reset_test_data_tx 清掉，
--   前端在 txn_no 為 null 時退回顯示單據號即可，會自己長好。
-- ============================================================

-- ① 兩張表加欄位
alter table public.orders       add column if not exists txn_no text;
alter table public.topup_orders add column if not exists txn_no text;

comment on column public.orders.txn_no is
  '交易編號（一次收款事件）。同一次結帳產生的消費單與儲值單共用。客人與店員看這個，財務看 order_no / topup_no。';
comment on column public.topup_orders.txn_no is
  '交易編號（一次收款事件）。同一次結帳產生的消費單與儲值單共用。';

create index if not exists idx_orders_txn_no       on public.orders(txn_no)       where txn_no is not null;
create index if not exists idx_topup_orders_txn_no on public.topup_orders(txn_no) where txn_no is not null;

-- ② 產號器加一種型別。簽名未變，不需 DROP。
create or replace function public.next_doc_no(p_org_id uuid, p_store_id uuid, p_doc_type text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_prefix   text;
  v_store    text;
  v_date     date := (now() at time zone 'Asia/Taipei')::date;
  v_seq      integer;
begin
  v_prefix := case p_doc_type
                when 'order'  then 'MG'   -- 消費（實現收入）
                when 'topup'  then 'TP'   -- 儲值（預收款）
                when 'coupon' then 'CP'   -- 券
                when 'shift'  then 'SH'   -- 交班
                when 'txn'    then 'TX'   -- ★ 交易（一次收款事件，可含多張單據）
                else 'XX'
              end;

  select code into v_store from stores where id = p_store_id;
  if v_store is null then
    raise exception 'store % 沒有店碼', p_store_id;
  end if;

  insert into doc_counters (org_id, store_id, doc_type, doc_date, last_no)
       values (p_org_id, p_store_id, p_doc_type, v_date, 1)
  on conflict (org_id, store_id, doc_type, doc_date)
    do update set last_no = doc_counters.last_no + 1
  returning last_no into v_seq;

  return v_prefix || '-' || v_store || '-'
         || to_char(v_date, 'YYMMDD') || '-'
         || lpad(v_seq::text, 4, '0');
end $function$;

-- ③ 兩張表的產號 trigger 一併設定 txn_no
--    沿用既有的 trg_*_set_no，不新增 trigger —— 同一件事（產號）留在同一個地方。
create or replace function public.trg_orders_set_no()
returns trigger
language plpgsql
as $function$
declare v_txn text;
begin
  if new.order_no is null then
    new.order_no := next_doc_no(new.org_id, new.store_id, 'order');
  end if;

  -- 交易編號：先找同一次收款的儲值單，找不到就自己開一個。
  -- 只有 pos-% 的冪等鍵才配對 —— 純 join 的 fallback key 是
  -- sessionId:memberId:seq，切出來是 sessionId，
  -- 不設這道守門會把整場所有玩家的訂單併成同一筆交易。
  if new.txn_no is null then
    if new.idempotency_key like 'pos-%' then
      select t.txn_no into v_txn
        from topup_orders t
       where t.org_id = new.org_id
         and t.txn_no is not null
         and t.idempotency_key like 'pos-%'
         and split_part(t.idempotency_key, ':', 1)
           = split_part(new.idempotency_key, ':', 1)
       limit 1;
    end if;
    new.txn_no := coalesce(v_txn, next_doc_no(new.org_id, new.store_id, 'txn'));
  end if;

  return new;
end $function$;

create or replace function public.trg_topup_set_no()
returns trigger
language plpgsql
as $function$
declare v_txn text;
begin
  if new.topup_no is null then
    new.topup_no := next_doc_no(new.org_id, new.store_id, 'topup');
  end if;

  -- 與 trg_orders_set_no 對稱：雙向查找，兩張單誰先建都正確。
  if new.txn_no is null then
    if new.idempotency_key like 'pos-%' then
      select o.txn_no into v_txn
        from orders o
       where o.org_id = new.org_id
         and o.txn_no is not null
         and o.idempotency_key like 'pos-%'
         and split_part(o.idempotency_key, ':', 1)
           = split_part(new.idempotency_key, ':', 1)
       limit 1;
    end if;
    new.txn_no := coalesce(v_txn, next_doc_no(new.org_id, new.store_id, 'txn'));
  end if;

  return new;
end $function$;

-- ④ 桌帳 RPC 一併回傳 txn_no（簽名未變，不需 DROP）
--    只加兩個鍵，其餘與線上版逐字相同。
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_session_member_orders_tx'
     and p.prokind = 'f';
  if v_old is null then raise exception 'get_session_member_orders_tx 不存在'; end if;

  -- 消費單那一支
  v_new := replace(v_old,
    '''order_no'', o.order_no,',
    '''order_no'', o.order_no,' || chr(10) || '               ''txn_no'', o.txn_no,');

  -- 沒配對到訂單的獨立儲值單那一支
  v_new := replace(v_new,
    '''order_no'', t.topup_no,',
    '''order_no'', t.topup_no,' || chr(10) || '               ''txn_no'', t.txn_no,');

  if v_new = v_old then
    raise exception '找不到目標字串，線上版可能已改過 —— 先撈 pg_get_functiondef 確認';
  end if;

  execute v_new;
end $$;

-- ============================================================
-- 驗證（單一 SELECT）
--   欄位數 2、TX 型別可用（回傳以 TX- 開頭）、RPC 已回傳 txn_no。
--   ⚠ 驗證會實際呼叫 next_doc_no，因此會消耗掉一個交易號 ——
--     doc_counters 是每日計數，跳一號不影響正確性。
--   後段列出最近 5 筆訂單的交易號與單據號，跑完新結一筆再看是否兩張同號。
-- ============================================================
select
  (select count(*) from information_schema.columns
    where table_schema='public' and column_name='txn_no'
      and table_name in ('orders','topup_orders'))                    as 欄位數,
  (select public.next_doc_no(s.org_id, s.id, 'txn') like 'TX-%'
     from public.stores s where s.code is not null
     order by s.code limit 1)                                         as TX型別可用,
  (select pg_get_functiondef(p.oid) like '%''txn_no'', o.txn_no%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname='get_session_member_orders_tx'
      and p.prokind='f' limit 1)                                      as RPC已回傳txn_no,
  o.order_no                                                          as 消費單號,
  o.txn_no                                                            as 交易號,
  (select t.topup_no from public.topup_orders t
    where t.org_id = o.org_id and t.txn_no = o.txn_no limit 1)        as 同號的儲值單,
  o.paid_at                                                           as 時間
from public.orders o
where o.deleted_at is null
order by o.created_at desc
limit 5;
