/* ============================================================
   2026-11-01  牌咖團顧問 · 商人熊：檯費每人少 50 元
   ------------------------------------------------------------
   使用者 2026-11-01 拍板的規則：
     · 結帳當下判斷：POS 結帳頁「這桌四位」都是同一團的團員，那團的顧問是商人熊
     · 只有直營店（stores.store_type = '直營'）
     · 每人每天一次（台北日曆日，同當日暢打的判準）
     · 當日暢打不折（暢打的人本來就不付檯費，那一份不算）
     · 有扣 50 就沒有會員等級折扣（擇一，不疊加）
     · 四人有一團都在就算；四人同時有兩個以上的共同團（而且都有顧問）時，
       挑「最早湊齊這四個人」的那一團（四人裡最晚入團的時間最早）

   ── 「這桌四位」是誰說的 ─────────────────────────────
   POS 結帳頁的四個座位（配桌自動帶入、現場由店員選人）。
   後端只能檢查「這四個人是不是同團」，**檢查不了人是不是真的在場**
   ⇒ 使用者 2026-11-01 知道並接受：每次只差 50、只有店員做得到、每一筆都有紀錄。
   🔴 前端只送「這桌四位是誰」（意圖），**折多少一律後端算**（硬規則 5.8）。

   ── 改了什麼 ─────────────────────────────────────────
   ① 新表 advisor_perk_uses：誰、哪天、哪一團、哪四個人、哪一筆訂單
      唯一索引 (member_id, kind, use_date) ⇒ 每人每天一次由索引擋，不是先查再寫
   ② orders 加 advisor_discount、advisor_team_id；金額約束 orders_amount_balance 一起改
   ③ v_real_orders 補上那兩欄（檢視表的欄位清單是寫死的，不會自己跟上 —— 硬規則 1.65）
   ④ _advisor_table_team：四個人的共同團（只有一份定義）
   ⑤ _join_plan    多收 p_table_members，回傳 advisor { code, team_id, members, cut, unit }
   ⑥ _cart_pricing 多收 p_advisor_cut；有折就不算等級折扣，回傳 advisor_discount
   ⑦ checkout_tx   多收 p_advisor；寫 orders 那兩欄與 advisor_perk_uses
   ⑧ join_session_tx／pos_checkout_with_topup_tx／pos_quote_tx 多收 p_table_members
   新參數一律放最後、預設 null ⇒ **還沒更新的 POS 照常結帳（只是沒有優惠）**，
   這份可以先跑、POS 後推。

   ⚠ 改簽名的一律先 DROP（硬規則 2），DROP 會丟授權 ⇒ 每一支結尾都補回原本的授權：
     內部三支（_join_plan／_cart_pricing／checkout_tx）原本只有 postgres、service_role
     前端三支（join_session_tx／pos_checkout_with_topup_tx／pos_quote_tx）原本多 authenticated
   ============================================================ */

-- ① 用了幾次的紀錄
create table if not exists public.advisor_perk_uses (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.orgs(id),
  kind          text not null check (kind in ('merchant')),
  member_id     uuid not null references public.members(id),
  use_date      date not null,
  team_id       uuid not null references public.teams(id),
  store_id      uuid not null references public.stores(id),
  session_id    uuid references public.table_sessions(id),
  order_id      uuid not null references public.orders(id),
  amount        bigint not null check (amount >= 0),
  table_members uuid[] not null,
  staff_id      uuid,
  created_at    timestamptz not null default now()
);
create unique index if not exists uq_advisor_perk_once_a_day
  on public.advisor_perk_uses (member_id, kind, use_date);
alter table public.advisor_perk_uses enable row level security;   -- 0 policy：只有 DEFINER 函式進得去
revoke all on public.advisor_perk_uses from public, anon, authenticated;
comment on table public.advisor_perk_uses is
  '牌咖團顧問的優惠用了誰、哪天（2026-11-01）。商人熊每人每天一次由唯一索引擋。table_members 是 POS 結帳頁宣告的這桌四位（稽核）';

-- ② orders 兩欄 ＋ 金額約束
alter table public.orders add column if not exists advisor_discount bigint not null default 0;
alter table public.orders add column if not exists advisor_team_id  uuid references public.teams(id);
comment on column public.orders.advisor_discount is '牌咖團顧問的折抵（2026-11-01 起只有商人熊的檯費 50）。有它就沒有等級折扣';
comment on column public.orders.advisor_team_id  is '顧問折抵算的是哪一團';

alter table public.orders drop constraint if exists orders_amount_balance;
alter table public.orders add constraint orders_amount_balance check (
      payable = subtotal - coupon_discount - tier_discount - advisor_discount
  and cash_due = payable - points_used
  and subtotal >= 0 and coupon_discount >= 0 and tier_discount >= 0
  and advisor_discount >= 0 and points_used >= 0 and cash_due >= 0);

-- ③ 報表檢視表補兩欄（只能加在最後面）
create or replace view public.v_real_orders as
 SELECT x.id, x.org_id, x.store_id, x.member_id, x.table_id, x.session_id, x.status, x.channel,
    x.total_points, x.deleted_at, x.created_at, x.updated_at, x.created_by, x.updated_by,
    x.order_no, x.subtotal, x.coupon_discount, x.tier_discount, x.payable, x.points_used,
    x.cash_due, x.tier_at_order, x.idempotency_key, x.wallet_txn_id, x.paid_at, x.entity_id,
    x.is_test, x.tier_discount_pct, x.txn_no,
    x.advisor_discount, x.advisor_team_id
   FROM orders x
     JOIN orgs o ON o.id = x.org_id
  WHERE NOT COALESCE(x.is_test, false) AND x.deleted_at IS NULL
    AND x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone)
    AND NOT (EXISTS ( SELECT 1 FROM stores s WHERE s.id = x.store_id AND s.is_test))
    AND NOT (EXISTS ( SELECT 1 FROM members m WHERE m.id = x.member_id AND m.is_test));


