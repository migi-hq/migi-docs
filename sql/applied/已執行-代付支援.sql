-- ============================================================
-- 代付支援：一人付多份檯費
--
-- 【需求】不分配桌包桌，都可能有人幫其他人付檯費。
--   實務上「誰出錢，帳就是誰的」——消費累積、發票都算買單的人，
--   被代付者只有入座記錄、沒有訂單。
--
-- 【本檔改動】
--   ① session_players 加 paid_by 欄位，記錄這位的檯費由誰支付
--   ② join_session_tx 加 p_pay_for 參數（被代付者 id 陣列）：
--        · 檯費份數 = 1（自己）+ 代付人數
--        · 為每位被代付者建立 session_players（charged_points=0、paid_by=代付人）
--        · 被代付者不另外建立 orders
--
-- 【為何被代付者仍要建 session_players】
--   他們確實入座了。少了這筆記錄會導致：
--     · 收桌時算不出實際入座人數
--     · M4 段位計算漏掉這些人的牌局
--     · CRM 看不出他們來過店裡
--   只是 charged_points 為 0，消費金額掛在代付人身上。
-- ============================================================


-- ============================================================
-- ① session_players 加代付欄位
-- ============================================================
ALTER TABLE session_players
  ADD COLUMN IF NOT EXISTS paid_by uuid REFERENCES members(id);

COMMENT ON COLUMN session_players.paid_by IS
  '此位的檯費由誰支付。null=自己付；有值=由該會員代付（本人 charged_points 為 0）';

CREATE INDEX IF NOT EXISTS idx_session_players_paid_by
  ON session_players(paid_by) WHERE paid_by IS NOT NULL;


-- ============================================================
-- ② join_session_tx 支援代付
--    改動簽名（新增 p_pay_for），依鐵則先 DROP 舊版避免新舊並存
-- ============================================================
DROP FUNCTION IF EXISTS public.join_session_tx(uuid, uuid, text, uuid[], bigint, jsonb, uuid, text);

CREATE OR REPLACE FUNCTION public.join_session_tx(
  p_session_id uuid,
  p_member_id uuid,
  p_join_type text DEFAULT 'opener',
  p_coupon_ids uuid[] DEFAULT NULL,
  p_points_used bigint DEFAULT 0,
  p_payments jsonb DEFAULT NULL,
  p_staff_id uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_pay_for uuid[] DEFAULT NULL)      -- 新增：這位要幫哪些人付檯費
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s record; v_fee jsonb; v_unit bigint; v_qty int; v_amount bigint;
  v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
  v_target uuid; v_created int := 0;
begin
  if p_join_type not in ('opener','mid_join','sub') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_join_type');
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

  if v_amount > 0 then
    v_items := jsonb_build_array(jsonb_build_object(
      'product_id', v_fee ->> 'product_id',
      'name',       v_fee ->> 'name',
      'kind',       'fee',
      'qty',        v_qty,
      'unit_price', v_unit));

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
    'daypass', coalesce((v_fee ->> 'daypass')::boolean, false),
    'checkout', v_res);
end $function$;


-- ============================================================
-- ③ get_session_tx 回傳代付關係（POS 顯示「代付中」用）
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_session_tx(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return (
    select jsonb_build_object(
      'id', s.id, 'status', s.status, 'mode', s.mode,
      'is_playing', (s.activated_at is not null),
      'table_id', s.table_id, 'table_label', t.label, 'area', t.area,
      'planned_rounds', s.planned_rounds, 'planned_minutes', s.planned_minutes,
      'started_at', s.started_at, 'activated_at', s.activated_at,
      'stake_level_id', s.stake_level_id,
      'stake_label', (select label from stake_levels where id = s.stake_level_id),
      'fee_total', (select coalesce(sum(charged_points),0) from session_players
                     where session_id = s.id and left_at is null),
      'players', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'player_id', sp.id, 'member_id', m.id, 'nickname', m.display_name,
          'rank', m.rank, 'avatar_source', m.avatar_source,
          'avatar_photo_path', m.avatar_photo_path,
          'join_type', sp.join_type, 'seat', sp.seat, 'status', sp.status,
          'charged', sp.charged_points, 'joined_at', sp.joined_at,
          'order_id', sp.order_id,
          'paid_by', sp.paid_by,
          'paid_by_name', (select display_name from members where id = sp.paid_by)
        ) order by sp.joined_at), '[]'::jsonb)
        from session_players sp join members m on m.id = sp.member_id
        where sp.session_id = s.id and sp.left_at is null)
    )
    from table_sessions s
    left join tables t on t.id = s.table_id
    where s.id = p_session_id
  );
end $function$;


-- ============================================================
-- ④ 驗證
-- ============================================================
SELECT '① paid_by 欄位' AS 項目,
       (SELECT string_agg(column_name || ' (' || data_type || ')', ', ')
        FROM information_schema.columns
        WHERE table_schema='public' AND table_name='session_players'
          AND column_name='paid_by') AS 內容
UNION ALL
SELECT '② join_session_tx 版本數（應為 1）',
       (SELECT count(*)::text || ' 個 · ' || string_agg(pronargs::text, ',')
        FROM pg_proc WHERE proname='join_session_tx')
UNION ALL
SELECT '③ join_session_tx 參數',
       (SELECT pg_get_function_arguments(oid) FROM pg_proc
        WHERE proname='join_session_tx' LIMIT 1)
UNION ALL
SELECT '④ get_session_tx 已含 paid_by',
       (SELECT CASE WHEN prosrc ILIKE '%paid_by_name%' THEN '✓' ELSE '✗' END
        FROM pg_proc WHERE proname='get_session_tx' LIMIT 1);


-- ============================================================
-- POS 端呼叫方式
-- ============================================================
-- 小明幫阿強、美美付（配桌 3 將，每份 150）：
--   join_session_tx(
--     場次id, 小明id, 'opener',
--     NULL,                      -- 優惠券
--     450,                       -- 點數折抵
--     NULL,                      -- 現金收款明細
--     店員id, NULL,
--     ARRAY[阿強id, 美美id]      -- ★ 代付名單
--   );
--
-- 結果：
--   orders  小明 1 張，明細「配桌檯費·3將 ×3 = 450」
--   session_players  三筆：
--     小明 charged_points=450, order_id=有值, paid_by=null
--     阿強 charged_points=0,   order_id=null, paid_by=小明
--     美美 charged_points=0,   order_id=null, paid_by=小明
-- ============================================================
