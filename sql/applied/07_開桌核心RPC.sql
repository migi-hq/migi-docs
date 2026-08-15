-- 【已執行】M2 開桌核心六支 RPC + 欄位/索引/約束，並封存 v1.0 舊收費函式。開桌流程的完整後端。
-- ============================================================
-- M2 開桌核心 RPC（v4）
--
-- 【v4 相對 v3 的修正，共兩處】
--   ① 中途加入／代打改用 SVC-TBL-MID（v3 誤用 SVC-TBL-M2）
--      依《MIGI_商品與貨號規範_v2.0》：MID 獨立不共用 M2。
--      理由：兩者同價但性質不同（預定2將 vs 半路入場低消），
--      共用會導致 2 將調價連帶改動中途加入，且報表分不出
--      「多少人是中途加入」——這是評估配桌成桌品質的關鍵指標。
--   ② REVOKE 補上 FROM PUBLIC（v3 只收回 anon/authenticated 無效）
--      PostgreSQL 建立函式時預設將 EXECUTE 授予 PUBLIC，
--      anon/authenticated 會從 PUBLIC 繼承。查證 proacl 確認
--      `=X/postgres` 存在（PUBLIC 有 EXECUTE），故必須一併收回。
--
-- 【v3 已驗證正確、v4 保留不動】
--   · 所有欄位／表／函式皆存在（orders.session_id/table_id/channel/entity_id、
--     stores.entity_id、members 四欄、tables 五欄、stake_levels.label、
--     _blocked_between 均已查證）
--   · join_type 約束名確為 session_players_join_type_check
--   · 無同桌重複 open 場次，唯一索引可安全建立
--   · mode='matched'/'private'、status='open'/'completed'/'voided'、
--     join_type='opener'/'mid_join'、players.status='playing' 等
--     皆依資料庫實際 CHECK 約束
--
-- 【前置作業】
--   必須先執行「商品貨號改三段式.sql」建立 SVC-TBL-* 商品，
--   否則 calc_session_fee_tx 一律回 product_not_found。
--
-- 【尚未涵蓋】
--   當日暢打（SVC-TBL-DAY 300 元）無程式路徑：open_session_tx 只收
--   matched/private 兩種模式。待決定是加第三種模式，或當一般商品販售。
--
-- 【狀態設計】
--   場次無獨立「進行中」狀態，以 activated_at 區分：
--     status='open' + activated_at IS NULL  → 收費中（客人陸續報到）
--     status='open' + activated_at NOT NULL → 已開打
--     status='completed'                    → 已收桌
--
-- 【計費規則】
--   配桌：開桌在場者依店員選定將數（3將→150 / 2將→100）
--         中途加入與代打→SVC-TBL-MID（100）
--   包桌：整桌計價，開桌者一次收足；同桌後續入座 0 元不建訂單
-- ============================================================


-- ============================================================
-- ① 補欄位與約束
-- ============================================================
ALTER TABLE table_sessions
  ADD COLUMN IF NOT EXISTS planned_rounds int,
  ADD COLUMN IF NOT EXISTS opened_by_staff_id uuid REFERENCES staff(id),
  ADD COLUMN IF NOT EXISTS activated_at timestamptz,
  ADD COLUMN IF NOT EXISTS idempotency_key text;

