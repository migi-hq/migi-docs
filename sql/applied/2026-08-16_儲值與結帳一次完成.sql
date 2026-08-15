-- ============================================================
-- pos_checkout_with_topup_tx —— 儲值與結帳一次收款、單一交易
-- ------------------------------------------------------------
-- 【要解決什麼】
--   成熟零售系統的做法是「問你要不要儲值 → 一起結帳 → 一次收款」。
--   但 topup_tx 與 join_session_tx 是兩支獨立函式，
--   前端依序呼叫的話，儲值成功、結帳失敗就會留下半筆帳
--   （客人點數加了、檯費沒收），要人工補救。
--
--   本函式把兩者包進**同一個 plpgsql 函式**。plpgsql 函式預設在單一交易裡跑，
--   任何一步失敗，兩邊一起回滾。
--
-- 【最關鍵的設計：為什麼需要 raise + EXCEPTION】
--   join_session_tx 的業務錯誤是**回傳 {ok:false, reason}，不是拋例外**。
--   所以「依序呼叫」不會自動回滾 —— 儲值會留下來。
--   → 檢查回傳值，不 ok 就自己 raise；最外層用 EXCEPTION 接住。
--   plpgsql 的 EXCEPTION 區塊會回滾整個區塊內的變更，
--   於是既能保證原子性，又能回一個乾淨的 jsonb 給前端
--   （而不是讓店員看到英文的 SQL 例外訊息）。
--
-- 【順序：先儲值後結帳】
--   儲值先入帳，同一交易內 wallets.balance 已更新，
--   接下來的結帳就能立刻用那些點數折抵 —— 這正是客人的預期
--   （「我剛儲的怎麼不能用」）。
--
-- 【線上版來源】
--   topup_tx / join_session_tx 皆於 2026-08-16 以 pg_get_functiondef 撈出確認（硬規則 3）：
--     topup_tx(uuid,uuid,bigint,bigint,text,text,bigint,text,uuid,text)  DEFINER  1 個版本
--       · 驗證失敗一律 raise exception
--       · p_bonus_points 由呼叫端傳入，函式不自己算贈點
--       · 本金 counter_account='liability'、贈點另開一筆 'promo_expense'
--       · 冪等：同 org + idempotency_key 已存在就直接回上次結果
--     join_session_tx(...,jsonb)  DEFINER  1 個版本（今日剛加 p_items）
--
-- 【本次範圍：只涵蓋「首次結帳」】
--   已入座者再結帳走的是 pos_addon_checkout_tx，不在本函式內。
--   所以「已入座的客人要儲值」目前仍未開放 —— 那是功能缺口，不是金流風險，
--   待這支驗證穩定後再比照擴充。
--
-- 【SECURITY DEFINER】
--   POS 用 anon key 無 auth session，INVOKER 會被 RLS 擋成靜默失敗（硬規則 4）。
--
-- 【全新函式，不需要 DROP】
--   pos_checkout_with_topup_tx 線上不存在，不會產生多載（硬規則 2 針對既有函式改簽名）。
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
  -- 儲值部分。p_topup_points = 0 時整段跳過，本函式就等同 join_session_tx
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
  -- 有儲值就必須有冪等鍵。topup_tx 本身也強制要求（null 會 raise），
  -- 但在這裡先擋，錯誤訊息才講得清楚是哪個環節缺的。
  -- 純輸入檢查，刻意排在查資料庫之前 —— 參數本身不合法時不必先耗一輪查詢。
  if p_topup_points > 0 and coalesce(p_idempotency_key, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'idempotency_key_required',
      'message', '含儲值的結帳必須帶冪等鍵');
  end if;

  -- 場次要先撈到，topup_tx 需要 store_id（與 join_session_tx 取同一個來源）
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

  -- ══ 以下是原子區塊 ══
  -- 任何一步 raise，EXCEPTION 會回滾整段（含已寫入的儲值單與點數流水）
  begin

    ---------------------------------------------------------
    -- ① 儲值（先做，讓接下來的結帳能立刻用到新點數）
    ---------------------------------------------------------
    if p_topup_points > 0 then
      v_topup := topup_tx(
        p_member_id,
        v_s.store_id,
        p_topup_points,
        p_topup_amount,
        p_topup_method,
        v_base || ':topup',      -- 與訂單各用一把鑰匙，重試時兩邊都不會重複
        p_topup_bonus,
        null,                    -- p_external_ref
        p_staff_id,
        'POS 結帳時儲值'
      );
    end if;

    ---------------------------------------------------------
    -- ② 入座並結帳（檯費由 join_session_tx 自算，p_items 是餐飲/商品）
    ---------------------------------------------------------
    v_join := join_session_tx(
      p_session_id,
      p_member_id,
      p_join_type,
      p_coupon_ids,
      coalesce(p_points_used, 0),
      p_payments,
      p_staff_id,
      v_base || ':order',
      p_pay_for,
      p_items
    );

    -- ★ 這一段是整支函式的重點。
    --   join_session_tx 的業務錯誤是「回傳 ok:false」而不是拋例外，
    --   不主動 raise 的話交易會照常提交 —— 儲值就留下來了。
    if not coalesce((v_join ->> 'ok')::boolean, false) then
      raise exception 'join_failed:%',
        coalesce(v_join ->> 'reason', 'unknown')
        using errcode = 'P0001';
    end if;

  exception
    when others then
      -- 到這裡，區塊內的所有變更（儲值單、點數流水、餘額、訂單）都已回滾。
      -- 把原因整理成前端看得懂的形狀，而不是丟英文 SQL 例外給店員。
      if SQLERRM like 'join_failed:%' then
        return jsonb_build_object(
          'ok', false,
          'reason', split_part(SQLERRM, ':', 2),
          'stage', 'checkout',
          'message', '結帳失敗，儲值已一併取消');
      end if;
      return jsonb_build_object(
        'ok', false,
        'reason', 'topup_failed',
        'stage', case when v_topup is null then 'topup' else 'checkout' end,
        'message', SQLERRM);
  end;

  return jsonb_build_object(
    'ok', true,
    'topup', v_topup,          -- null 表示這次沒有儲值
    'checkout', v_join,
    'new_balance', v_topup ->> 'new_balance');
