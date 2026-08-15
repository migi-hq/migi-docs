-- 【這是什麼】MA1-B 已上線：牌咖邀請、App 通知中心兩張表 + 8 支 RPC（邀請/回應/牌咖列表/通知）。
-- 【何時讀】要改牌咖或通知邏輯、查 send_buddy_invite_tx 等定義時。已執行。
-- ============================================================
-- MIGI MA1-B：牌咖關係與通知（正式版 v1.0，可直接執行，冪等）
-- 前置：需先跑過 MA1-A（會員資料）
-- 範圍：牌咖邀請(單向發起→確認) / App通知 / 牌咖列表 / 最近同桌
-- 模型：接受邀請→mahjong_buddies 寫兩筆互指；拒絕無痕（不通知對方）
-- ============================================================

-- ------------------------------------------------------------
-- 1. 建表
-- ------------------------------------------------------------

-- 牌咖邀請
create table if not exists buddy_invites (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete restrict,
  inviter_id   uuid not null references members(id) on delete restrict,
  invitee_id   uuid not null references members(id) on delete restrict,
  status       text not null default 'pending'
               check (status in ('pending','accepted','rejected')),
  responded_at timestamptz,
  created_at   timestamptz not null default now(),
  check (inviter_id <> invitee_id)
);
create unique index if not exists uq_pending_invite
  on buddy_invites(inviter_id, invitee_id) where status = 'pending';
create index if not exists idx_invites_invitee on buddy_invites(invitee_id) where status = 'pending';
alter table buddy_invites enable row level security;
revoke all on buddy_invites from anon, authenticated;

-- mahjong_buddies 補防重複唯一鍵
create unique index if not exists uq_buddy_pair
  on mahjong_buddies(member_id, buddy_id) where deleted_at is null;

-- App 通知（通知中心資料源）
create table if not exists app_notifications (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  member_id   uuid not null references members(id) on delete restrict,
  type        text not null check (type in
              ('settle','buddy_req','buddy_ok','table_req','table_ok','system')),
  payload     jsonb not null default '{}'::jsonb,
  ref_id      uuid,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists idx_notif_member on app_notifications(member_id, created_at desc);
alter table app_notifications enable row level security;
revoke all on app_notifications from anon, authenticated;

-- ------------------------------------------------------------
-- 2. RPC
-- ------------------------------------------------------------

-- 2a. 發牌咖邀請（黑名單防護留待 C 塊 member_blocks 建立後補；此處先做核心）
create or replace function send_buddy_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if p_inviter = p_invitee then raise exception '不能加自己'; end if;
  -- 已是牌咖 → 略過
  if exists (select 1 from mahjong_buddies
             where member_id = p_inviter and buddy_id = p_invitee and deleted_at is null) then
    return;
  end if;
  -- 建邀請（已 pending 則靠唯一索引擋，用 on conflict 吃掉）
  insert into buddy_invites(org_id, inviter_id, invitee_id)
  values (p_org_id, p_inviter, p_invitee)
  on conflict do nothing;
  -- 通知對方
  select display_name into v_name from members where id = p_inviter;
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  values (p_org_id, p_invitee, 'buddy_req',
          jsonb_build_object('from_name', v_name, 'from_id', p_inviter,
                             'text', v_name || ' 想加你為牌咖'),
          p_inviter);
end $$;

-- 2b. 回應牌咖邀請（接受：寫兩筆互指＋通知邀請方；拒絕：無痕改狀態）
create or replace function respond_buddy_invite_tx(p_org_id uuid, p_invitee uuid, p_inviter uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  update buddy_invites
     set status = case when p_accept then 'accepted' else 'rejected' end,
         responded_at = now()
   where inviter_id = p_inviter and invitee_id = p_invitee and status = 'pending';

  -- 消化對方那則 buddy_req 通知（標記已讀）
  update app_notifications set read_at = now()
   where member_id = p_invitee and type = 'buddy_req' and ref_id = p_inviter and read_at is null;

  if not p_accept then return; end if;   -- 拒絕無痕，到此為止

  -- 接受：寫兩筆互指（冪等）
  insert into mahjong_buddies(org_id, member_id, buddy_id, origin)
  values (p_org_id, p_inviter, p_invitee, 'pre_existing'),
         (p_org_id, p_invitee, p_inviter, 'pre_existing')
  on conflict do nothing;

  -- 通知邀請方「已接受」
  select display_name into v_name from members where id = p_invitee;
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  values (p_org_id, p_inviter, 'buddy_ok',
          jsonb_build_object('from_name', v_name, 'from_id', p_invitee,
                             'text', v_name || ' 已接受你的牌咖邀請'),
          p_invitee);
end $$;

-- 2c. 解除牌咖（靜默雙向軟刪，對方不通知）
create or replace function remove_buddy_tx(p_org_id uuid, p_member uuid, p_buddy uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update mahjong_buddies set deleted_at = now()
   where org_id = p_org_id and deleted_at is null
     and ((member_id = p_member and buddy_id = p_buddy)
       or (member_id = p_buddy and buddy_id = p_member));
end $$;

-- 2d. 我的牌咖列表（含段位/獲讚快照）
create or replace function list_buddies_tx(p_org_id uuid, p_member uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.buddy_id, 'nickname', m.display_name,
      'rank', m.rank, 'title', m.title, 'likes_count', m.likes_count,
      'avatar_url', m.avatar_url, 'co_play_count', b.co_play_count,
      'linked_at', b.linked_at
    ) order by b.linked_at desc)
    from mahjong_buddies b
    join members m on m.id = b.buddy_id and m.deleted_at is null
    where b.member_id = p_member and b.org_id = p_org_id and b.deleted_at is null
  ), '[]'::jsonb);