-- ④ 四個人的共同團（有顧問的）
create or replace function public._advisor_table_team(p_org uuid, p_members uuid[])
 returns table(team_id uuid, advisor text, team_name text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  /* 「整桌 4 位都是團員」只有這一份定義。
     · 四個不同的人（少於四個或有重複就沒有團）
     · 只看有顧問的團：四人另有一個沒顧問的共同團，不應該讓他們失去加成
     · 兩個以上時挑「最早湊齊這四個人」的那一團 ⇒ 四人裡最晚入團的時間最早（使用者：算最早加入的那一團） */
  with m as (select distinct x as id from unnest(p_members) x where x is not null)
  select t.id, t.advisor, t.name
    from public.teams t
    join public.team_members tm on tm.team_id = t.id and tm.left_at is null
                               and tm.member_id in (select id from m)
   where t.org_id = p_org and t.deleted_at is null and t.advisor is not null
     and (select count(*) from m) = 4
   group by t.id, t.advisor, t.name, t.created_at
  having count(distinct tm.member_id) = 4
   order by max(tm.joined_at), t.created_at
   limit 1
$function$;
revoke execute on function public._advisor_table_team(uuid, uuid[]) from public, anon, authenticated;
grant  execute on function public._advisor_table_team(uuid, uuid[]) to service_role;


-- ⑤ _join_plan：多收 p_table_members，算出商人熊誰有、折多少
drop function if exists public._join_plan(uuid, uuid, text, uuid[], jsonb);

create function public._join_plan(p_session_id uuid, p_member_id uuid, p_join_type text, p_pay_for uuid[], p_items jsonb,
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
  v_adv jsonb := null; v_team record; v_elig uuid[];
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

  /* 🆕 2026-11-01 商人熊：檯費每人少 50 元
     · 付款人一定要在 POS 宣告的這桌四位裡（不然那四位不是他這一桌）
     · 四人有共同團、顧問是商人熊、直營店
     · 有資格的是「這次要付檯費的人 ∩ 這桌四位 ∩ 今天還沒用過」 —— 暢打的人那一份本來就是 0，不算
     · 折多少由 _cart_pricing 再夾一次（不會折超過檯費） */
  if v_amount > 0 and p_table_members is not null and p_member_id = any(p_table_members)
     and exists (select 1 from stores st where st.id = v_s.store_id and st.store_type = '直營') then
    select * into v_team from public._advisor_table_team(v_s.org_id, p_table_members);
    if v_team.team_id is not null and v_team.advisor = 'merchant' then
      select coalesce(array_agg(f), '{}') into v_elig
        from unnest(v_fee_members) f
       where f = any(p_table_members)
         and not exists (select 1 from advisor_perk_uses u
                          where u.member_id = f and u.kind = 'merchant' and u.use_date = v_today);
      if cardinality(v_elig) > 0 then
        v_adv := jsonb_build_object(
          'code', 'merchant', 'team_id', v_team.team_id, 'team_name', v_team.team_name,
          'unit', 50, 'members', to_jsonb(v_elig), 'cut', 50 * cardinality(v_elig),
          'table_members', to_jsonb(p_table_members), 'session_id', p_session_id);
      end if;
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

revoke execute on function public._join_plan(uuid, uuid, text, uuid[], jsonb, uuid[]) from public, anon, authenticated;
grant  execute on function public._join_plan(uuid, uuid, text, uuid[], jsonb, uuid[]) to service_role;


-- ⑥ _cart_pricing：多收 p_advisor_cut
drop function if exists public._cart_pricing(uuid, uuid, jsonb, uuid[]);

create function public._cart_pricing(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[],
                                     p_advisor_cut bigint default 0)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_tier text; v_pct int;
  v_sub bigint := 0; v_fee bigint := 0; v_fnb bigint := 0; v_goods bigint := 0;
  v_nodisc bigint := 0;   -- 不參與折扣的金額（只為驗算與回傳，不進任何桶）
  v_coupon_cut bigint := 0; v_tier_cut bigint; v_adv_cut bigint := 0; v_payable bigint;
  v_coupons jsonb := '[]'::jsonb;
  -- 每一個品項：商品、營收類別、子分類、扣的順序（檯費 1、餐飲 2、其餘 3）、可不可折、還剩多少可折
  l_pid uuid[] := '{}'; l_rt text[] := '{}'; l_sub text[] := '{}'; l_ord int[] := '{}';
  l_disc boolean[] := '{}'; l_rem bigint[] := '{}'; n int := 0;
  v_match boolean[]; v_has_scope boolean; v_rem_fee bigint;
  it jsonb; cp record; cap bigint; cut bigint; r bigint; d bigint; i int; k int;
begin
  /* 品項：前端只送「意圖」（product_id ＋ qty），其餘一律回查主檔（2026-08-27 起）。
     ⚠ 不過濾 is_active：結帳是已經發生的交易，不是決定要不要賣。 */
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    for it in select * from jsonb_array_elements(p_items) loop
      declare
        x_pid uuid := nullif(it->>'product_id','')::uuid;
        x_qty int := (it->>'qty')::int;
        x_price bigint; x_name text; x_bucket text; x_disc boolean; x_sub text; x_line bigint;
      begin
        if x_pid is null then
          raise exception '品項缺少 product_id：%', coalesce(it->>'name', '(未命名)');
        end if;
        select pr.unit_price, pr.name, pr.revenue_type, pr.discountable, pr.subcategory
          into x_price, x_name, x_bucket, x_disc, x_sub
          from public.products pr
         where pr.id = x_pid and pr.org_id = p_org and pr.deleted_at is null;
        if not found then
          raise exception '商品不存在或不屬於本機構：%', x_pid;
        end if;
        if x_qty <= 0 then raise exception '品項數量不合法：%', x_qty; end if;
        if x_price < 0 then raise exception '商品 % 主檔單價為負', x_name; end if;
        -- 值域檢查要留著：日後加了新的收入類別而這裡沒跟上時，要大聲失敗
        if x_bucket not in ('venue_fee','fnb','retail','other') then
          raise exception '商品 % 的 revenue_type 尚未支援：%', x_name, x_bucket;
        end if;
        x_line := x_qty * x_price;
        v_sub  := v_sub + x_line;
        if not x_disc then                v_nodisc := v_nodisc + x_line;
        elsif x_bucket = 'venue_fee' then v_fee    := v_fee    + x_line;
        elsif x_bucket = 'fnb'       then v_fnb    := v_fnb    + x_line;
        else                              v_goods  := v_goods  + x_line;
        end if;
        n := n + 1;
        l_pid[n] := x_pid; l_rt[n] := x_bucket; l_sub[n] := x_sub;
        l_ord[n] := case x_bucket when 'venue_fee' then 1 when 'fnb' then 2 else 3 end;
        l_disc[n] := x_disc;
        l_rem[n] := case when x_disc then x_line else 0 end;   -- 不可折扣的品項從一開始就沒有可折的額度
      end;
    end loop;
  end if;

  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    for cp in
      select mc.id as mc_id, c.id as coupon_id, c.name as c_name, c.discount_type, c.discount_value,
             c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
        from member_coupons mc
        join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
       order by array_position(p_coupon_ids, mc.id)   -- 店員選的順序
    loop
      perform 1 from member_coupons
        where id = cp.mc_id and used_at is null and coalesce(status,'') <> 'used'
          and (expires_at is null or expires_at > now());
      if not found then
        raise exception '券 % 已使用或已過期', cp.c_name;
      end if;

      -- 這張券涵蓋哪些品項
      v_has_scope := exists (select 1 from coupon_scopes s where s.coupon_id = cp.coupon_id);
      v_match := '{}'; cap := 0;
      for i in 1 .. n loop
        if cp.discount_type = 'free' and cp.free_product_id is not null then
          v_match[i] := l_disc[i] and l_pid[i] = cp.free_product_id;          -- 指定商品免費券：只有那個商品
        elsif not v_has_scope then
          v_match[i] := l_disc[i];                                          -- 沒有規則：全部可折扣品項
        else
          v_match[i] := l_disc[i] and exists (
            select 1 from coupon_scopes s
             where s.coupon_id = cp.coupon_id
               and ((s.scope_type = 'revenue_type' and s.scope_value = l_rt[i])
                 or (s.scope_type = 'subcategory'  and s.scope_value = l_sub[i])
                 or (s.scope_type = 'product'      and s.scope_value = l_pid[i]::text)));
        end if;
        if v_match[i] then cap := cap + l_rem[i]; end if;
      end loop;

      if cp.discount_type = 'free' and cp.free_product_id is not null then
        if cap <= 0 then
          raise exception '券 % 指定商品不在本次訂單中，或該商品不參與折扣', cp.c_name;
        end if;
      elsif cap <= 0 then
        raise exception '券 % 不適用於本次品項', cp.c_name;
      end if;

      if cp.min_spend is not null and cap < cp.min_spend then
        raise exception '券 % 需最低消費 %（本次適用範圍僅 %）', cp.c_name, cp.min_spend, cap;
      end if;

      cut := case cp.discount_type
               when 'free'    then cap
               when 'percent' then round(cap * coalesce(cp.discount_value,0) / 100.0)
               else                least(coalesce(cp.discount_value,0), cap)
             end;
      if cp.max_discount is not null and cut > cp.max_discount then cut := cp.max_discount; end if;
      cut := least(cut, cap);
      if cut <= 0 then raise exception '券 % 折抵金額為 0', cp.c_name; end if;

      v_coupon_cut := v_coupon_cut + cut;
      v_coupons := v_coupons || jsonb_build_array(jsonb_build_object(
        'member_coupon_id', cp.mc_id, 'name', cp.c_name, 'scope_label', public._coupon_scope_label(cp.coupon_id),
        'cut', cut, 'cost_bearer', cp.cost_bearer));

      -- 從涵蓋的品項扣：檯費 → 餐飲 → 其餘，同一類照品項順序
      r := cut;
      for k in 1 .. 3 loop
        for i in 1 .. n loop
          if v_match[i] and l_ord[i] = k and r > 0 then
            d := least(r, l_rem[i]); l_rem[i] := l_rem[i] - d; r := r - d;
          end if;
        end loop;
      end loop;
    end loop;
  end if;

  -- 檯費（券折抵後剩下、而且可折扣的那一部分）
  v_rem_fee := 0;
  for i in 1 .. n loop
    if l_rt[i] = 'venue_fee' then v_rem_fee := v_rem_fee + l_rem[i]; end if;
  end loop;
  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;

  /* 🆕 2026-11-01 牌咖團顧問：折抵也只折檯費，夾在剩下的檯費以內。
     **有折就不算等級折扣**（使用者：有扣 50 就沒有等級優惠）—— 等級折扣率也記成 0，
     訂單上的快照才不會出現「9 折但折了 0 元」。金額由 _join_plan 算好傳進來，前端碰不到。 */
  v_adv_cut := least(greatest(coalesce(p_advisor_cut, 0), 0), v_rem_fee);
  if v_adv_cut > 0 then
    v_pct := 0;
  else
    -- 等級折扣：只折檯費；查不到的等級一律 0
    select coalesce(t.discount_pct, 0) into v_pct from member_tiers t where t.code = v_tier and t.is_active;
    v_pct := coalesce(v_pct, 0);
  end if;
  v_tier_cut := round(v_rem_fee * v_pct / 100.0);

  v_payable := v_sub - v_coupon_cut - v_tier_cut - v_adv_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;

  return jsonb_build_object(
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'fee', v_fee, 'fnb', v_fnb, 'goods', v_goods,
    'coupon_discount', v_coupon_cut, 'coupons', v_coupons,
    'tier', v_tier, 'tier_discount_pct', v_pct, 'tier_discount', v_tier_cut,
    'advisor_discount', v_adv_cut,
    'payable', v_payable);
end $function$;

revoke execute on function public._cart_pricing(uuid, uuid, jsonb, uuid[], bigint) from public, anon, authenticated;
grant  execute on function public._cart_pricing(uuid, uuid, jsonb, uuid[], bigint) to service_role;


-- ⑦ checkout_tx：多收 p_advisor（只有入座結帳會帶，其他結帳路徑一律 null）
drop function if exists public.checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid);

create function public.checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[],
                                   p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid,
                                   p_advisor jsonb default null)
 returns jsonb
 language plpgsql
