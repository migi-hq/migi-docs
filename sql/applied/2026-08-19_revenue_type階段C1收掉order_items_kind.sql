-- 【待執行】revenue_type 階段 C-1：收掉 order_items.kind（contract）
-- ============================================================
-- 前置：階段 A（後端雙軌）與階段 B（POS 改用 revenue_type）都已完成並實測。
--
-- 本檔做四件事：
--   ① 兩支讀取函式改回 revenue_type（桌帳與收據的分類牌）
--   ② checkout_tx 停止寫 kind，但**繼續容忍前端送 kind**
--   ③ drop order_items.kind 與它的 CHECK
--   ④ 驗證，並順帶探測 products.kind 有沒有讀者（留給 C-2）
--
-- 【排序陷阱 —— 本檔最容易被忽略的一行】
--   原本是 `order by i.kind, i.name`。fee / fnb / goods 按字母排，
--   檯費**剛好**是第一個 —— 那是巧合不是設計。
--   換成 revenue_type 之後字母序變成 fnb / other / retail / venue_fee，
--   **檯費會掉到最後一行**。收據上檯費不在第一行是明顯的退步，
--   而且沒有人會想到那是排序造成的（畫面沒壞、金額也對）。
--   → 改成明寫的桶序 CASE。順序從此是決定，不是副作用。
--
-- 【儲值那一列不給 revenue_type】
--   get_session_member_orders_tx 會把「沒配對到訂單的儲值單」也列出來，
--   它組了一個假品項，原本標 'kind','topup'。
--   儲值是預收款不是收入桶 —— 給它一個 revenue_type 等於把
--   階段 B 前端剛拆掉的「一欄兩用」在 API 這層重新裝回去。
--   → 改成獨立旗標 'is_topup', true，與前端的 isTopup 對齊。
--
-- 【為什麼 checkout_tx 仍收 kind】
--   POS 部署在店裡的平板，Cloudflare 快取讓「手上跑的是哪一版」無法保證。
--   停止**寫**是這一階段的目的；停止**讀**沒有好處，只有風險。
--   那段 coalesce 留著，直到確定沒有舊 bundle 為止。
--
-- 【products.kind 不在本檔】
--   盤點顯示 create_invoice_draft_tx 同時提到 products 與 kind，
--   但那個 kind 極可能是 invoices.kind（它建的是發票草稿）。
--   「極可能」不是「確定」，而它是碰錢的函式 ——
--   本檔最後一欄把它的定義探測出來，確認後再走 C-2。
-- ============================================================

-- ① get_order_tx
create or replace function public.get_order_tx(p_order_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  return (
    select jsonb_build_object(
      'id', o.id,
      'order_no', o.order_no,
      'status', o.status,
      'subtotal', o.subtotal,
      'coupon_discount', o.coupon_discount,
      'tier_discount', o.tier_discount,
      'payable', o.payable,
      'points_used', o.points_used,
      'cash_due', o.cash_due,
      'tier_at_order', o.tier_at_order,
      'tier_discount_pct', o.tier_discount_pct,
      'paid_at', o.paid_at,
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'name', i.name, 'revenue_type', i.revenue_type, 'qty', i.qty,
          'unit_price', i.unit_price, 'line_total', i.line_total
        ) order by case i.revenue_type
                     when 'venue_fee' then 1
                     when 'fnb'       then 2
                     when 'retail'    then 3
                     else 4 end, i.name), '[]'::jsonb)
        from order_items i where i.order_id = o.id),
      'payments', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'method', pm.method, 'amount', pm.amount,
          'cash_received', pm.cash_received, 'change_given', pm.change_given
        )), '[]'::jsonb)
        from order_payments pm where pm.order_id = o.id)
    )
    from orders o
    where o.id = p_order_id and o.deleted_at is null
  );
end $function$;

