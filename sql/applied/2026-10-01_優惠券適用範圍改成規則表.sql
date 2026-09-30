/* ============================================================
   優惠券適用範圍：從一個欄位改成一張規則表（CLAUDE.md 待辦 0.8）
   2026-10-01 · MIGI 咪吉麻將
   行為測試：sql/checks/2026-10-01_驗優惠券適用範圍規則表.sql（跑完這份再跑）

   ── 為什麼 ─────────────────────────────────────────────
   coupons.applies_to 只能是「檯費／餐飲／不指定」三選一。行銷每發明一種新範圍
   （飲料券、指定甜點、聯名商品）就要改 CHECK、改計價函式 —— 等於一個活動企劃＝一次金流函式改版。
   ⇒ 改成規則：coupon_scopes(券, 規則種類, 值)，一張券可以多列。
   🎯 時機：計價 2026-10-01 剛集中成一支（_cart_pricing），現在改只要動一個地方；
     發券後台還沒開工、已發出的券只有 7 張，搬家成本最低。

   ── 規則 ─────────────────────────────────────────────
   scope_type ∈ revenue_type（檯費／餐飲／周邊／其他）
              ∈ subcategory （飲料、甜點、炸物… 對 product_taxonomy 的子分類代碼）
              ∈ product     （指定商品，值是 products.id）
   · 一張券多列 ＝ 符合任一條就算
   · 一條都沒有 ＝ 全部可折扣的品項（與舊的 applies_to 空白同義）
   · 不可折扣的品項（例：當日暢打）不管規則怎麼寫都折不到
   · 一張券同時涵蓋好幾類時，扣的順序是 檯費 → 餐飲 → 周邊（與舊版相同 ⇒ 會員折扣的基數不變）

   ── 計價改成「逐品項」──────────────────────────────────
   舊版維護三個桶的餘額（rem_fee／rem_fnb／rem_goods），只能表達「整個桶」。
   新版記每一個品項還剩多少可折，券折抵依上面的順序從它涵蓋的品項扣。
   · 舊有的三種寫法（限檯費、限餐飲、不指定）結果與舊版**完全相同**（行為測試逐案比對）
   · ⚠ 唯一刻意的改變：「指定商品免費券」只從那個商品扣。
     舊版那種券若範圍是空白，會先從檯費扣 ⇒ 會員折扣的基數被悄悄變小。
     線上目前 0 張這種券（free_product_id 全部是空的），不影響任何既有資料。

   ── 舊欄位 applies_to ────────────────────────────────────
   · 既有 5 張券搬成規則：限檯費 → (revenue_type, venue_fee)；限餐飲 → (revenue_type, fnb)
   · 之後**凍結**：寫入新值會報錯「請改用 coupon_scopes」—— 不然同一張券會有兩個答案
   · 欄位本身等 POS 的兩處顯示改讀 scope_label 之後再刪（expand → migrate → contract）
   ============================================================ */

-- ① 規則表
create table if not exists public.coupon_scopes (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id),
  coupon_id   uuid not null references public.coupons(id),
  scope_type  text not null check (scope_type in ('revenue_type', 'subcategory', 'product')),
  scope_value text not null,
  created_at  timestamptz not null default now(),
  unique (coupon_id, scope_type, scope_value)
);
comment on table public.coupon_scopes is
  '優惠券適用範圍（2026-10-01 取代 coupons.applies_to）。一列一條規則，同一張券多列＝符合任一條即可；沒有任何一列＝全部可折扣品項';
alter table public.coupon_scopes enable row level security;
revoke all on table public.coupon_scopes from public, anon, authenticated;

-- 值要對得上主檔：寫錯就大聲失敗（一條寫錯的規則會讓券「怎樣都不適用」，而且不報錯）
create or replace function public.trg_coupon_scopes_check()
returns trigger language plpgsql set search_path to 'public' as $fn$
begin
  if new.org_id is distinct from (select org_id from coupons where id = new.coupon_id) then
    raise exception '規則的機構與券不一致';
  end if;
  if new.scope_type = 'revenue_type' and not exists
       (select 1 from product_taxonomy where dimension = 'revenue_type' and code = new.scope_value) then
    raise exception '營收類別「%」不存在（可用：venue_fee／fnb／retail／other）', new.scope_value;
  elsif new.scope_type = 'subcategory' and not exists
       (select 1 from product_taxonomy where dimension = 'subcategory' and code = new.scope_value) then
    raise exception '子分類「%」不存在（見 product_taxonomy 的 subcategory）', new.scope_value;
  elsif new.scope_type = 'product' and not exists
       (select 1 from products where id::text = new.scope_value and org_id = new.org_id and deleted_at is null) then
    raise exception '指定商品「%」不存在或不屬於本機構', new.scope_value;
  end if;
  return new;
