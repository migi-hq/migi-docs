-- ============================================================
-- topup_orders 加 cash_received / change_given，並讓桌帳回傳
-- ------------------------------------------------------------
-- 【問題】
--   消費全部用點數付、儲值收現金時，收據上的實收現金與找零整個消失。
--   實測：測試03 消費 $140 全用點數、儲值 $500 收現金、實收 $1000 找零 $500，
--   結完帳後收據只剩「現金 $500」，找零沒有任何紀錄。
--
--   原因：前端的 payments 是
--       orderCash > 0 ? [{..., cash_received, change_given}] : null
--   而 orderCash = 消費應付 − 點數折抵 = 140 − 140 = 0，
--   所以 order_payments 一筆都沒寫，實收與找零沒有地方記。
--
--   最討厭的是它**時有時無** —— 消費有現金要付時找零會出現，
--   全部用點數付時就不見。店員無法預期，這比一直沒有更糟。
--
-- 【根因與第 27 條同類】
--   order_payments 有 cash_received / change_given 兩欄，topup_orders 沒有。
--   同一件事（記錄實收找零）在兩張單據上有兩種能力，
--   只要現金落到沒有欄位的那一張，資訊就消失。
--
-- 【規則：實收找零只記在一張單上】
--   實體收款是**一次事件**，不該重複記錄。
--     消費有現金要收 → 記在 order_payments（維持現狀）
--     消費不用收現金 → 記在 topup_orders
--   由前端依 orderCash 是否為 0 決定送哪一邊，兩邊不會同時有值。
--
-- 【線上版來源】
--   兩支函式都是我在 2026-08-16 本次工作階段建立並驗證過的版本，
--   sql/applied/ 下的檔案與執行內容一致，未再經他人修改。
--   本檔以那些檔案為基礎，只加必要的欄位與參數傳遞。
--   驗證段會確認版本數與新簽名，若線上與預期不符會立刻看得出來。
--
-- 【pos_checkout_with_topup_tx 加參數 = 改簽名 → 必須先 DROP】（硬規則 2）
--   get_session_member_orders_tx 簽名不變，CREATE OR REPLACE 即可。
-- ============================================================


-- ============================================================
-- ① 加欄位
-- ============================================================
alter table topup_orders
  add column if not exists cash_received bigint,
  add column if not exists change_given  bigint;

comment on column topup_orders.cash_received is
  '實收現金。只有在「這次收款的現金全部歸儲值」時才有值（消費有現金要收時記在 order_payments）。';
comment on column topup_orders.change_given is
  '找零。與 cash_received 成對，同上。';


-- ============================================================
-- ② pos_checkout_with_topup_tx 接收並寫入實收找零
-- ============================================================
DROP FUNCTION IF EXISTS public.pos_checkout_with_topup_tx(
  uuid, uuid, text, jsonb, uuid[], bigint, jsonb, uuid[], uuid, text,
  bigint, bigint, bigint, text);

