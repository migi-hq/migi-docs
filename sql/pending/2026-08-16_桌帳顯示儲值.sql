-- ============================================================
-- 讓桌帳看得到儲值：topup_orders 加 session_id，並併進本場交易列表
-- ------------------------------------------------------------
-- 【問題】
--   儲值寫 topup_orders，收據與本場列表讀的是 get_session_member_orders_tx
--   （查 orders）。兩張不同的單據流，互相看不到。
--   店員剛收了現金卻在畫面上找不到那筆，無法對帳、也無法回答客人。
--
-- 【根因】
--   orders 有 session_id / table_id（join_session_tx 會回填），
--   topup_orders 沒有任何桌次脈絡。
--
-- 【三步】
--   ① topup_orders 加 session_id（**可為 null**）
--   ② pos_checkout_with_topup_tx 回填，比照 join_session_tx 對 orders 的做法
--   ③ get_session_member_orders_tx 併入儲值單
--
-- 【為什麼 session_id 必須允許 null】
--   會員在 App 自助儲值時沒有桌次脈絡。設 NOT NULL 會把那條路擋死。
--
-- 【線上版來源】
--   兩支函式皆於 2026-08-16 以 pg_get_functiondef 撈出（硬規則 3）。
--   簽名皆未變更，CREATE OR REPLACE 不會產生多載，不需 DROP。
--     get_session_member_orders_tx(uuid,uuid)                    DEFINER
--     pos_checkout_with_topup_tx(uuid,uuid,text,jsonb,uuid[],
--       bigint,jsonb,uuid[],uuid,text,bigint,bigint,bigint,text) DEFINER
--
-- 【合計欄位的語意刻意不動】
--   total_payable / total_points_used / total_cash_due 仍只算 orders ——
--   儲值是預收款不是消費，混進去那些數字會失去意義。
--   另外新增 total_topup，要用的人自己取。
-- ============================================================


-- ============================================================
-- ① 加欄位
-- ============================================================
alter table topup_orders
  add column if not exists session_id uuid references table_sessions(id);

create index if not exists idx_topup_orders_session
  on topup_orders(session_id) where session_id is not null;

comment on column topup_orders.session_id is
  '在哪一桌收的（POS 結帳時儲值）。會員 App 自助儲值為 null。';


-- ============================================================
-- ①b 一次性回填既有資料
--
-- POS 的冪等鍵格式是 pos-<sessionId>-<memberId>-<時間戳>:topup，
-- session id 就編在裡面 —— 從第 5 個字元起算 36 碼。
-- 只回填「解出來的 uuid 確實對應到一個存在的場次」的那些，
-- 解錯就跳過，不硬塞。
-- ============================================================
update topup_orders t
   set session_id = substring(t.idempotency_key from 5 for 36)::uuid
 where t.session_id is null
   and t.idempotency_key like 'pos-%:topup'
   and length(t.idempotency_key) > 41
   and substring(t.idempotency_key from 5 for 36) ~
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   and exists (select 1 from table_sessions s
                where s.id = substring(t.idempotency_key from 5 for 36)::uuid);


