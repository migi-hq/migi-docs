/* ============================================================================
   2026-11-14 檯費優惠擇優 ＋ 生日券計價
   ----------------------------------------------------------------------------
   使用者定案（2026-11-14，整合 POS 版本那一輪的第 1、2、4、5 題）：

   ① 檯費一次只用一種優惠，系統自動挑折最多的：
        牌咖團優惠（商人熊 50 × 人）／會員折扣／檯費券  三選一
      餐飲券、商品券跟上面三種都能一起用；點數永遠可以用。
      ⇒ 推翻 2026-11-01「選了券就整桌走正常結帳」：
         以前用一張飲料券，商人熊的 50 會不見；現在照拿。
   ② 檯費券和會員折扣只取一種（以前是先扣券、剩下再打會員折扣，疊在一起）。
   ④ 生日券：兌換一份當日暢打（0 元），效期是生日前後各 15 天。
      ⇒ 發出去的券要記「從哪天起能用」（member_coupons.valid_from）。
   ⑤ 壽星用生日券、同桌三位照拿牌咖團優惠 —— 生日券送的是暢打，
      不算檯費優惠，不會跟商人熊搶。

   怎麼挑（全部在 _cart_pricing，POS 報價與實際結帳叫同一支）：
     · 先照舊把券套上去，算出「券從檯費扣了多少」
     · 券扣的檯費 > 牌咖團優惠與會員折扣裡較大的那一個 ⇒ 用券，另外兩個不算
     · 否則 ⇒ 券不准碰檯費，重新套一次：
         只折檯費的券 ⇒ 結帳失敗並說明（券不會被用掉，留著下次用）
         同時涵蓋餐飲的券 ⇒ 改折餐飲
       再從牌咖團優惠、會員折扣挑大的；一樣大就用會員折扣
       （商人熊每人每天一次，不必浪費在一樣的金額上）

   這份做的事
     1. coupons.kind 多一個 birthday；member_coupons 加 valid_from、birthday_year
     2. _cart_pricing 改成上面的規則（簽名不變）
     3. pos_quote_tx 多回 coupon_options：這位客人每一張券「這次能不能用、省多少」，
        給 POS 把用不到的券反灰並寫原因（簽名不變）
     4. pos_member_detail_tx、get_wallet_tx 的券多回 valid_from（生日券還沒到可用日時要寫出來）

   ⚠ 生日券怎麼建、怎麼發、生日鎖住 —— 在下一份（2026-11-14_生日券發放與生日鎖.sql）。
   行為測試：sql/checks/2026-11-14_驗檯費優惠擇優與生日券計價.sql
   ============================================================================ */

-- ── 1. 欄位 ────────────────────────────────────────────────────────────────
alter table public.coupons drop constraint coupons_kind_check;
alter table public.coupons add constraint coupons_kind_check
  check (kind = any (array['table_discount','unlimited_play','ride','fnb','topup_bonus','generic','birthday']));

alter table public.member_coupons add column if not exists valid_from timestamptz;
alter table public.member_coupons add column if not exists birthday_year int;
comment on column public.member_coupons.valid_from is
  '從這個時間起才能用（null ＝ 發出就能用）。生日券＝生日前 15 天台北零時';
comment on column public.member_coupons.birthday_year is
  '生日券是哪一年的生日（每年只發一張，唯一索引擋）。其他券是 null';
create unique index if not exists uq_member_coupons_birthday_year
  on public.member_coupons (member_id, birthday_year) where birthday_year is not null;

