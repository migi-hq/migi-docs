/* ============================================================
   會員來源記錄（2026-11-02 使用者拍板分類）
   ── 只記錄，不發任何獎勵 ──

   起因：自然流量是零，註冊全靠人帶；而 members.acquisition_source
         158 位非測試會員全部是空的 ⇒ 不知道誰帶了誰。
         這是事後補不回來的資料（硬規則 5.6），所以先記再談獎勵。

   ── 分類（members.acquisition_source）──────────────────────
   staff    A 店員：客人掃了店員在 POS 產生的 QR（碼綁那位店員）
   member   B 會員：客人用會員的邀請連結註冊（牌咖／牌咖團／配桌／好友練習賽）
   ad       C 廣告：連結帶的管道代碼屬於廣告（google、meta…）
   other    D 其他自有管道：官網、LINE 官方帳號…（同上，代碼屬於自有管道）
   none     有在記錄，但什麼標記都沒有
   null     ← 開始記錄之前註冊的人（不是「沒有來源」，是「不知道」）

   ── 規則 ────────────────────────────────────────────────
   · 一律由後端認定：店員看 QR 碼、會員看邀請連結、管道看主檔白名單。
     前端送不進「是誰帶的」—— members 新增時觸發器強制寫 none。
   · 只認註冊後 1 小時內、而且只記一次（先到先記）。
     ⇒ 老會員之後再點別人的連結不會被改掉。
   · 管道代碼是主檔（acquisition_channels），新增管道加一列資料就好。
   · 舊會員：只補得回 12 位（用邀請連結註冊、使用時間在註冊 1 小時內），
     標 acquisition_backfilled = true；其餘維持 null。

   ── 寫入點（不改任何既有函式，全部走觸發器）────────────────
   buddy_invite_links.used_by      → member / buddy_link
   team_invite_links.used_by       → member / team_link
   match_queue_players.invited_by  → member / queue_link
   friendly_game_players（link）   → member / friendly_link（邀請人＝開局的人）
   redeem_staff_referral_tx        → staff
   set_my_acquisition_channel_tx   → ad 或 other（看主檔）

   ⚠ 新增指向 members 的外鍵 1 個、指向 staff 1 個 ——
     會員合併稿（_設計稿未落地）本來就過期，要用之前先重跑盤點。
   ============================================================ */

-- ① 管道主檔 ------------------------------------------------------
create table if not exists public.acquisition_channels (
  code   text primary key check (code ~ '^[a-z][a-z0-9_]{0,29}$'),
  kind   text not null check (kind in ('ad', 'other')),
  label  text not null,
  sort   int  not null default 0,
  created_at timestamptz not null default now()
);
alter table public.acquisition_channels enable row level security;   -- 0 policy：只有函式讀得到
comment on table public.acquisition_channels is
  '會員來源的管道代碼白名單。kind=ad 廣告（C）／other 自有管道（D）。新增管道加一列，不用改程式';

insert into public.acquisition_channels (code, kind, label, sort) values
  ('google',  'ad',    'Google 廣告',         10),
  ('meta',    'ad',    'Meta 廣告（FB／IG）', 20),
  ('site',    'other', '官方網站',            110),
  ('line_oa', 'other', 'LINE 官方帳號',       120)
on conflict (code) do nothing;

-- ② 欄位 ----------------------------------------------------------
alter table public.members
  add column if not exists acquisition_channel    text,
  add column if not exists acquisition_campaign   text,
  add column if not exists referred_by_staff_id   uuid references public.staff(id),
  add column if not exists referred_by_member_id  uuid references public.members(id),
  add column if not exists acquisition_at         timestamptz,
  add column if not exists acquisition_backfilled boolean not null default false;

alter table public.members drop constraint if exists members_acquisition_source_chk;
alter table public.members add constraint members_acquisition_source_chk
  check (acquisition_source is null or acquisition_source in ('staff','member','ad','other','none'));

