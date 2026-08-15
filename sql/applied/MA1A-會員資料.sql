-- 【這是什麼】MA1-A 已上線：會員段位/稱號/獲讚欄位、按讚明細、養成熊雲端存檔、空檔時段，含 7 支 RPC。
-- 【何時讀】要改會員資料相關 RPC、或查 get_my_profile_tx / save_app_state_tx 定義時。已執行，勿重跑破壞資料（本身冪等但無需再跑）。
-- ============================================================
-- MIGI MA1-A：會員資料（正式版 v1.0，可直接執行）
-- Supabase Dashboard → SQL Editor 整段貼上 → Run（冪等可重跑）
--
-- 範圍：段位/稱號/獲讚 + App 進度雲端化（養成熊）+ 我的空檔時段
-- 依基石：uuid①/UTC②/org+RLS⑥/check⑮/寫入只走 SECURITY DEFINER RPC⑱
-- ============================================================

-- ------------------------------------------------------------
-- 1. members 擴充
-- ------------------------------------------------------------
alter table members add column if not exists rank  text not null default '銅牌熊 I';
alter table members add column if not exists title text not null default '新手上路';
alter table members add column if not exists likes_count int not null default 0;

comment on column members.rank  is '段位快取（M4 賽季 Elo 結算後更新；格式「金牌熊 II」）';
comment on column members.title is '配戴中的稱號';
comment on column members.likes_count is '累計獲讚（like_player_tx 維護，member_likes 為明細）';

-- ------------------------------------------------------------
-- 2. 按讚明細
-- ------------------------------------------------------------
create table if not exists member_likes (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  liker_id    uuid not null references members(id) on delete restrict,
  target_id   uuid not null references members(id) on delete restrict,
  session_id  uuid references table_sessions(id) on delete restrict,
  created_at  timestamptz not null default now(),
  check (liker_id <> target_id)
);
create unique index if not exists uq_like_per_session
  on member_likes(liker_id, target_id, session_id) where session_id is not null;
create index if not exists idx_likes_target on member_likes(target_id);

alter table member_likes enable row level security;
revoke all on member_likes from anon, authenticated;

-- ------------------------------------------------------------
-- 3. App 進度雲端化（養成熊 / 稱號解鎖）
--    換手機、清快取進度不丟。遊戲存檔性質用 jsonb（非交易資料）
-- ------------------------------------------------------------
create table if not exists member_app_state (
  member_id   uuid primary key references members(id) on delete restrict,
  org_id      uuid not null references orgs(id) on delete restrict,
  bear        jsonb not null default '{}'::jsonb,   -- {growth, snacks:{cookie:3,...}, fed_total...}
  titles      jsonb not null default '[]'::jsonb,   -- 已解鎖稱號 ["新手上路","早鳥達人"]
  updated_at  timestamptz not null default now()
);
comment on table member_app_state is
  '會員 App 端進度（養成熊/稱號解鎖）。遊戲存檔性質，jsonb 彈性結構；
   碰錢的東西（點數/券）不在這裡，在 wallets/member_coupons。';

alter table member_app_state enable row level security;
revoke all on member_app_state from anon, authenticated;

-- ------------------------------------------------------------
-- 4. RPC（前端唯一入口）
-- ------------------------------------------------------------

-- 4a. 讀我的完整資料（App 開啟時一次拉齊）
create or replace function get_my_profile_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v jsonb;
begin
  select jsonb_build_object(
    'id', m.id, 'nickname', m.display_name,
    'rank', m.rank, 'title', m.title,
    'likes_count', m.likes_count, 'avatar_url', m.avatar_url,
    'tier', m.tier,
    'app_state', coalesce(s.bear, '{}'::jsonb),
    'titles_unlocked', coalesce(s.titles, '[]'::jsonb)
  ) into v
  from members m
  left join member_app_state s on s.member_id = m.id
  where m.id = p_member_id and m.org_id = p_org_id and m.deleted_at is null;
  if v is null then raise exception '會員不存在'; end if;
  return v;
end $$;