as $function$
declare
  v_org uuid; v_order_id uuid; v_order_no text;
  v_price jsonb; v_tier text; v_pct int;
  v_sub bigint; v_nodisc bigint; v_coupon_cut bigint; v_tier_cut bigint; v_adv_cut bigint; v_payable bigint;
  v_pts bigint; v_cash_due bigint; v_pay_sum bigint := 0; v_bal bigint; v_txn uuid;
  v_adv_team uuid; v_who text;
  pay jsonb; cl jsonb;
begin
  /* 🔴 操作者身分從 JWT 取，不採信呼叫端送的 p_staff_id（2026-09-04）。
     ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），不可以報錯。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_idempotency_key is null then
    raise exception 'idempotency_key 必填';
  end if;

  select id, order_no into v_order_id, v_order_no from orders where idempotency_key = p_idempotency_key;
  if found then
    select balance into v_bal from wallets where member_id = p_member_id;
    return jsonb_build_object('idempotent', true, 'order_id', v_order_id,
                              'order_no', v_order_no, 'new_balance', v_bal);
  end if;

  select org_id into v_org from stores where id = p_store_id;
  if v_org is null then raise exception 'store % 不存在', p_store_id; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception '沒有可結帳的品項';
  end if;

  -- 先鎖住要用的券，再算錢（兩個店員同時用同一張券時，後到的會等前一個結束）
  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    perform 1 from member_coupons where id = any(p_coupon_ids) and member_id = p_member_id for update;
  end if;

  /* 🎯 2026-10-01：金額一律由共用核心算 —— POS 的報價（pos_quote_tx）叫的是同一支，
     畫面與實收不可能不一樣。算法本身（主檔價、三個桶、券、等級只折檯費）見 _cart_pricing。
     🆕 2026-11-01：p_advisor 是 _join_plan 算好的商人熊（只有入座結帳會帶）。 */
  v_price      := public._cart_pricing(v_org, p_member_id, p_items, p_coupon_ids,
                                       coalesce((p_advisor ->> 'cut')::bigint, 0));
  v_sub        := (v_price ->> 'subtotal')::bigint;
  v_nodisc     := (v_price ->> 'non_discountable')::bigint;
  v_coupon_cut := (v_price ->> 'coupon_discount')::bigint;
  v_tier       := v_price ->> 'tier';
  v_pct        := (v_price ->> 'tier_discount_pct')::int;
  v_tier_cut   := (v_price ->> 'tier_discount')::bigint;
  v_adv_cut    := (v_price ->> 'advisor_discount')::bigint;
  v_payable    := (v_price ->> 'payable')::bigint;
  v_adv_team   := case when v_adv_cut > 0 then (p_advisor ->> 'team_id')::uuid end;

  for cl in select * from jsonb_array_elements(v_price -> 'coupons') loop
    update member_coupons
       set discounted_amount = (cl ->> 'cut')::bigint, cost_bearer = cl ->> 'cost_bearer'
     where id = (cl ->> 'member_coupon_id')::uuid;
  end loop;

  select balance into v_bal from wallets where member_id = p_member_id for update;
  if v_bal is null then raise exception 'member % 沒有錢包', p_member_id; end if;

  v_pts := greatest(0, least(coalesce(p_points_used,0), least(v_bal, v_payable)));
  v_cash_due := v_payable - v_pts;

  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      v_pay_sum := v_pay_sum + (pay->>'amount')::bigint;
    end loop;
  end if;
  if v_pay_sum <> v_cash_due then
    raise exception '收款金額 % 與尚需支付 % 不符', v_pay_sum, v_cash_due;
  end if;

  insert into orders(
    id, org_id, store_id, member_id, status,
    subtotal, coupon_discount, tier_discount, advisor_discount, advisor_team_id, payable, points_used, cash_due,
    tier_at_order, tier_discount_pct, idempotency_key, created_by, paid_at
  ) values (
    gen_random_uuid(), v_org, p_store_id, p_member_id, 'paid',
    v_sub, v_coupon_cut, v_tier_cut, v_adv_cut, v_adv_team, v_payable, v_pts, v_cash_due,
    v_tier, v_pct, p_idempotency_key, p_staff_id, now()
  )
  returning id, order_no into v_order_id, v_order_no;

  -- 品項快照一律寫主檔的值（與上面的金額計算同一個來源）
  insert into order_items(org_id, order_id, product_id, name, spec, revenue_type, qty, unit_price, line_total)
  select v_org, v_order_id, pr.id, pr.name, pr.spec, pr.revenue_type,
         (it2->>'qty')::int, pr.unit_price, (it2->>'qty')::int * pr.unit_price
    from jsonb_array_elements(p_items) it2
    join public.products pr on pr.id = nullif(it2->>'product_id','')::uuid
   where pr.org_id = v_org and pr.deleted_at is null;

  /* 🆕 2026-11-01 顧問優惠用掉了：每個有資格的人記一列。
     ⚠ 同一人同一天第二次會撞 uq_advisor_perk_once_a_day ⇒ 整筆結帳回滾（不會有人折兩次）。
       平常走不到這裡（_join_plan 已經排除今天用過的人），會撞到只有兩台 POS 同時結同一個人。 */
  if v_adv_cut > 0 then
    for v_who in select * from jsonb_array_elements_text(p_advisor -> 'members') loop
      begin
        insert into advisor_perk_uses(org_id, kind, member_id, use_date, team_id, store_id, session_id,
                                      order_id, amount, table_members, staff_id)
        values (v_org, p_advisor ->> 'code', v_who::uuid, (now() at time zone 'Asia/Taipei')::date,
                v_adv_team, p_store_id, nullif(p_advisor ->> 'session_id', '')::uuid, v_order_id,
                coalesce((p_advisor ->> 'unit')::bigint, 0),
                array(select jsonb_array_elements_text(p_advisor -> 'table_members'))::uuid[], p_staff_id);
      exception when unique_violation then
        raise exception '今天已經用過商人熊的優惠了，請重新結帳';
      end;
    end loop;
  end if;

  if v_pts > 0 then
    insert into wallet_txns(
      org_id, store_id, member_id, type, amount, status,
      counter_account, idempotency_key, ref_table, ref_id, staff_id, note
    ) values (
      v_org, p_store_id, p_member_id, 'spend', -v_pts, 'completed',
      'liability', p_idempotency_key || ':spend', 'orders', v_order_id, p_staff_id, '消費扣點 ' || v_order_no
    )
    returning id into v_txn;
    update wallets set balance = balance - v_pts where member_id = p_member_id;
    update orders set wallet_txn_id = v_txn where id = v_order_id;
  end if;

  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      insert into order_payments(
        org_id, store_id, order_id, method, amount, cash_received, change_given, ref_no, staff_id
      ) values (
        v_org, p_store_id, v_order_id, pay->>'method', (pay->>'amount')::bigint,
        nullif(pay->>'cash_received','')::bigint, nullif(pay->>'change_given','')::bigint,
        nullif(pay->>'ref_no',''), p_staff_id
      );
    end loop;
  end if;

  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    update member_coupons
       set used_at = now(), used_order = v_order_id, used_txn_id = v_txn, status = 'used'
     where id = any(p_coupon_ids) and member_id = p_member_id;
  end if;

  return jsonb_build_object(
    'order_id', v_order_id, 'order_no', v_order_no,
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'coupon_discount', v_coupon_cut, 'tier', v_tier, 'tier_discount_pct', v_pct,
    'tier_discount', v_tier_cut, 'advisor_discount', v_adv_cut, 'payable', v_payable,
    'points_used', v_pts, 'cash_due', v_cash_due, 'new_balance', v_bal - v_pts);