end $fn$;
drop trigger if exists trg_coupon_scopes_check on public.coupon_scopes;
create trigger trg_coupon_scopes_check before insert or update on public.coupon_scopes
  for each row execute function public.trg_coupon_scopes_check();

-- ② 既有的券搬成規則（重跑不重複）
insert into public.coupon_scopes (org_id, coupon_id, scope_type, scope_value)
select c.org_id, c.id, 'revenue_type', case c.applies_to when 'table_fee' then 'venue_fee' else 'fnb' end
  from public.coupons c
 where c.applies_to in ('table_fee', 'fnb')
on conflict (coupon_id, scope_type, scope_value) do nothing;

-- ③ 舊欄位凍結：新的寫入一律擋下
create or replace function public.trg_coupons_applies_to_frozen()
returns trigger language plpgsql set search_path to 'public' as $fn$
begin
  if (tg_op = 'INSERT' and new.applies_to is not null)
     or (tg_op = 'UPDATE' and new.applies_to is distinct from old.applies_to) then
    raise exception '券的適用範圍已改用 coupon_scopes 設定（coupons.applies_to 已凍結，2026-10-01）';
  end if;
  return new;
end $fn$;
drop trigger if exists trg_coupons_applies_to_frozen on public.coupons;
create trigger trg_coupons_applies_to_frozen before insert or update on public.coupons
  for each row execute function public.trg_coupons_applies_to_frozen();

