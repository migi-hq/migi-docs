-- ============================================================
-- join_session_tx 加 p_items：首次結帳一併收購物車品項
-- ------------------------------------------------------------
-- 【問題】
--   首次結帳走 join_session_tx，它只收自己用 calc_session_fee_tx 算的檯費，
--   **沒有 items 參數** —— 開桌時加的餐飲／商品一項都沒送出去。
--   而前端送的 p_payments 含了那些金額，checkout_tx 第 6 步
--   「收款驗證：payments 總和必須剛好等於應付減點數」必然拋例外。
--   這條路（最常用的路徑）等於結不掉帳。
--   加購那條路走 pos_addon_checkout_tx，有送 items，所以一直沒被發現。
--
-- 【線上版來源】
--   2026-08-16 以 pg_get_functiondef 撈出（硬規則 3）。
--   本檔在該版本上只做必要修改，其餘邏輯一字未動。
--   撈出時確認線上只有 1 個版本，故 DROP 一次即可清乾淨。
--
-- 【必須 DROP FUNCTION】
--   加參數＝改簽名，CREATE OR REPLACE 不會覆蓋，會建出多載版本（硬規則 2）。
--   舊簽名：join_session_tx(uuid,uuid,text,uuid[],bigint,jsonb,uuid,text,uuid[])
--
-- 【三個設計決定】
--   ① p_items 放在參數列最後 —— PostgREST 依參數名解析，順序不影響前端，
--      放最後對任何位置呼叫的舊程式碼衝擊最小。
--   ② 拒收 kind='fee' —— 檯費由本函式自己算。前端若也送一份會重複收費。
--   ③ 拒收 kind='topup' —— 儲值寫的是 topup_orders 不是 orders，
--      本來就不該混進同一張單。要走 topup_tx，獨立一步。
--
-- 【已知且未在本檔處理】
--   p_items 的 unit_price 仍由前端傳入，checkout_tx 不查 products 主檔
--   （CLAUDE.md 待辦 2）。本次只是讓首次結帳與加購走同一條既有路徑，
--   沒有擴大既有風險 —— pos_addon_checkout_tx 早就這樣。
--   根本解（只送 product_id + qty）要連 checkout_tx 一起改，
--   時機是 KIOSK 開工前。
--
--   ⚠️ charged_points 的語意會變寬：原本這條路只有檯費，
--   所以它等於「此人實付檯費（折後）」；加入商品後它變成「此人本單實付總額」。
--   get_session_tx 的 'fee_total' 是 sum(charged_points)，
--   數字會從「檯費合計」變成「實付合計」。
--   本檔**刻意不改這個行為** —— 要拆分檯費與商品各自的折後金額，
--   得先決定折扣如何分攤，那是另一個決策。先照舊，並在此記明。
-- ============================================================

DROP FUNCTION IF EXISTS public.join_session_tx(
  uuid, uuid, text, uuid[], bigint, jsonb, uuid, text, uuid[]);

CREATE OR REPLACE FUNCTION public.join_session_tx(
  p_session_id      uuid,
  p_member_id       uuid,
  p_join_type       text   DEFAULT 'opener'::text,
  p_coupon_ids      uuid[] DEFAULT NULL::uuid[],
  p_points_used     bigint DEFAULT 0,
  p_payments        jsonb  DEFAULT NULL::jsonb,
  p_staff_id        uuid   DEFAULT NULL::uuid,
  p_idempotency_key text   DEFAULT NULL::text,
  p_pay_for         uuid[] DEFAULT NULL::uuid[],
  p_items           jsonb  DEFAULT NULL::jsonb)      -- ★ 新增：購物車的餐飲／商品
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s record; v_fee jsonb; v_unit bigint; v_qty int; v_amount bigint;
  v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
  v_target uuid; v_created int := 0;
  v_extra int := 0;                                  -- ★ 附加品項筆數