-- 4b. 設定頭像（存段位熊代號如 'rank:gold'，或 Storage 照片網址）
create or replace function set_my_avatar_tx(p_org_id uuid, p_member_id uuid, p_avatar text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update members set avatar_url = p_avatar
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $$;

-- 4c. 設定稱號（必須是已解鎖的）
create or replace function set_my_title_tx(p_org_id uuid, p_member_id uuid, p_title text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from member_app_state
     where member_id = p_member_id and titles ? p_title
  ) and p_title <> '新手上路' then
    raise exception '稱號未解鎖';
  end if;
  update members set title = p_title
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $$;

-- 4d. 儲存 App 進度（養成熊餵食後整包 upsert；titles 只增不減防倒退）
create or replace function save_app_state_tx(p_org_id uuid, p_member_id uuid, p_bear jsonb, p_titles jsonb default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if pg_column_size(p_bear) > 8192 then raise exception 'bear state 過大'; end if;
  insert into member_app_state(member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id, coalesce(p_bear,'{}'::jsonb), coalesce(p_titles,'[]'::jsonb), now())
  on conflict (member_id) do update set
    bear = excluded.bear,
    -- 稱號聯集：只增不減（防舊裝置覆蓋掉新解鎖）
    titles = (select jsonb_agg(distinct t) from jsonb_array_elements_text(member_app_state.titles || excluded.titles) t),
    updated_at = now();
end $$;

-- 4e. 按讚 / 取消讚（無 session 過渡期：同人同日一次；likes_count 同步維護）
create or replace function like_player_tx(p_org_id uuid, p_liker uuid, p_target uuid, p_on boolean, p_session uuid default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_today_like uuid;
begin
  if p_liker = p_target then raise exception '不能讚自己'; end if;
  -- 找今天(台北營業日)對同一人的讚
  select id into v_today_like from member_likes
   where liker_id = p_liker and target_id = p_target
     and (p_session is not null and session_id = p_session
          or p_session is null and (created_at at time zone 'Asia/Taipei')::date = (now() at time zone 'Asia/Taipei')::date)
   limit 1;
  if p_on then
    if v_today_like is not null then return; end if;  -- 已讚過，冪等
    insert into member_likes(org_id, liker_id, target_id, session_id)
    values (p_org_id, p_liker, p_target, p_session);
    update members set likes_count = likes_count + 1 where id = p_target;
  else
    if v_today_like is null then return; end if;
    delete from member_likes where id = v_today_like;
    update members set likes_count = greatest(0, likes_count - 1) where id = p_target;
  end if;
end $$;

-- 4f. 我的空檔時段（stated 來源整批覆蓋；inferred 由 M3 維護不動）
create or replace function set_my_availability_tx(p_org_id uuid, p_member_id uuid, p_slots jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
declare r jsonb;
begin
  delete from member_availability
   where member_id = p_member_id and org_id = p_org_id and source = 'stated';
  for r in select * from jsonb_array_elements(coalesce(p_slots,'[]'::jsonb)) loop
    insert into member_availability(org_id, member_id, weekday, slot, preference, source)
    values (p_org_id, p_member_id, (r->>'weekday')::smallint, r->>'slot',
            coalesce(r->>'preference','often'), 'stated');
  end loop;
end $$;

create or replace function get_my_availability_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('weekday', weekday, 'slot', slot, 'preference', preference))
    from member_availability
    where member_id = p_member_id and org_id = p_org_id and source = 'stated'
  ), '[]'::jsonb);
end $$;

-- ------------------------------------------------------------
-- 5. 授權（anon 過渡期；LINE 真登入後收斂為 authenticated）
-- ------------------------------------------------------------
grant execute on function get_my_profile_tx(uuid, uuid) to anon, authenticated;
grant execute on function set_my_avatar_tx(uuid, uuid, text) to anon, authenticated;
grant execute on function set_my_title_tx(uuid, uuid, text) to anon, authenticated;
grant execute on function save_app_state_tx(uuid, uuid, jsonb, jsonb) to anon, authenticated;
grant execute on function like_player_tx(uuid, uuid, uuid, boolean, uuid) to anon, authenticated;
grant execute on function set_my_availability_tx(uuid, uuid, jsonb) to anon, authenticated;
grant execute on function get_my_availability_tx(uuid, uuid) to anon, authenticated;

-- ============================================================
-- 驗證
-- ============================================================
select column_name from information_schema.columns
 where table_name='members' and column_name in ('rank','title','likes_count');
select count(*) as new_tables from information_schema.tables
 where table_name in ('member_likes','member_app_state');
-- 手動測（換成實際 org/member id）：
-- select get_my_profile_tx(':ORG', ':MEMBER');
-- select like_player_tx(':ORG', ':MEMBER_A', ':MEMBER_B', true);
-- select likes_count from members where id=':MEMBER_B';  -- 應為 1