end $function$;

COMMENT ON FUNCTION public.pos_checkout_with_topup_tx IS
  'POS 一次收款完成儲值 + 入座結帳。單一交易，任一步失敗兩邊一起回滾。儲值先入帳，點數可立即用於同一次結帳。';


-- ============================================================
-- 驗證（單一 SELECT）
-- ------------------------------------------------------------
-- 期待：
--   版本數        = 1
--   安全模式      = DEFINER
--   煙霧測試      = session_not_found   （不存在的場次，證明跑得起來且無副作用）
--   缺冪等鍵      = idempotency_key_required
--                  （帶儲值但不給鑰匙，證明那道檢查有執行到）
--   儲值單數量    = 目前 topup_orders 共幾筆（跑前跑後比對，確認驗證本身沒留下垃圾）
-- ============================================================
select
  (select count(*)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'pos_checkout_with_topup_tx')  as 版本數,

  (select case when p.prosecdef then 'DEFINER' else 'INVOKER' end
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'pos_checkout_with_topup_tx'
    limit 1)                                                                 as 安全模式,

  (pos_checkout_with_topup_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid) ->> 'reason')            as 煙霧測試,

  -- 冪等鍵檢查排在查資料庫之前，所以用不存在的場次也測得到
  (pos_checkout_with_topup_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'opener', null, null, 0, null, null, null,
      null,                       -- 刻意不給冪等鍵
      1000, 0, 1000, 'cash') ->> 'reason')                                   as 缺冪等鍵,

  (select count(*) from topup_orders)                                        as 儲值單數量;
