/* ============================================================
   2026-11-01  商人熊：以「這一桌」為單位，全有或全無；用了券就不折
   ------------------------------------------------------------
   接在 2026-11-01_牌咖團顧問_商人熊檯費折50.sql 之後。使用者 2026-11-01 定的原則：
     「系統偵測到本桌 4 位都是同團，自動跑出每個人優惠折 50；其中少一位，就全部都沒有。」
     「只有兩種結果：整團拿顧問優惠 50，或是正常結帳（會員、優惠券、點數…）。」
     「券不能用、點數可以付。」

   ① _join_plan（整支重寫，簽名不變）
      這桌四位要**全部**符合：同一個商人熊團、直營店、**四位今天都沒有在別桌用過**
        ⇒ 這次要付檯費的每一位都折 50
      有一位不符合 ⇒ 這桌四個人都沒有
      ⚠ 同一桌先結帳的人用掉的不算（各付各的時候，第一位折完、後面三位照樣有）
        ⇒ 判斷「用過」只看 session_id 不是這一場的紀錄
      ⚠ 暢打的人那一份檯費本來就是 0，不影響其他三位
   ② _cart_pricing（只換一行）
      有選優惠券 ⇒ 不算商人熊（走正常結帳：會員折扣 ＋ 券）；點數是付款方式，不受影響
   兩支都是 CREATE OR REPLACE（簽名不變）⇒ 授權不會掉，POS 不用重推。
   ============================================================ */

-- ① _join_plan
create or replace function public._join_plan(p_session_id uuid, p_member_id uuid, p_join_type text, p_pay_for uuid[], p_items jsonb,
                                             p_table_members uuid[] default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_s record; v_base jsonb; v_unit bigint; v_qty int; v_amount bigint;
  v_items jsonb; v_target uuid; v_extra int := 0;
  v_buy_daypass boolean := false;   -- 本次結帳是否含當日暢打
  v_self_pass boolean := false;     -- 付款人是否已持有暢打
  v_fee_members uuid[] := '{}';     -- 這次要付檯費的人（付款人自己 ＋ 被代付的），暢打的不算
  v_adv jsonb := null; v_team record;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if p_join_type not in ('opener','mid_join','sub') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_join_type');
  end if;

  -- 附加品項驗證。純輸入檢查，刻意排在查場次之前。
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  if v_extra > 0 then
    select exists (
      select 1 from jsonb_array_elements(p_items) it
       where exists (select 1 from products pr
                      where pr.id = nullif(it ->> 'product_id', '')::uuid and pr.sku = 'SVC-TBL-DAY'))
      into v_buy_daypass;

    -- 場地費由系統自己算，前端再送一份會重複收費；暢打例外（它賣的是今天不再收場地費的權利）
    if exists (
      select 1 from jsonb_array_elements(p_items) it
        join products pr on pr.id = nullif(it ->> 'product_id', '')::uuid
       where pr.revenue_type = 'venue_fee' and pr.sku <> 'SVC-TBL-DAY' and pr.deleted_at is null
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed',
        'message', '場地費由系統計算，不可由前端傳入');
    end if;

    -- 儲值寫的是 topup_orders 不是 orders，不能混進同一張單（儲值不是商品，維持讀前端旗標）
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'is_topup' = 'true' or it ->> 'revenue_type' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed',
        'message', '儲值請走儲值流程，不能併入結帳');
    end if;

    if exists (
      select 1 from jsonb_array_elements(p_items) it
       where nullif(it ->> 'product_id', '') is null or coalesce((it ->> 'qty')::int, 0) <= 0
    ) or exists (
      select 1 from jsonb_array_elements(p_items) it
        left join products pr on pr.id = nullif(it ->> 'product_id', '')::uuid and pr.deleted_at is null
       where nullif(it ->> 'product_id', '') is not null
         and (pr.id is null or (pr.revenue_type not in ('fnb','retail','other') and pr.sku <> 'SVC-TBL-DAY'))
    ) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_item',
        'message', '品項需有存在的 product_id、數量大於 0，且收入桶為 fnb／retail／other');
    end if;
  end if;

  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '此場次已收桌或已作廢');
  end if;

  -- 鐵則一：一律會員
  if not exists (select 1 from members where id = p_member_id and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '需先建立會員資料');
  end if;

  if exists (select 1 from session_players
              where session_id = p_session_id and member_id = p_member_id and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_joined');
  end if;

  -- 座位上限：自己 ＋ 代付人數不可超過 4
  if (select count(*) from session_players where session_id = p_session_id and left_at is null)
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
        return jsonb_build_object('ok', false, 'reason', 'payfor_member_invalid', 'member_id', v_target);
      end if;
      if exists (select 1 from session_players
                  where session_id = p_session_id and member_id = v_target and left_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_already_joined', 'member_id', v_target);
      end if;
    end loop;
  end if;

  -- 標準單價：會員傳 null 取得「不看暢打」的價格（暢打是個人權利，不因誰付錢而轉移）
  v_base := public.calc_session_fee_tx(p_session_id, p_join_type, null);
  if not (v_base ->> 'ok')::boolean then return v_base; end if;
  v_unit := coalesce((v_base ->> 'amount')::bigint, 0);

  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);
  if v_buy_daypass and v_self_pass then
    return jsonb_build_object('ok', false, 'reason', 'daypass_already_held',
      'message', '此會員今日已持有當日暢打，不需再購買');
  end if;

  -- 份數逐人判斷：本次買暢打的話付款人自己這份當場歸零
  v_qty := 0;
  if not v_buy_daypass and not v_self_pass then
    v_qty := 1; v_fee_members := v_fee_members || p_member_id;
  end if;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if not has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then
        v_qty := v_qty + 1; v_fee_members := v_fee_members || v_target;
      end if;
    end loop;
  end if;
  v_amount := v_unit * v_qty;

  /* 🆕 2026-11-01 商人熊：以「這一桌」為單位（使用者：本桌 4 位都是同團就每人折 50，少一位就全部沒有）
     · 付款人與這次要付檯費的人都要在 POS 宣告的這桌四位裡
     · 四人有共同團、顧問是商人熊、直營店
     · 四位**今天都沒有在別桌用過** —— 同一場（同一桌）先結帳的人用掉的不算，
       不然各付各的時候第一位折完，後面三位就被他擋掉了
     · 符合 ⇒ 這次要付檯費的每一位都折 50；不符合 ⇒ 全部沒有（沒有「只有部分人有」）
     · 折多少由 _cart_pricing 再夾一次（不會折超過檯費）；有選券的話 _cart_pricing 也會整筆不算 */
  if v_amount > 0 and p_table_members is not null
     and p_member_id = any(p_table_members) and v_fee_members <@ p_table_members
     and exists (select 1 from stores st where st.id = v_s.store_id and st.store_type = '直營') then
    select * into v_team from public._advisor_table_team(v_s.org_id, p_table_members);
    if v_team.team_id is not null and v_team.advisor = 'merchant'
       and not exists (select 1 from advisor_perk_uses u
                        where u.member_id = any(p_table_members) and u.kind = 'merchant'
                          and u.use_date = v_today and u.session_id is distinct from p_session_id) then
      v_adv := jsonb_build_object(
        'code', 'merchant', 'team_id', v_team.team_id, 'team_name', v_team.team_name,
        'unit', 50, 'members', to_jsonb(v_fee_members), 'cut', 50 * cardinality(v_fee_members),
        'table_members', to_jsonb(p_table_members), 'session_id', p_session_id);
    end if;
  end if;

  v_items := '[]'::jsonb;
  if v_amount > 0 then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id', v_base ->> 'product_id', 'name', v_base ->> 'name',
      'revenue_type', 'venue_fee', 'qty', v_qty, 'unit_price', v_unit));
  end if;
  if v_extra > 0 then v_items := v_items || p_items; end if;

  return jsonb_build_object('ok', true,
    'org_id', v_s.org_id, 'store_id', v_s.store_id, 'table_id', v_s.table_id,
    'unit_fee', v_unit, 'qty', v_qty, 'amount', v_amount,
    'fee_product_id', v_base ->> 'product_id', 'fee_name', v_base ->> 'name',
    'daypass', v_self_pass, 'daypass_bought', v_buy_daypass,
    'extra_items', v_extra, 'items', v_items,
    'advisor', v_adv);
