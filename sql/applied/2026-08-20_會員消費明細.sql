-- 【待執行】get_my_orders_tx：會員 App 的「最近消費」
-- ============================================================
-- 問題
--   wallet.jsx 的清單來自 get_wallet_tx 回的 **wallet_txns（點數流水）**，
--   不是消費紀錄。所以：
--     · **付現金的消費完全不會出現** —— 收現金不產生點數異動
--     · 分類牌讀 wallet_txns.type，而那一欄裝了兩個維度
--       （topup/refund/reversal/adjust 是交易性質，
--         spend/table_fee/fnb/merch/event_fee 是消費類別），
--       且 checkout_tx 現在一律寫 'spend' —— 那些類別值是舊世代遺留（待辦 12）
--
--   改元計價 + 混合付款之後，檯費可以直接收現金。
--   一個只付現金的客人，打開會員 App 會看到「還沒有紀錄」。
--
-- 解法
--   從事實表 orders / order_items / order_payments 直接取，
--   與 get_session_member_orders_tx 是同一份資料的不同切法
--   （那支按場次，這支按會員、跨場次、可分頁）。
--
-- 【為什麼不擴充 get_wallet_tx】
--   它管的是餘額與券，兩者都不需要分頁。
--   把時間軸與分頁參數塞進去，它就變成一支什麼都做的函式，
--   而錢包頁每次載入都要付分頁查詢的成本。
--   前端兩支平行呼叫，延遲跟一支一樣。
--
-- 【儲值與消費的配對】
--   同一次收款可能同時產生 orders 與 topup_orders 兩張單，
--   靠冪等鍵前綴配對（pos-<sess>-<member>-<ts> 加 :order / :topup）——
--   與 POS 桌帳完全同一套邏輯，兩邊看到的列數才會一樣。
--   沒配對到的儲值單單獨列出，不能默默消失。
--
-- 【刻意不回門市名稱】
--   orders 有 store_id，但 topup_orders 有沒有我沒查證（硬規則 3）——
--   為了一個欄位再跑一趟盤點不划算，而「在哪家店」對單店期沒有用途。
--   之後真的要顯示門市時再一起加，那時把兩張表一起查清楚。
--
-- 🔴 **既有的存取問題（本檔沿用，不是新開的洞）**
--   SECURITY DEFINER + p_member_id 由前端傳入 ——
--   知道任何一個會員 uuid 就能查他的資料。get_wallet_tx 一直是這樣。
--   但**消費明細比餘額敏感**（買了什麼、花多少、什麼時間在店裡）。
--   正解是 LIFF 換 JWT、RPC 改從 auth.uid() 取會員，那是另一件工。
--   → 已記進 CLAUDE.md 待辦。KIOSK 或任何公開入口上線前必須先做。
-- ============================================================

drop function if exists public.get_my_orders_tx(uuid, integer);
drop function if exists public.get_my_orders_tx(uuid, integer, timestamptz);

create or replace function public.get_my_orders_tx(
  p_member_id uuid,
  p_limit     integer     default 10,
  p_before    timestamptz default null)   -- 分頁游標：只取比它更早的（「全部」頁用）
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 10), 100));
  v_list  jsonb;
