-- 【待執行】包桌改單人計價，與配桌走同一條路
-- ============================================================
-- 問題
--   包桌的前後端是兩套算法，而且各錯一半：
--
--     後端 calc_session_fee_tx：整桌計價，opener 收全額、其餘收 0
--     前端 OpenCheckoutPage：  Math.ceil(PRIV_PRICE[minutes] / seated)
--
--   再加上 POS 送的 join_type 是 `tableStarted ? 'mid_join' : 'opener'`——
--   帶桌前所有人都是 opener，所以四個人分開結帳時後端會**每人算全額**。
--   而 join_session_tx 的 v_qty = 1 + 代付人數 不分模式一律相乘，
--   開桌者代付三人會算成 400 × 4 = 1600。
--
--   結果：包桌只有「結帳當下剛好只有 1 人在座」會對上，
--   其餘情況一律收款驗證失敗或超收。測試時放一個人剛好是唯一會過的路徑。
--
-- 決定：包桌比照配桌，一律單人計價
--   麻將桌固定四人，包桌總價 ÷ 4 就是單人價。四人包桌總額不變。
--   這樣「整桌 vs 人頭」的分歧從根本消失 —— 系統裡只剩一種算法。
--
--   ⚠ 已知後果：只來 3 人時收 300 而不是 400。
--     要收滿請在**開桌設定的 UI** 擋「包桌必須四人」，不要回頭改計價邏輯。
--
-- 為什麼不是改前端去配合後端（整桌計價）
--   整桌計價要回答「誰是 opener」，而那個答案目前來自前端的 tableStarted，
--   是還原出來的推測值。讓推測值決定收多少錢，跟 2026-08-16 修掉的
--   `cur.seated` 是同一類的洞。單人計價不需要這個答案。
--
-- 當日暢打維持只對配桌有效
--   暢打（SVC-TBL-DAY 300）賣的是「當日不限將數配桌」，
--   包桌是預訂整張桌子的時段，兩者不是同一個商品。維持現行行為。
-- ============================================================

-- ① 三筆包桌商品改單人價（原為整桌價 ÷ 4）
update public.products
   set unit_price = case sku
                      when 'SVC-TBL-P02' then 100   -- 原 400，≤120 分
                      when 'SVC-TBL-P05' then 150   -- 原 600，≤300 分
                      when 'SVC-TBL-P24' then 200   -- 原 800，≤1440 分
                    end,
       updated_at = now()
 where sku in ('SVC-TBL-P02', 'SVC-TBL-P05', 'SVC-TBL-P24')
   and deleted_at is null;

-- ② 移除包桌特判
--    簽名未變（p_session_id, p_join_type, p_member_id），故不需 DROP。
--    改完之後兩種模式完全對稱：
--      包桌 依 planned_minutes 挑 SKU
--      配桌 依 planned_rounds  挑 SKU
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

  if v_s.mode = 'private' then
    -- 包桌：單人計價，與配桌對稱。
    -- 舊版在此回傳 amount 0（整桌只跟 opener 收一次），
    -- 但 opener 的判斷來自前端推測值，四人各自結帳時每人都被算全額。
    -- 改為每人各付一份，join_type 不影響金額。
    v_sku := case when v_s.planned_minutes <= 120 then 'SVC-TBL-P02'
                  when v_s.planned_minutes <= 300 then 'SVC-TBL-P05'
                  else 'SVC-TBL-P24' end;
  else
    -- 配桌：先看有沒有當日暢打，有的話這一桌不收檯費
    if p_member_id is not null and has_daypass_tx(v_s.org_id, p_member_id) then
      return jsonb_build_object('ok', true, 'amount', 0, 'product_id', null,
        'daypass', true, 'note', '此會員今日已購買當日暢打，不再收取檯費');
    end if;
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
  '試算單人檯費。包桌與配桌一律單人計價：包桌依 planned_minutes、配桌依 planned_rounds 挑 SKU，單價與品名來自 products。配桌另判當日暢打。份數（含代付）由 join_session_tx 決定。';

-- ============================================================
-- ③ 檯費價目 RPC
--    開桌設定頁要在「還沒有 session」的時候顯示價格，
--    所以不能用 calc_session_fee_tx（它吃 session_id）。
--    目前那頁是寫死的 PRIV_PRICE = {120:400, 300:600, 1440:800}
--    與 "3 將 · 每人 $150"，包桌改單人價之後會顯示錯的金額。
--
--    list_products_tx 撈不到這些（service 類被排除，所以 POS 沒有「服務」分頁），
--    因此另開一支只回檯費商品的。
-- ============================================================
drop function if exists public.list_fee_menu_tx(uuid);

create or replace function public.list_fee_menu_tx(p_org_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_object_agg(p.sku, jsonb_build_object(
           'product_id', p.id,
           'name',       p.name,
           'amount',     p.unit_price)), '{}'::jsonb)
    from public.products p
   where p.org_id = p_org_id
     and p.deleted_at is null
     and p.is_active
     and p.is_system
     and p.revenue_type = 'venue_fee';
$$;

comment on function public.list_fee_menu_tx(uuid) is
  '檯費價目表，格式 {SVC-TBL-M3: {product_id, name, amount}, ...}。給開桌設定頁在還沒有 session 時顯示價格用；有 session 之後一律改用 calc_session_fee_tx（它才會判暢打與代付）。';

grant execute on function public.list_fee_menu_tx(uuid) to anon, authenticated;

-- ============================================================
-- 驗證（單一 SELECT）
--   三筆包桌商品的新價格應為 100 / 150 / 200；
--   函式版本數應為 1；包桌特判已移除應為 true；
--   煙霧測試應回 session_not_found（證明函式跑得起來）；
--   價目表筆數應為 7（七個系統檯費商品）。
-- ============================================================
select
  p.sku                                                as 貨號,
  p.name                                               as 品名,
  p.unit_price                                         as 單人價,
  (select count(*) from pg_proc f
     join pg_namespace n on n.oid = f.pronamespace
    where n.nspname = 'public' and f.proname = 'calc_session_fee_tx')     as 函式版本數,
  (select pg_get_functiondef(f.oid) not like '%整桌收費%'
     from pg_proc f join pg_namespace n on n.oid = f.pronamespace
    where n.nspname = 'public' and f.proname = 'calc_session_fee_tx'
      and f.prokind = 'f' limit 1)                                        as 包桌特判已移除,
  (public.calc_session_fee_tx(
     '00000000-0000-0000-0000-000000000000'::uuid) ->> 'reason')          as 煙霧測試,
  (select count(*) from jsonb_object_keys(
     public.list_fee_menu_tx(p.org_id)))                                  as 價目表筆數
from public.products p
where p.sku in ('SVC-TBL-P02', 'SVC-TBL-P05', 'SVC-TBL-P24')
  and p.deleted_at is null
order by p.sku;