CREATE OR REPLACE FUNCTION public.pos_checkout_with_topup_tx(
  p_session_id          uuid,
  p_member_id           uuid,
  p_join_type           text   DEFAULT 'opener'::text,
  p_items               jsonb  DEFAULT NULL::jsonb,
  p_coupon_ids          uuid[] DEFAULT NULL::uuid[],
  p_points_used         bigint DEFAULT 0,
  p_payments            jsonb  DEFAULT NULL::jsonb,
  p_pay_for             uuid[] DEFAULT NULL::uuid[],
  p_staff_id            uuid   DEFAULT NULL::uuid,
  p_idempotency_key     text   DEFAULT NULL::text,
  p_topup_points        bigint DEFAULT 0,
  p_topup_bonus         bigint DEFAULT 0,
  p_topup_amount        bigint DEFAULT 0,
  p_topup_method        text   DEFAULT 'cash'::text,
  -- ★ 新增：現金全部歸儲值時，實收與找零記在儲值單上
  p_topup_cash_received bigint DEFAULT NULL,
  p_topup_change_given  bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s      record;
  v_topup  jsonb := null;
  v_join   jsonb := null;
  v_base   text;
  v_seated boolean;
  v_extra  int := 0;
  v_mode   text;
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

  -- 由資料庫判斷是否已入座，不採信前端傳來的推測值
  select exists (
    select 1 from session_players sp
     where sp.session_id = p_session_id
       and sp.member_id  = p_member_id
       and sp.left_at is null) into v_seated;

  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  v_mode := case
              when not v_seated   then 'join'
              when v_extra > 0    then 'addon'
              else 'topup_only'
            end;

  if v_mode = 'topup_only' and p_topup_points <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_do',
      'message', '這位客人已入座，請選擇商品或儲值');
  end if;

  v_base := coalesce(p_idempotency_key,
                     p_session_id::text || ':' || p_member_id::text);

  -- ══ 原子區塊：任何一步 raise，整段回滾 ══
  begin

    if p_topup_points > 0 then
      v_topup := topup_tx(
        p_member_id, v_s.store_id, p_topup_points, p_topup_amount,
        p_topup_method, v_base || ':topup', p_topup_bonus,
        null, p_staff_id, 'POS 結帳時儲值');

      -- 回填桌次脈絡與實收找零。
      -- 實收找零只有在「現金全部歸儲值」時才會有值 ——
      -- 消費有現金要收時，前端會把它記在 order_payments 那邊，
      -- 兩邊不會同時有值（實體收款是一次事件，不該重複記錄）。
      update topup_orders
         set session_id    = p_session_id,
             cash_received = p_topup_cash_received,
             change_given  = p_topup_change_given
       where id = (v_topup ->> 'topup_id')::uuid;
    end if;

    if v_mode = 'join' then
      v_join := join_session_tx(
        p_session_id, p_member_id, p_join_type, p_coupon_ids,
        coalesce(p_points_used, 0), p_payments, p_staff_id,
        v_base || ':order', p_pay_for, p_items);

    elsif v_mode = 'addon' then
      v_join := pos_addon_checkout_tx(
        p_session_id, p_member_id, p_items, p_coupon_ids,
        coalesce(p_points_used, 0), p_payments,
        v_base || ':order', p_staff_id);
    end if;

    -- 兩支結帳函式的業務錯誤都是「回傳 ok:false」而不是拋例外。
    -- 不主動 raise 的話交易會照常提交 —— 儲值就留下來了。
    if v_join is not null
       and not coalesce((v_join ->> 'ok')::boolean, false) then
      raise exception 'checkout_failed:%',
        coalesce(v_join ->> 'reason', 'unknown') using errcode = 'P0001';
    end if;

  exception
    when others then
      if SQLERRM like 'checkout_failed:%' then
        return jsonb_build_object('ok', false,
          'reason', split_part(SQLERRM, ':', 2),
          'stage', 'checkout', 'mode', v_mode,
          'message', case when p_topup_points > 0
                          then '結帳失敗，儲值已一併取消'
                          else '結帳失敗' end);
      end if;
      return jsonb_build_object('ok', false, 'reason', 'topup_failed',
        'stage', case when v_topup is null then 'topup' else 'checkout' end,
        'mode', v_mode, 'message', SQLERRM);
  end;

  return jsonb_build_object(
    'ok', true, 'mode', v_mode,
    'topup', v_topup, 'checkout', v_join,
    'new_balance', v_topup ->> 'new_balance');
end $function$;

COMMENT ON FUNCTION public.pos_checkout_with_topup_tx IS
  'POS 一次收款完成儲值 + 結帳。單一交易，任一步失敗一起回滾。'
  '由後端判斷未入座走 join、已入座走 addon、無商品則只儲值。'
  '實收找零只記在一張單上：消費有現金記 order_payments，否則記 topup_orders。';


-- ============================================================
-- ③ 桌帳回傳儲值單的實收找零
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
               'items', jsonb_build_array(jsonb_build_object(
                 'name', '會員儲值 ' || (t.points + t.bonus_points)::text || ' 點',
                 'kind', 'topup', 'qty', 1,
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


-- ============================================================
-- 驗證（單一 SELECT）
-- ------------------------------------------------------------
-- 期待：
--   欄位已加        = 2   （cash_received / change_given）
--   checkout版本數  = 1   （DROP 有生效，沒留下多載）
--   checkout簽名    結尾為 …,text,bigint,bigint（最後兩個是新加的）
--   桌帳版本數      = 1
--   煙霧測試        = session_not_found
--   桌帳含找零欄位  = true（回傳的 topup 物件裡看得到 cash_received）
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
      and column_name in ('cash_received','change_given'))              as 欄位已加,

  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='pos_checkout_with_topup_tx') as checkout版本數,

  (select p.oid::regprocedure::text
     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='pos_checkout_with_topup_tx'
    limit 1)                                                            as checkout簽名,

  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='get_session_member_orders_tx') as 桌帳版本數,

  (pos_checkout_with_topup_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid) ->> 'reason')       as 煙霧測試,

  (select (get_session_member_orders_tx(p.session_id, p.member_id)
             -> 'orders' -> 0 -> 'topup') ? 'cash_received'
     from probe p)                                                      as 桌帳含找零欄位;
