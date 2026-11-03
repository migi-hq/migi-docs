/* ============================================================
   2026-11-03 · 碎片改成帳本（比照小熊餅乾 snack_grants）
   使用者：「發餅乾跟發碎片都同一個邏輯沒錯嗎」→「寫，給胡牌的人」

   ── 為什麼改 ──
   今天稍早上線的版本（2026-11-03_頂條碎片數.sql）是每次打開 App 從每一局「重算」：
     · 哪天把某個牌型改成 1 台，大家過去拿到的碎片會跟著變少
     · 跟餅乾、點數不一樣 —— 那兩種都是「發的當下記一筆帳」（世界級遊戲的貨幣也都是這樣）
   改成帳本之後：
     · 一局入帳那一刻記一筆「誰、哪一局、幾個」，之後不管牌型台數怎麼改都不會變
     · 商城做好之後，花掉記一筆負的，跟拿到的在同一本帳（同 consume_snack_tx）
     · 碎片自己一本帳，不跟餅乾共用（使用者定過：碎片跟養成分開）

   ── 規則（沒變）──
     · 胡牌那一家，那一局選了的牌型裡主檔台數 ≥ 2 的，一個牌型 1 個；按幾次算幾個（花槓 ×2 ＝ 2 個）
     · 好友練習賽不算；作廢、刪除的場次不算
   ── 跟重算版不一樣的兩件事（使用者同日拍板）──
     · 🔴 換人上桌：碎片給「當時真的胡牌的人」，不跟著位置走
       （重算版看的是現在坐那個位置的人；分數仍然照舊跟著位置走，那是另一件事）
     · 局被撤銷：帳本只加不改，補記一筆負的把那一局的碎片收回

   ── 舊帳怎麼補 ──
   已經入帳的每一局用今天的主檔台數補記一筆（時間記那一局的入帳時間）。
   誰拿：那一局入帳之後，那個位置如果有換過人，記給「入帳之後第一次換人」的換下的那一位
         （他就是當時坐在那裡的人）；沒換過人就是現在坐那裡的人。
   ⇒ 總數跟重算版一樣（590），只有換人上桌的那幾位會在兩人之間移動（換手前約 11 個）

   ⚠ 新表與新函式預設全關（硬規則 2.7）。帳本 0 條 policy、前端讀不到；只有 get_my_shards_tx 給 authenticated
   ============================================================ */

-- ① 帳本
create table if not exists public.shard_grants (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.orgs(id) on delete restrict,
  member_id  uuid not null references public.members(id) on delete restrict,
  qty        integer not null check (qty <> 0),
  reason     text not null check (reason in ('hand', 'hand_undo', 'admin')),
  ref_id     uuid,
  idem_key   text not null,
  created_at timestamptz not null default now()
);
comment on table public.shard_grants is
  '碎片帳本（牌桌商城的貨幣）。只加不改：拿到記正的、收回或花掉記負的；手上的數 ＝ sum(qty)。'
  ' hand ＝ 胡牌給的（ref_id ＝ hands.id）；hand_undo ＝ 那一局被撤銷收回；admin ＝ 人工調整。'
  ' 商城做好時再加花掉的原因。規則：docs/03-會員App與社交/桌邊背景皮膚.md';
create unique index if not exists uq_shard_grants_idem on public.shard_grants (idem_key);
create index if not exists ix_shard_grants_member on public.shard_grants (member_id, created_at desc);

alter table public.shard_grants enable row level security;
revoke all on table public.shard_grants from public, anon, authenticated;

-- 只加不改：改或刪一律擋（要修正就記一筆 admin）
create or replace function public.trg_shard_grants_no_mutate()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  raise exception '碎片帳本只能新增，不能修改或刪除；要修正請新增一筆調整' using errcode = '55000';
end $function$;

drop trigger if exists trg_shard_grants_no_mutate on public.shard_grants;
create trigger trg_shard_grants_no_mutate
  before update or delete on public.shard_grants
  for each row execute function public.trg_shard_grants_no_mutate();

-- ② 一局給幾個碎片：唯一一份算法（觸發器與補舊帳都叫它）
create or replace function public._hand_shards(p_patterns jsonb)
returns integer
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(sum((p->>'n')::int), 0)::int
    from jsonb_array_elements(coalesce(p_patterns, '[]'::jsonb)) p
    join scoring_patterns pt on pt.code = p->>'code'
   where pt.tai >= 2