CREATE UNIQUE INDEX IF NOT EXISTS uq_sessions_idem
  ON table_sessions(idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_sessions_open_table
  ON table_sessions(table_id) WHERE status = 'open' AND deleted_at IS NULL;

ALTER TABLE session_players
  ADD COLUMN IF NOT EXISTS order_id uuid REFERENCES orders(id),
  ADD COLUMN IF NOT EXISTS seat text,
  ADD COLUMN IF NOT EXISTS left_at timestamptz;

-- join_type 擴充 'sub'（代打補位）：M4 計算段位時需排除代打成績
-- 約束名已查證為 session_players_join_type_check
ALTER TABLE session_players DROP CONSTRAINT IF EXISTS session_players_join_type_check;
ALTER TABLE session_players
  ADD CONSTRAINT session_players_join_type_check
  CHECK (join_type IN ('opener','mid_join','sub'));

COMMENT ON COLUMN table_sessions.planned_rounds IS
  '配桌預定將數（2 或 3），決定開桌時在場者收費；包桌為 null';
COMMENT ON COLUMN table_sessions.activated_at IS
  '桌子實際開打時間。null=仍在收費報到中，有值=已開打（取代另設 playing 狀態）';
COMMENT ON COLUMN session_players.join_type IS
  'opener=開桌時在場（依將數收費）| mid_join=中途加入（SVC-TBL-MID）| sub=代打補位（SVC-TBL-MID，M4 排除其成績）';
COMMENT ON COLUMN session_players.charged_points IS
  '此人實付金額（元）。欄名沿用 v1.0，v2.0 起為元計價';


-- ============================================================
-- ② 開桌：建立場次（不收費）
--    org/store 由桌位反查，不信任呼叫端傳入（防跨租戶）
-- ============================================================
CREATE OR REPLACE FUNCTION public.open_session_tx(
  p_table_id uuid,
  p_mode text,
  p_stake_level_id uuid DEFAULT NULL,
  p_planned_rounds int DEFAULT NULL,
  p_planned_minutes int DEFAULT NULL,
  p_staff_id uuid DEFAULT NULL,
  p_open_method text DEFAULT 'manual',
  p_idempotency_key text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_t record; v_id uuid; v_busy uuid;
begin
  if p_mode not in ('matched','private') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_mode',
      'message', '模式須為 matched（配桌）或 private（包桌）');
  end if;
  if p_mode = 'matched' and coalesce(p_planned_rounds, 0) not in (2, 3) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_rounds',
      'message', '配桌需指定 2 或 3 將');
  end if;
  if p_mode = 'private' and coalesce(p_planned_minutes, 0) not in (120, 300, 1440) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_minutes',
      'message', '包桌需選擇 2 小時／5 小時／24 小時');
  end if;
  if p_open_method not in ('auto','manual') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_open_method');
  end if;

  if p_idempotency_key is not null then
    select id into v_id from table_sessions where idempotency_key = p_idempotency_key;
    if v_id is not null then
      return jsonb_build_object('ok', true, 'session_id', v_id, 'duplicate', true);
    end if;
  end if;

  select t.id, t.org_id, t.store_id into v_t
    from tables t
   where t.id = p_table_id and t.deleted_at is null and t.is_active;
  if v_t.id is null then
    return jsonb_build_object('ok', false, 'reason', 'table_unavailable',
      'message', '桌位不存在或已停用');
  end if;

  select id into v_busy from table_sessions
   where table_id = p_table_id and status = 'open' and deleted_at is null;
  if v_busy is not null then
    return jsonb_build_object('ok', false, 'reason', 'table_busy',
      'session_id', v_busy, 'message', '此桌已有進行中的牌局');
  end if;

  insert into table_sessions(
    org_id, store_id, table_id, mode, stake_level_id, status,
    planned_rounds, planned_minutes, open_method,
    opened_by_staff_id, promoted_by_staff_id, started_at, idempotency_key)
  values (
    v_t.org_id, v_t.store_id, p_table_id, p_mode, p_stake_level_id, 'open',
    p_planned_rounds, p_planned_minutes, p_open_method,
    p_staff_id, p_staff_id, now(), p_idempotency_key)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'session_id', v_id,
    'mode', p_mode, 'store_id', v_t.store_id, 'org_id', v_t.org_id);
end $function$;


-- ============================================================
-- ③ 試算檯費
--    ★v4 修正：中途加入／代打改用 SVC-TBL-MID
-- ============================================================
CREATE OR REPLACE FUNCTION public.calc_session_fee_tx(
  p_session_id uuid, p_join_type text DEFAULT 'opener')
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_s record; v_sku text; v_p record;
begin
  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  if v_s.mode = 'private' then
    -- 包桌整桌計價：只在開桌者身上收一次
    if p_join_type <> 'opener' then
      return jsonb_build_object('ok', true, 'amount', 0, 'product_id', null,
        'note', '包桌已於開桌時整桌收費，後續入座不另收');
    end if;
    v_sku := case when v_s.planned_minutes <= 120 then 'SVC-TBL-P02'
                  when v_s.planned_minutes <= 300 then 'SVC-TBL-P05'
                  else 'SVC-TBL-P24' end;
  else
    -- 配桌按人頭：開桌在場者依將數；中途加入／代打用獨立的 MID 商品
    v_sku := case when p_join_type = 'opener'
                  then (case when v_s.planned_rounds = 2 then 'SVC-TBL-M2' else 'SVC-TBL-M3' end)
                  else 'SVC-TBL-MID' end;
  end if;

  select id, sku, name, unit_price into v_p
    from products
   where sku = v_sku and org_id = v_s.org_id and is_active and deleted_at is null
   limit 1;
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'reason', 'product_not_found', 'sku', v_sku,
      'message', '請先執行「商品貨號改三段式.sql」建立檯費商品');
  end if;

  return jsonb_build_object('ok', true, 'product_id', v_p.id, 'sku', v_p.sku,
    'name', v_p.name, 'amount', v_p.unit_price);
end $function$;


