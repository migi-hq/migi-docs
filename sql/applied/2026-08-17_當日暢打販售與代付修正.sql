-- 【待執行】當日暢打：販售路徑、包桌也免、單店限定，並修掉代付全免的破洞
-- ============================================================
-- 規則（2026-08-17 拍板，見 docs/08-決策與踩坑/決策紀錄.md 第十九節）
--   ① 當天 23:59:59 前免費，隔天 00:00:00 開始收費
--   ② 配桌與包桌都免
--   ③ 在結帳頁的「檯費」分頁賣
--   ④ 先做單店限定，預留未來可跨店
--
-- 🔴 順帶修一個碰錢的破洞
--   join_session_tx 是 `v_unit × (1 + 代付人數)`，而 v_unit 來自
--   calc_session_fee_tx(session, join_type, **付款人**)。
--   付款人持有暢打時 v_unit = 0 —— **他幫另外三人代付，四份場地費全部免費**。
--   暢打是個人權利，不會因為誰付錢而轉移給別人。
--   → 改成逐人判斷：標準單價用 calc(..., null) 取得（不看暢打），
--     份數只算「沒有暢打的人」。
--
-- 為什麼暢打賣不掉（現況）
--   list_products_tx 不回傳 service 類（所以 POS 沒有「服務」分頁），
--   而且 SVC-TBL-DAY 的 kind='fee'，join_session_tx 會回 fee_item_not_allowed
--   —— 那個擋是為了防止前端重複送場地費，但暢打不是這一桌的場地費。
--   → 放行「product 是 SVC-TBL-DAY」的 fee 品項，其餘 fee 照擋。
--
--   同一次結帳買暢打時，這一桌的場地費要當場歸零 ——
--   否則 calc_session_fee_tx 跑的時候訂單還沒成立，has_daypass_tx 查不到，
--   會變成「暢打 300 + 場地費 150」一起收。
--
-- 為什麼 p_store_id 必填而不給預設值
--   有預設值時「忘記傳」會靜靜變成全連鎖通用 —— 那是收錢的行為。
--   給 null 表示不限店（未來要開放跨店就傳 null），必須是明寫的決定。
-- ============================================================

-- ① has_daypass_tx 加店別限定。改簽名，依硬規則 2 先 DROP。
drop function if exists public.has_daypass_tx(uuid, uuid);

create or replace function public.has_daypass_tx(
  p_org_id uuid, p_member_id uuid, p_store_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
      from orders o
      join order_items oi on oi.order_id = o.id
      join products pr on pr.id = oi.product_id
     where o.org_id = p_org_id
       and o.member_id = p_member_id
       and o.status = 'paid'
       and o.deleted_at is null
       and pr.sku = 'SVC-TBL-DAY'
       -- 單店限定：給 null 表示不限店（預留未來跨店）
       and (p_store_id is null or o.store_id = p_store_id)
       -- 以台北時區的「今天」為準
       and (o.created_at at time zone 'Asia/Taipei')::date
           = (now() at time zone 'Asia/Taipei')::date
  );
$function$;

comment on function public.has_daypass_tx(uuid, uuid, uuid) is
  '此會員今日（台北時區）是否已購買當日暢打。p_store_id 給值＝限該店、給 null＝全連鎖通用。不給預設值是刻意的：忘記傳會靜靜變成跨店，那是收錢的行為。';