$function$;

-- ③ 每一局入帳時發、被撤銷時收回
create or replace function public.trg_hands_shards()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_qty    int;
  v_member uuid;
  v_ok     boolean;
begin
  -- 入帳：變成 confirmed 的那一刻（新增時就是 confirmed 也算）
  if new.status = 'confirmed'
     and (tg_op = 'INSERT' or old.status is distinct from 'confirmed')
     and new.result in ('ron', 'tsumo') then
    select (s.deleted_at is null and s.status <> 'voided' and coalesce(s.mode, '') <> 'friendly')
      into v_ok
      from table_sessions s where s.id = new.session_id;
    if coalesce(v_ok, false) then
      v_qty := public._hand_shards(new.patterns);
      if v_qty > 0 then
        -- 給「這一刻」坐在胡牌位置的人（換人上桌之後也不會跟著位置走）
        select sp.member_id into v_member
          from session_players sp
         where sp.session_id = new.session_id and sp.seat = new.winner_seat
         limit 1;
        if v_member is not null then
          insert into shard_grants (org_id, member_id, qty, reason, ref_id, idem_key)
          values (new.org_id, v_member, v_qty, 'hand', new.id, 'hand:' || new.id)
          on conflict (idem_key) do nothing;
        end if;
      end if;
    end if;
  end if;

  -- 撤銷：從 confirmed 變成別的狀態 ⇒ 把那一局發的收回（記給當初拿到的那一位）
  if tg_op = 'UPDATE' and old.status = 'confirmed' and new.status is distinct from 'confirmed' then
    insert into shard_grants (org_id, member_id, qty, reason, ref_id, idem_key)
    select g.org_id, g.member_id, -g.qty, 'hand_undo', g.ref_id, 'hand_undo:' || new.id
      from shard_grants g
     where g.idem_key = 'hand:' || new.id
    on conflict (idem_key) do nothing;
  end if;

  return null;
end $function$;

drop trigger if exists trg_hands_shards on public.hands;
create trigger trg_hands_shards
  after insert or update of status on public.hands
  for each row execute function public.trg_hands_shards();

-- ④ 補舊帳：已經入帳的每一局
insert into public.shard_grants (org_id, member_id, qty, reason, ref_id, idem_key, created_at)
select h.org_id,
       coalesce(
         (select w.from_member_id
            from session_seat_swaps w
           where w.player_row_id = sp.id
             and w.used_at is not null
             and w.used_at > h.confirmed_at
           order by w.used_at
           limit 1),
         sp.member_id),
       public._hand_shards(h.patterns), 'hand', h.id, 'hand:' || h.id, h.confirmed_at
  from hands h
  join table_sessions s   on s.id = h.session_id
  join session_players sp on sp.session_id = h.session_id and sp.seat = h.winner_seat
 where h.status = 'confirmed'
   and h.result in ('ron', 'tsumo')
   and s.deleted_at is null and s.status <> 'voided' and coalesce(s.mode, '') <> 'friendly'
   and public._hand_shards(h.patterns) > 0
on conflict (idem_key) do nothing;

-- ⑤ 頂條改讀帳本；重算版的那一支拿掉（全庫只有 get_my_shards_tx 叫它，2026-11-03 查過）
create or replace function public.get_my_shards_tx()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  -- 手上的 ＝ 帳本加總（拿到的 − 收回的；商城做好之後也扣花掉的）
  return jsonb_build_object('shard',
    coalesce((select sum(qty) from shard_grants where member_id = v_me), 0));
end $function$;

drop function if exists public._member_shards_earned(uuid);

revoke execute on function public._hand_shards(jsonb)          from public, anon, authenticated;
revoke execute on function public.trg_hands_shards()           from public, anon, authenticated;
revoke execute on function public.trg_shard_grants_no_mutate() from public, anon, authenticated;
revoke execute on function public.get_my_shards_tx()           from public, anon;
grant  execute on function public.get_my_shards_tx()           to authenticated;

/* ── 驗證（單一 SELECT，不用 raise，硬規則 1.8）──────────────
   ② 正對照：帳本總數 ＝ 用重算版的條件直接從每一局算（今天稍早是 590），而且 > 0
   ③ 跟重算版逐人比：不一樣的人一定都是換人上桌的兩方（碎片只在他們之間移動）
   觸發器的行為（入帳發、撤銷收回、好友練習賽不發）另外跑 sql/checks/2026-11-03_驗碎片帳本.sql */