-- ② get_session_member_orders_tx
create or replace function public.get_session_member_orders_tx(p_session_id uuid, p_member_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_list jsonb;
begin
  select coalesce(jsonb_agg(x order by x_at), '[]'::jsonb)
    into v_list
    from (
      -- ── 消費單（可能附帶同一次交易的儲值）──
      select o.paid_at as x_at,
             jsonb_build_object(
               'type', 'order',
               'id', o.id,
               'order_no', o.order_no,
               'txn_no', o.txn_no,
               'paid_at', o.paid_at,
               'subtotal', o.subtotal,
               'coupon_discount', o.coupon_discount,
               'tier_discount', o.tier_discount,
               'payable', o.payable,
               'points_used', o.points_used,
               'cash_due', o.cash_due,
               'items', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                   'name', i.name, 'revenue_type', i.revenue_type, 'qty', i.qty,
                   'unit_price', i.unit_price, 'line_total', i.line_total
                 ) order by case i.revenue_type
                              when 'venue_fee' then 1
                              when 'fnb'       then 2
                              when 'retail'    then 3
                              else 4 end, i.name), '[]'::jsonb)
                 from order_items i where i.order_id = o.id),
               'payments', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                   'method', pm.method, 'amount', pm.amount,
                   'cash_received', pm.cash_received, 'change_given', pm.change_given
                 )), '[]'::jsonb)
                 from order_payments pm where pm.order_id = o.id),

               'topup', (
                 select jsonb_build_object(
                          'topup_no',      t.topup_no,
                          'points',        t.points,
                          'bonus_points',  t.bonus_points,
                          'credit',        t.points + t.bonus_points,
                          'amount_twd',    t.amount_twd,
                          'pay_method',    t.pay_method,
                          -- ★ 現金全部歸儲值時，實收找零記在這裡
                          'cash_received', t.cash_received,
                          'change_given',  t.change_given)
                   from topup_orders t
                  where t.session_id = p_session_id
                    and t.member_id  = p_member_id
                    and t.status = 'paid'
                    and o.idempotency_key like 'pos-%'
                    and split_part(t.idempotency_key, ':', 1)
                      = split_part(o.idempotency_key, ':', 1)
                  limit 1),

               'collected', o.payable + coalesce((
                 select t.amount_twd from topup_orders t
                  where t.session_id = p_session_id
                    and t.member_id  = p_member_id
                    and t.status = 'paid'
                    and o.idempotency_key like 'pos-%'
                    and split_part(t.idempotency_key, ':', 1)
                      = split_part(o.idempotency_key, ':', 1)
                  limit 1), 0)
             ) as x
        from orders o
       where o.session_id = p_session_id
         and o.member_id  = p_member_id
         and o.deleted_at is null
         and o.status <> 'void'

      union all

      -- ── 沒有配對到訂單的儲值單：仍單獨列出，不能默默消失 ──
      select t.created_at as x_at,
             jsonb_build_object(
               'type', 'topup',
               'id', t.id,
               'order_no', t.topup_no,
               'txn_no', t.txn_no,
               'paid_at', t.created_at,
               'subtotal', t.amount_twd,
               'coupon_discount', 0,
               'tier_discount', 0,
               'payable', t.amount_twd,
               'points_used', 0,
               'cash_due', t.amount_twd,
               'collected', t.amount_twd,
               'points', t.points,
               'bonus_points', t.bonus_points,
               -- 儲值不是收入桶，所以不給 revenue_type，改用獨立旗標
               'items', jsonb_build_array(jsonb_build_object(
                 'name', '會員儲值 ' || (t.points + t.bonus_points)::text || ' 點',
                 'is_topup', true, 'qty', 1,
                 'unit_price', t.amount_twd, 'line_total', t.amount_twd)),
               'payments', jsonb_build_array(jsonb_build_object(
                 'method', t.pay_method, 'amount', t.amount_twd,
                 'cash_received', t.cash_received, 'change_given', t.change_given))
             ) as x
        from topup_orders t
       where t.session_id = p_session_id
         and t.member_id  = p_member_id
         and t.status = 'paid'
         and not exists (
           select 1 from orders o
            where o.session_id = p_session_id
              and o.member_id  = p_member_id
              and o.deleted_at is null
              and o.status <> 'void'
              and o.idempotency_key like 'pos-%'
              and split_part(o.idempotency_key, ':', 1)
                = split_part(t.idempotency_key, ':', 1))
    ) u;

  return jsonb_build_object(
    'orders', v_list,
    -- 以下三個合計只算消費單。儲值是預收款不是消費。
    'total_payable', (
      select coalesce(sum(o.payable), 0) from orders o
       where o.session_id = p_session_id and o.member_id = p_member_id
         and o.deleted_at is null and o.status <> 'void'),
    'total_points_used', (
      select coalesce(sum(o.points_used), 0) from orders o
       where o.session_id = p_session_id and o.member_id = p_member_id
         and o.deleted_at is null and o.status <> 'void'),
    'total_cash_due', (
      select coalesce(sum(o.cash_due), 0) from orders o
       where o.session_id = p_session_id and o.member_id = p_member_id
         and o.deleted_at is null and o.status <> 'void'),
    'total_topup', (
      select coalesce(sum(t.amount_twd), 0) from topup_orders t
       where t.session_id = p_session_id and t.member_id = p_member_id
         and t.status = 'paid'));
end $function$;

-- ③ checkout_tx 停止寫 kind（仍容忍前端送 kind）
--    階段 A 加進去的那兩段，把 kind 那一半拿掉即可。
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'checkout_tx' and p.prokind = 'f';
  if v_old is null then raise exception 'checkout_tx 不存在'; end if;

  v_new := replace(v_old,
    $src$product_id, name, kind, revenue_type, qty,$src$,
    $dst$product_id, name, revenue_type, qty,$dst$);

  v_new := replace(v_new,
    $src$            it->>'name', it->>'kind',
            coalesce($src$,
    $dst$            it->>'name',
            coalesce($dst$);

  if v_new = v_old then
    raise exception 'checkout_tx 找不到錨點 —— 階段 A 是否跑過？';
  end if;

  execute v_new;
end $$;

-- ④ 移除欄位
alter table public.order_items drop constraint if exists order_items_kind_chk;
alter table public.order_items drop column if exists kind;

-- ============================================================
-- 驗證（單一 SELECT）
--   前四欄必須 true / 0。
--   最後一欄是 C-2 的前置判斷：把 create_invoice_draft_tx 裡
--   所有「<別名>.kind」的寫法抓出來。
--   若只出現 invoices 的別名（或根本沒有），products.kind 就可以安全 drop。
--   ⚠ 這是文字探測不是語意分析 —— 看到結果仍要用眼睛確認一次。
-- ============================================================
with fns as (
  select p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select
  (select count(*) = 0 from information_schema.columns
    where table_schema = 'public' and table_name = 'order_items'
      and column_name = 'kind')                                           as 欄位已移除,
  (select count(*) from fns
    where proname in ('get_order_tx', 'get_session_member_orders_tx')
      and def like '%i.kind%')                                            as 讀取函式殘留,
  (select bool_or(def not like '%it->>''kind'', %') from fns
    where proname = 'checkout_tx')                                        as checkout已停寫,
  (select bool_or(def like '%it->>''revenue_type''%') from fns
    where proname = 'checkout_tx')                                        as checkout仍容忍舊key,
  (select jsonb_agg(distinct m[1])
     from fns, regexp_matches(def, '(\w+\.kind)', 'g') m
    where proname = 'create_invoice_draft_tx')                            as 發票函式的kind寫法;