-- ── 2. 計價核心 ────────────────────────────────────────────────────────────
create or replace function public._cart_pricing(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[], p_advisor_cut bigint default 0)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_tier text; v_pct int := 0;
  v_sub bigint := 0; v_fee bigint := 0; v_fnb bigint := 0; v_goods bigint := 0;
  v_nodisc bigint := 0;   -- 不參與折扣的金額（只為驗算與回傳，不進任何桶）
  v_coupon_cut bigint := 0; v_tier_cut bigint := 0; v_adv_cut bigint := 0; v_payable bigint;
  v_coupons jsonb := '[]'::jsonb;
  -- 每一個品項：商品、營收類別、子分類、扣的順序（檯費 1、餐飲 2、其餘 3）、可不可折、單價、一開始可折多少
  l_pid uuid[] := '{}'; l_rt text[] := '{}'; l_sub text[] := '{}'; l_ord int[] := '{}';
  l_disc boolean[] := '{}'; l_unit bigint[] := '{}'; l_rem0 bigint[] := '{}'; n int := 0;
  l_rem bigint[]; l_gift boolean[];
  v_match boolean[]; v_has_scope boolean; v_fee_hit boolean;
  -- 檯費的三個選項
  v_opt_tier bigint := 0; v_opt_adv bigint := 0; v_best bigint; v_best_label text;
  v_coupon_fee bigint := 0; v_lock_fee boolean := false; v_choice text; v_pass int;
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
        l_disc[n] := x_disc; l_unit[n] := x_price;
        l_rem0[n] := case when x_disc then x_line else 0 end;   -- 不可折扣的品項從一開始就沒有可折的額度
      end;
    end loop;
  end if;

  /* 檯費的另外兩個選項（都只看可折的檯費、還沒被券碰過的金額）
     · 會員折扣：查不到的等級一律 0
     · 牌咖團優惠：金額由 _join_plan 算好傳進來，前端碰不到；不會折超過檯費 */
  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;
  select coalesce(t.discount_pct, 0) into v_pct from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);
  v_opt_tier := round(v_fee * v_pct / 100.0);
  v_opt_adv  := least(greatest(coalesce(p_advisor_cut, 0), 0), v_fee);
  if v_opt_adv > v_opt_tier then v_best := v_opt_adv;  v_best_label := '牌咖團優惠';
  else                           v_best := v_opt_tier; v_best_label := '會員折扣';
  end if;

  -- 券本身能不能用（用過、過期、還沒到可用日）只看一次
  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    for cp in
      select c.name as c_name, mc.used_at, mc.status, mc.expires_at, mc.valid_from
        from member_coupons mc join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
    loop
      if cp.used_at is not null or coalesce(cp.status, '') = 'used'
         or (cp.expires_at is not null and cp.expires_at <= now()) then
        raise exception '券 % 已使用或已過期', cp.c_name;
      end if;
      if cp.valid_from is not null and cp.valid_from > now() then
        raise exception '券 % 還沒到可用日（% 起才能用）', cp.c_name,
          to_char(cp.valid_from at time zone 'Asia/Taipei', 'FMMM/FMDD');
      end if;
    end loop;
  end if;

  /* 套券：最多兩輪。
     第一輪照舊套；券從檯費扣的沒有比另外兩個選項多 ⇒ 第二輪鎖住檯費再套一次。 */
  for v_pass in 1 .. 2 loop
    l_rem := l_rem0; l_gift := '{}'; v_coupon_cut := 0; v_coupons := '[]'::jsonb;
    if v_lock_fee then
      for i in 1 .. n loop
        if l_rt[i] = 'venue_fee' then l_rem[i] := 0; end if;
      end loop;
    end if;

    if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
      for cp in
        select mc.id as mc_id, c.id as coupon_id, c.name as c_name, c.kind, c.discount_type, c.discount_value,
               c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
          from member_coupons mc
          join coupons c on c.id = mc.coupon_id
         where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
         order by array_position(p_coupon_ids, mc.id)   -- 店員選的順序
      loop
        v_match := '{}'; cap := 0; v_fee_hit := false;

        if cp.kind = 'birthday' then
          /* 生日券：送一份指定商品（當日暢打）。那個商品不參與折扣也照送，只送一份。
             送的是暢打不是檯費優惠 ⇒ 不算進「券從檯費扣了多少」，不跟商人熊、會員折扣搶。 */
          for i in 1 .. n loop
            v_match[i] := false;
            if cap = 0 and l_pid[i] = cp.free_product_id and not coalesce(l_gift[i], false) then
              v_match[i] := true; cap := l_unit[i]; l_gift[i] := true;
            end if;
          end loop;
          if cap <= 0 then
            raise exception '券 % 要跟當日暢打一起結帳（先在檯費選當日暢打，再用這張券）', cp.c_name;
          end if;
          cut := cap;
        else
          -- 這張券涵蓋哪些品項
          v_has_scope := exists (select 1 from coupon_scopes s where s.coupon_id = cp.coupon_id);
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
            if v_match[i] then
              cap := cap + l_rem[i];
              if l_rt[i] = 'venue_fee' and l_rem0[i] > 0 then v_fee_hit := true; end if;
            end if;
          end loop;

          if cap <= 0 then
            if v_lock_fee and v_fee_hit then
              -- 只折檯費、而另一個選項比較多：結帳失敗才不會把券用掉
              raise exception '券 % 只折檯費，這次%折 $% 比較多，已經自動用了；這張券會留著下次用',
                cp.c_name, v_best_label, v_best;
            elsif cp.discount_type = 'free' and cp.free_product_id is not null then
              raise exception '券 % 指定商品不在本次訂單中，或該商品不參與折扣', cp.c_name;
            else
              raise exception '券 % 不適用於本次品項', cp.c_name;
            end if;
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

          -- 從涵蓋的品項扣：檯費 → 餐飲 → 其餘，同一類照品項順序
          r := cut;
          for k in 1 .. 3 loop
            for i in 1 .. n loop
              if v_match[i] and l_ord[i] = k and r > 0 then
                d := least(r, l_rem[i]); l_rem[i] := l_rem[i] - d; r := r - d;
              end if;
            end loop;
          end loop;
        end if;

        v_coupon_cut := v_coupon_cut + cut;
        v_coupons := v_coupons || jsonb_build_array(jsonb_build_object(
          'member_coupon_id', cp.mc_id, 'name', cp.c_name, 'kind', cp.kind,
          'scope_label', public._coupon_scope_label(cp.coupon_id),
          'cut', cut, 'cost_bearer', cp.cost_bearer));
      end loop;
    end if;

    -- 券從檯費扣了多少
    v_coupon_fee := 0;
    for i in 1 .. n loop
      if l_rt[i] = 'venue_fee' then v_coupon_fee := v_coupon_fee + (l_rem0[i] - l_rem[i]); end if;
    end loop;

    if v_pass = 1 and v_coupon_fee > 0 and v_coupon_fee <= v_best then
      v_lock_fee := true;   -- 券沒有比較多 ⇒ 不准碰檯費，重算一次
    else
      exit;
    end if;
  end loop;

  /* 檯費只用一種：券／牌咖團優惠／會員折扣。
     沒用會員折扣時折扣率也記成 0，訂單上的快照才不會出現「9 折但折了 0 元」。 */
  if v_coupon_fee > 0 then
    v_choice := 'coupon';  v_pct := 0; v_tier_cut := 0; v_adv_cut := 0;
  elsif v_opt_adv > v_opt_tier then
    v_choice := 'advisor'; v_pct := 0; v_tier_cut := 0; v_adv_cut := v_opt_adv;
  elsif v_opt_tier > 0 then
    v_choice := 'tier';    v_tier_cut := v_opt_tier; v_adv_cut := 0;
  else
    v_choice := 'none';    v_tier_cut := 0; v_adv_cut := 0;
  end if;

  v_payable := v_sub - v_coupon_cut - v_tier_cut - v_adv_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;

  return jsonb_build_object(
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'fee', v_fee, 'fnb', v_fnb, 'goods', v_goods,
    'coupon_discount', v_coupon_cut, 'coupons', v_coupons,
    'tier', v_tier, 'tier_discount_pct', v_pct, 'tier_discount', v_tier_cut,
    'advisor_discount', v_adv_cut,
    -- 🆕 2026-11-14：檯費用了哪一種（coupon／advisor／tier／none），與另外兩個選項各折多少
    'fee_choice', v_choice,
    'fee_options', jsonb_build_object('tier', v_opt_tier, 'advisor', v_opt_adv, 'coupon', v_coupon_fee),
    'payable', v_payable);
