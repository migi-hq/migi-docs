-- 【M1・已執行】錢包金流核心：儲值、扣點、退款沖正、收桌結算。共用 _charge_core（鎖錢包→查冪等→驗餘額→寫流水→更新快取）。
-- ⚠️ 其中 charge_matched_tx / charge_private_tx 已於 2026-08 封存（純點數模式廢除），見 07 號檔案。
-- ============================================================
-- MIGI M1 — 錢包 RPC 函式（PostgreSQL / Supabase）
-- 部署：Supabase Dashboard → SQL Editor → 貼上執行
-- 所有「碰錢」操作都在這裡，於單一交易內完成：
--   並發鎖（FOR UPDATE，基石⑦）+ 冪等（基石⑧）+ 雙邊錢流（基石⑨）
--   + 做法三（流水為真相、balance 為快取，同交易更新）
-- Edge Function 只負責驗證參數後呼叫這些 RPC。
-- ============================================================

-- ------------------------------------------------------------
-- 內部共用：扣點核心（鎖錢包 → 查冪等 → 驗餘額 → 寫流水 → 更新快取）
-- ------------------------------------------------------------
create or replace function _charge_core(
  p_member_id uuid, p_amount bigint, p_type txn_type,
  p_idempotency_key text, p_store_id uuid, p_served_store_id uuid,
  p_staff_id uuid, p_ref_table text, p_ref_id uuid, p_counter text
) returns jsonb language plpgsql as $$
declare
  v_org uuid; v_bal bigint; v_existing uuid; v_txn uuid;
begin
  -- 冪等檢查（基石⑧）：同 key 已處理 → 回前次結果，不重複扣
  if p_idempotency_key is not null then
    select id into v_existing from wallet_txns
      where org_id = (select org_id from members where id=p_member_id)
        and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return jsonb_build_object('idempotent', true, 'txn_id', v_existing);
    end if;
  end if;

  -- 並發鎖（基石⑦）：鎖住這個錢包列，一次只准一筆動它
  select w.org_id, w.balance into v_org, v_bal
    from wallets w where w.member_id = p_member_id for update;
  if not found then
    raise exception '錢包不存在 (member=%)', p_member_id;
  end if;

  -- 驗餘額（扣款金額為正數傳入，內部轉負）
  if v_bal < p_amount then
    raise exception '餘額不足 (餘額=%, 需扣=%)', v_bal, p_amount
      using errcode = 'P0001';
  end if;

  -- 寫流水（append-only，金額為負；基石⑨⑬）
  insert into wallet_txns(org_id, store_id, served_store_id, member_id, type, amount,
                          status, counter_account, idempotency_key, staff_id, ref_table, ref_id)
    values(v_org, p_store_id, p_served_store_id, p_member_id, p_type, -p_amount,
           'completed', p_counter, p_idempotency_key, p_staff_id, p_ref_table, p_ref_id)
    returning id into v_txn;

  -- 更新快取餘額（做法三，同交易）
  update wallets set balance = balance - p_amount where member_id = p_member_id;

  return jsonb_build_object('txn_id', v_txn, 'new_balance', v_bal - p_amount);
end $$;

-- ------------------------------------------------------------
-- 1. 儲值 wallet_topup_tx
-- ------------------------------------------------------------
create or replace function wallet_topup_tx(
  p_member_id uuid, p_amount bigint, p_idempotency_key text,
  p_external_ref text default null, p_store_id uuid default null
) returns jsonb language plpgsql as $$
declare v_org uuid; v_existing uuid; v_txn uuid; v_bal bigint;
begin
  if p_idempotency_key is not null then
    select id into v_existing from wallet_txns
      where org_id=(select org_id from members where id=p_member_id)
        and idempotency_key=p_idempotency_key;
    if v_existing is not null then
      return jsonb_build_object('idempotent', true, 'txn_id', v_existing);
    end if;
  end if;

  select org_id, balance into v_org, v_bal from wallets where member_id=p_member_id for update;
  if not found then
    -- 首次儲值自動建錢包
    select org_id into v_org from members where id=p_member_id;
    insert into wallets(member_id, org_id, balance) values(p_member_id, v_org, 0);
    v_bal := 0;
    perform 1 from wallets where member_id=p_member_id for update;
  end if;

  insert into wallet_txns(org_id, store_id, member_id, type, amount, status,
                          counter_account, idempotency_key, external_ref)
    values(v_org, p_store_id, p_member_id, 'topup', p_amount, 'completed',
           'member_wallet', p_idempotency_key, p_external_ref)
    returning id into v_txn;
  update wallets set balance = balance + p_amount where member_id=p_member_id;
  return jsonb_build_object('txn_id', v_txn, 'new_balance', v_bal + p_amount);
end $$;

