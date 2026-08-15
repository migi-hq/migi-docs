-- ============================================================
-- ① get_order_tx        —— 讀單張訂單的完整明細（給 POS 顯示收據）
-- ② pos_addon_checkout_tx —— 已入座者的加購結帳（只收商品，不再收檯費）
-- 產生日期：2026-08-15
--
-- 【為什麼需要 ①】
--   從桌況重新進入已開的桌時，已結帳的座位只能顯示
--   「本次入座已結帳，檯費 600 點／明細不在此工作階段」——
--   因為明細本來只存在於前端記憶體，離開頁面就沒了。
--   session_players.order_id 有存訂單編號，但沒有任何函式能讀訂單內容，
--   而 POS 依硬規則 4 不能直接查表。
--
-- 【為什麼需要 ②】
--   現行 doPay() 一律呼叫 join_session_tx，那是「入座 + 收費」。
--   已入座的人再走一次會**重複收檯費**（前端的 feeQty 不知道他付過了）。
--   加購應該只收購物車裡的商品。
--
--   checkout_tx 是 SECURITY INVOKER，POS 用 anon 無 session 直接呼叫會被 RLS 擋。
--   解法沿用既有模式：join_session_tx 也是 DEFINER 包著 checkout_tx —— 這條路已驗證可行。
--
--   另外 checkout_tx 不寫 orders.session_id / table_id（2026-08-15 讀原始碼確認），
--   所以加購訂單會跟場次脫鉤，收桌結算算不到那筆消費。
--   本函式在結帳後補上關聯 —— 「收桌觸發消費累積」是決策紀錄的既定設計。
--
-- 兩支都是新函式，不需要 DROP。
-- ============================================================


-- ---------- ① get_order_tx ----------
CREATE OR REPLACE FUNCTION public.get_order_tx(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      'tier_rate', o.tier_rate,
      'paid_at', o.paid_at,
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
        from order_payments pm where pm.order_id = o.id)
    )
    from orders o
    where o.id = p_order_id and o.deleted_at is null
  );
end $function$;

COMMENT ON FUNCTION public.get_order_tx IS
  'POS 讀單張訂單完整明細（品項／折扣／收款）。用於重新進入桌況時還原已結帳座位的收據。';


-- ---------- ② pos_addon_checkout_tx ----------
CREATE OR REPLACE FUNCTION public.pos_addon_checkout_tx(
  p_session_id uuid,
  p_member_id uuid,
  p_items jsonb,
  p_coupon_ids uuid[] DEFAULT NULL,
  p_points_used bigint DEFAULT 0,
  p_payments jsonb DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_staff_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s      record;
  v_seated uuid;
  v_res    jsonb;
  v_order  uuid;
begin
  select s.id, s.store_id, s.table_id, s.status
    into v_s
    from table_sessions s
   where s.id = p_session_id and s.deleted_at is null;

  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found',
      'message', '場次不存在');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed',
      'message', '此場次已結束，無法加購');
  end if;

  -- 必須是本場次還在座的人才能加購，避免把消費掛到不相干的會員身上
  select sp.id into v_seated
    from session_players sp
   where sp.session_id = p_session_id
     and sp.member_id = p_member_id
     and sp.left_at is null;
  if v_seated is null then
    return jsonb_build_object('ok', false, 'reason', 'not_seated',
      'message', '此會員不在本桌，請先入座');
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_items',
      'message', '沒有可結帳的品項');
  end if;

  -- 委派給 checkout_tx：券折抵、等級折扣、混合付款、冪等、五表寫入都在裡面。
  -- 本函式是 SECURITY DEFINER，所以被呼叫的 checkout_tx（INVOKER）
  -- 會以定義者身分執行，不受 anon 的 RLS 限制 —— 與 join_session_tx 同一套做法。
  v_res := checkout_tx(
    p_member_id, v_s.store_id, p_items, p_coupon_ids,
    coalesce(p_points_used, 0), p_payments, p_idempotency_key, p_staff_id);

  -- checkout_tx 不寫 session_id / table_id，補上關聯，
  -- 否則收桌結算時算不到這筆加購消費
  v_order := nullif(v_res->>'order_id', '')::uuid;
  if v_order is not null then
    update orders
       set session_id = p_session_id,
           table_id   = v_s.table_id
     where id = v_order;
  end if;

  return v_res || jsonb_build_object('ok', true, 'addon', true,
                                     'session_id', p_session_id);
end $function$;

COMMENT ON FUNCTION public.pos_addon_checkout_tx IS
  '已入座會員的加購結帳：只收購物車商品不再收檯費，並把訂單掛回場次供收桌結算彙總。';


-- ---------- ③ 驗證（單一 SELECT）----------
select p.proname as 函式,
       case when p.prosecdef then 'DEFINER' else 'INVOKER' end as 安全性,
       pg_get_function_identity_arguments(p.oid) as 參數
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('get_order_tx', 'pos_addon_checkout_tx')
order by 1;

-- 跑完期待：兩列，安全性都是 DEFINER。
-- 若 pos_addon_checkout_tx 只有一列但參數不含 p_session_id，代表建錯了。
--
-- checkout_tx 回傳的 key 名稱是 'order_id' —— 已核對 sql/applied/02_結帳函式改用新欄位.sql
-- 的兩個 return（第 55 行的冪等提早返回、第 244 行的正常返回），兩處一致。