-- ② calc_session_fee_tx：暢打判斷移到模式分支之前（包桌也免）
create or replace function public.calc_session_fee_tx(
  p_session_id uuid,
  p_join_type  text default 'opener',
  p_member_id  uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_s record; v_sku text; v_p record;
begin
  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  -- ★ 暢打先判，配桌包桌都免（2026-08-17 拍板）。
  --   舊版把這段寫在配桌那個 else 裡，理由是「包桌是場地費」——
  --   但包桌同日改成單人計價之後，兩者都是按人頭收的場地費，那個理由不再成立。
  --   暢打買的就是「今天在這間店打牌不再收場地費」。
  --   p_member_id 為 null 時跳過 —— 呼叫端要「不看暢打的標準單價」時就傳 null。
  if p_member_id is not null
     and has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id) then
    return jsonb_build_object('ok', true, 'amount', 0, 'product_id', null,
      'daypass', true, 'note', '此會員今日已購買當日暢打，不再收取場地費');
  end if;

  if v_s.mode = 'private' then
    -- 包桌：單人計價，與配桌對稱（2026-08-17）
    v_sku := case when v_s.planned_minutes <= 120 then 'SVC-TBL-P02'
                  when v_s.planned_minutes <= 300 then 'SVC-TBL-P05'
                  else 'SVC-TBL-P24' end;
  else
    v_sku := case when p_join_type = 'opener'
                  then (case when v_s.planned_rounds = 2 then 'SVC-TBL-M2' else 'SVC-TBL-M3' end)
                  else 'SVC-TBL-MID' end;
  end if;

  select id, sku, name, unit_price into v_p
    from products
   where sku = v_sku and org_id = v_s.org_id and is_active and deleted_at is null
   limit 1;
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'reason', 'product_not_found', 'sku', v_sku);
  end if;

  return jsonb_build_object('ok', true, 'product_id', v_p.id, 'sku', v_p.sku,
    'name', v_p.name, 'amount', v_p.unit_price, 'daypass', false);
end $function$;

comment on function public.calc_session_fee_tx(uuid, text, uuid) is
  '試算單人場地費。暢打優先（配桌包桌都免、限本店、台北時區當日）；其餘依模式挑 SKU：包桌看 planned_minutes、配桌看 planned_rounds。p_member_id 傳 null 可取得「不看暢打的標準單價」。';

