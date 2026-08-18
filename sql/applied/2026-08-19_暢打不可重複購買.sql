-- 【待執行】已持有當日暢打的人不可再買第二張
-- ============================================================
-- 問題
--   has_daypass_tx 問的只有「今天這間店有沒有一張 paid 的 SVC-TBL-DAY 訂單」。
--   所以第二張暢打**完全沒有作用** —— 但錢照收 300。
--   前端已改成持有暢打時不顯示暢打卡，但那不夠：
--   hasPass 讀的是 calc 報價的回傳，報價還沒回來時它是 false，
--   店員在那個空窗點下去就賣掉了。碰錢的事不能只靠前端。
--
-- 為什麼不用 CHECK 或唯一索引
--   「同一天同一店同一會員只能有一張暢打」寫成約束要靠
--   表達式索引 + 時區轉換 + 只算 status='paid'，而 status 會變動
--   （作廢後應該可以再買）—— 部分索引的條件會隨列更新而進出索引，
--   維護成本高過它擋掉的問題。這裡是流程限制，擋在流程上。
--
-- 放在哪
--   v_self_pass 算完的**下一行**。那時還沒有任何寫入
--   （checkout_tx 在更後面），所以 return {ok:false} 不會留下半筆帳。
--   ⚠ join_session_tx 的業務錯誤慣例是回 {ok:false} 而不是拋例外 ——
--     照慣例走，最外層的 pos_checkout_with_topup_tx 會 raise 來回滾。
--
-- 加購路徑不用擋
--   pos_addon_checkout_tx 走 checkout_tx，不經過這裡；
--   但前端在已入座（seated）時本來就不顯示暢打卡，沒有入口。
--   ⚠ 日後若開放「入座後補買暢打」，那條路要自己再擋一次。
-- ============================================================

do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'join_session_tx' and p.prokind = 'f';
  if v_old is null then raise exception 'join_session_tx 不存在'; end if;

  v_new := replace(v_old,
$src$  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);
  v_qty := 0;$src$,
$dst$  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);

  -- 已持有暢打就不能再買一張：has_daypass_tx 只問「今天有沒有」，
  -- 第二張沒有任何作用而錢照收。此處尚未寫入任何資料，可安全返回。
  if v_buy_daypass and v_self_pass then
    return jsonb_build_object('ok', false, 'reason', 'daypass_already_held',
      'message', '此會員今日已持有當日暢打，不需再購買');
  end if;

  v_qty := 0;$dst$);

  if v_new = v_old then
    raise exception '找不到目標字串，線上版可能已改過 —— 先撈 pg_get_functiondef 確認';
  end if;

  execute v_new;
end $$;

-- ============================================================
-- 驗證（單一 SELECT）
--   擋牆已寫入 true、版本數 1、DEFINER true。
--   後兩欄是暢打的營運數字（免收金額用 order_items.line_total，
--   不是 orders.payable —— 後者含同一張單的餐飲，2026-08-19 修正過）。
-- ============================================================
with fns as (
  select p.oid, p.proname, p.prosecdef, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.proname = 'join_session_tx'
)
select
  (select bool_or(def like '%daypass_already_held%') from fns)              as 擋牆已寫入,
  (select count(*) from fns)                                               as 版本數,
  (select bool_and(prosecdef) from fns)                                    as 是DEFINER,
  (select coalesce(sum(fee_waived_amount), 0) from public.session_players
    where fee_waived_reason = 'daypass')                                   as 暢打抵掉金額,
  (select coalesce(sum(oi.line_total), 0)
     from public.order_items oi
     join public.orders o on o.id = oi.order_id
     join public.products pr on pr.id = oi.product_id
    where pr.sku = 'SVC-TBL-DAY' and o.status = 'paid')                    as 暢打售出金額;