end
$function$;

revoke execute on function public.checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid, jsonb) from public, anon, authenticated;
grant  execute on function public.checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid, jsonb) to service_role;


-- ⑧-1 join_session_tx：多收 p_table_members
drop function if exists public.join_session_tx(uuid, uuid, text, uuid[], bigint, jsonb, uuid, text, uuid[], jsonb);

create function public.join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text default 'opener'::text,
  p_coupon_ids uuid[] default null::uuid[], p_points_used bigint default 0, p_payments jsonb default null::jsonb,
  p_staff_id uuid default null::uuid, p_idempotency_key text default null::text, p_pay_for uuid[] default null::uuid[],
  p_items jsonb default null::jsonb, p_table_members uuid[] default null::uuid[])
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_plan jsonb; v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
  v_target uuid; v_created int := 0; v_unit bigint; v_self_pass boolean; v_buy_daypass boolean;
  v_org uuid; v_store uuid;
begin
  /* 🔴 操作者身分從 JWT 取，不採信呼叫端送的 p_staff_id（2026-09-04）。 */
  p_staff_id := (select staff_id from public.current_staff());

  /* 🎯 2026-10-01：入座前的全部檢查與檯費那一行搬到 _join_plan ——
     POS 的報價（pos_quote_tx）叫同一支，畫面上的檯費份數與實收不可能不一樣。
     🆕 2026-11-01：p_table_members ＝ POS 結帳頁的這桌四位，商人熊用（_join_plan 判斷、算好金額）。 */
  v_plan := public._join_plan(p_session_id, p_member_id, p_join_type, p_pay_for, p_items, p_table_members);
  if not coalesce((v_plan ->> 'ok')::boolean, false) then return v_plan; end if;

  v_items       := v_plan -> 'items';
  v_unit        := (v_plan ->> 'unit_fee')::bigint;
  v_self_pass   := (v_plan ->> 'daypass')::boolean;
  v_buy_daypass := (v_plan ->> 'daypass_bought')::boolean;
  v_org         := (v_plan ->> 'org_id')::uuid;
  v_store       := (v_plan ->> 'store_id')::uuid;

  select count(*) + 1 into v_seq from session_players where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key, p_session_id::text || ':' || p_member_id::text || ':' || v_seq);

  if jsonb_array_length(v_items) > 0 then
    v_res := checkout_tx(p_member_id, v_store, v_items, p_coupon_ids,
                         coalesce(p_points_used, 0), p_payments, v_key, p_staff_id,
                         case when jsonb_typeof(v_plan -> 'advisor') = 'object' then v_plan -> 'advisor' end);
    v_order := (v_res ->> 'order_id')::uuid;
    update orders o
       set session_id = p_session_id,
           table_id   = (v_plan ->> 'table_id')::uuid,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id, (select entity_id from stores where id = v_store))
     where o.id = v_order;
  end if;

  -- 付款人自己入座
  insert into session_players(
    org_id, session_id, member_id, join_type, status, charged_points, order_id, joined_at, created_by,
    fee_waived_amount, fee_waived_reason)
  values (
    v_org, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id,
    -- 免收金額是使用量指標，不是折讓：不進 orders、不影響營收毛額
    case when (v_self_pass or v_buy_daypass) then v_unit else 0 end,
    case when (v_self_pass or v_buy_daypass) then 'daypass' end)
  returning id into v_sp;

  -- 被代付者一併入座：有入座記錄但沒有訂單，消費金額掛在代付人身上
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      insert into session_players(
        org_id, session_id, member_id, join_type, status, charged_points, order_id, paid_by, joined_at, created_by,
        fee_waived_amount, fee_waived_reason)
      values (
        v_org, p_session_id, v_target, p_join_type, 'playing', 0, null, p_member_id, now(), p_staff_id,
        case when has_daypass_tx(v_org, v_target, v_store) then v_unit else 0 end,
        case when has_daypass_tx(v_org, v_target, v_store) then 'daypass' end);
      v_created := v_created + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'player_id', v_sp,
    'order_id', v_order, 'unit_fee', v_unit, 'qty', (v_plan ->> 'qty')::int,
    'listed_amount', (v_plan ->> 'amount')::bigint, 'paid_for_count', v_created,
    'extra_items', (v_plan ->> 'extra_items')::int,
    'daypass', v_self_pass, 'daypass_bought', v_buy_daypass,
    'advisor', v_plan -> 'advisor',
    'checkout', v_res);
