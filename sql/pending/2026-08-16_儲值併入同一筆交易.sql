-- ============================================================
-- 桌帳：儲值與消費併成同一筆交易，不再分兩列
-- ------------------------------------------------------------
-- 【要解決什麼】
--   前一版把儲值單當成獨立一列塞進本場交易紀錄。
--   但那是**一次收款** —— 客人給一次錢、店員按一次確認，
--   畫面卻列出兩筆，對帳時得自己記得「這兩筆是同一件事」。
--
-- 【怎麼配對】
--   pos_checkout_with_topup_tx 用同一個 base 產生兩把冪等鍵：
--       pos-<sessionId>-<memberId>-<時間戳>:order   → orders.idempotency_key
--       pos-<sessionId>-<memberId>-<時間戳>:topup   → topup_orders.idempotency_key
--   所以 split_part(key, ':', 1) 相等就是同一次交易。
--
--   **不會誤配**：join_session_tx 沒帶鍵時用的預設格式是
--   `<sessionUuid>:<memberUuid>:<序號>`，split_part 取出來是一個 uuid，
--   不可能等於 'pos-…' 開頭的字串。加購用的是 'addon-…' 前綴，同理。
--   為求保險仍加上 like 'pos-%' 的條件。
--
-- 【儲值單沒有配對到訂單時】
--   仍單獨列出（type='topup'）。理論上 POS 不會產生這種資料
--   （那支函式是原子的），但真出現了要看得到，不能默默消失。
--
-- 【線上版來源】
--   get_session_member_orders_tx(uuid,uuid) DEFINER，2026-08-16 以
--   pg_get_functiondef 撈出確認（硬規則 3）。簽名未變，不需 DROP。
--
-- 【合計語意仍不變】
--   total_payable / total_points_used / total_cash_due 只算消費單。
--   total_topup 另計。儲值是預收款不是營業額，這條線不能模糊。
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_session_member_orders_tx(
  p_session_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
               'paid_at', o.paid_at,
               'subtotal', o.subtotal,
               'coupon_discount', o.coupon_discount,
               'tier_discount', o.tier_discount,
               'payable', o.payable,
               'points_used', o.points_used,
               'cash_due', o.cash_due,
               'items', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                   'name', i.name, 'kind', i.kind, 'qty', i.qty,
                   'unit_price', i.unit_price, 'line_total', i.line_total
                 ) order by i.kind, i.name), '[]'::jsonb)
                 from order_items i where i.order_id = o.id),
               'payments', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                   'method', pm.method, 'amount', pm.amount,
                   'cash_received', pm.cash_received, 'change_given', pm.change_given
                 )), '[]'::jsonb)
                 from order_payments pm where pm.order_id = o.id),

               -- ★ 同一次交易的儲值（沒有就是 null）
               'topup', (
                 select jsonb_build_object(
                          'topup_no',     t.topup_no,
                          'points',       t.points,
                          'bonus_points', t.bonus_points,
                          'credit',       t.points + t.bonus_points,
                          'amount_twd',   t.amount_twd,
                          'pay_method',   t.pay_method)
                   from topup_orders t
                  where t.session_id = p_session_id
                    and t.member_id  = p_member_id
                    and t.status = 'paid'
                    and o.idempotency_key like 'pos-%'
                    and split_part(t.idempotency_key, ':', 1)
                      = split_part(o.idempotency_key, ':', 1)
                  limit 1),

               -- 這次交易總共收了多少（消費應付 + 儲值）。
               -- 摘要列顯示這個數字，因為那才是客人實際付的。
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
               'paid_at', t.created_at,
               'subtotal', t.amount_twd,
               'coupon_discount', 0,
               'tier_discount', 0,
               'payable', t.amount_twd,
               'points_used', 0,
               'cash_due', t.amount_twd,
               'collected', t.amount_twd,
               'items', jsonb_build_array(jsonb_build_object(
                 'name', '會員儲值 ' || (t.points + t.bonus_points)::text || ' 點'
                         || case when t.bonus_points > 0
                                 then '（含贈 ' || t.bonus_points::text || '）'
                                 else '' end,
                 'kind', 'topup', 'qty', 1,
                 'unit_price', t.amount_twd, 'line_total', t.amount_twd)),
               'payments', jsonb_build_array(jsonb_build_object(
                 'method', t.pay_method, 'amount', t.amount_twd,
                 'cash_received', null, 'change_given', null))
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


-- ============================================================
-- 驗證（單一 SELECT）
-- ------------------------------------------------------------
-- 期待（以先前那筆含儲值的交易為對象）：
--   版本數           = 1
--   實測筆數         = 1     ← 從 2 變 1，儲值已併入消費單
--   該筆是否附儲值   = true
--   該筆收款合計     = 消費應付 + 儲值（207 + 150 = 357）
--   儲值合計         = 150   ← 合計欄位語意不變
-- ============================================================
with probe as (
  select t.session_id, t.member_id
    from topup_orders t
   where t.session_id is not null
   order by t.created_at desc
   limit 1
), r as (
  select get_session_member_orders_tx(p.session_id, p.member_id) as j
    from probe p
)
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='get_session_member_orders_tx') as 版本數,
  (select jsonb_array_length(j -> 'orders') from r)                        as 實測筆數,
  (select (j -> 'orders' -> 0 -> 'topup') is not null
      and (j -> 'orders' -> 0 -> 'topup') <> 'null'::jsonb from r)         as 該筆是否附儲值,
  (select j -> 'orders' -> 0 ->> 'collected' from r)                       as 該筆收款合計,
  (select j -> 'orders' -> 0 ->> 'payable' from r)                         as 其中消費應付,
  (select j ->> 'total_topup' from r)                                      as 儲值合計;