-- ============================================================
-- ② 回填 session_id（新的儲值）
-- ============================================================
CREATE OR REPLACE FUNCTION public.pos_checkout_with_topup_tx(
  p_session_id      uuid,
  p_member_id       uuid,
  p_join_type       text   DEFAULT 'opener'::text,
  p_items           jsonb  DEFAULT NULL::jsonb,
  p_coupon_ids      uuid[] DEFAULT NULL::uuid[],
  p_points_used     bigint DEFAULT 0,
  p_payments        jsonb  DEFAULT NULL::jsonb,
  p_pay_for         uuid[] DEFAULT NULL::uuid[],
  p_staff_id        uuid   DEFAULT NULL::uuid,
  p_idempotency_key text   DEFAULT NULL::text,
  p_topup_points    bigint DEFAULT 0,
  p_topup_bonus     bigint DEFAULT 0,
  p_topup_amount    bigint DEFAULT 0,
  p_topup_method    text   DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s      record;
  v_topup  jsonb := null;
  v_join   jsonb;
  v_base   text;
begin
  if p_topup_points > 0 and coalesce(p_idempotency_key, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'idempotency_key_required',
      'message', '含儲值的結帳必須帶冪等鍵');
  end if;

  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed',
      'message', '此場次已收桌或已作廢');
  end if;

  v_base := coalesce(p_idempotency_key,
                     p_session_id::text || ':' || p_member_id::text);

  begin
    if p_topup_points > 0 then
      v_topup := topup_tx(
        p_member_id, v_s.store_id, p_topup_points, p_topup_amount,
        p_topup_method, v_base || ':topup', p_topup_bonus,
        null, p_staff_id, 'POS 結帳時儲值');

      -- ★ 回填桌次脈絡，比照 join_session_tx 對 orders 的做法。
      --   沒有這一步，儲值單就查不出「是在哪一桌收的」，桌帳與對帳都看不到。
      --   冪等重放時 topup_tx 一樣會回 topup_id，這個 update 重跑無害。
      update topup_orders
         set session_id = p_session_id
       where id = (v_topup ->> 'topup_id')::uuid;
    end if;

    v_join := join_session_tx(
      p_session_id, p_member_id, p_join_type, p_coupon_ids,
      coalesce(p_points_used, 0), p_payments, p_staff_id,
      v_base || ':order', p_pay_for, p_items);

    -- join_session_tx 的業務錯誤是回傳 ok:false 而不是拋例外，
    -- 不主動 raise 的話交易會照常提交 —— 儲值就留下來了。
    if not coalesce((v_join ->> 'ok')::boolean, false) then
      raise exception 'join_failed:%',
        coalesce(v_join ->> 'reason', 'unknown') using errcode = 'P0001';
    end if;

  exception
    when others then
      if SQLERRM like 'join_failed:%' then
        return jsonb_build_object('ok', false,
          'reason', split_part(SQLERRM, ':', 2), 'stage', 'checkout',
          'message', '結帳失敗，儲值已一併取消');
      end if;
      return jsonb_build_object('ok', false, 'reason', 'topup_failed',
        'stage', case when v_topup is null then 'topup' else 'checkout' end,
        'message', SQLERRM);
  end;

  return jsonb_build_object('ok', true,
    'topup', v_topup, 'checkout', v_join,
    'new_balance', v_topup ->> 'new_balance');
end $function$;


-- ============================================================
-- ③ 本場列表併入儲值
--
-- 每一列多一個 'type'：'order' 消費單 / 'topup' 儲值單。
-- 儲值列刻意組成與訂單相同的形狀（items / payments），
-- 前端的 OrderDetail 才能沿用同一份元件渲染，不必另寫一套。
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
      -- ── 消費單 ──
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
                 from order_payments pm where pm.order_id = o.id)
             ) as x
        from orders o
       where o.session_id = p_session_id
         and o.member_id  = p_member_id
         and o.deleted_at is null
         and o.status <> 'void'

      union all

      -- ── 儲值單 ──
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
               -- 儲值特有：入帳點數與贈點
               'points', t.points,
               'bonus_points', t.bonus_points,
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
    ) u;

  return jsonb_build_object(
    'orders', v_list,
    -- 以下三個合計**只算消費單**，語意不變 ——
    -- 儲值是預收款不是消費，混進去這些數字就沒有意義了。
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
    -- 新增：本場儲值合計（元），要用的人自己取
    'total_topup', (
      select coalesce(sum(t.amount_twd), 0) from topup_orders t
       where t.session_id = p_session_id and t.member_id = p_member_id
         and t.status = 'paid'));
end $function$;


-- ============================================================
-- 驗證（單一 SELECT）
-- ------------------------------------------------------------
-- 期待：
--   session欄位        = 1
--   函式版本數         = 2   （兩支各一個版本，沒有多載）
--   已回填的儲值單     ≥ 1   （先前那筆 TP-S02-260816-0001 應被冪等鍵救回）
--   實測筆數 / 實測儲值合計 = 那一場的實際內容
--   含type欄位         = true
-- ============================================================
with probe as (
  select t.session_id, t.member_id
    from topup_orders t
   where t.session_id is not null
   order by t.created_at desc
   limit 1
)
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='topup_orders'
      and column_name='session_id')                              as session欄位,

  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('get_session_member_orders_tx','pos_checkout_with_topup_tx'))
                                                                 as 函式版本數,

  (select count(*) from topup_orders where session_id is not null) as 已回填的儲值單,

  (select jsonb_array_length(
            get_session_member_orders_tx(p.session_id, p.member_id) -> 'orders')
     from probe p)                                               as 實測筆數,

  (select get_session_member_orders_tx(p.session_id, p.member_id) ->> 'total_topup'
     from probe p)                                               as 實測儲值合計,

  (select get_session_member_orders_tx(p.session_id, p.member_id)
            -> 'orders' -> 0 ? 'type'
     from probe p)                                               as 含type欄位;