end $function$;

revoke execute on function public.join_session_tx(uuid, uuid, text, uuid[], bigint, jsonb, uuid, text, uuid[], jsonb, uuid[]) from public, anon;
grant  execute on function public.join_session_tx(uuid, uuid, text, uuid[], bigint, jsonb, uuid, text, uuid[], jsonb, uuid[]) to authenticated, service_role;


-- ⑧-2 pos_checkout_with_topup_tx：多收 p_table_members，原樣傳給 join_session_tx
drop function if exists public.pos_checkout_with_topup_tx(uuid, uuid, text, jsonb, uuid[], bigint, jsonb, uuid[], uuid, text, bigint, bigint, bigint, text, bigint, bigint);

create function public.pos_checkout_with_topup_tx(p_session_id uuid, p_member_id uuid, p_join_type text default 'opener'::text,
  p_items jsonb default null::jsonb, p_coupon_ids uuid[] default null::uuid[], p_points_used bigint default 0,
  p_payments jsonb default null::jsonb, p_pay_for uuid[] default null::uuid[], p_staff_id uuid default null::uuid,
  p_idempotency_key text default null::text, p_topup_points bigint default 0, p_topup_bonus bigint default 0,
  p_topup_amount bigint default 0, p_topup_method text default 'cash'::text, p_topup_cash_received bigint default null::bigint,
  p_topup_change_given bigint default null::bigint, p_table_members uuid[] default null::uuid[])
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_s      record;
  v_topup  jsonb := null;
  v_join   jsonb := null;
  v_base   text;
  v_seated boolean;
  v_extra  int := 0;
  v_mode   text;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
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

  -- 由資料庫判斷是否已入座，不採信前端傳來的推測值
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

  if v_mode = 'topup_only' and p_topup_points <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_do',
      'message', '這位客人已入座，請選擇商品或儲值');
  end if;

  v_base := coalesce(p_idempotency_key,
                     p_session_id::text || ':' || p_member_id::text);

  -- ══ 原子區塊：任何一步 raise，整段回滾 ══
  begin

    if p_topup_points > 0 then
      /* ★ 2026-08-25 改成具名參數（唯一的改動）。
         原本是位置參數，topup_tx 哪天少一個參數就會整排位移，
         而型別相容時不會報錯，只會把值寫到錯的欄位。

         ⚠ p_bonus_points 照樣傳（值被 topup_tx 忽略，由
           calc_topup_bonus_tx 從 topup_plans 算）——
           **明著傳而不是靜靜省略**：省略的話，哪天有人把忽略邏輯拿掉，
           行為會無聲改變。傳過去則永遠是「送了但被忽略」這個明確狀態，
           而 topup_tx 的回傳有 bonus_ignored 會標出來。 */
      v_topup := topup_tx(
        p_member_id       => p_member_id,
        p_store_id        => v_s.store_id,
        p_points          => p_topup_points,
        p_amount_twd      => p_topup_amount,
        p_pay_method      => p_topup_method,
        p_idempotency_key => v_base || ':topup',
        p_bonus_points    => p_topup_bonus,
        p_external_ref    => null,
        p_staff_id        => p_staff_id,
        p_note            => 'POS 結帳時儲值');

      -- 回填桌次脈絡與實收找零。
      -- 實收找零只有在「現金全部歸儲值」時才會有值 ——
      -- 消費有現金要收時，前端會把它記在 order_payments 那邊，
      -- 兩邊不會同時有值（實體收款是一次事件，不該重複記錄）。
      update topup_orders
         set session_id    = p_session_id,
             cash_received = p_topup_cash_received,
             change_given  = p_topup_change_given
       where id = (v_topup ->> 'topup_id')::uuid;
    end if;

    if v_mode = 'join' then
      -- 🆕 2026-11-01：這桌四位（商人熊用）原樣往下傳
      v_join := join_session_tx(
        p_session_id, p_member_id, p_join_type, p_coupon_ids,
        coalesce(p_points_used, 0), p_payments, p_staff_id,
        v_base || ':order', p_pay_for, p_items, p_table_members);

    elsif v_mode = 'addon' then
      v_join := pos_addon_checkout_tx(
        p_session_id, p_member_id, p_items, p_coupon_ids,
        coalesce(p_points_used, 0), p_payments,
        v_base || ':order', p_staff_id);
    end if;

    -- 兩支結帳函式的業務錯誤都是「回傳 ok:false」而不是拋例外。
    -- 不主動 raise 的話交易會照常提交 —— 儲值就留下來了。
    if v_join is not null
       and not coalesce((v_join ->> 'ok')::boolean, false) then
      raise exception 'checkout_failed:%',
        coalesce(v_join ->> 'reason', 'unknown') using errcode = 'P0001';
    end if;

  exception
    when others then
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
    'ok', true, 'mode', v_mode,
    'topup', v_topup, 'checkout', v_join,
    'new_balance', v_topup ->> 'new_balance');
