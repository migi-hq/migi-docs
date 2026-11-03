/* ============================================================
   2026-11-03 · 牌桌商城（用碎片換計分板背景）
   使用者：「開始做。一開始推兩種就好：目前的星點跟櫻花；星點取別的名字，接近小熊宇宙可愛風格」
   預覽定稿：https://claude.ai/artifact/QbFoYx886C9Lq9Sin7XSvy
   規則與價格：docs/03-會員App與社交/桌邊背景皮膚.md

   ── 這一份做的事 ──
   ① shop_items      商品主檔（目前只有計分板背景）：熊熊星空（預設、免費）、櫻花（稀有、40 碎片）
                     價格與上下架都是資料，之後調價改這張表就好
   ② member_items    誰換到了哪一款（綁帳號；沒有任何轉移擁有權的函式 —— 背景皮膚 09-29 拍板）
   ③ member_equips   誰現在用哪一款（一個欄位一款：目前只有 table_bg）
   ④ shard_grants    原因多一個 shop：兌換記一筆負的（同小熊餅乾餵食）
   ⑤ get_my_shop_tx / buy_shop_item_tx / equip_shop_item_tx  —— 會員 App 用，身分一律 current_member_id()
   ⑥ _tbl_state_for_device  每一家多回 table_bg、裝置多回 owner_bg ⇒ 計分板畫坐那一台的人選的背景

   ── 為什麼這樣做 ──
   · 碎片夠不夠、有沒有重複換，一律後端擋（never trust the client）
   · 同一個人同時按兩次：鎖住這個人的碎片帳（advisory lock），第二次看到的是扣過的餘額；
     而且帳本的冪等鍵 shop:<會員>:<款式> 讓同一款只扣一次
   · 預設款不用換：誰都擁有，不寫 member_items
   · 選了某款之後那一款被下架：計分板退回預設，不報錯（_member_table_bg）
   · 牌型框暫緩（使用者 2026-11-03）：這一份不建任何牌型框的資料，前端點分頁只跳「即將推出」

   ⚠ 新表與新函式預設全關（硬規則 2.7）：三張新表 0 條 policy、前端讀不到；三支會員函式明確 grant 給 authenticated
   ============================================================ */

-- ① 商品主檔
create table if not exists public.shop_items (
  code       text primary key,
  kind       text not null check (kind in ('table_bg')),
  name       text not null,
  tier       text not null check (tier in ('default', 'basic', 'normal', 'rare')),
  price      integer not null check (price >= 0),
  sort       integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  constraint shop_items_default_free check ((tier = 'default') = (price = 0))
);
comment on table public.shop_items is
  '牌桌商城的商品（目前只有計分板背景）。code 也是計分板認背景的代碼，改了計分板就認不得 —— 只改 name、price、is_active。'
  ' tier：default 預設（免費、誰都有）／basic 入門／normal 一般／rare 稀有。價格三級 10／20／40（docs/03-會員App與社交/桌邊背景皮膚.md）';
alter table public.shop_items enable row level security;
revoke all on table public.shop_items from public, anon, authenticated;

insert into public.shop_items (code, kind, name, tier, price, sort) values
  ('starry', 'table_bg', '熊熊星空', 'default', 0, 10),
  ('sakura', 'table_bg', '櫻花',     'rare',   40, 20)
on conflict (code) do nothing;

-- ② 誰換到了哪一款
create table if not exists public.member_items (
  member_id   uuid not null references public.members(id) on delete restrict,
  item_code   text not null references public.shop_items(code) on delete restrict,
  source      text not null check (source in ('shop', 'grant')),
  acquired_at timestamptz not null default now(),
  primary key (member_id, item_code)
);
comment on table public.member_items is
  '會員擁有的商城款式（預設款不寫在這裡）。shop ＝ 用碎片換的；grant ＝ 成就、活動送的（日後）。綁帳號，不可轉送。';
alter table public.member_items enable row level security;
revoke all on table public.member_items from public, anon, authenticated;

-- ③ 誰現在用哪一款
create table if not exists public.member_equips (
  member_id  uuid not null references public.members(id) on delete restrict,
  slot       text not null check (slot in ('table_bg')),
  item_code  text not null references public.shop_items(code) on delete restrict,
  updated_at timestamptz not null default now(),
  primary key (member_id, slot)
);
comment on table public.member_equips is '會員現在用的款式，一個欄位一款（table_bg ＝ 計分板背景）。沒有這一列 ＝ 用預設款。';
alter table public.member_equips enable row level security;
revoke all on table public.member_equips from public, anon, authenticated;