begin
  if p_join_type not in ('opener','mid_join','sub') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_join_type');
  end if;

  -- ★ 附加品項驗證。純輸入檢查，刻意排在查資料庫之前 ——
  --   格式錯誤不該先耗一輪查詢，而且這樣才擋得住「參數本身就不合法」的呼叫。
  --   與其讓 checkout_tx 或資料庫約束拋英文錯誤（店員看不懂欄位名），
  --   不如在這裡回可讀的 reason。
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  if v_extra > 0 then
    -- 檯費由本函式自己算，前端再送一份會重複收費
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'kind' = 'fee') then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed',
        'message', '檯費由系統計算，不可由前端傳入');
    end if;

    -- 儲值寫的是 topup_orders 不是 orders，不能混進同一張單
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'kind' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed',
        'message', '儲值請走儲值流程，不能併入結帳');
    end if;

    -- order_items.kind 只允許 fee/fnb/goods；product_id 是 NOT NULL
    if exists (select 1 from jsonb_array_elements(p_items) it
                where coalesce(it ->> 'kind', '') not in ('fnb','goods')
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

  -- 單份檯費（暢打判斷以付款人為準）
  v_fee := calc_session_fee_tx(p_session_id, p_join_type, p_member_id);
  if not (v_fee ->> 'ok')::boolean then return v_fee; end if;
  v_unit := coalesce((v_fee ->> 'amount')::bigint, 0);

  -- 份數 = 自己 1 份 + 代付人數
  v_qty := 1 + coalesce(array_length(p_pay_for, 1), 0);
  v_amount := v_unit * v_qty;

  select count(*) + 1 into v_seq from session_players
   where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key,
                    p_session_id::text || ':' || p_member_id::text || ':' || v_seq);

  -- ★ 檯費與附加品項合成同一張單。
  --   原本只有 v_amount > 0 才建單；現在只要「檯費或商品其中之一有金額」就要建，
  --   否則包桌後續入座的人買了東西會收不到錢。
  v_items := '[]'::jsonb;

  if v_amount > 0 then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id', v_fee ->> 'product_id',
      'name',       v_fee ->> 'name',
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
    'extra_items', v_extra,                          -- ★ 這次一併收了幾項商品
    'daypass', coalesce((v_fee ->> 'daypass')::boolean, false),
    'checkout', v_res);
end $function$;

COMMENT ON FUNCTION public.join_session_tx IS
  '入座並收費：檯費由 calc_session_fee_tx 自算，p_items 可一併帶入餐飲/商品（拒收 fee 與 topup），全部委派 checkout_tx 開成同一張單。';


-- ============================================================
-- 驗證（單一 SELECT）
-- ------------------------------------------------------------
-- 期待：
--   版本數      = 1              （DROP 有生效，沒留下多載）
--   簽名        = …,uuid[],jsonb  （最後一個是新加的 p_items）
--   安全模式    = DEFINER
--   煙霧測試    = session_not_found
--                （拿不存在的場次呼叫，證明函式真的跑得起來且無副作用 —— 硬規則 7）
--   擋儲值      = topup_not_allowed
--                （帶一筆 kind=topup，證明新的驗證分支真的有執行到）
-- ============================================================
select
  (select count(*)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'join_session_tx')          as 版本數,

  (select p.oid::regprocedure::text
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'join_session_tx'
    limit 1)                                                              as 簽名,

  (select case when p.prosecdef then 'DEFINER' else 'INVOKER' end
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'join_session_tx'
    limit 1)                                                              as 安全模式,

  (join_session_tx('00000000-0000-0000-0000-000000000000'::uuid,
                   '00000000-0000-0000-0000-000000000000'::uuid) ->> 'reason')
                                                                          as 煙霧測試,

  -- 品項驗證排在查資料庫之前，所以用不存在的場次與會員也測得到
  (join_session_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'opener', null, 0, null, null, null, null,
      jsonb_build_array(jsonb_build_object(
        'product_id','00000000-0000-0000-0000-000000000000',
        'name','會員儲值','kind','topup','qty',1,'unit_price',1000))
   ) ->> 'reason')                                                        as 擋儲值,

  (join_session_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'opener', null, 0, null, null, null, null,
      jsonb_build_array(jsonb_build_object(
        'product_id','00000000-0000-0000-0000-000000000000',
        'name','配桌檯費','kind','fee','qty',1,'unit_price',150))
   ) ->> 'reason')                                                        as 擋重複檯費;