end $$;

-- 2e. 最近同桌（1 天內，排除已是牌咖/已邀/自己）★需 M2 session_players 有資料才有內容
create or replace function list_recent_players_tx(p_org_id uuid, p_member uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'id', other.member_id, 'nickname', mm.display_name, 'rank', mm.rank
    ))
    from session_players sp
    join session_players other on other.session_id = sp.session_id and other.member_id <> sp.member_id
    join members mm on mm.id = other.member_id and mm.deleted_at is null
    where sp.member_id = p_member and sp.org_id = p_org_id
      and sp.created_at > now() - interval '1 day'
      and not exists (select 1 from mahjong_buddies b
                      where b.member_id = p_member and b.buddy_id = other.member_id and b.deleted_at is null)
      and not exists (select 1 from buddy_invites i
                      where i.inviter_id = p_member and i.invitee_id = other.member_id and i.status = 'pending')
  ), '[]'::jsonb);
end $$;

-- 2f. 通知列表
create or replace function list_notifications_tx(p_org_id uuid, p_member uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'type', type, 'payload', payload, 'ref_id', ref_id,
      'unread', (read_at is null), 'created_at', created_at
    ) order by created_at desc)
    from app_notifications
    where member_id = p_member and org_id = p_org_id
      and created_at > now() - interval '30 days'
  ), '[]'::jsonb);
end $$;

-- 2g. 全部標記已讀
create or replace function mark_notifs_read_tx(p_org_id uuid, p_member uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update app_notifications set read_at = now()
   where member_id = p_member and org_id = p_org_id and read_at is null;
end $$;

-- 2h. 未讀數（鈴鐺紅點）
create or replace function unread_count_tx(p_org_id uuid, p_member uuid)
returns int language plpgsql security definer set search_path = public as $$
begin
  return (select count(*) from app_notifications
          where member_id = p_member and org_id = p_org_id and read_at is null);
end $$;

-- ------------------------------------------------------------
-- 3. 授權
-- ------------------------------------------------------------
grant execute on function send_buddy_invite_tx(uuid,uuid,uuid) to anon, authenticated;
grant execute on function respond_buddy_invite_tx(uuid,uuid,uuid,boolean) to anon, authenticated;
grant execute on function remove_buddy_tx(uuid,uuid,uuid) to anon, authenticated;
grant execute on function list_buddies_tx(uuid,uuid) to anon, authenticated;
grant execute on function list_recent_players_tx(uuid,uuid) to anon, authenticated;
grant execute on function list_notifications_tx(uuid,uuid) to anon, authenticated;
grant execute on function mark_notifs_read_tx(uuid,uuid) to anon, authenticated;
grant execute on function unread_count_tx(uuid,uuid) to anon, authenticated;

-- ============================================================
-- 驗證（用測試01→測試02 走一輪）
-- ============================================================
-- select send_buddy_invite_tx(':ORG', ':T01', ':T02');
-- select list_notifications_tx(':ORG', ':T02');          -- 應有 buddy_req
-- select respond_buddy_invite_tx(':ORG', ':T02', ':T01', true);
-- select list_buddies_tx(':ORG', ':T01');                -- 應含測試02
-- select list_notifications_tx(':ORG', ':T01');          -- 應有 buddy_ok
select count(*) as b_tables from information_schema.tables
 where table_name in ('buddy_invites','app_notifications');