with direct as (
  select coalesce(sum(public._hand_shards(h.patterns)), 0) as n
    from hands h join table_sessions s on s.id = h.session_id
   where s.deleted_at is null and s.status <> 'voided' and coalesce(s.mode, '') <> 'friendly'
     and h.status = 'confirmed' and h.result in ('ron', 'tsumo')
), ledger as (
  select coalesce(sum(qty), 0) as n, count(distinct member_id) filter (where qty > 0) as people, count(*) as rows_
    from shard_grants
), old_per as (   -- 重算版的算法（現在坐那個位置的人）
  select sp.member_id, sum(public._hand_shards(h.patterns)) as n
    from session_players sp
    join table_sessions s on s.id = sp.session_id
    join hands h on h.session_id = sp.session_id and h.winner_seat = sp.seat
   where s.deleted_at is null and s.status <> 'voided' and coalesce(s.mode, '') <> 'friendly'
     and h.status = 'confirmed' and h.result in ('ron', 'tsumo')
   group by sp.member_id
), new_per as (
  select member_id, sum(qty) as n from shard_grants group by member_id
), diff as (
  select coalesce(o.member_id, n.member_id) as member_id
    from old_per o full join new_per n on n.member_id = o.member_id
   where coalesce(o.n, 0) <> coalesce(n.n, 0)
), swappers as (
  select from_member_id as m from session_seat_swaps where used_at is not null
  union select to_member_id from session_seat_swaps where used_at is not null and to_member_id is not null
)
select concat_ws(E'\n',
  case when (select relrowsecurity from pg_class where oid = 'public.shard_grants'::regclass)
        and (select count(*) from pg_policies where tablename = 'shard_grants') = 0
        and not has_table_privilege('authenticated', 'public.shard_grants', 'select')
        and not has_table_privilege('anon', 'public.shard_grants', 'select')
       then '✅ ① 帳本建好：RLS 開、0 條 policy、前端讀不到'
       else '🔴 ① 帳本的權限不對' end,
  case when (select n from ledger) = (select n from direct) and (select n from direct) > 0
       then '✅ ② 帳本總數 ' || (select n from ledger) || ' ＝ 每一局直接算 ' || (select n from direct)
            || '（' || (select rows_ from ledger) || ' 筆、' || (select people from ledger) || ' 人）'
       else '🔴 ② 帳本 ' || (select n from ledger) || '，每一局直接算 ' || (select n from direct) end,
  case when (select count(*) from diff) = 0
       then '✅ ③ 每個人的數字都跟重算版一樣'
       when not exists (select 1 from diff where member_id not in (select m from swappers))
       then '✅ ③ ' || (select count(*) from diff) || ' 人跟重算版不同，全部是換人上桌的兩方（碎片回到當時胡牌的人）'
       else '🔴 ③ 有 ' || (select count(*) from diff where member_id not in (select m from swappers)) || ' 人跟重算版不同、卻沒有換過人' end,
  case when exists (select 1 from pg_trigger where tgname = 'trg_hands_shards' and tgrelid = 'public.hands'::regclass and not tgisinternal)
        and exists (select 1 from pg_trigger where tgname = 'trg_shard_grants_no_mutate' and tgrelid = 'public.shard_grants'::regclass)
       then '✅ ④ 兩個觸發器都在（每一局發／收回、帳本只加不改）'
       else '🔴 ④ 觸發器少了' end,
  case when pg_get_functiondef('public.get_my_shards_tx()'::regprocedure) like '%shard_grants%'
        and has_function_privilege('authenticated', 'public.get_my_shards_tx()', 'execute')
        and not has_function_privilege('anon', 'public.get_my_shards_tx()', 'execute')
        and not has_function_privilege('authenticated', 'public._hand_shards(jsonb)', 'execute')
        and not exists (select 1 from pg_proc where proname = '_member_shards_earned' and pronamespace = 'public'::regnamespace)
       then '✅ ⑤ 頂條改讀帳本、權限對、重算版那一支已拿掉'
       else '🔴 ⑤ get_my_shards_tx／權限／舊函式有一項不對' end
) as "驗證";
