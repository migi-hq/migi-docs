-- ============================================================
-- ① 修正 pos_addon_checkout_tx：補上 channel 與 entity_id
-- ② 新增 get_session_member_orders_tx：撈某人在某場次的所有消費
-- 產生日期：2026-08-15
--
-- 【背景：一個座位會有多張訂單】
--   檯費 1 張 + 每次加購各 1 張。原本右欄只顯示單張收據，撐不住這個模型。
--   正確的概念是「桌帳」—— 一場牌局裡每個人的消費是一本流水帳。
--   收桌結算要彙總的也正是這本帳，所以資料結構現在就要做對。
--
-- 【① 為什麼要補兩欄】
--   線上的 join_session_tx 在建完檯費訂單後會補：
--     session_id / table_id / channel='counter' / entity_id（取自門市）
--   我的 pos_addon_checkout_tx 只補了前兩個。
--   entity_id 是加盟帳務分潤在用的（v_entity_settlement 靠它），
--   缺了會讓加購營收歸不到對的營運主體；channel 缺了則報表分不出通路。
--
-- 【本機檔案不可信】
--   sql/applied/已執行-代付支援.sql 裡的 join_session_tx **沒有**那段 update，
--   線上版本有 —— 後來改過但沒留檔。
--   → applied/ 是「當時交付的版本」，不保證等於線上現況。
--   動既有函式前一律用 pg_get_functiondef 撈線上版，不要拿檔案當基準（硬規則 3）。
--
-- 兩支都是 CREATE OR REPLACE 且簽名不變，不需要 DROP。
-- ============================================================


-- ---------- ① pos_addon_checkout_tx（補 channel / entity_id）----------
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

  -- 委派給 checkout_tx。本函式是 SECURITY DEFINER，
  -- 被呼叫的 checkout_tx（INVOKER）會以定義者身分執行，不受 anon 的 RLS 限制
  -- —— 與 join_session_tx 同一套做法。
  v_res := checkout_tx(
    p_member_id, v_s.store_id, p_items, p_coupon_ids,
    coalesce(p_points_used, 0), p_payments, p_idempotency_key, p_staff_id);

  -- 補齊 checkout_tx 沒寫的欄位，與 join_session_tx 的處理完全一致：
  -- session_id/table_id 讓收桌結算找得到，entity_id 讓加盟分潤歸對主體，
  -- channel 讓報表分得出通路
  v_order := nullif(v_res->>'order_id', '')::uuid;
  if v_order is not null then
    update orders o
       set session_id = p_session_id,
           table_id   = v_s.table_id,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id,
                                 (select entity_id from stores where id = v_s.store_id))
     where o.id = v_order;
  end if;

  return v_res || jsonb_build_object('ok', true, 'addon', true,
                                     'session_id', p_session_id);
end $function$;


-- ---------- ② get_session_member_orders_tx ----------
-- 某位會員在某場次的完整消費流水（桌帳）。
-- 檯費訂單由 join_session_tx 掛上 session_id，加購訂單由上面那支掛上，
-- 所以這裡用 orders.session_id 一致查詢即可，不必拼裝兩種來源。
CREATE OR REPLACE FUNCTION public.get_session_member_orders_tx(
  p_session_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_list jsonb;
begin
  select coalesce(jsonb_agg(x order by x_paid_at), '[]'::jsonb)
    into v_list
    from (
      select o.paid_at as x_paid_at,
             jsonb_build_object(
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
                 from order_payments pm where pm.order_id = o.id)
             ) as x
        from orders o
       where o.session_id = p_session_id
         and o.member_id  = p_member_id
         and o.deleted_at is null
         and o.status <> 'void'
    ) t;

  return jsonb_build_object(
    'orders', v_list,
    -- 合計給畫面直接用，免得前端每次自己加總又算錯一次
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
         and o.deleted_at is null and o.status <> 'void'));
end $function$;

COMMENT ON FUNCTION public.get_session_member_orders_tx IS
  '某會員在某場次的完整消費流水（桌帳）：檯費與各次加購，含品項與收款方式。收桌結算彙總亦可沿用。';


-- ---------- ③ 驗證（單一 SELECT）----------
select 'pos_addon_checkout_tx 已補欄位' as 項目,
       case when prosrc like '%entity_id%' and prosrc like '%channel%'
            then '✓' else '✗ 仍是舊版' end as 結果
from pg_proc where proname = 'pos_addon_checkout_tx'
union all
select 'get_session_member_orders_tx 已建立',
       case when count(*) > 0 then '✓' else '✗' end::text
from pg_proc where proname = 'get_session_member_orders_tx'
union all
select '檯費訂單有掛 session_id 的比例',
       (select count(*) filter (where session_id is not null)::text || ' / ' || count(*)::text
          from orders where deleted_at is null)
order by 1;

-- 第三列是順帶盤點：若「有掛」的數量明顯少於總數，
-- 代表有些訂單建立時沒關聯到場次（例如非開桌流程的純商品結帳），
-- 那是正常的；但若連檯費訂單都沒掛上就要再查。