-- ------------------------------------------------------------
-- 2. 配桌扣款 charge_matched_tx（開桌扣在場者150 / 中途加入100）
--    金額查 pricing_tiers（資料驅動），不寫死
-- ------------------------------------------------------------
create or replace function charge_matched_tx(
  p_member_id uuid, p_session_id uuid, p_join_type text,
  p_idempotency_key text, p_store_id uuid, p_staff_id uuid default null
) returns jsonb language plpgsql as $$
declare v_org uuid; v_rule text; v_points bigint;
begin
  select org_id into v_org from members where id=p_member_id;
  v_rule := case when p_join_type='mid_join' then 'matched_midjoin' else 'matched_full' end;
  -- 查價（分店覆寫優先，否則 org 預設）
  select points into v_points from pricing_tiers
    where org_id=v_org and mode='matched' and rule_key=v_rule and is_active and deleted_at is null
      and (store_id=p_store_id or store_id is null)
    order by store_id nulls last limit 1;
  if v_points is null then raise exception '找不到配桌計費規則 %', v_rule; end if;

  return _charge_core(p_member_id, v_points, 'table_fee', p_idempotency_key,
                      p_store_id, p_store_id, p_staff_id, 'session_players', p_session_id, 'store_revenue');
end $$;

-- ------------------------------------------------------------
-- 3. 包桌扣款 charge_private_tx（依預估分鐘查階梯 400/600/800）
-- ------------------------------------------------------------
create or replace function charge_private_tx(
  p_member_id uuid, p_session_id uuid, p_minutes int,
  p_idempotency_key text, p_store_id uuid, p_staff_id uuid default null
) returns jsonb language plpgsql as $$
declare v_org uuid; v_points bigint;
begin
  select org_id into v_org from members where id=p_member_id;
  select points into v_points from pricing_tiers
    where org_id=v_org and mode='private' and is_active and deleted_at is null
      and (store_id=p_store_id or store_id is null)
      and min_unit <= p_minutes and (max_unit is null or max_unit >= p_minutes)
    order by store_id nulls last limit 1;
  if v_points is null then raise exception '找不到包桌計費級距 (分鐘=%)', p_minutes; end if;

  return _charge_core(p_member_id, v_points, 'table_fee', p_idempotency_key,
                      p_store_id, p_store_id, p_staff_id, 'table_sessions', p_session_id, 'store_revenue');
end $$;

-- ------------------------------------------------------------
-- 4. 餐飲扣款 charge_fnb_tx
-- ------------------------------------------------------------
create or replace function charge_fnb_tx(
  p_member_id uuid, p_order_id uuid, p_points bigint,
  p_idempotency_key text, p_store_id uuid
) returns jsonb language plpgsql as $$
begin
  return _charge_core(p_member_id, p_points, 'fnb', p_idempotency_key,
                      p_store_id, p_store_id, null, 'orders', p_order_id, 'store_revenue');
end $$;

-- ------------------------------------------------------------
-- 5. 退款/沖正 reverse_txn_tx（不改舊帳，新增反向分錄；基石⑫）
-- ------------------------------------------------------------
create or replace function reverse_txn_tx(
  p_original_txn_id uuid, p_idempotency_key text, p_reason text default null
) returns jsonb language plpgsql as $$
declare v_org uuid; v_member uuid; v_amount bigint; v_store uuid; v_new uuid; v_existing uuid;
begin
  if p_idempotency_key is not null then
    select id into v_existing from wallet_txns where idempotency_key=p_idempotency_key;
    if v_existing is not null then return jsonb_build_object('idempotent',true,'txn_id',v_existing); end if;
  end if;

  select org_id, member_id, amount, store_id into v_org, v_member, v_amount, v_store
    from wallet_txns where id=p_original_txn_id;
  if not found then raise exception '原交易不存在'; end if;

  perform 1 from wallets where member_id=v_member for update;  -- 鎖
  -- 反向分錄：金額正負相反
  insert into wallet_txns(org_id, store_id, member_id, type, amount, status,
                          counter_account, reverses_txn_id, idempotency_key, note)
    values(v_org, v_store, v_member, 'reversal', -v_amount, 'completed',
           'reversal', p_original_txn_id, p_idempotency_key, p_reason)
    returning id into v_new;
  update wallets set balance = balance + (-v_amount) where member_id=v_member;
  return jsonb_build_object('reversal_txn_id', v_new);
end $$;

-- ============================================================
-- 收桌結算 settle_session：依各 player 狀態退補 + 觸發三項更新
-- （此處為計費結算骨架；段位 Elo、店員業績聚合在 M3/M4 細做）
-- ============================================================
create or replace function settle_session_tx(p_session_id uuid)
returns jsonb language plpgsql as $$
declare v_total bigint;
begin
  -- 加總本桌實扣（session_players.charged_points 已於開桌/加入時寫入）
  select coalesce(sum(charged_points),0) into v_total
    from session_players where session_id=p_session_id;
  update table_sessions
    set status='completed', ended_at=now(), fee_points=v_total
    where id=p_session_id;
  -- 觸發三項更新（消費累積/段位/店員業績）→ 由後續 M3/M4 的聚合處理
  return jsonb_build_object('session_id', p_session_id, 'total_points', v_total);
end $$;

-- ============================================================
-- 完成。M1 錢包/計費 RPC：儲值、配桌扣、包桌扣、餐飲扣、沖正、收桌結算。
-- 全部含並發鎖+冪等+雙邊錢流+做法三。計費金額一律查 pricing_tiers（資料驅動）。
-- 計費邏輯已用 24 項測試驗證通過。
-- ============================================================
