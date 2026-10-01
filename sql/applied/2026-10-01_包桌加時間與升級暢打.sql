/* ============================================================
   包桌加時間：加 2 小時，或補差價升級當日暢打 · 2026-10-01（同日第四版）
   📄 使用者 2026-10-01：
      「原本 5 小時 150，追加包桌 0～2 小時 +100，或是當日暢打 +150；
        如果原本包 2 小時，追加包桌 0～2 小時 +100，或是當日暢打 +200」
      已經加過再升級：**補到 300 為止**（開桌與加過的每一段都算進去）
      升級之後：**跟真的當日暢打一樣**（今天這間店其他桌也免檯費、這一桌不再計時）
      會員折扣：加 2 小時套用，升級暢打不套（暢打本來就固定價）
      加時間各選各的；桌子的到期時間看最早到期的那一位

   ── 規則 ──────────────────────────────────────────────
   開桌      只剩 2 小時（P02 100）與 5 小時（P05 150）；24 小時（P24）停用，會員 App 預約也拿掉
   加 2 小時 每人 ＝ 2 小時包桌價（新商品 SVC-TBL-PX02，跟 P02 連動），可以一直加
   升級暢打  每人補 暢打價 −（開桌那一段的價 ＋ 已加的 2 小時 × 2 小時價），最少 0
             例：開 2 小時 → 補 200；開 5 小時 → 補 150；開 2 小時又加過一次 → 補 100
             商品 SVC-TBL-DAYUP「當日暢打 · 補差價」，單價 ＝ 暢打、P02、P05 三個價的最大公因數（現在 50），
             收幾份 ＝ 差額 ÷ 單價（同檯費用份數表達暢打的做法，金額一律由後端算）
   自動轉換  加 2 小時會讓累計 ≥ 暢打價時，那一次直接變成升級暢打，只收差額（不會收超過 300）
   升級之後  has_daypass_tx_core 認得 ⇒ 今天在這間店其他桌開桌免檯費、不能再買暢打；這一桌整場不再計時
   不變      各補各的、也可以替別人付；持當日暢打的人不用加；鎖定是後端真的擋

   ── 改動 ──────────────────────────────────────────────
   ✏️ 商品        🆕 PX02、DAYUP；PX05／PX24（舊的升檔延長）與 P24 停用
   ✏️ 觸發器      價格連動改看 P02／P05／DAY；擋手改價格改看 PX02／DAYUP
   ✏️ session_extensions  多 kind（'2h'／'daypass'）；to_minutes 改成「加完之後的總時數」（升級暢打是 null）；
                          order_id 可空（差額剛好 0 的升級沒有訂單）
   ✏️ has_daypass_tx_core 也認延長紀錄裡的升級暢打（記的是被升級的人，不是付錢的人）
   ✏️ _pkg_time    每人各自的時數；players 多 minutes、expires_at、upgrade_price
   ✏️ pos_pkg_quote_tx / pos_pkg_extend_tx   多 p_kind（'2h'／'daypass'）⇒ 簽名改了，先 DROP（硬規則 2）
                          收款回來的訂單如果已經記過延長 ＝ 重送 ⇒ 不再加
   ✏️ open_session_tx 包桌只收 120／300；三支預約函式只收 2／5 小時
   ⚠ 查證過：開著的包桌 0 場、未來的 24 小時預約 0 筆、延長紀錄 0 筆 ⇒ 沒有舊資料要搬
   ⚠ 驗證段不 raise（硬規則 1.8）；修補工具只在錨點對不上時 raise ⇒ 整份不執行，不會半改
   ============================================================ */

-- ⓪ 修補工具：撈線上全文 → 換掉指定片段 → 全部換完才重建一次
create or replace function pg_temp.patch_many(p_fn regprocedure, p_marker text, p_anchors text[], p_news text[])
returns text language plpgsql as $$
declare v_def text; v_n int; i int;
begin
  v_def := pg_get_functiondef(p_fn);
  if position(p_marker in v_def) > 0 then return p_fn::text || ' 已經改過'; end if;
  for i in 1 .. array_length(p_anchors, 1) loop
    v_n := (length(v_def) - length(replace(v_def, p_anchors[i], ''))) / length(p_anchors[i]);
    if v_n <> 1 then
      raise exception '% 的第 % 個錨點出現 % 次（要剛好 1 次），整份不執行：%', p_fn, i, v_n, left(p_anchors[i], 40);
    end if;
    v_def := replace(v_def, p_anchors[i], p_news[i]);
  end loop;
  execute v_def;
  return p_fn::text || ' 已改 ' || array_length(p_anchors, 1) || ' 處';
