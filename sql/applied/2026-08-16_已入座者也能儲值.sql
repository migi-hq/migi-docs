-- ============================================================
-- pos_checkout_with_topup_tx 擴充：已入座的客人也能儲值
-- ------------------------------------------------------------
-- 【要解決什麼】
--   原版只接 join_session_tx（首次結帳）。已入座的人再結帳走的是
--   pos_addon_checkout_tx，那條路沒接儲值，所以前端一直擋著。
--   待辦 0 的最後一項。
--
-- 【由後端判斷該走哪條路，不由前端傳旗標】
--   查 session_players 有沒有這個人的在座紀錄：
--     未入座 → join_session_tx（收檯費 + 商品）
--     已入座 → pos_addon_checkout_tx（只收商品，不再收檯費）
--   前端的 cur.seated 是從 get_session_tx 還原出來的推測值。
--   **讓推測值決定收不收檯費，是重複收費的溫床。**
--   真相在資料庫，就讓資料庫判斷。
--
-- 【三種模式】
--   join       未入座 → 入座並收費（檯費 + 商品）
--   addon      已入座且有商品 → 加購
--   topup_only 已入座但沒有商品 → 只儲值，不建訂單
--
--   最後一種是這次才發現要處理的：pos_addon_checkout_tx 對空品項會回
--   empty_items，若照樣呼叫就會 raise 進而回滾掉儲值 ——
--   而「已入座的客人只想儲值」是完全合理的情境。
--
-- 【線上版來源（硬規則 3，2026-08-16 以 pg_get_functiondef 撈出）】
--   pos_checkout_with_topup_tx(...14 參數)  DEFINER  1 個版本
--   pos_addon_checkout_tx(uuid,uuid,jsonb,uuid[],bigint,jsonb,text,uuid)
--                                           DEFINER  1 個版本
--     · 業務錯誤**回傳 {ok:false}，不拋例外** → 必須主動 raise，否則交易照常提交
--     · 空品項回 empty_items
--     · 未在座回 not_seated
--     · 回傳是 checkout_tx 結果直接合併（v_res || {ok,addon,session_id}），
--       所以 new_balance 在**頂層**；join 那條則包在 'checkout' 底下。
--       前端已同時處理兩種形狀。
--
-- 【簽名未變，不需 DROP】
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

  -- ★ 由資料庫判斷是否已入座，不採信前端傳來的推測值
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

  -- 已入座、沒有商品、也沒有儲值 —— 這次呼叫什麼都不會做，直接擋下
  if v_mode = 'topup_only' and p_topup_points <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_do',
      'message', '這位客人已入座，請選擇商品或儲值');
  end if;

  v_base := coalesce(p_idempotency_key,
                     p_session_id::text || ':' || p_member_id::text);

  -- ══ 原子區塊：任何一步 raise，整段回滾（含已寫入的儲值單與點數流水）══
  begin

    -- ① 儲值先做，讓接下來的結帳能立刻用到新點數
    if p_topup_points > 0 then
      v_topup := topup_tx(
        p_member_id, v_s.store_id, p_topup_points, p_topup_amount,
        p_topup_method, v_base || ':topup', p_topup_bonus,
        null, p_staff_id, 'POS 結帳時儲值');

      -- 回填桌次脈絡，比照 join_session_tx / pos_addon_checkout_tx 對 orders 的做法
      update topup_orders
         set session_id = p_session_id
       where id = (v_topup ->> 'topup_id')::uuid;
    end if;

    -- ② 結帳（依模式分流）
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
    -- topup_only 不呼叫任何結帳函式，v_join 維持 null

    -- ★ 兩支結帳函式的業務錯誤都是「回傳 ok:false」而不是拋例外。
    --   不主動 raise 的話交易會照常提交 —— 儲值就留下來了。
    if v_join is not null
       and not coalesce((v_join ->> 'ok')::boolean, false) then
      raise exception 'checkout_failed:%',
        coalesce(v_join ->> 'reason', 'unknown') using errcode = 'P0001';
    end if;

  exception
    when others then
      -- 區塊內所有變更（儲值單、點數流水、餘額、訂單）都已回滾
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
    'ok', true,
    'mode', v_mode,            -- join / addon / topup_only
    'topup', v_topup,          -- null 表示這次沒有儲值
    'checkout', v_join,        -- topup_only 時為 null
    'new_balance', v_topup ->> 'new_balance');
end $function$;

COMMENT ON FUNCTION public.pos_checkout_with_topup_tx IS
  'POS 一次收款完成儲值 + 結帳。單一交易，任一步失敗一起回滾。由後端判斷未入座走 join、已入座走 addon、無商品則只儲值。儲值先入帳，點數可立即用於同一次結帳。';


-- ============================================================
-- 驗證（單一 SELECT）
-- ------------------------------------------------------------
-- 期待：
--   版本數        = 1
--   簽名          = 14 個參數，與先前相同（沒有建出多載）
--   安全模式      = DEFINER
--   煙霧測試      = session_not_found
--   缺冪等鍵      = idempotency_key_required
--   無事可做      = nothing_to_do
--                  （拿一個已入座的會員、不給商品也不給儲值，
--                    證明新的模式判斷真的執行到了）
--   addon函式在   = 1  （要呼叫的對象還在，且沒有多載）
-- ============================================================
with seated as (
  select sp.session_id, sp.member_id
    from session_players sp
    join table_sessions s on s.id = sp.session_id
   where sp.left_at is null and s.status = 'open'
   order by sp.joined_at desc
   limit 1
)
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='pos_checkout_with_topup_tx')   as 版本數,

  (select p.oid::regprocedure::text
     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='pos_checkout_with_topup_tx'
    limit 1)                                                              as 簽名,

  (select case when p.prosecdef then 'DEFINER' else 'INVOKER' end
     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='pos_checkout_with_topup_tx'
    limit 1)                                                              as 安全模式,

  (pos_checkout_with_topup_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid) ->> 'reason')         as 煙霧測試,

  (pos_checkout_with_topup_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'opener', null, null, 0, null, null, null,
      null, 1000, 0, 1000, 'cash') ->> 'reason')                          as 缺冪等鍵,

  (select pos_checkout_with_topup_tx(x.session_id, x.member_id) ->> 'reason'
     from seated x)                                                       as 無事可做,

  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='pos_addon_checkout_tx')       as addon函式在;