begin
  if p_member_id is null then
    raise exception 'member_id required';
  end if;

  select coalesce(jsonb_agg(x order by x_at desc), '[]'::jsonb)
    into v_list
    from (
      select u.x_at, u.x
        from (
          -- ── 消費單（可能附帶同一次交易的儲值）──
          select o.paid_at as x_at,
                 jsonb_build_object(
                   'type', 'order',
                   'id', o.id,
                   'order_no', o.order_no,
                   'txn_no', o.txn_no,
                   'paid_at', o.paid_at,
                   'subtotal', o.subtotal,
                   'coupon_discount', o.coupon_discount,
                   'tier_discount', o.tier_discount,
                   'payable', o.payable,
                   'points_used', o.points_used,
                   'cash_due', o.cash_due,
                   'items', (
                     select coalesce(jsonb_agg(jsonb_build_object(
                       'name', i.name, 'revenue_type', i.revenue_type, 'qty', i.qty,
                       'unit_price', i.unit_price, 'line_total', i.line_total
                     ) order by case i.revenue_type
                                  when 'venue_fee' then 1
                                  when 'fnb'       then 2
                                  when 'retail'    then 3
                                  else 4 end, i.name), '[]'::jsonb)
                     from order_items i where i.order_id = o.id),
                   'payments', (
                     select coalesce(jsonb_agg(jsonb_build_object(
                       'method', pm.method, 'amount', pm.amount
                     )), '[]'::jsonb)
                     from order_payments pm where pm.order_id = o.id),

                   -- 同一次收款的儲值（冪等鍵前綴配對，與 POS 桌帳同一套）
                   'topup', (
                     select jsonb_build_object(
                              'topup_no',     t.topup_no,
                              'points',       t.points,
                              'bonus_points', t.bonus_points,
                              'credit',       t.points + t.bonus_points,
                              'amount_twd',   t.amount_twd)
                       from topup_orders t
                      where t.member_id = o.member_id
                        and t.status = 'paid'
                        and o.idempotency_key like 'pos-%'
                        and split_part(t.idempotency_key, ':', 1)
                          = split_part(o.idempotency_key, ':', 1)
                      limit 1),

                   'collected', o.payable + coalesce((
                     select t.amount_twd from topup_orders t
                      where t.member_id = o.member_id
                        and t.status = 'paid'
                        and o.idempotency_key like 'pos-%'
                        and split_part(t.idempotency_key, ':', 1)
                          = split_part(o.idempotency_key, ':', 1)
                      limit 1), 0)
                 ) as x
            from orders o
           where o.member_id = p_member_id
             and o.deleted_at is null
             and o.status = 'paid'

          union all

          -- ── 沒有配對到訂單的儲值單 ──
          select t.created_at as x_at,
                 jsonb_build_object(
                   'type', 'topup',
                   'id', t.id,
                   'order_no', t.topup_no,
                   'txn_no', t.txn_no,
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
                   -- 儲值不是收入桶，用獨立旗標標記（與 POS 一致）
                   'items', jsonb_build_array(jsonb_build_object(
                     'name', '會員儲值 ' || (t.points + t.bonus_points)::text || ' 點',
                     'is_topup', true, 'qty', 1,
                     'unit_price', t.amount_twd, 'line_total', t.amount_twd)),
                   'payments', jsonb_build_array(jsonb_build_object(
                     'method', t.pay_method, 'amount', t.amount_twd))
                 ) as x
            from topup_orders t
           where t.member_id = p_member_id
             and t.status = 'paid'
             and not exists (
               select 1 from orders o
                where o.member_id = t.member_id
                  and o.deleted_at is null
                  and o.status = 'paid'
                  and o.idempotency_key like 'pos-%'
                  and split_part(o.idempotency_key, ':', 1)
                    = split_part(t.idempotency_key, ':', 1))
        ) u
       where p_before is null or u.x_at < p_before
       order by u.x_at desc
       limit v_limit
    ) z;

  return jsonb_build_object(
    'orders', v_list,
    -- 還有更多：前端據此決定要不要顯示「載入更多」。
    -- 回筆數等於上限就當作還有 —— 少一次查詢，代價是最後一頁可能多按一次。
    'has_more', jsonb_array_length(v_list) >= v_limit,
    'next_before', case when jsonb_array_length(v_list) > 0
                        then (v_list -> (jsonb_array_length(v_list) - 1) ->> 'paid_at')
                   end);
end $function$;

comment on function public.get_my_orders_tx(uuid, integer, timestamptz) is
  '會員 App 的消費時間軸：orders（含同次交易的儲值）與未配對的儲值單合併，時間新到舊。與 get_session_member_orders_tx 是同一份資料的不同切法（那支按場次，這支按會員、可分頁）。取代原本讀 wallet_txns 的做法 —— 那個看不到現金消費。';

grant execute on function public.get_my_orders_tx(uuid, integer, timestamptz) to anon, authenticated;

-- ============================================================
-- 驗證（單一 SELECT）
--   ⚠ 硬規則 7：不是「CREATE 成功」就算完成，要真的執行並看到回傳。
--   第三欄實際呼叫函式，回的是測試01 最近 3 筆的摘要。
--   ★ 第四欄是這支存在的理由：**只付現金、沒有點數異動的訂單數**。
--     那些就是舊做法（讀 wallet_txns）永遠看不到的消費。
-- ============================================================
with m as (
  select id from public.members
   where display_name = '測試01' and is_test = true limit 1
)
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_my_orders_tx'
      and p.prokind = 'f')                                                as 版本數,
  (select bool_and(p.prosecdef) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_my_orders_tx')        as 是DEFINER,
  (select jsonb_agg(jsonb_build_object(
            'type', e ->> 'type',
            'txn',  e ->> 'txn_no',
            'when', to_char((e ->> 'paid_at')::timestamptz
                            at time zone 'Asia/Taipei', 'MM/DD HH24:MI'),
            'payable', e -> 'payable',
            'points',  e -> 'points_used',
            'items', (select jsonb_agg(i ->> 'name')
                        from jsonb_array_elements(e -> 'items') i)))
     from m, jsonb_array_elements(
            public.get_my_orders_tx((select id from m), 3) -> 'orders') e) as 測試01最近三筆,
  (select count(*) from public.orders o, m
    where o.member_id = m.id and o.status = 'paid' and o.deleted_at is null
      and coalesce(o.points_used, 0) = 0)                                 as 純現金訂單數;