-- ============================================================
-- ④ 加人並收費 —— 收費委派給既有的 checkout_tx
--
-- checkout_tx 已處理：券折抵、會員等級折扣、點數折抵、多筆混合付款、
-- 冪等、orders/order_items/wallet_txns/order_payments/member_coupons 寫入。
-- 此處只負責「決定收哪個檯費商品」與「入座」，不重複實作收費。
--
-- p_payments 格式：
--   [{"method":"cash","amount":70,"cash_received":100,"change_given":30}]
--   method 限 cash / credit_card / line_pay
-- ============================================================
CREATE OR REPLACE FUNCTION public.join_session_tx(
  p_session_id uuid,
  p_member_id uuid,
  p_join_type text DEFAULT 'opener',
  p_coupon_ids uuid[] DEFAULT NULL,
  p_points_used bigint DEFAULT 0,
  p_payments jsonb DEFAULT NULL,
  p_staff_id uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s record; v_fee jsonb; v_amount bigint;
  v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
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

  -- 鐵則一：一律會員（純現金客人也要建會員，否則 CRM 資料斷掉）
  if not exists (select 1 from members where id = p_member_id and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_required',
      'message', '需先建立會員資料');
  end if;

  if exists (select 1 from session_players
              where session_id = p_session_id and member_id = p_member_id
                and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_joined');
  end if;

  if (select count(*) from session_players
       where session_id = p_session_id and left_at is null) >= 4 then
    return jsonb_build_object('ok', false, 'reason', 'table_full');
  end if;

  v_fee := calc_session_fee_tx(p_session_id, p_join_type);
  if not (v_fee ->> 'ok')::boolean then return v_fee; end if;
  v_amount := coalesce((v_fee ->> 'amount')::bigint, 0);

  -- 冪等鍵帶入座序號：同一人退出後再加入是新的收費事件，不可被視為重複
  select count(*) + 1 into v_seq from session_players
   where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key,
                    p_session_id::text || ':' || p_member_id::text || ':' || v_seq);

  -- 金額 > 0 才結帳；包桌後續入座為 0 元，直接入座不建訂單
  if v_amount > 0 then
    v_items := jsonb_build_array(jsonb_build_object(
      'product_id', v_fee ->> 'product_id',
      'name',       v_fee ->> 'name',
      'kind',       'fee',
      'qty',        1,
      'unit_price', v_amount));

    v_res := checkout_tx(
      p_member_id, v_s.store_id, v_items, p_coupon_ids,
      coalesce(p_points_used, 0), p_payments, v_key, p_staff_id);

    v_order := (v_res ->> 'order_id')::uuid;

    -- 補上桌次脈絡與法人歸屬（checkout_tx 不知道這些）
    update orders o
       set session_id = p_session_id,
           table_id   = v_s.table_id,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id,
                                 (select entity_id from stores where id = v_s.store_id))
     where o.id = v_order;
  end if;

  insert into session_players(
    org_id, session_id, member_id, join_type, status,
    charged_points, order_id, joined_at, created_by)
  values (
    v_s.org_id, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id)
  returning id into v_sp;

  return jsonb_build_object('ok', true, 'player_id', v_sp,
    'order_id', v_order, 'listed_amount', v_amount, 'checkout', v_res);
end $function$;


-- ============================================================
-- ⑤ 互黑檢查（警示而不阻擋：系統處理標準，人處理例外）
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_session_blocks_tx(
  p_session_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; v_list jsonb;
begin
  select org_id into v_org from table_sessions where id = p_session_id;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'member_id', m.id, 'nickname', m.display_name)), '[]'::jsonb)
    into v_list
    from session_players sp
    join members m on m.id = sp.member_id
   where sp.session_id = p_session_id and sp.left_at is null
     and _blocked_between(v_org, p_member_id, sp.member_id);

  return jsonb_build_object('ok', true,
    'has_conflict', jsonb_array_length(v_list) > 0, 'conflicts', v_list);
end $function$;


-- ============================================================
-- ⑥ 啟動桌子（滿四自動／店員手動）
-- ============================================================
CREATE OR REPLACE FUNCTION public.activate_session_tx(
  p_session_id uuid, p_staff_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int;
begin
  select count(*) into v_n from session_players
   where session_id = p_session_id and left_at is null;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_players',
      'message', '尚無人入座');
  end if;

  update table_sessions
     set activated_at = now(), updated_at = now()
   where id = p_session_id and status = 'open' and activated_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_open_or_already_active');
  end if;

  return jsonb_build_object('ok', true, 'players', v_n, 'activated_at', now());
end $function$;