-- ④ 碎片帳本多一個原因：shop（兌換）
alter table public.shard_grants drop constraint if exists shard_grants_reason_check;
alter table public.shard_grants add constraint shard_grants_reason_check
  check (reason in ('hand', 'hand_undo', 'admin', 'shop'));

-- ⑤-0 某人計分板該畫哪個背景（計分板與商城共用的唯一一份判斷）
create or replace function public._member_table_bg(p_member uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select e.item_code
       from member_equips e
       join shop_items i on i.code = e.item_code and i.is_active
      where e.member_id = p_member and e.slot = 'table_bg'
        and (i.tier = 'default'
             or exists (select 1 from member_items mi where mi.member_id = p_member and mi.item_code = e.item_code))),
    (select code from shop_items where kind = 'table_bg' and tier = 'default' and is_active order by sort limit 1),
    'starry')
$function$;

-- ⑤-1 商城：手上的碎片 ＋ 每一款（擁有、使用中）
create or replace function public.get_my_shop_tx()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
  v_bg text;
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  v_bg := public._member_table_bg(v_me);
  return jsonb_build_object(
    'shard', coalesce((select sum(qty) from shard_grants where member_id = v_me), 0),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', i.code, 'kind', i.kind, 'name', i.name, 'tier', i.tier, 'price', i.price,
               'owned', i.tier = 'default' or mi.item_code is not null,
               'equipped', i.kind = 'table_bg' and i.code = v_bg)
             order by i.sort, i.code)
        from shop_items i
        left join member_items mi on mi.member_id = v_me and mi.item_code = i.code
       where i.is_active or mi.item_code is not null), '[]'::jsonb));
end $function$;

-- ⑤-2 兌換
create or replace function public.buy_shop_item_tx(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid;
  i      shop_items%rowtype;
  v_bal  int;
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  -- 同一個人的碎片帳一次只處理一筆（兩支手機同時按兌換，第二筆會看到扣過的餘額）
  perform pg_advisory_xact_lock(hashtextextended('shard:' || v_me::text, 0));

  select * into i from shop_items where code = p_code;
  if not found or not i.is_active then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '這一款目前沒有在商城裡');
  end if;
  if i.tier = 'default' or exists (select 1 from member_items where member_id = v_me and item_code = i.code) then
    return jsonb_build_object('ok', false, 'reason', 'owned', 'message', '你已經兌換過這一款了');
  end if;
  select coalesce(sum(qty), 0) into v_bal from shard_grants where member_id = v_me;
  if v_bal < i.price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough', 'need', i.price - v_bal,
                              'message', '碎片不夠，還差 ' || (i.price - v_bal) || ' 個');
  end if;

  select org_id into v_org from members where id = v_me;
  insert into shard_grants (org_id, member_id, qty, reason, ref_id, idem_key)
  values (v_org, v_me, -i.price, 'shop', null, 'shop:' || v_me || ':' || i.code);
  insert into member_items (member_id, item_code, source) values (v_me, i.code, 'shop');

  return jsonb_build_object('ok', true, 'code', i.code, 'shard', v_bal - i.price);
end $function$;

-- ⑤-3 使用
create or replace function public.equip_shop_item_tx(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
  i    shop_items%rowtype;
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  select * into i from shop_items where code = p_code and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '這一款目前沒有在商城裡');
  end if;
  if i.tier <> 'default' and not exists (select 1 from member_items where member_id = v_me and item_code = i.code) then
    return jsonb_build_object('ok', false, 'reason', 'not_owned', 'message', '要先兌換才能使用');
  end if;
  insert into member_equips (member_id, slot, item_code) values (v_me, i.kind, i.code)
  on conflict (member_id, slot) do update set item_code = excluded.item_code, updated_at = now();
  return jsonb_build_object('ok', true, 'code', i.code);
end $function$;

revoke execute on function public._member_table_bg(uuid)    from public, anon, authenticated;
revoke execute on function public.get_my_shop_tx()          from public, anon;
revoke execute on function public.buy_shop_item_tx(text)    from public, anon;
revoke execute on function public.equip_shop_item_tx(text)  from public, anon;
grant  execute on function public.get_my_shop_tx()          to authenticated;
grant  execute on function public.buy_shop_item_tx(text)    to authenticated;
grant  execute on function public.equip_shop_item_tx(text)  to authenticated;

-- ⑥ 計分板：每一家多回 table_bg、裝置多回 owner_bg（手機還沒開局時畫擁有者的）
--   函式很長，只改兩處 ⇒ 撈線上全文、換掉那兩個片段、確認各換到才建（換不到就整份回滾）
do $$
declare
  v_def text := pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure);
  v_new text;