-- ③ join_session_tx：逐人算份數 + 放行暢打商品
create or replace function public.join_session_tx(
  p_session_id uuid,
  p_member_id uuid,
  p_join_type text default 'opener',
  p_coupon_ids uuid[] default null,
  p_points_used bigint default 0,
  p_payments jsonb default null,
  p_staff_id uuid default null,
  p_idempotency_key text default null,
  p_pay_for uuid[] default null,
  p_items jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_s record; v_base jsonb; v_unit bigint; v_qty int; v_amount bigint;
  v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
  v_target uuid; v_created int := 0;
  v_extra int := 0;
  v_buy_daypass boolean := false;   -- ★ 本次結帳是否含當日暢打
  v_self_pass boolean := false;     -- ★ 付款人是否已持有暢打
begin
  if p_join_type not in ('opener','mid_join','sub') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_join_type');
  end if;

  -- 附加品項驗證。純輸入檢查，刻意排在查資料庫之前。
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  if v_extra > 0 then
    -- ★ 本次是否買了當日暢打。它是 kind='fee' 但不是「這一桌的場地費」，
    --   所以下面的 fee 擋要放行它。
    select exists (
      select 1 from jsonb_array_elements(p_items) it
       where exists (select 1 from products pr
                      where pr.id = nullif(it ->> 'product_id', '')::uuid
                        and pr.sku = 'SVC-TBL-DAY'))
      into v_buy_daypass;

    -- 場地費由本函式自己算，前端再送一份會重複收費。
    -- 暢打例外放行（它賣的是「今天不再收場地費」的權利，不是這一桌的費用）。
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'kind' = 'fee'
                  and not exists (select 1 from products pr
                                   where pr.id = nullif(it ->> 'product_id', '')::uuid
                                     and pr.sku = 'SVC-TBL-DAY')) then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed',
        'message', '場地費由系統計算，不可由前端傳入');
    end if;

    -- 儲值寫的是 topup_orders 不是 orders，不能混進同一張單
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'kind' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed',
        'message', '儲值請走儲值流程，不能併入結帳');
    end if;

    -- order_items.kind 只允許 fee/fnb/goods；product_id 是 NOT NULL
    if exists (select 1 from jsonb_array_elements(p_items) it
                where coalesce(it ->> 'kind', '') not in ('fee','fnb','goods')
                   or it ->> 'product_id' is null
                   or coalesce((it ->> 'qty')::int, 0) <= 0) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_item',
        'message', '品項需有 product_id、數量大於 0，且類別為 fnb 或 goods');
    end if;
  end if;

  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed',
      'message', '此場次已收桌或已作廢');
  end if;

  -- 鐵則一：一律會員
  if not exists (select 1 from members where id = p_member_id and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_required',
      'message', '需先建立會員資料');
  end if;

  if exists (select 1 from session_players
              where session_id = p_session_id and member_id = p_member_id
                and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_joined');
  end if;

  -- 座位上限：自己 + 代付人數不可超過 4
  if (select count(*) from session_players
       where session_id = p_session_id and left_at is null)
     + 1 + coalesce(array_length(p_pay_for, 1), 0) > 4 then
    return jsonb_build_object('ok', false, 'reason', 'table_full');
  end if;

  -- 被代付者必須是有效會員，且尚未入座
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if v_target = p_member_id then
        return jsonb_build_object('ok', false, 'reason', 'cannot_pay_for_self');
      end if;
      if not exists (select 1 from members where id = v_target and deleted_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_member_invalid',
          'member_id', v_target);
      end if;
      if exists (select 1 from session_players
                  where session_id = p_session_id and member_id = v_target
                    and left_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_already_joined',
          'member_id', v_target);
      end if;
    end loop;
  end if;

  -- ★ 標準單價：傳 null 取得「不看暢打」的價格。
  --   舊版用付款人的試算當單價，付款人持有暢打時單價 = 0，
  --   `v_unit × (1 + 代付人數)` 就讓四份全部免費 ——
  --   暢打是個人權利，不會因為誰付錢而轉移給別人。
  v_base := calc_session_fee_tx(p_session_id, p_join_type, null);
  if not (v_base ->> 'ok')::boolean then return v_base; end if;
  v_unit := coalesce((v_base ->> 'amount')::bigint, 0);

  -- ★ 份數逐人判斷：只算「這一桌要付場地費的人」。
  --   本次結帳有買暢打的話，付款人自己這一份當場歸零 ——
  --   否則 calc 跑的時候訂單還沒成立、has_daypass_tx 查不到，
  --   會變成「暢打 300 + 場地費 150」一起收。
  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);
  v_qty := 0;
  if not v_buy_daypass and not v_self_pass then
    v_qty := 1;
  end if;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if not has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then
        v_qty := v_qty + 1;
      end if;
    end loop;
  end if;
  v_amount := v_unit * v_qty;

  select count(*) + 1 into v_seq from session_players
   where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key,
                    p_session_id::text || ':' || p_member_id::text || ':' || v_seq);

  v_items := '[]'::jsonb;

  if v_amount > 0 then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id', v_base ->> 'product_id',
      'name',       v_base ->> 'name',
      'kind',       'fee',
      'qty',        v_qty,
      'unit_price', v_unit));
  end if;

  if v_extra > 0 then
    v_items := v_items || p_items;
  end if;

  if jsonb_array_length(v_items) > 0 then
    v_res := checkout_tx(
      p_member_id, v_s.store_id, v_items, p_coupon_ids,
      coalesce(p_points_used, 0), p_payments, v_key, p_staff_id);

    v_order := (v_res ->> 'order_id')::uuid;

    update orders o
       set session_id = p_session_id,
           table_id   = v_s.table_id,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id,
                                 (select entity_id from stores where id = v_s.store_id))
     where o.id = v_order;
  end if;

  -- 付款人自己入座
  insert into session_players(
    org_id, session_id, member_id, join_type, status,
    charged_points, order_id, joined_at, created_by)
  values (
    v_s.org_id, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id)
  returning id into v_sp;

  -- 被代付者一併入座：有入座記錄但沒有訂單，消費金額掛在代付人身上
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      insert into session_players(
        org_id, session_id, member_id, join_type, status,
        charged_points, order_id, paid_by, joined_at, created_by)
      values (
        v_s.org_id, p_session_id, v_target, p_join_type, 'playing',
        0, null, p_member_id, now(), p_staff_id);
      v_created := v_created + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'player_id', v_sp,
    'order_id', v_order, 'unit_fee', v_unit, 'qty', v_qty,
    'listed_amount', v_amount, 'paid_for_count', v_created,
    'extra_items', v_extra,
    'daypass', v_self_pass,
    'daypass_bought', v_buy_daypass,
    'checkout', v_res);
