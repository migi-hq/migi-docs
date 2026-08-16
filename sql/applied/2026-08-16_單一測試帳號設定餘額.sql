-- ============================================================
-- dev_set_test_balance_tx —— 把單一測試帳號的餘額設成指定值
-- ------------------------------------------------------------
-- 【為什麼需要】
--   dev_reset_test_data_tx 是「全部測試帳號一起歸位」，
--   但很多情境需要混合狀態，例如驗證
--   「0 點的客人現場儲值後能不能立刻折抵」時，
--   要有一個帳號是 0、其他帳號有錢當對照。
--
-- 【安全設計】
--   · 只認 is_test = true 的會員，正式會員一律拒絕
--   · 用 display_name 比對而非 uuid —— 帳號重建過 id 會變，名字不會
--   · **不直接 UPDATE wallets.balance**，而是補一筆 adjust 流水再重算。
--     這是 M1 碰錢五條鐵則第 1 條：餘額一律由 wallet_txns 推導。
--     直接設會與 audit_wallet_balance 稽核衝突。
--   · 差額以**流水加總**為基準，不是 wallets.balance ——
--     快取可能失準（2026-08-16 就發生過），流水才是真相。
--
-- 【全新函式，不需 DROP】
-- ============================================================

CREATE OR REPLACE FUNCTION public.dev_set_test_balance_tx(
  p_display_name text,
  p_balance      bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_m     record;
  v_now   bigint;
  v_delta bigint;
begin
  if p_balance < 0 then
    return jsonb_build_object('ok', false, 'reason', 'negative_balance',
      'message', '餘額不可為負（wallets.balance 有 >= 0 的 check）');
  end if;

  select m.id, m.org_id, m.display_name, m.is_test
    into v_m
    from members m
   where m.display_name = p_display_name
     and m.deleted_at is null
   limit 1;

  if v_m.id is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'display_name', p_display_name);
  end if;

  -- 這是開發工具，不准碰到正式會員
  if not coalesce(v_m.is_test, false) then
    return jsonb_build_object('ok', false, 'reason', 'not_test_member',
      'message', '這支只能用在測試帳號（is_test = true）');
  end if;

  -- 現況以流水加總為準，不看 wallets.balance（快取可能失準）
  select coalesce(sum(tx.amount), 0) into v_now
    from wallet_txns tx
   where tx.member_id = v_m.id and tx.status = 'completed';

  v_delta := p_balance - v_now;

  if v_delta <> 0 then
    insert into wallet_txns(org_id, member_id, type, amount, note)
    values (v_m.org_id, v_m.id, 'adjust'::txn_type, v_delta, '測試餘額設定');
  end if;

  -- 不論有無異動都重算快取（冪等，順便修復先前的失準）
  perform fix_wallet_balance_tx(v_m.org_id, v_m.id);

  return jsonb_build_object(
    'ok', true,
    'member', v_m.display_name,
    'before', v_now,
    'after',  p_balance,
    'delta',  v_delta,
    'balance', (select balance from wallets where member_id = v_m.id));
end $function$;

COMMENT ON FUNCTION public.dev_set_test_balance_tx IS
  '把單一測試帳號的餘額設成指定值（補 adjust 流水再重算，不直接改快取）。只接受 is_test = true 的會員。';


-- ============================================================
-- 驗證（單一 SELECT）—— 會實際把測試04 設成 0
-- ------------------------------------------------------------
-- 期待：
--   結果        ok = true、member = 測試04、after = 0
--   拒絕正式會員 not_test_member 或 member_not_found
--   全部餘額     測試04=0，其他維持原值
-- ============================================================
with r as (
  select dev_set_test_balance_tx('測試04', 0) as res
)
select
  res ->> 'ok'      as 成功,
  res ->> 'member'  as 帳號,
  res ->> 'before'  as 原餘額,
  res ->> 'after'   as 新餘額,
  res ->> 'delta'   as 補的流水,

  -- 安全檢查：拿一個不存在或非測試的名字，必須被擋
  (dev_set_test_balance_tx('這個帳號不存在', 500) ->> 'reason')   as 亂給名字時,

  (case when res is not null then (
     select string_agg(m.display_name || '=' || w.balance, ' / '
                       order by m.display_name)
       from wallets w join members m on m.id = w.member_id
      where m.is_test = true) end)                              as 全部餘額
from r;