-- ============================================================
-- ⑦ 場次詳情（POS 本桌頁）
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
          'charged', sp.charged_points, 'joined_at', sp.joined_at
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
-- ⑧ 封存 v1.0 收費函式
--    ★v4 修正：補 REVOKE FROM PUBLIC
--    查證 proacl 為 `=X/postgres,...`，開頭的空白 grantee 即 PUBLIC，
--    代表 PUBLIC 擁有 EXECUTE。只收回 anon/authenticated 的話，
--    它們仍從 PUBLIC 繼承執行權 → 封存無效。
--    用 REVOKE 而非 CREATE OR REPLACE：覆寫會抹掉原始碼（無法稽核），
--    且參數預設值不符時會直接報 42P13。
-- ============================================================
REVOKE EXECUTE ON FUNCTION public.charge_matched_tx(uuid, uuid, text, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.charge_private_tx(uuid, uuid, integer, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.charge_matched_tx(uuid, uuid, text, text, uuid, uuid) IS
  '【v2.0 已停用】純點數扣款模式已廢除，改用 join_session_tx（走 checkout_tx，支援現金與混合付款）。函式保留供稽核，已撤銷 PUBLIC/anon/authenticated 執行權限';
COMMENT ON FUNCTION public.charge_private_tx(uuid, uuid, integer, text, uuid, uuid) IS
  '【v2.0 已停用】同 charge_matched_tx，改用 join_session_tx';


-- ============================================================
-- ⑨ 驗證（單一結果表）
-- ============================================================
SELECT '① 新增欄位' AS 項目,
       'sessions: ' || (SELECT string_agg(column_name, ', ' ORDER BY column_name)
        FROM information_schema.columns WHERE table_schema='public' AND table_name='table_sessions'
          AND column_name IN ('planned_rounds','opened_by_staff_id','activated_at','idempotency_key')) ||
       ' / players: ' || (SELECT string_agg(column_name, ', ' ORDER BY column_name)
        FROM information_schema.columns WHERE table_schema='public' AND table_name='session_players'
          AND column_name IN ('order_id','seat','left_at')) AS 內容
UNION ALL
SELECT '② 新增索引',
       (SELECT string_agg(indexname, ', ' ORDER BY indexname) FROM pg_indexes
        WHERE schemaname='public' AND indexname IN ('uq_sessions_idem','uq_sessions_open_table'))
UNION ALL
SELECT '③ join_type 約束已含 sub',
       (SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conrelid='session_players'::regclass AND conname='session_players_join_type_check')
UNION ALL
SELECT '④ 新增 RPC',
       (SELECT string_agg(proname, ', ' ORDER BY proname) FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND proname IN
        ('open_session_tx','join_session_tx','calc_session_fee_tx',
         'check_session_blocks_tx','activate_session_tx','get_session_tx'))
UNION ALL
SELECT '⑤ 舊函式權限（應無 PUBLIC 的 =X）',
       coalesce((SELECT string_agg(p.proname || '→' ||
                 coalesce(array_to_string(p.proacl,','), '(僅擁有者)'), ' | ')
                 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public'
                   AND p.proname IN ('charge_matched_tx','charge_private_tx')), '(查無)')
UNION ALL
SELECT '⑥ 檯費商品（需含 SVC-TBL-MID）',
       coalesce((SELECT string_agg(sku || '=' || unit_price, ', ' ORDER BY sku)
        FROM products WHERE sku LIKE 'SVC-TBL-%' AND is_active AND deleted_at IS NULL),
        '❌尚未建立，請先跑 商品貨號改三段式.sql');


-- ============================================================
-- 已知限制與後續
-- ============================================================
-- 1. 【當日暢打未涵蓋】SVC-TBL-DAY（300 元）無程式路徑。open_session_tx
--    只接受 matched/private。待決定：加第三種模式 daypass，或當一般商品販售。
--
-- 2. 【org 驗證的現況】理想上應以 current_org_id() 取代呼叫端傳入，但該函式
--    查 staff.auth_uid 與 members.line_user_id，接上 Supabase Auth 前多為 null。
--    本版改為「由桌位反查 org/store」，呼叫端無法指定租戶，已消除跨租戶風險。
--    待認證升級後再加 has_store_access() 限制店員只能操作自己門市。
--
-- 3. 【錯誤處理】checkout_tx 以 raise exception 回報業務錯誤（券過期、收款金額
--    不符等），本函式刻意不用 exception when others 捕捉，以免連程式 bug 一併
--    吞掉。POS 端需處理 Postgres 錯誤訊息並顯示。
--
-- 4. 【打 1 將】open_session_tx 只接受 2 或 3 將，實務上打 1 將者以 2 將場次
--    開桌，收 SVC-TBL-M2。
--
-- 5. settle_session_tx 仍是空殼，下一步改寫：包桌超時補收、建立發票、
--    消費累積與店員業績歸因。
--
-- 6. charge_fnb_tx 同屬 _charge_core 系列，POS 做點餐時一併改走 checkout_tx。
--
-- 7. pricing_tiers 為空且已無函式引用，檯費改以 products 管理。該表暫留，
--    日後若需分店覆寫價格再啟用。
-- ============================================================