begin
  if v_def like '%''table_bg''%' then
    return;   -- 已經改過（重跑這份時）
  end if;
  v_new := replace(v_def,
    $a$'no1', v_no1 is not null and sp.member_id = v_no1 and s.mode <> 'friendly')$a$,
    $b$'table_bg', public._member_table_bg(sp.member_id),   -- 🎨 計分板背景（牌桌商城，2026-11-03）
           'no1', v_no1 is not null and sp.member_id = v_no1 and s.mode <> 'friendly')$b$);
  if v_new = v_def then
    raise exception '🔴 找不到 no1 那一行，_tbl_state_for_device 沒有改（整份回滾）';
  end if;
  v_def := v_new;
  v_new := replace(v_def,
    $a$'kind', d.kind,$a$,
    $b$'kind', d.kind, 'owner_bg', case when d.member_id is not null then public._member_table_bg(d.member_id) end,$b$);
  if (length(v_new) - length(v_def)) <> 2 * (length($b$'kind', d.kind, 'owner_bg', case when d.member_id is not null then public._member_table_bg(d.member_id) end,$b$) - length($a$'kind', d.kind,$a$)) then
    raise exception '🔴 裝置那一段應該剛好有兩處，_tbl_state_for_device 沒有改（整份回滾）';
  end if;
  execute v_new;
end $$;

/* ── 驗證（單一 SELECT，不用 raise，硬規則 1.8）────────────────
   兌換、使用、碎片不夠、重複兌換的行為另外跑 sql/checks/2026-11-03_驗牌桌商城.sql */
select concat_ws(E'\n',
  case when (select count(*) from pg_class c where c.oid in ('public.shop_items'::regclass, 'public.member_items'::regclass, 'public.member_equips'::regclass) and c.relrowsecurity) = 3
        and (select count(*) from pg_policies where tablename in ('shop_items', 'member_items', 'member_equips')) = 0
        and not has_table_privilege('authenticated', 'public.member_items', 'select')
        and not has_table_privilege('anon', 'public.shop_items', 'select')
       then '✅ ① 三張表建好：RLS 開、0 條 policy、前端讀不到'
       else '🔴 ① 三張表的權限不對' end,
  case when (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items) = 'starry 熊熊星空 0、sakura 櫻花 40'
       then '✅ ② 商品：熊熊星空（免費）、櫻花（40）'
       else '🔴 ② 商品不對：' || coalesce((select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items), '（空的）') end,
  case when pg_get_constraintdef((select oid from pg_constraint where conname = 'shard_grants_reason_check')) like '%shop%'
       then '✅ ③ 碎片帳本可以記兌換（shop）' else '🔴 ③ 碎片帳本的原因沒有 shop' end,
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname in ('get_my_shop_tx', 'buy_shop_item_tx', 'equip_shop_item_tx', '_member_table_bg')) = 4
        and has_function_privilege('authenticated', 'public.get_my_shop_tx()', 'execute')
        and has_function_privilege('authenticated', 'public.buy_shop_item_tx(text)', 'execute')
        and has_function_privilege('authenticated', 'public.equip_shop_item_tx(text)', 'execute')
        and not has_function_privilege('anon', 'public.buy_shop_item_tx(text)', 'execute')
        and not has_function_privilege('authenticated', 'public._member_table_bg(uuid)', 'execute')
       then '✅ ④ 四支函式各一個版本；登入的人叫得動三支會員函式、沒登入叫不動、內部那支前端叫不到'
       else '🔴 ④ 函式數或權限不對' end,
  case when (length(pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure))
             - length(replace(pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure), '''owner_bg''', ''))) / length('''owner_bg''') = 2
        and pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure) like '%''table_bg'', public._member_table_bg(sp.member_id)%'
        and (select count(*) from pg_proc where proname = '_tbl_state_for_device' and pronamespace = 'public'::regnamespace) = 1
       then '✅ ⑤ 計分板狀態：每一家有 table_bg、兩個裝置段落都有 owner_bg（一個版本）'
       else '🔴 ⑤ _tbl_state_for_device 沒有改對' end,
  case when public._member_table_bg(gen_random_uuid()) = 'starry'
       then '✅ ⑥ 沒選過的人 ⇒ 熊熊星空（預設）' else '🔴 ⑥ 預設背景不對：' || coalesce(public._member_table_bg(gen_random_uuid()), 'null') end
) as "驗證";