end $function$;

revoke execute on function public.pos_checkout_with_topup_tx(uuid, uuid, text, jsonb, uuid[], bigint, jsonb, uuid[], uuid, text, bigint, bigint, bigint, text, bigint, bigint, uuid[]) from public, anon;
grant  execute on function public.pos_checkout_with_topup_tx(uuid, uuid, text, jsonb, uuid[], bigint, jsonb, uuid[], uuid, text, bigint, bigint, bigint, text, bigint, bigint, uuid[]) to authenticated, service_role;


-- ⑧-3 pos_quote_tx：多收 p_table_members，報價也算商人熊（與實收同一支 _join_plan、同一支 _cart_pricing）
drop function if exists public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[]);

create function public.pos_quote_tx(p_session_id uuid, p_member_id uuid, p_join_type text default 'opener'::text,
  p_pay_for uuid[] default null::uuid[], p_items jsonb default null::jsonb, p_coupon_ids uuid[] default null::uuid[],
  p_table_members uuid[] default null::uuid[])
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
/* 給 POS 結帳頁畫金額用。**不寫入任何東西**。
   模式跟實際結帳走的那一支判斷方式一樣（由資料庫判斷，不採信前端的推測）：
     quick  沒有桌次                 ⇒ 只有購物車
     join   有桌次、這個人還沒入座   ⇒ 檯費那一行（_join_plan）＋ 購物車
     addon  有桌次、已經入座          ⇒ 只有購物車
   金額一律由 _cart_pricing 算 —— checkout_tx 叫的是同一支。
   🆕 2026-11-01：p_table_members ＝ 這桌四位，商人熊的判斷與金額都在 _join_plan。
   錯誤一律回 {ok:false, reason, message}，不拋例外：畫面要能把那句話原樣顯示。 */