end $function$;


-- ② _cart_pricing：有券就不算商人熊（只換一行；沒換到就整份不提交 —— raise 只在失敗時走，硬規則 1.8）
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef('public._cart_pricing(uuid, uuid, jsonb, uuid[], bigint)'::regprocedure) into v_old;
  if v_old !~ 'p_coupon_ids is not null and array_length\(p_coupon_ids, 1\) > 0 then 0' then
    v_new := replace(v_old,
      'v_adv_cut := least(greatest(coalesce(p_advisor_cut, 0), 0), v_rem_fee);',
      'v_adv_cut := case when p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then 0   -- 用了券就走正常結帳（使用者 2026-11-01）'
      || E'\n                   else least(greatest(coalesce(p_advisor_cut, 0), 0), v_rem_fee) end;');
    if v_new = v_old then raise exception '_cart_pricing 沒有換到，整份不提交'; end if;
    execute v_new;
  end if;
end $$;

/* ── 驗證（單一 SELECT，不用 raise）── 行為另外跑 sql/checks/2026-11-01_驗商人熊檯費折50.sql（已更新成新規則） */
select
  (select pg_get_functiondef('public._join_plan(uuid, uuid, text, uuid[], jsonb, uuid[])'::regprocedure)
          ~ 'session_id is distinct from p_session_id') as "① 以這一桌為單位（應為 true）",
  (select pg_get_functiondef('public._cart_pricing(uuid, uuid, jsonb, uuid[], bigint)'::regprocedure)
          ~ 'p_coupon_ids is not null and array_length\(p_coupon_ids, 1\) > 0 then 0') as "② 有券就不折（應為 true）",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('_join_plan', '_cart_pricing')) as "③ 兩支各一個版本（應為 2）",
  (select string_agg(p.proname || '=' || (select string_agg(a.grantee::regrole::text, '/' order by 1) from aclexplode(p.proacl) a where a.grantee <> 0), '  ')
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('_join_plan', '_cart_pricing')) as "④ 授權沒掉（只有 postgres／service_role）";
