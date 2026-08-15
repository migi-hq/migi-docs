-- 【M1・已執行】get_wallet_tx：會員 App 錢包頁的餘額與交易明細查詢。
-- ============================================================
-- MIGI 會員錢包讀取 RPC（修正版：修掉 granted_at 排序欄位問題）
-- 部署：Supabase Dashboard → SQL Editor → 貼上執行（會覆蓋舊版同名函式）
-- 給一個 member_id，回傳：點數餘額 + 近期消費紀錄 + 持有的優惠券
-- SECURITY DEFINER：前端 anon 可呼叫（讀單一會員自己的錢包），不破 RLS
-- ============================================================

create or replace function get_wallet_tx(
  p_member_id uuid,
  p_txn_limit int default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance bigint;
  v_name    text;
  v_txns    jsonb;
  v_coupons jsonb;
begin
  if p_member_id is null then
    raise exception 'member_id required';
  end if;

  select display_name into v_name from members where id = p_member_id and deleted_at is null;
  if v_name is null then
    raise exception 'member not found';
  end if;
  select coalesce(balance, 0) into v_balance from wallets where member_id = p_member_id;
  v_balance := coalesce(v_balance, 0);

  -- 近期消費/儲值紀錄
  select coalesce(jsonb_agg(t order by t.created_at desc), '[]'::jsonb) into v_txns
  from (
    select
      wt.id,
      wt.amount,
      wt.type::text as type,
      case wt.type
        when 'topup'     then '儲值'
        when 'table_fee' then '桌時費'
        when 'fnb'       then '餐飲'
        when 'merch'     then '商品'
        when 'refund'    then '退款'
        when 'adjust'    then '贈點/調整'
        when 'event_fee' then '活動費'
        when 'reversal'  then '沖正'
        else wt.type::text
      end as label,
      wt.note,
      wt.created_at
    from wallet_txns wt
    where wt.member_id = p_member_id
      and wt.status = 'completed'
    order by wt.created_at desc
    limit greatest(1, least(p_txn_limit, 100))
  ) t;

  -- 持有中的優惠券（active）— 把 granted_at 一起選進子查詢再排序
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', c.id,
             'name', c.name,
             'kind', c.kind,
             'discount_type', c.discount_type,
             'discount_value', c.discount_value,
             'expires_at', c.expires_at
           ) order by c.granted_at desc
         ), '[]'::jsonb) into v_coupons
  from (
    select
      mc.id,
      co.name,
      co.kind::text as kind,
      co.discount_type::text as discount_type,
      co.discount_value,
      mc.expires_at,
      mc.granted_at
    from member_coupons mc
    join coupons co on co.id = mc.coupon_id
    where mc.member_id = p_member_id
      and mc.status = 'active'
  ) c;

  return jsonb_build_object(
    'member_id', p_member_id,
    'display_name', v_name,
    'balance', v_balance,
    'txns', v_txns,
    'coupons', v_coupons
  );
end;
$$;