end $function$;

-- ── 3. POS 報價：多回每一張券這次能不能用 ──────────────────────────────────
create or replace function public.pos_quote_tx(p_session_id uuid, p_member_id uuid, p_join_type text default 'opener'::text, p_pay_for uuid[] default null::uuid[], p_items jsonb default null::jsonb, p_coupon_ids uuid[] default null::uuid[], p_table_members uuid[] default null::uuid[])
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
   🆕 2026-11-14：coupon_options ＝ 這位客人每一張券「這次單獨用能不能用、省多少、不能用的原因」，
     給 POS 把用不到的券反灰。選了券報價失敗時也照樣回，畫面才知道要灰掉哪一張。
   錯誤一律回 {ok:false, reason, message}，不拋例外：畫面要能把那句話原樣顯示。 */
declare
  v_mode text; v_org uuid; v_items jsonb; v_plan jsonb := null; v_price jsonb; v_s record; v_adv jsonb := null;
  v_adv_cut bigint; v_base jsonb; v_try jsonb; v_opts jsonb := '[]'::jsonb; oc record;
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
  v_adv_cut := coalesce((v_adv ->> 'cut')::bigint, 0);

  -- 每一張券單獨試算一次（購物車是空的就不算：還沒有東西可折）
  if jsonb_array_length(v_items) > 0 then
    begin
      v_base := public._cart_pricing(v_org, p_member_id, v_items, null, v_adv_cut);
    exception when others then v_base := null;
    end;
    if v_base is not null then
      for oc in
        select mc.id, c.name, c.kind
          from member_coupons mc join coupons c on c.id = mc.coupon_id
         where mc.member_id = p_member_id and mc.used_at is null and coalesce(mc.status, '') <> 'used'
           and (mc.expires_at is null or mc.expires_at > now())
         order by mc.expires_at nulls last, mc.granted_at
         limit 30
      loop
        begin
          v_try := public._cart_pricing(v_org, p_member_id, v_items, array[oc.id], v_adv_cut);
          v_opts := v_opts || jsonb_build_array(jsonb_build_object(
            'member_coupon_id', oc.id, 'name', oc.name, 'kind', oc.kind, 'ok', true,
            'saves', (v_base ->> 'payable')::bigint - (v_try ->> 'payable')::bigint));
        exception when others then
          v_opts := v_opts || jsonb_build_array(jsonb_build_object(
            'member_coupon_id', oc.id, 'name', oc.name, 'kind', oc.kind, 'ok', false, 'message', sqlerrm));
        end;
      end loop;
    end if;
  end if;

  begin
    v_price := public._cart_pricing(v_org, p_member_id, v_items, p_coupon_ids, v_adv_cut);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'pricing', 'mode', v_mode, 'message', sqlerrm,
                              'coupon_options', v_opts);
  end;

  return v_price || jsonb_build_object('ok', true, 'mode', v_mode, 'coupon_options', v_opts,
    /* 畫面上那一行：「牌咖團專屬：檯費優惠 50 元」。金額以 advisor_discount 為準（_cart_pricing 挑過、夾過的） */
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

-- ── 4. 會員券清單多回 valid_from（只加欄位，其餘一字不動）─────────────────
do $$
declare v_def text; v_new text;
begin
  -- POS 會員查詢
  v_def := pg_get_functiondef('public.pos_member_detail_tx(uuid,uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, '''expires_at'', mc.expires_at', ''))) / length('''expires_at'', mc.expires_at') <> 1 then
    raise exception 'pos_member_detail_tx：找不到唯一一處券的到期欄位，整份不跑（線上版本跟預期不同）';
  end if;
  v_new := replace(v_def, '''expires_at'', mc.expires_at',
                   '''expires_at'', mc.expires_at, ''valid_from'', mc.valid_from, ''kind'', c.kind');
  execute v_new;

  -- 會員 App 錢包
  v_def := pg_get_functiondef('public.get_wallet_tx(uuid,integer)'::regprocedure);
  if (length(v_def) - length(replace(v_def, '''expires_at'', c.expires_at', ''))) / length('''expires_at'', c.expires_at') <> 1
     or (length(v_def) - length(replace(v_def, 'mc.expires_at,', ''))) / length('mc.expires_at,') <> 1 then
    raise exception 'get_wallet_tx：找不到唯一一處券的到期欄位，整份不跑（線上版本跟預期不同）';
  end if;
  v_new := replace(v_def, '''expires_at'', c.expires_at', '''expires_at'', c.expires_at, ''valid_from'', c.valid_from');
  v_new := replace(v_new, 'mc.expires_at,', 'mc.expires_at, mc.valid_from,');
  execute v_new;
end $$;

-- ── 驗證（單一 SELECT，不 raise；只驗結構，行為在 checks 那一份）──────────
select
  (select case when count(*) = 1 then '✅' else '🔴' end || ' ① _cart_pricing 版本數 ' || count(*)
     from pg_proc where pronamespace = 'public'::regnamespace and proname = '_cart_pricing') || E'\n' ||
  (select case when pg_get_functiondef(p.oid) like '%fee_choice%' and pg_get_functiondef(p.oid) like '%v_lock_fee%'
               then '✅ ② 計價核心是新版（擇優、鎖檯費）' else '🔴 ② 計價核心不是新版' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_cart_pricing') || E'\n' ||
  (select case when pg_get_functiondef(p.oid) like '%coupon_options%' then '✅' else '🔴' end || ' ③ pos_quote_tx 回 coupon_options'
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'pos_quote_tx') || E'\n' ||
  (select case when count(*) = 2 then '✅' else '🔴' end || ' ④ 兩支會員券清單回 valid_from（' || count(*) || '/2）'
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('pos_member_detail_tx','get_wallet_tx')
      and pg_get_functiondef(p.oid) like '%valid_from%') || E'\n' ||
  (select case when count(*) = 2 then '✅' else '🔴' end || ' ⑤ member_coupons 新欄位 ' || count(*) || '/2'
     from information_schema.columns where table_schema = 'public' and table_name = 'member_coupons'
      and column_name in ('valid_from','birthday_year')) || E'\n' ||
  (select case when pg_get_constraintdef(oid) like '%birthday%' then '✅' else '🔴' end || ' ⑥ 券種類可以是 birthday'
     from pg_constraint where conname = 'coupons_kind_check') || E'\n' ||
  (select case when has_function_privilege('authenticated', 'public.pos_quote_tx(uuid,uuid,text,uuid[],jsonb,uuid[],uuid[])', 'execute')
                and not has_function_privilege('anon', 'public._cart_pricing(uuid,uuid,jsonb,uuid[],bigint)', 'execute')
               then '✅' else '🔴' end || ' ⑦ 授權沒變（POS 叫得到報價；計價核心前端叫不到）')
  as "驗證";