declare
  v_mode text; v_org uuid; v_items jsonb; v_plan jsonb := null; v_price jsonb; v_s record; v_adv jsonb := null;
begin
  perform public._api_staff_only();
  if p_member_id is null then
    return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '請先選擇會員');
  end if;

  if p_session_id is null then
    v_mode := 'quick';
    select org_id into v_org from members where id = p_member_id and deleted_at is null;
    if v_org is null then
      return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '需先建立會員資料');
    end if;
    v_items := coalesce(p_items, '[]'::jsonb);
  else
    select id, org_id, status into v_s from table_sessions where id = p_session_id and deleted_at is null;
    if v_s.id is null then
      return jsonb_build_object('ok', false, 'reason', 'session_not_found', 'message', '場次不存在');
    end if;
    if exists (select 1 from session_players
                where session_id = p_session_id and member_id = p_member_id and left_at is null) then
      v_mode := 'addon';
      if v_s.status <> 'open' then
        return jsonb_build_object('ok', false, 'reason', 'session_closed', 'mode', v_mode, 'message', '此場次已結束，無法加購');
      end if;
      v_org := v_s.org_id;
      v_items := coalesce(p_items, '[]'::jsonb);
    else
      v_mode := 'join';
      v_plan := public._join_plan(p_session_id, p_member_id, coalesce(p_join_type, 'opener'), p_pay_for, p_items, p_table_members);
      if not coalesce((v_plan ->> 'ok')::boolean, false) then
        return v_plan || jsonb_build_object('mode', v_mode);
      end if;
      v_org := (v_plan ->> 'org_id')::uuid;
      v_items := v_plan -> 'items';
      if jsonb_typeof(v_plan -> 'advisor') = 'object' then v_adv := v_plan -> 'advisor'; end if;
    end if;
  end if;

  begin
    v_price := public._cart_pricing(v_org, p_member_id, v_items, p_coupon_ids, coalesce((v_adv ->> 'cut')::bigint, 0));
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'pricing', 'mode', v_mode, 'message', sqlerrm);
  end;

  return v_price || jsonb_build_object('ok', true, 'mode', v_mode,
    /* 畫面上那一行：「商人熊 · 檯費 −50 × N」。金額以 advisor_discount 為準（_cart_pricing 夾過的） */
    'advisor', case when v_adv is null or coalesce((v_price ->> 'advisor_discount')::bigint, 0) = 0 then null
                    else jsonb_build_object('code', v_adv ->> 'code', 'team_name', v_adv ->> 'team_name',
                                            'count', jsonb_array_length(v_adv -> 'members'),
                                            'members', v_adv -> 'members',
                                            'amount', (v_price ->> 'advisor_discount')::bigint) end,
    'fee_line', case when v_plan is null then null else jsonb_build_object(
      'product_id', v_plan ->> 'fee_product_id', 'name', v_plan ->> 'fee_name',
      'unit', (v_plan ->> 'unit_fee')::bigint, 'qty', (v_plan ->> 'qty')::int,
      'amount', (v_plan ->> 'amount')::bigint,
      'daypass', (v_plan ->> 'daypass')::boolean, 'daypass_bought', (v_plan ->> 'daypass_bought')::boolean) end);