comment on column public.members.acquisition_source is
  '從哪裡來：staff 店員 QR／member 會員邀請連結／ad 廣告／other 官網等自有管道／none 沒有標記／null 開始記錄（2026-11-02）之前註冊';
comment on column public.members.acquisition_channel is
  'member 時是連結種類（buddy_link/team_link/queue_link/friendly_link）；ad、other 時是 acquisition_channels.code';
comment on column public.members.acquisition_campaign is '廣告或自有管道帶的活動代碼（前端送的，只當參考）';
comment on column public.members.referred_by_staff_id  is '帶他來的店員（acquisition_source = staff）';
comment on column public.members.referred_by_member_id is '帶他來的會員（acquisition_source = member）';
comment on column public.members.acquisition_backfilled is 'true = 2026-11-02 事後從邀請連結補記，不是當下記的';

create index if not exists idx_members_referred_by_member on public.members (referred_by_member_id) where referred_by_member_id is not null;
create index if not exists idx_members_referred_by_staff  on public.members (referred_by_staff_id)  where referred_by_staff_id  is not null;

alter table public.staff add column if not exists referral_code text;
create unique index if not exists uq_staff_referral_code on public.staff (referral_code) where referral_code is not null;
comment on column public.staff.referral_code is '店員推薦 QR 的代碼（POS 第一次產生時建立，之後固定）';

-- ③ 新會員一律從 none 開始（前端／任何人都不能在建立時指定來源）------
create or replace function public._members_acquisition_init()
returns trigger language plpgsql as $$
begin
  new.acquisition_source     := 'none';
  new.acquisition_channel    := null;
  new.acquisition_campaign   := null;
  new.referred_by_staff_id   := null;
  new.referred_by_member_id  := null;
  new.acquisition_at         := null;
  new.acquisition_backfilled := false;
  return new;
end $$;

drop trigger if exists trg_members_acquisition_init on public.members;
create trigger trg_members_acquisition_init
  before insert on public.members
  for each row execute function public._members_acquisition_init();