-- ④ 給人看的範圍文字：「全品項」「限檯費」「限飲料、甜點」「限 拿鐵」
create or replace function public._coupon_scope_label(p_coupon_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select case
    when c.free_product_id is not null then
      '限 ' || coalesce((select name from products where id = c.free_product_id), '指定商品')
    when not exists (select 1 from coupon_scopes s where s.coupon_id = c.id) then '全品項'
    else '限' || (
      select string_agg(x.lbl, '、' order by x.o, x.lbl) from (
        select case s.scope_type
                 when 'revenue_type' then (select t.label from product_taxonomy t where t.dimension = 'revenue_type' and t.code = s.scope_value)
                 when 'subcategory'  then (select t.label from product_taxonomy t where t.dimension = 'subcategory'  and t.code = s.scope_value)
                 else ' ' || (select p.name from products p where p.id::text = s.scope_value)
               end as lbl,
               case s.scope_type when 'revenue_type' then 1 when 'subcategory' then 2 else 3 end as o
          from coupon_scopes s where s.coupon_id = c.id) x)
  end
  from coupons c where c.id = p_coupon_id
$fn$;
revoke execute on function public._coupon_scope_label(uuid) from public, anon, authenticated;
grant  execute on function public._coupon_scope_label(uuid) to service_role;

-- ⑤ 計價核心改成逐品項（簽名不變 ⇒ checkout_tx 與報價不用動）
create or replace function public._cart_pricing(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_tier text; v_pct int;
  v_sub bigint := 0; v_fee bigint := 0; v_fnb bigint := 0; v_goods bigint := 0;
  v_nodisc bigint := 0;   -- 不參與折扣的金額（只為驗算與回傳，不進任何桶）
  v_coupon_cut bigint := 0; v_tier_cut bigint; v_payable bigint;
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

  -- 等級折扣：只折檯費（券折抵後剩下、而且可折扣的那一部分）；查不到的等級一律 0
  v_rem_fee := 0;
  for i in 1 .. n loop
    if l_rt[i] = 'venue_fee' then v_rem_fee := v_rem_fee + l_rem[i]; end if;
  end loop;
  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;
  select coalesce(t.discount_pct, 0) into v_pct from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);
  v_tier_cut := round(v_rem_fee * v_pct / 100.0);

  v_payable := v_sub - v_coupon_cut - v_tier_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;

  return jsonb_build_object(
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'fee', v_fee, 'fnb', v_fnb, 'goods', v_goods,
    'coupon_discount', v_coupon_cut, 'coupons', v_coupons,
    'tier', v_tier, 'tier_discount_pct', v_pct, 'tier_discount', v_tier_cut,
    'payable', v_payable);
end $fn$;

-- ⑥ POS 會員詳情與會員 App 錢包：券多回一個 scope_label（原本的 applies_to 先留著，前端換完再拿掉）
do $$
declare v_def text; v_new text; v_n int;
begin
  v_def := pg_get_functiondef('public.pos_member_detail_tx'::regproc);
  if position('scope_label' in v_def) = 0 then
    v_n := (length(v_def) - length(replace(v_def, $a$'applies_to', c.applies_to,$a$, ''))) / length($a$'applies_to', c.applies_to,$a$);
    if v_n <> 1 then raise exception '🔴 pos_member_detail_tx 的錨點出現 % 次（期望 1），整份不提交', v_n; end if;
    execute replace(v_def, $a$'applies_to', c.applies_to,$a$,
                    $a$'applies_to', c.applies_to, 'scope_label', public._coupon_scope_label(c.id),$a$);
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'get_wallet_tx';
  if position('scope_label' in v_def) = 0 then
    v_new := regexp_replace(v_def, 'mc\.id,(\s*)co\.name,', 'mc.id,\1co.id as coupon_id,\1co.name,');
    v_new := replace(v_new, $a$'kind', c.kind,$a$, $a$'kind', c.kind, 'scope_label', public._coupon_scope_label(c.coupon_id),$a$);
    if position('co.id as coupon_id' in v_new) = 0 or position('_coupon_scope_label(c.coupon_id)' in v_new) = 0 then
      raise exception '🔴 get_wallet_tx 的錨點對不上，整份不提交';
    end if;
    execute v_new;
  end if;
end $$;

/* ============================================================
   驗證（不 raise —— 這份要留下東西）
   ============================================================ */
do $$
declare v_msg text := ''; v_n int; v_m int; v_txt text; v_err text;
begin
  -- ① 規則表：RLS 開、前端讀不到
  v_msg := v_msg || case when (select relrowsecurity from pg_class where oid = 'public.coupon_scopes'::regclass)
                          and not has_table_privilege('anon', 'public.coupon_scopes', 'SELECT')
                          and not has_table_privilege('authenticated', 'public.coupon_scopes', 'SELECT')
                         then '✅' else '🔴' end || ' ① coupon_scopes：RLS 開、前端讀不到' || E'\n';

  -- ② 搬家：每一張有 applies_to 的券都有一條對得上的規則
  select count(*) into v_n from coupons where applies_to in ('table_fee', 'fnb');
  select count(*) into v_m from coupons c
   where c.applies_to in ('table_fee', 'fnb')
     and exists (select 1 from coupon_scopes s where s.coupon_id = c.id and s.scope_type = 'revenue_type'
                   and s.scope_value = case c.applies_to when 'table_fee' then 'venue_fee' else 'fnb' end);
  v_msg := v_msg || case when v_n = v_m and v_n > 0 then '✅' else '🔴' end
        || ' ② 既有的券搬成規則：' || v_m || ' / ' || v_n || E'\n';

  -- ③ 計價核心改讀規則表、不再讀舊欄位
  v_txt := pg_get_functiondef('public._cart_pricing(uuid,uuid,jsonb,uuid[])'::regprocedure);
  v_msg := v_msg || case when v_txt ~ 'from coupon_scopes s' and v_txt !~ 'c\.applies_to' then '✅' else '🔴' end
        || ' ③ _cart_pricing 讀 coupon_scopes、不讀 applies_to' || E'\n';

  -- ④ 舊欄位凍結了（試著寫一張帶 applies_to 的券，應該被擋；子交易裡做，不會留下東西）
  begin
    insert into coupons (org_id, name, kind, discount_type, discount_value, applies_to)
    values ('11111111-1111-1111-1111-111111111111', 'ZZ 凍結測試', 'generic', 'percent', 10, 'fnb');
    raise exception 'migi_not_blocked';
  exception when others then v_err := sqlerrm;
  end;
  v_msg := v_msg || case when v_err like '%已凍結%' then '✅' else '🔴' end || ' ④ 寫入 applies_to 被擋：' || v_err || E'\n';

  -- ⑤ 規則值寫錯會被擋
  begin
    insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value)
    select org_id, id, 'subcategory', 'NOPE' from coupons limit 1;
    raise exception 'migi_not_blocked';
  exception when others then v_err := sqlerrm;
  end;
  v_msg := v_msg || case when v_err like '%不存在%' then '✅' else '🔴' end || ' ⑤ 不存在的子分類被擋：' || v_err || E'\n';

  -- ⑥ 兩支回券的函式都多了 scope_label、各只有一個版本
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname in ('pos_member_detail_tx', 'get_wallet_tx')
     and pg_get_functiondef(p.oid) ~ '_coupon_scope_label\(';
  select count(*) into v_m from pg_proc where pronamespace = 'public'::regnamespace and proname in ('pos_member_detail_tx', 'get_wallet_tx');
  v_msg := v_msg || case when v_n = 2 and v_m = 2 then '✅' else '🔴' end || ' ⑥ 會員詳情與錢包都回 scope_label（' || v_n || '/2，版本數 ' || v_m || '）' || E'\n';

  -- ⑦ 既有的券顯示成什麼（參考）
  select string_agg(distinct c.name || '＝' || public._coupon_scope_label(c.id), '、') into v_txt from coupons c where c.deleted_at is null;
  v_msg := v_msg || '　⑦ 既有的券：' || coalesce(v_txt, '（沒有券）');

  perform set_config('migi.v', v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