end $$;

-- ① 加時商品的價格怎麼來
--    加 2 小時 ＝ 2 小時包桌價；補差價的單位 ＝ 暢打、2 小時、5 小時三個價的最大公因數
create or replace function public._pkg_ext_expected(p_org uuid, p_sku text)
returns bigint language sql stable security definer set search_path to 'public' as $$
  select case p_sku
           when 'SVC-TBL-PX02' then
             (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P02' and deleted_at is null)
           when 'SVC-TBL-DAYUP' then
             gcd(gcd((select unit_price from products where org_id = p_org and sku = 'SVC-TBL-DAY' and deleted_at is null),
                     (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P02' and deleted_at is null)),
                 (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P05' and deleted_at is null))
         end
$$;

create or replace function public._pkg_tier_sync()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  update products p
     set unit_price = public._pkg_ext_expected(p.org_id, p.sku), updated_at = now()
   where p.org_id = new.org_id and p.deleted_at is null
     and p.sku in ('SVC-TBL-PX02', 'SVC-TBL-DAYUP')
     and p.unit_price is distinct from public._pkg_ext_expected(p.org_id, p.sku);
  return null;
end $$;

-- 觸發器綁的商品清單跟著換（價格連動看 P02／P05／暢打；擋手改價格看兩支加時商品）
drop trigger if exists trg_products_pkg_tier_sync on public.products;
create trigger trg_products_pkg_tier_sync after update of unit_price on public.products
  for each row when (new.sku = any (array['SVC-TBL-P02', 'SVC-TBL-P05', 'SVC-TBL-DAY']))
  execute function public._pkg_tier_sync();
drop trigger if exists trg_products_pkg_ext_guard on public.products;
create trigger trg_products_pkg_ext_guard before insert or update of unit_price on public.products
  for each row when (new.sku = any (array['SVC-TBL-PX02', 'SVC-TBL-DAYUP']))
  execute function public._pkg_ext_guard();

-- ② 商品：新增兩支（欄位照抄舊的延長商品）；舊的三支停用
insert into public.products (org_id, sku, name, category, unit_price, unit_cost, is_active, stock_qty, is_available,
                             revenue_type, subcategory, tracks_stock, is_system, discountable)
select x.org_id, 'SVC-TBL-PX02', '包桌加時 · 2 小時', x.category, public._pkg_ext_expected(x.org_id, 'SVC-TBL-PX02'),
       0, true, 0, true, x.revenue_type, x.subcategory, false, true, true          -- 套會員折扣（同包桌檯費）
  from public.products x
 where x.sku = 'SVC-TBL-PX05' and x.deleted_at is null
   and not exists (select 1 from public.products y where y.org_id = x.org_id and y.sku = 'SVC-TBL-PX02' and y.deleted_at is null);

insert into public.products (org_id, sku, name, category, unit_price, unit_cost, is_active, stock_qty, is_available,
                             revenue_type, subcategory, tracks_stock, is_system, discountable)
select x.org_id, 'SVC-TBL-DAYUP', '當日暢打 · 補差價', x.category, public._pkg_ext_expected(x.org_id, 'SVC-TBL-DAYUP'),
       0, true, 0, true, x.revenue_type, x.subcategory, false, true, false         -- 不套折扣（同當日暢打）
  from public.products x
 where x.sku = 'SVC-TBL-PX05' and x.deleted_at is null
   and not exists (select 1 from public.products y where y.org_id = x.org_id and y.sku = 'SVC-TBL-DAYUP' and y.deleted_at is null);

update public.products
   set is_active = false, updated_at = now()
 where sku in ('SVC-TBL-PX05', 'SVC-TBL-PX24', 'SVC-TBL-P24') and deleted_at is null and is_active;

-- ③ 延長紀錄：一列 ＝ 一個人的一次加時（加 2 小時記加完之後的總時數；升級暢打不記時數）
alter table public.session_extensions add column if not exists kind text not null default '2h';
alter table public.session_extensions alter column to_minutes drop not null;
alter table public.session_extensions alter column order_id drop not null;
alter table public.session_extensions drop constraint if exists session_extensions_to_minutes_check;
alter table public.session_extensions drop constraint if exists session_extensions_kind_check;
alter table public.session_extensions add constraint session_extensions_kind_check check (
  (kind = '2h' and to_minutes > 120 and to_minutes <= 1440) or (kind = 'daypass' and to_minutes is null));
create unique index if not exists uq_session_extensions_daypass
  on public.session_extensions (session_id, member_id) where kind = 'daypass';
comment on column public.session_extensions.kind is
  '2h ＝ 加 2 小時（to_minutes 記加完之後的總時數）；daypass ＝ 補差價升級當日暢打（to_minutes 是 null）。2026-10-01 第四版';
comment on column public.session_extensions.order_id is
  '收這一筆的訂單；升級暢打的差額剛好是 0 時沒有訂單（null）';

-- ④ 「今天有沒有暢打」也認升級的那一種（記的是被升級的人，所以替別人付也認得到對的人）
create or replace function public.has_daypass_tx_core(p_org_id uuid, p_member_id uuid, p_store_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1
      from orders o
      join order_items oi on oi.order_id = o.id
      join products pr on pr.id = oi.product_id
     where o.org_id = p_org_id
       and o.member_id = p_member_id
       and o.status = 'paid'
       and o.deleted_at is null
       and pr.sku = 'SVC-TBL-DAY'
       -- 單店限定：給 null 表示不限店（預留未來跨店）
       and (p_store_id is null or o.store_id = p_store_id)
       -- 以台北時區的「今天」為準
       and (o.created_at at time zone 'Asia/Taipei')::date
           = (now() at time zone 'Asia/Taipei')::date
  ) or exists (
    -- 包桌加時間時補差價升級的（2026-10-01）
    select 1
      from session_extensions e
      join table_sessions ts on ts.id = e.session_id
      left join orders o on o.id = e.order_id
     where e.kind = 'daypass'
       and e.member_id = p_member_id
       and ts.org_id = p_org_id
       and (p_store_id is null or ts.store_id = p_store_id)
       and (e.order_id is null or (o.status = 'paid' and o.deleted_at is null))
       and (e.created_at at time zone 'Asia/Taipei')::date
           = (now() at time zone 'Asia/Taipei')::date
  );
$$;

-- ⑤ 計時：每個人各自的時數，桌子看最早到期的那一位
create or replace function public._pkg_time(p_session_id uuid, p_with_ids boolean default true)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  s        public.table_sessions;
  v_base   int; v_eff int; v_base_price bigint; v_2h bigint; v_day bigint;
  v_start  timestamptz; v_exp timestamptz; v_phase text; v_rows jsonb; v_players jsonb; v_payers jsonb;
  c_warn   constant interval := interval '30 minutes';
  c_grace  constant interval := interval '15 minutes';
  c_cap    constant int := 1440;
begin
  select * into s from table_sessions where id = p_session_id and deleted_at is null;
  if s.id is null or s.mode <> 'private' then return null; end if;
  if s.status <> 'open' then return jsonb_build_object('phase', 'closed'); end if;

  -- 開桌那一段（24 小時那一檔已停用，舊場次照樣認）
  v_base := case when coalesce(s.planned_minutes, 0) <= 120 then 120
                 when s.planned_minutes <= 300 then 300 else c_cap end;
  select unit_price into v_base_price from products
   where org_id = s.org_id and deleted_at is null
     and sku = case v_base when 120 then 'SVC-TBL-P02' when 300 then 'SVC-TBL-P05' else 'SVC-TBL-P24' end;
  select unit_price into v_2h  from products where org_id = s.org_id and sku = 'SVC-TBL-PX02' and deleted_at is null;
  select unit_price into v_day from products where org_id = s.org_id and sku = 'SVC-TBL-DAY'  and deleted_at is null;

  select min(r.started_at) into v_start
    from session_rounds r where r.session_id = s.id and r.status <> 'voided';

  -- 每一位：自己的時數 ＝ 開桌那一段，或他最後一次加完的總時數（取大的）；
  --         升級暢打要補多少 ＝ 暢打價 −（開桌價 ＋ 加過幾次 2 小時 × 2 小時價），最少 0
  select jsonb_agg(jsonb_build_object(
           'seat', x.seat, 'name', x.name, 'member_id', x.member_id, 'dp', x.dp, 'mins', x.mins,
           'upgrade', greatest(coalesce(v_day, 0) - coalesce(v_base_price, 0) - x.n2h * coalesce(v_2h, 0), 0),
           'payer_name', x.payer_name)
         order by x.seat nulls last, x.name)
    into v_rows
    from (select sp.seat, sp.member_id, coalesce(m.display_name, '會員') as name,
                 (coalesce(sp.fee_waived_reason, '') = 'daypass'
                  or exists (select 1 from session_extensions d
                              where d.session_id = s.id and d.member_id = sp.member_id and d.kind = 'daypass')
                  or public.has_daypass_tx_core(s.org_id, sp.member_id, s.store_id)) as dp,
                 least(greatest(v_base, coalesce((select max(e.to_minutes) from session_extensions e
                                                   where e.session_id = s.id and e.member_id = sp.member_id
                                                     and e.kind = '2h'), 0)), c_cap) as mins,
                 (select count(*) from session_extensions e
                   where e.session_id = s.id and e.member_id = sp.member_id and e.kind = '2h') as n2h,
                 (select case when e.paid_by <> sp.member_id then coalesce(pm.display_name, '會員') end
                    from session_extensions e left join members pm on pm.id = e.paid_by
                   where e.session_id = s.id and e.member_id = sp.member_id
                   order by e.created_at desc limit 1) as payer_name
            from session_players sp
            left join members m on m.id = sp.member_id
           where sp.session_id = s.id and sp.member_id is not null and sp.left_at is null) x;

  -- 桌子的時數 ＝ 要計時的人裡最短的那一位；沒有人要計時（全是暢打）＝ 封頂
  select min((x ->> 'mins')::int) into v_eff
    from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) x where not (x ->> 'dp')::boolean;
  v_eff := least(coalesce(v_eff, c_cap), c_cap);

  -- 對外的形狀：owed ＝ 他就是最早到期的那幾位；paid ＝ 加過、比桌子晚到期；daypass ＝ 不計時
  select jsonb_agg(jsonb_build_object(
           'seat', x -> 'seat', 'name', x ->> 'name',
           'status', case when (x ->> 'dp')::boolean then 'daypass'
                          when (x ->> 'mins')::int >= c_cap then 'capped'
                          when (x ->> 'mins')::int <= v_eff then 'owed'
                          else 'paid' end,
           'minutes', case when (x ->> 'dp')::boolean then null else (x ->> 'mins')::int end,
           'expires_at', case when (x ->> 'dp')::boolean or v_start is null then null
                              else v_start + make_interval(mins => (x ->> 'mins')::int) end,
           'upgrade_price', case when (x ->> 'dp')::boolean then null else (x ->> 'upgrade')::bigint end,
           'payer_name', x ->> 'payer_name')
         || case when p_with_ids then jsonb_build_object('member_id', x -> 'member_id') else '{}'::jsonb end
         order by ord)
    into v_players
    from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) with ordinality t(x, ord);

  -- payers：最早到期、要加時間的人（POS 提示條、舊版平板的退回顯示用）
  select jsonb_agg(jsonb_build_object('name', x ->> 'name', 'shares', 1, 'paid', 0, 'owed', 1)
           || case when p_with_ids then jsonb_build_object('member_id', x -> 'member_id') else '{}'::jsonb end)
    into v_payers
    from jsonb_array_elements(coalesce(v_players, '[]'::jsonb)) x
   where x ->> 'status' = 'owed';

  if v_eff >= c_cap then
    v_phase := 'capped';
  elsif v_start is null then
    v_phase := 'not_started';
  else
    v_exp := v_start + make_interval(mins => v_eff);
    v_phase := case when now() <  v_exp - c_warn  then 'ok'
                    when now() <  v_exp           then 'warn'
                    when now() <  v_exp + c_grace then 'grace'
                    else 'locked' end;
  end if;

  return jsonb_build_object(
    'phase',        v_phase,
    'locked',       v_phase = 'locked',
    'now',          now(),
    'started_at',   v_start,
    'base_minutes', v_base,
    'tier_minutes', v_eff,
    'expires_at',   v_exp,
    'warn_at',      v_exp - c_warn,
    'lock_at',      v_exp + c_grace,
    'next_minutes', case when v_eff < c_cap then least(v_eff + 120, c_cap) end,   -- 舊版 POS 用；新版看 options
    'next_sku',     case when v_eff < c_cap then 'SVC-TBL-PX02' end,
    'two_hour_price', v_2h,
    'options',      jsonb_build_array(
                      jsonb_build_object('kind', '2h',      'label', '加 2 小時'),
                      jsonb_build_object('kind', 'daypass', 'label', '升級當日暢打')),
    'players',      coalesce(v_players, '[]'::jsonb),
    'payers',       coalesce(v_payers, '[]'::jsonb),
    'owed_shares',  coalesce(jsonb_array_length(v_payers), 0));
end $$;

-- ⑥ 報價與收款：多 p_kind ⇒ 簽名改了，先 DROP 舊的
drop function if exists public.pos_pkg_extend_tx(uuid, uuid, uuid[], bigint, jsonb, text);
drop function if exists public.pos_pkg_quote_tx(uuid, uuid, uuid[]);

create function public.pos_pkg_quote_tx(p_session_id uuid, p_member_id uuid, p_for uuid[] default null,
  p_kind text default '2h')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_pkg jsonb; v_cover uuid[]; v_bad text; v_org uuid; v_items jsonb := '[]'::jsonb; v_price jsonb;
        v_rows jsonb; v_2h bigint; v_unit bigint; v_n2h int; v_up bigint; v_pid uuid;
begin
  perform public._api_staff_only();
  if coalesce(p_kind, '') not in ('2h', 'daypass') then
    return jsonb_build_object('ok', false, 'reason', 'bad_kind', 'message', '加時間只有「加 2 小時」與「升級當日暢打」兩種');
  end if;
  v_pkg := public._pkg_time(p_session_id, true);
  if v_pkg is null then
    return jsonb_build_object('ok', false, 'reason', 'not_private', 'message', '這一場不是包桌');
  end if;
  if v_pkg ->> 'phase' = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '這一場已經收桌');
  end if;
  if v_pkg ->> 'phase' = 'capped' then
    return jsonb_build_object('ok', false, 'reason', 'capped', 'message', '這一桌都是當日暢打，不用再加', 'pkg', v_pkg);
  end if;
  if not exists (select 1 from session_players
                  where session_id = p_session_id and member_id = p_member_id and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_seated', 'message', '付錢的人要在這一桌');
  end if;

  -- 替誰加：不給 ＝ 替自己；自己不用加（已經是暢打）就沒有東西可以收
  select array_agg(distinct x) into v_cover
    from unnest(coalesce(p_for, array[p_member_id])) x where x is not null;
  if p_for is null and not exists (
       select 1 from jsonb_array_elements(v_pkg -> 'players') e
        where (e ->> 'member_id')::uuid = p_member_id and e ->> 'status' in ('owed', 'paid')) then
    return jsonb_build_object('ok', false, 'reason', 'nothing_owed', 'message', '這位客人已經是當日暢打，不用再加', 'pkg', v_pkg);
  end if;
  if v_cover is null or cardinality(v_cover) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_owed', 'message', '沒有選要替誰加', 'pkg', v_pkg);
  end if;

  -- 每一位都要是還要計時的人（在這一桌、不是暢打）
  select string_agg(coalesce(y.e ->> 'name', '有一位不在這一桌的人'), '、') into v_bad
    from unnest(v_cover) c
    left join lateral (select e from jsonb_array_elements(v_pkg -> 'players') e
                        where (e ->> 'member_id')::uuid = c) y on true
   where y.e is null or y.e ->> 'status' not in ('owed', 'paid');
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'not_owed', 'message', v_bad || ' 已經是當日暢打，不用再加', 'pkg', v_pkg);
  end if;

  select org_id into v_org from table_sessions where id = p_session_id;
  select unit_price into v_2h   from products where org_id = v_org and sku = 'SVC-TBL-PX02'  and deleted_at is null;
  select unit_price into v_unit from products where org_id = v_org and sku = 'SVC-TBL-DAYUP' and deleted_at is null;
  if v_2h is null or v_unit is null or v_unit <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'product_not_found', 'message', '找不到包桌加時商品');
  end if;

  -- 每一位這次拿到什麼：加 2 小時，或升級暢打（自己選的、或加 2 小時會讓累計到暢打價 ⇒ 直接升級，只收差額）
  select jsonb_agg(jsonb_build_object(
           'member_id', c, 'name', y.e ->> 'name',
           'result',     case when p_kind = 'daypass' or (y.e ->> 'upgrade_price')::bigint <= v_2h then 'daypass' else '2h' end,
           'to_minutes', case when p_kind = 'daypass' or (y.e ->> 'upgrade_price')::bigint <= v_2h then null
                              else least((y.e ->> 'minutes')::int + 120, 1440) end,
           'list_amount', case when p_kind = 'daypass' or (y.e ->> 'upgrade_price')::bigint <= v_2h
                               then (y.e ->> 'upgrade_price')::bigint else v_2h end) order by c)
    into v_rows
    from unnest(v_cover) c
    join lateral (select e from jsonb_array_elements(v_pkg -> 'players') e
                   where (e ->> 'member_id')::uuid = c) y on true;

  select count(*) filter (where r ->> 'result' = '2h'),
         coalesce(sum((r ->> 'list_amount')::bigint) filter (where r ->> 'result' = 'daypass'), 0)
    into v_n2h, v_up
    from jsonb_array_elements(v_rows) r;
  if v_up % v_unit <> 0 then
    return jsonb_build_object('ok', false, 'reason', 'price_unit', 'message', '暢打補差價換算不出整數份，請檢查包桌與暢打的價格');
  end if;

  if v_n2h > 0 then
    select id into v_pid from products where org_id = v_org and sku = 'SVC-TBL-PX02' and deleted_at is null;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', v_pid, 'qty', v_n2h));
  end if;
  if v_up > 0 then
    select id into v_pid from products where org_id = v_org and sku = 'SVC-TBL-DAYUP' and deleted_at is null;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', v_pid, 'qty', v_up / v_unit));
  end if;

  if jsonb_array_length(v_items) > 0 then
    v_price := public._cart_pricing(v_org, p_member_id, v_items, null);   -- 等級折扣看付錢的人（升級暢打不參與折扣）
  end if;
  return jsonb_build_object('ok', true, 'kind', p_kind, 'owed', cardinality(v_cover), 'cover', v_rows,
    'cover_ids', to_jsonb(v_cover), 'items', v_items,
    'amount', coalesce((v_price ->> 'payable')::bigint, 0), 'pricing', v_price, 'pkg', v_pkg);
end $$;

create function public.pos_pkg_extend_tx(p_session_id uuid, p_member_id uuid, p_for uuid[] default null,
  p_kind text default '2h', p_points_used bigint default 0, p_payments jsonb default null,
  p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_q jsonb; v_res jsonb; v_order uuid; v_org uuid; v_key text;
begin
  perform public._api_staff_only();
  v_q := public.pos_pkg_quote_tx(p_session_id, p_member_id, p_for, p_kind);
  if not coalesce((v_q ->> 'ok')::boolean, false) then return v_q; end if;
  select org_id into v_org from table_sessions where id = p_session_id;

  if jsonb_array_length(v_q -> 'items') > 0 then
    -- 沒給冪等鍵就照「誰付、替誰、拿到什麼」自己組（同一個人可以連加好幾次，鍵裡一定要有時數）
    select coalesce(p_idempotency_key,
             'pkgx-' || p_session_id || '-' || p_member_id || '-'
             || string_agg((c ->> 'member_id') || ':' || (c ->> 'result') || ':' || coalesce(c ->> 'to_minutes', ''),
                           ',' order by c ->> 'member_id'))
      into v_key
      from jsonb_array_elements(v_q -> 'cover') c;

    v_res := public.pos_addon_checkout_tx(p_session_id, p_member_id, v_q -> 'items', null,
               coalesce(p_points_used, 0), p_payments, v_key, null);
    if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;

    v_order := nullif(v_res ->> 'order_id', '')::uuid;
    if v_order is null then
      -- 錢收了卻找不到訂單 ⇒ 記不了「加給誰」⇒ 整筆退回（例外會回滾收款），不留半筆帳
      raise exception '包桌加時：收款成功但找不到訂單，整筆取消';
    end if;

    -- 🔴 重送：同一把鍵回的是舊訂單，而那張訂單已經記過延長 ⇒ 不再加（否則沒收錢卻多加了一段）
    if exists (select 1 from session_extensions where order_id = v_order) then
      return v_res || jsonb_build_object('replayed', true, 'pkg', public._pkg_time(p_session_id, true));
    end if;
  else
    -- 差額剛好是 0（已經付滿暢打價）：不開訂單，直接記升級
    v_res := jsonb_build_object('ok', true, 'order_id', null, 'amount', 0);
  end if;

  insert into session_extensions (org_id, session_id, member_id, kind, to_minutes, paid_by, order_id, created_by)
  select v_org, p_session_id, (c ->> 'member_id')::uuid, c ->> 'result', (c ->> 'to_minutes')::int, p_member_id, v_order,
         (select staff_id from public.current_staff())
    from jsonb_array_elements(v_q -> 'cover') c
  on conflict do nothing;

  perform public._tbl_ping(p_session_id);   -- 讓計分板馬上重新拿狀態
  return v_res || jsonb_build_object('cover', v_q -> 'cover', 'pkg', public._pkg_time(p_session_id, true));
end $$;

revoke execute on function public.pos_pkg_quote_tx(uuid, uuid, uuid[], text) from public, anon;
revoke execute on function public.pos_pkg_extend_tx(uuid, uuid, uuid[], text, bigint, jsonb, text) from public, anon;
grant  execute on function public.pos_pkg_quote_tx(uuid, uuid, uuid[], text) to authenticated;
grant  execute on function public.pos_pkg_extend_tx(uuid, uuid, uuid[], text, bigint, jsonb, text) to authenticated;

-- ⑦ 開桌與預約不再收 24 小時
select pg_temp.patch_many(p.oid::regprocedure, '要打更久',
         array[$a$not in (120, 300, 1440) then$a$, $a$'包桌需選擇 2 小時／5 小時／24 小時'$a$],
         array[$a$not in (120, 300) then$a$,       $a$'包桌需選擇 2 小時或 5 小時（要打更久，到時候加時間或升級當日暢打）'$a$])
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'open_session_tx';

select pg_temp.patch_many(p.oid::regprocedure, '當天在櫃檯加時間',
         array[$a$p_hours not in (2, 5, 24)$a$, $a$'時長只能選 2、5 或 24 小時'$a$],
         array[$a$p_hours not in (2, 5)$a$,     $a$'時長只能選 2 或 5 小時（要打更久，當天在櫃檯加時間或升級當日暢打）'$a$])
  from pg_proc p where p.pronamespace = 'public'::regnamespace
   and p.proname in ('create_booking_tx', 'booking_capacity_tx', 'booking_slots_tx');

-- ⑧ 驗證（只讀狀態、不寫東西，不用 raise —— 硬規則 1.8）
do $$
declare v_msg text := ''; v_n int; v_ok boolean; v_t text;
begin
  select string_agg(sku || '=' || unit_price || case when is_active then '' else '(停用)' end
                    || case when discountable then '' else '(不折)' end, ' ' order by sku) into v_t
    from products where (sku like 'SVC-TBL-P%' or sku like 'SVC-TBL-DAY%') and deleted_at is null;
  v_ok := exists (select 1 from products x join products p2 on p2.org_id = x.org_id and p2.sku = 'SVC-TBL-P02'
                   where x.sku = 'SVC-TBL-PX02' and x.is_active and x.discountable and x.unit_price = p2.unit_price)
      and exists (select 1 from products x where x.sku = 'SVC-TBL-DAYUP' and x.is_active and not x.discountable
                     and x.unit_price = public._pkg_ext_expected(x.org_id, 'SVC-TBL-DAYUP') and x.unit_price > 0)
      and not exists (select 1 from products where sku in ('SVC-TBL-PX05', 'SVC-TBL-PX24', 'SVC-TBL-P24')
                         and is_active and deleted_at is null);
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ① 商品：' || coalesce(v_t, '—') || E'\n';

  select string_agg(pg_get_triggerdef(oid), ' ／ ') into v_t from pg_trigger
   where tgrelid = 'public.products'::regclass and tgname in ('trg_products_pkg_tier_sync', 'trg_products_pkg_ext_guard');
  v_ok := v_t ~ 'SVC-TBL-DAY''' and v_t ~ 'SVC-TBL-DAYUP' and v_t ~ 'SVC-TBL-PX02' and v_t !~ 'PX05' and v_t !~ 'P24';
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ② 兩個觸發器改看新的商品清單' || E'\n';

  select pg_get_constraintdef(oid) into v_t from pg_constraint
   where conrelid = 'public.session_extensions'::regclass and conname = 'session_extensions_kind_check';
  v_ok := v_t ~ 'daypass'
      and exists (select 1 from pg_indexes where tablename = 'session_extensions' and indexname = 'uq_session_extensions_daypass')
      and (select is_nullable from information_schema.columns
            where table_schema = 'public' and table_name = 'session_extensions' and column_name = 'order_id') = 'YES'
      and not exists (select 1 from pg_constraint where conrelid = 'public.session_extensions'::regclass
                         and conname = 'session_extensions_to_minutes_check');
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ③ 延長紀錄多了種類、升級暢打的唯一索引、訂單可空' || E'\n';

  v_t := pg_get_functiondef('public.has_daypass_tx_core(uuid,uuid,uuid)'::regprocedure);
  v_ok := v_t ~ 'from session_extensions e' and v_t ~ 'SVC-TBL-DAY''';
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ④ 「今天有沒有暢打」也認升級的那一種，原本的買暢打照樣認' || E'\n';

  v_t := pg_get_functiondef('public._pkg_time(uuid,boolean)'::regprocedure);
  v_ok := v_t ~ 'upgrade_price' and v_t ~ 'has_daypass_tx_core\(' and v_t !~ 'while v_eff';
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⑤ 計時改成每人各自、帶升級差價、認得暢打' || E'\n';

  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace and proname in ('pos_pkg_quote_tx', 'pos_pkg_extend_tx');
  v_ok := v_n = 2
      and has_function_privilege('authenticated', 'public.pos_pkg_quote_tx(uuid,uuid,uuid[],text)', 'execute')
      and has_function_privilege('authenticated', 'public.pos_pkg_extend_tx(uuid,uuid,uuid[],text,bigint,jsonb,text)', 'execute')
      and not has_function_privilege('anon', 'public.pos_pkg_quote_tx(uuid,uuid,uuid[],text)', 'execute')
      and not has_function_privilege('anon', 'public.pos_pkg_extend_tx(uuid,uuid,uuid[],text,bigint,jsonb,text)', 'execute')
      and pg_get_functiondef('public.pos_pkg_extend_tx(uuid,uuid,uuid[],text,bigint,jsonb,text)'::regprocedure)
          ~ 'from session_extensions where order_id = v_order';
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end
        || ' ⑥ 報價與收款各一個版本（多 p_kind）、只給登入的人、收款會擋重送；版本數 ' || v_n || E'\n';

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and ((p.proname = 'open_session_tx' and pg_get_functiondef(p.oid) ~ 'not in \(120, 300\) then')
       or (p.proname in ('create_booking_tx', 'booking_capacity_tx', 'booking_slots_tx')
           and pg_get_functiondef(p.oid) ~ 'p_hours not in \(2, 5\)'));
  v_msg := v_msg || case when v_n = 4 then '✅' else '🔴' end || ' ⑦ 開桌與三支預約都不再收 24 小時（' || v_n || '/4）' || E'\n';

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('tbl_state_tx', 'list_tables_tx', 'pos_pkg_state_tx', 'tbl_submit_hand_tx', 'tbl_start_round_tx')
     and pg_get_functiondef(p.oid) ~ '_pkg_time\(';
  v_msg := v_msg || case when v_n = 5 then '✅' else '🔴' end || ' ⑧ 五支既有函式仍然接著計時（' || v_n || '/5）';

  perform set_config('migi.pkg4', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.pkg4', true), ''), '🔴 沒有驗證訊息') as "驗證";