-- ④ 唯一的寫入點 ---------------------------------------------------
-- 只在「還是 none、而且註冊不到 1 小時」時寫；回傳有沒有寫到
create or replace function public._set_acquisition(
  p_member uuid, p_source text, p_channel text, p_campaign text,
  p_staff uuid, p_ref_member uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_member is null or p_ref_member = p_member then return false; end if;
  update members
     set acquisition_source    = p_source,
         acquisition_channel   = p_channel,
         acquisition_campaign  = left(nullif(btrim(p_campaign), ''), 60),
         referred_by_staff_id  = p_staff,
         referred_by_member_id = p_ref_member,
         acquisition_at        = now()
   where id = p_member
     and acquisition_source = 'none'
     and created_at > now() - interval '1 hour';
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;
revoke execute on function public._set_acquisition(uuid,text,text,text,uuid,uuid) from public, anon, authenticated;

-- ⑤ 會員邀請連結：觸發器（不改既有的兌換函式）---------------------
create or replace function public._acq_from_link()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'buddy_invite_links' then
    if old.used_by is null and new.used_by is not null then
      perform _set_acquisition(new.used_by, 'member', 'buddy_link', null, null, new.created_by);
    end if;
  elsif tg_table_name = 'team_invite_links' then
    if old.used_by is null and new.used_by is not null then
      perform _set_acquisition(new.used_by, 'member', 'team_link', null, null, new.created_by);
    end if;
  elsif tg_table_name = 'match_queue_players' then
    if new.invited_by is not null
       and (tg_op = 'INSERT' or old.invited_by is distinct from new.invited_by) then
      perform _set_acquisition(new.member_id, 'member', 'queue_link', null, null, new.invited_by);
    end if;
  elsif tg_table_name = 'friendly_game_players' then
    if new.join_source = 'link' then
      perform _set_acquisition(new.member_id, 'member', 'friendly_link', null, null,
                               (select g.opened_by from friendly_games g where g.id = new.game_id));
    end if;
  end if;
  return null;
end $$;
revoke execute on function public._acq_from_link() from public, anon, authenticated;

drop trigger if exists trg_acq_buddy_link on public.buddy_invite_links;
create trigger trg_acq_buddy_link after update of used_by on public.buddy_invite_links
  for each row execute function public._acq_from_link();

drop trigger if exists trg_acq_team_link on public.team_invite_links;
create trigger trg_acq_team_link after update of used_by on public.team_invite_links
  for each row execute function public._acq_from_link();

drop trigger if exists trg_acq_queue_link on public.match_queue_players;
create trigger trg_acq_queue_link after insert or update of invited_by on public.match_queue_players
  for each row execute function public._acq_from_link();

drop trigger if exists trg_acq_friendly_link on public.friendly_game_players;
create trigger trg_acq_friendly_link after insert on public.friendly_game_players
  for each row execute function public._acq_from_link();

-- ⑥ A 店員：POS 拿自己的推薦碼 -------------------------------------
create or replace function public.pos_my_referral_code_tx()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid; v_name text; v_code text; i int;
begin
  perform public._api_staff_only();
  select cs.staff_id, cs.name into v_staff, v_name from public.current_staff() cs limit 1;
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先用店員帳號登入');
  end if;

  select referral_code into v_code from staff where id = v_staff;
  if v_code is null then
    for i in 1..10 loop
      -- 8 碼，去掉 0/O/1/I/L 這類容易看錯的字
      v_code := (select string_agg(substr('23456789ABCDEFGHJKMNPQRSTUVWXYZ', 1 + floor(random() * 31)::int, 1), '')
                   from generate_series(1, 8));
      begin
        update staff set referral_code = v_code where id = v_staff and referral_code is null;
        exit;
      exception when unique_violation then v_code := null;
      end;
    end loop;
    select referral_code into v_code from staff where id = v_staff;
  end if;

  return jsonb_build_object('ok', v_code is not null, 'code', v_code, 'staff_name', v_name);
end $$;
revoke execute on function public.pos_my_referral_code_tx() from public, anon;
grant  execute on function public.pos_my_referral_code_tx() to authenticated;

-- ⑦ A 店員：客人註冊完兌換店員碼 -----------------------------------
create or replace function public.redeem_staff_referral_tx(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid; v_staff uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入，請重新開啟 App' using errcode = '28000'; end if;

  select s.id into v_staff from staff s
   where s.referral_code = upper(btrim(p_code)) and s.deleted_at is null;
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  return jsonb_build_object('ok', true,
    'recorded', public._set_acquisition(v_me, 'staff', null, null, v_staff, null));
end $$;
revoke execute on function public.redeem_staff_referral_tx(text) from public, anon;
grant  execute on function public.redeem_staff_referral_tx(text) to authenticated;

-- ⑧ C／D：連結帶的管道代碼 ----------------------------------------
create or replace function public.set_my_acquisition_channel_tx(p_channel text, p_campaign text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid; v_kind text; v_code text := lower(btrim(p_channel));
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入，請重新開啟 App' using errcode = '28000'; end if;

  select kind into v_kind from acquisition_channels where code = v_code;
  if v_kind is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_channel');
  end if;

  return jsonb_build_object('ok', true,
    'recorded', public._set_acquisition(v_me, v_kind, v_code, p_campaign, null, null));
end $$;
revoke execute on function public.set_my_acquisition_channel_tx(text, text) from public, anon;
grant  execute on function public.set_my_acquisition_channel_tx(text, text) to authenticated;

-- ⑨ 舊會員補記：只補得回用邀請連結註冊的那幾位 ----------------------
-- 判準：連結使用時間落在註冊前 10 分鐘～後 1 小時；同一人有兩條取最早那條
with m as (
  select id, created_at from members where not is_test and deleted_at is null and acquisition_source is null
), l as (
  select m.id mid, 'buddy_link' ch, b.created_by ref, b.used_at
    from m join buddy_invite_links b on b.used_by = m.id
     and b.used_at between m.created_at - interval '10 minutes' and m.created_at + interval '1 hour'
  union all
  select m.id, 'team_link', t.created_by, t.used_at
    from m join team_invite_links t on t.used_by = m.id
     and t.used_at between m.created_at - interval '10 minutes' and m.created_at + interval '1 hour'
), pick as (
  select distinct on (mid) * from l order by mid, used_at
)
update members x
   set acquisition_source     = 'member',
       acquisition_channel    = p.ch,
       referred_by_member_id  = p.ref,
       acquisition_at         = p.used_at,
       acquisition_backfilled = true
  from pick p
 where x.id = p.mid and p.ref is distinct from p.mid;

-- ⑩ 驗證（不 raise，硬規則 1.8）------------------------------------
do $$
declare v text := ''; n int; e int;
begin
  -- ① 欄位
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'members'
     and column_name in ('acquisition_source','acquisition_channel','acquisition_campaign',
                         'referred_by_staff_id','referred_by_member_id','acquisition_at','acquisition_backfilled');
  v := v || case when n = 7 then '✅' else '🔴' end || ' ① members 來源欄位 ' || n || '/7' || E'\n';

  -- ② 管道主檔
  select count(*) into n from acquisition_channels where code in ('google','meta','site','line_oa');
  v := v || case when n = 4 then '✅' else '🔴' end || ' ② 管道主檔 ' || n || '/4' || E'\n';

  -- ③ 觸發器 5 個（members 建立 ＋ 四種連結）
  select count(*) into n from pg_trigger where not tgisinternal and tgname in
    ('trg_members_acquisition_init','trg_acq_buddy_link','trg_acq_team_link','trg_acq_queue_link','trg_acq_friendly_link');
  v := v || case when n = 5 then '✅' else '🔴' end || ' ③ 觸發器 ' || n || '/5' || E'\n';

  -- ④ 前端叫得動的三支：authenticated 有、anon 沒有
  select count(*) into n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pos_my_referral_code_tx','redeem_staff_referral_tx','set_my_acquisition_channel_tx')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and not has_function_privilege('anon', p.oid, 'EXECUTE');
  v := v || case when n = 3 then '✅' else '🔴' end || ' ④ 三支 RPC：登入的人叫得動、anon 叫不動 ' || n || '/3' || E'\n';

  -- ⑤ 內部函式前端叫不動（負對照）
  select count(*) into n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname in ('_set_acquisition','_acq_from_link')
     and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  v := v || case when n = 0 then '✅' else '🔴' end || ' ⑤ 寫入函式前端叫不動（' || n || ' 支叫得動）' || E'\n';

  -- ⑥ 補記：期望 12（2026-11-02 查：牌咖團連結 10 ＋ 牌咖連結 2）
  select count(*) into n from members where acquisition_backfilled;
  v := v || case when n = 12 then '✅' else '⚠' end || ' ⑥ 舊會員補記 ' || n || ' 位（期望 12 ＝ 牌咖團 10 ＋ 牌咖 2）' || E'\n';

  -- ⑦ 其餘舊會員維持 null（不可以被寫成 none —— none 是「有在記但沒標記」）
  select count(*) into n from members where acquisition_source is not null and not acquisition_backfilled;
  v := v || case when n = 0 then '✅' else '🔴' end || ' ⑦ 其餘舊會員維持「開始記錄之前」（被寫到的 ' || n || ' 位）' || E'\n';

  -- ⑧ 補記的人都有推薦人、而且不是自己
  select count(*) into n from members
   where acquisition_backfilled and (referred_by_member_id is null or referred_by_member_id = id);
  v := v || case when n = 0 then '✅' else '🔴' end || ' ⑧ 補記的人都有推薦人且不是自己（不合格 ' || n || '）';

  perform set_config('migi.acq', v, true);
end $$;

select coalesce(nullif(current_setting('migi.acq', true), ''), '🔴 沒有訊息') as "驗證";