end $function$;

comment on function public.join_session_tx(uuid, uuid, text, uuid[], bigint, jsonb, uuid, text, uuid[], jsonb) is
  '入座並收費。場地費份數**逐人判斷**：只算沒有當日暢打的人（暢打是個人權利，不因誰付錢而轉移）。p_items 可帶餐飲/商品，以及當日暢打（唯一放行的 fee 品項）；本次買暢打時付款人自己那份場地費當場歸零。';

-- ④ 暢打商品要讓 POS 撈得到
--    list_products_tx 不回 service 類，所以 POS 沒有「服務」分頁，
--    OpenCheckoutPage 那三處 sku === 'SVC-TBL-DAY' 的特判一直是空轉的。
--    另開一支只回暢打的，避免動 list_products_tx 影響現有分頁。
drop function if exists public.list_daypass_tx(uuid);

create or replace function public.list_daypass_tx(p_org_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',          p.id,
           'sku',         p.sku,
           'name',        p.name,
           'unit_price',  p.unit_price,
           'kind',        'fee')), '[]'::jsonb)
    from public.products p
   where p.org_id = p_org_id
     and p.sku = 'SVC-TBL-DAY'
     and p.is_active
     and p.deleted_at is null;
$$;

comment on function public.list_daypass_tx(uuid) is
  '當日暢打商品（SVC-TBL-DAY）。list_products_tx 不回 service 類，POS 要在「檯費」分頁賣它得單獨撈。';

grant execute on function public.list_daypass_tx(uuid) to anon, authenticated;

-- ============================================================
-- 驗證（單一 SELECT）
--   has_daypass 三參數版 1、舊兩參數版 0、
--   暢打商品可撈到 true、包桌判斷已前移 true、
--   份數改逐人 true、仍呼叫兩參數版的函式數 0。
--   煙霧測試：不存在的場次應回 session_not_found。
-- ============================================================
with fns as materialized (
  select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select
  (select count(*) from fns
    where proname = 'has_daypass_tx' and args like '%uuid, %uuid, %uuid')     as 三參數版,
  (select count(*) from fns
    where proname = 'has_daypass_tx' and args = 'p_org_id uuid, p_member_id uuid') as 舊兩參數版,
  (select jsonb_array_length(public.list_daypass_tx(
     (select org_id from public.stores limit 1))) = 1)                        as 暢打商品可撈到,
  (select pg_get_functiondef(oid) like '%暢打先判%' from fns
    where proname = 'calc_session_fee_tx' limit 1)                            as 包桌判斷已前移,
  (select pg_get_functiondef(oid) like '%份數逐人判斷%' from fns
    where proname = 'join_session_tx' limit 1)                                as 份數改逐人,
  (select count(*) from fns
    where pg_get_functiondef(oid) like '%has_daypass_tx(%'
      and pg_get_functiondef(oid) not like '%has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id)%'
      and pg_get_functiondef(oid) not like '%has_daypass_tx(v_s.org_id, v_target, v_s.store_id)%'
      and proname <> 'has_daypass_tx')                                        as 可能仍用舊簽名的函式數,
  (public.calc_session_fee_tx(
     '00000000-0000-0000-0000-000000000000'::uuid) ->> 'reason')              as 煙霧測試;