end $function$;

revoke execute on function public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[], uuid[]) from public, anon;
grant  execute on function public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[], uuid[]) to authenticated, service_role;


-- ⑨ 訂單查詢三支多回 advisor_discount（POS 收據、會員 App 消費明細、單筆訂單）
/* 三支用的是同一行寫法，一個迴圈一起換；**任何一支沒換到就整份回滾** ——
   只換到一半的話，收據會出現「小計 400、應付 200」而中間沒有任何一行說明。
   ⚠ 這裡的 raise 是失敗才走的保險（要它擋下整份），不是成功路徑上的訊息（硬規則 1.8）。 */
do $$
declare
  f text; v_old text; v_new text;
begin
  foreach f in array array['_member_orders_core', 'get_session_member_orders_tx', 'get_order_tx'] loop
    select pg_get_functiondef(p.oid) into v_old from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = f;
    if v_old is null then raise exception '找不到 %', f; end if;
    if v_old ~ '''advisor_discount''' then continue; end if;   -- 重跑時已經換過
    v_new := regexp_replace(v_old, '''tier_discount'',(\s*)o\.tier_discount,',
                            '''tier_discount'',\1o.tier_discount, ''advisor_discount'', o.advisor_discount,');
    if v_new = v_old then raise exception '% 沒有換到（寫法跟預期不同），整份不提交', f; end if;
    execute v_new;
  end loop;
end $$;


/* ── 驗證（單一 SELECT，不用 raise —— 硬規則 1.8）────────────────
   行為（新舊結帳逐項相同、商人熊真的折到）另外跑 sql/checks/2026-11-01_驗商人熊檯費折50.sql */
select
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('_join_plan','_cart_pricing','checkout_tx','join_session_tx','pos_checkout_with_topup_tx','pos_quote_tx')
  ) as "① 六支函式各一個版本（應為 6）",
  (select string_agg(proname || '=' || coalesce((select string_agg(a.grantee::regrole::text, '/' order by 1)
                                                   from aclexplode(p.proacl) a where a.grantee <> 0), '-'), '  ' order by proname)
     from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('_join_plan','_cart_pricing','checkout_tx','_advisor_table_team')
  ) as "② 內部四支授權（只能有 postgres／service_role）",
  (select string_agg(proname || '=' || coalesce((select string_agg(a.grantee::regrole::text, '/' order by 1)
                                                   from aclexplode(p.proacl) a where a.grantee <> 0), '-'), '  ' order by proname)
     from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('join_session_tx','pos_checkout_with_topup_tx','pos_quote_tx')
  ) as "③ 前端三支授權（要有 authenticated、不可有 anon）",
  (select count(*) from pg_proc p, aclexplode(p.proacl) a
    where p.pronamespace = 'public'::regnamespace and a.grantee = 0 and a.privilege_type = 'EXECUTE'
      and p.proname in ('_join_plan','_cart_pricing','checkout_tx','_advisor_table_team','join_session_tx','pos_checkout_with_topup_tx','pos_quote_tx')
  ) as "④ PUBLIC 授權（應為 0）",
  (select pg_get_constraintdef(oid) ~ 'advisor_discount' from pg_constraint
    where conrelid = 'public.orders'::regclass and conname = 'orders_amount_balance') as "⑤ 金額約束含顧問折扣（應為 true）",
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'v_real_orders'
      and column_name in ('advisor_discount','advisor_team_id')) as "⑥ 報表檢視表兩欄（應為 2）",
  (select count(*) from pg_indexes where schemaname = 'public' and indexname = 'uq_advisor_perk_once_a_day') as "⑦ 每人每天一次的索引（應為 1）",
  (select count(*) from public.orders where advisor_discount <> 0) as "⑧ 既有訂單的顧問折扣（應為 0）",
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('_member_orders_core', 'get_session_member_orders_tx', 'get_order_tx')
     and pg_get_functiondef(oid) ~ '''advisor_discount'', o\.advisor_discount') as "⑨ 訂單查詢三支回傳顧問折扣（應為 3）";
