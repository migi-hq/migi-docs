-- ============================================================
-- 2026-10-30 配桌的邀請：揪桌接上真的後端 ＋ 配桌 LINE 邀請連結（分支 migi-web feat/invite）
--
-- 使用者拍板（2026-10-30）：
--   ① 揪桌（等人中「＋ 邀牌咖加入這桌」、開房前先勾選的牌咖）真的送出、真的能接受／拒絕
--   ② 等人中多一顆「LINE 邀請朋友」：**這一房共用一條連結**（同一個人對同一房按幾次都是同一條），
--      房還在等人就能一直用；朋友點了**直接報名**（登入或註冊完自動加入，同牌咖／牌咖團連結）
--
-- 這一份做的事：
--   A. match_queue_players.invited_by   誰把這個人帶進這一房（揪桌與連結兩條路都記；事後補不回來）
--   B. queue_invite_links               配桌邀請連結（一房一個邀請人一條，0 policy，只有 DEFINER 進得去）
--   C. send_table_invite_tx             補檢查：你在房裡、房還在等人、對方是你的牌咖、沒封鎖、沒隱藏、
--                                       還不在房裡、同一個人同一房只發一則（簽名不變）
--   D. respond_table_invite_tx          要真的有這則邀請；接受 ⇒ 報名（來源 invite）＋ 記 invited_by；
--                                       接受或拒絕都記 done_at（已讀會被「全部已讀」一起清掉，不能拿來當回覆）
--   E. list_notifications_tx            table_req 也回 invite_status（accepted／rejected／expired／pending），
--                                       重新整理之後仍然看得到結論
--   F. create_queue_invite_link_tx      拿這一房的邀請連結（＋ LINE 訊息要用的門市、時間、積分、玩法）
--   G. redeem_queue_invite_tx           用連結報名（來源 link）＋ 記 invited_by
--   H. send／respond 兩支收回 anon 與 PUBLIC（它們本來就只認登入的本人，anon 叫了也只會拿到 28000）
--
-- ⚠ 不改任何既有函式的簽名 ⇒ 全部 CREATE OR REPLACE，既有授權不會掉。
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格。行為測試另一份：sql/checks/2026-10-30_驗配桌揪桌與邀請連結.sql
-- ============================================================

-- A. 誰把這個人帶進這一房
alter table public.match_queue_players
  add column if not exists invited_by uuid references public.members(id);
comment on column public.match_queue_players.invited_by is
  '誰把這個人帶進這一房：揪桌（join_source = invite）是發邀請的人、配桌邀請連結（join_source = link）是連結的主人；其他來源是 null（2026-10-30）';

-- B. 配桌邀請連結
create table if not exists public.queue_invite_links (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.orgs(id),
  queue_id   uuid not null references public.match_queues(id),
  token      text not null unique,
  created_by uuid not null references public.members(id),
  created_at timestamptz not null default now()
);
create unique index if not exists uq_queue_invite_links_owner on public.queue_invite_links (queue_id, created_by);
alter table public.queue_invite_links enable row level security;
comment on table public.queue_invite_links is
  '配桌邀請連結（2026-10-30）：一房一個邀請人一條、可以重複用，房還在等人就有效；網址 liff.line.me/<LIFF_ID>?q=<token>。0 policy，只有 DEFINER 函式進得去';

-- C. 發揪桌邀請
create or replace function public.send_table_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid, p_queue uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_name text; v_q record;
begin
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_inviter := public.current_member_id();
  if p_inviter is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if p_invitee is null or p_invitee = p_inviter then raise exception '找不到要邀請的人'; end if;

  /* 2026-10-30：房要還在等人，而且發邀請的人自己要在房裡 */
  select q.id, q.status, q.expires_at into v_q
    from match_queues q where q.id = p_queue and q.org_id = p_org_id;
  if v_q.id is null then raise exception '找不到這個牌局'; end if;
  if v_q.status <> 'waiting' or (v_q.expires_at is not null and v_q.expires_at < now()) then
    raise exception '這一房已經不在等人了';
  end if;
  if not exists (select 1 from match_queue_players
                  where queue_id = p_queue and member_id = p_inviter and left_at is null) then
    raise exception '你不在這一房裡，不能邀請別人';
  end if;

  /* 只能邀自己的牌咖（兩個方向都算），跟好友練習賽的邀請同一個判準 */
  if not exists (select 1 from mahjong_buddies b
                  where b.deleted_at is null
                    and ((b.member_id = p_inviter and b.buddy_id = p_invitee)
                      or (b.member_id = p_invitee and b.buddy_id = p_inviter))) then
    raise exception '只能邀請你的牌咖';
  end if;
  if exists (select 1 from members where id = p_invitee and hidden_at is not null) then
    raise exception '這位會員目前無法邀請';
  end if;
  if exists (select 1 from match_queue_players
              where queue_id = p_queue and member_id = p_invitee and left_at is null) then
    raise exception '他已經在這一房了';
  end if;

  if _blocked_between(p_org_id, p_inviter, p_invitee) then return; end if;  -- 互黑靜默不發

  /* 同一個人同一房只發一則（不管是誰邀的、他回覆過沒有）—— 不讓同一房一直跳通知給他 */
  if exists (select 1 from app_notifications
              where member_id = p_invitee and type = 'table_req' and ref_id = p_queue) then
    return;
  end if;

  select display_name into v_name from members where id = p_inviter;
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  values (p_org_id, p_invitee, 'table_req',
          jsonb_build_object('from_name', v_name, 'from_id', p_inviter,
                             'text', v_name || ' 揪你一起打牌', 'queue_id', p_queue),
          p_queue);
end $function$;

-- D. 回覆揪桌邀請
create or replace function public.respond_table_invite_tx(p_org_id uuid, p_invitee uuid, p_queue uuid, p_accept boolean)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_from uuid; v_status text;
begin
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_invitee := public.current_member_id();
  if p_invitee is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;

  /* 2026-10-30：要真的有人邀過他這一房 */
  select (n.payload ->> 'from_id')::uuid into v_from
    from app_notifications n
   where n.org_id = p_org_id and n.member_id = p_invitee and n.type = 'table_req' and n.ref_id = p_queue
   order by n.created_at desc limit 1;
  if not found then raise exception '找不到這則邀請'; end if;

  /* 回覆過了就記 done_at（已讀會被「全部已讀」一起清掉，不能拿來判斷回覆了沒）。
     ⚠ 接受時報名失敗（滿了、時間衝突）會整筆退回 ⇒ done_at 也不會留下，畫面照樣是待處理 */
  update app_notifications set read_at = coalesce(read_at, now()), done_at = coalesce(done_at, now())
   where org_id = p_org_id and member_id = p_invitee and type = 'table_req' and ref_id = p_queue;
  if not p_accept then return 'rejected'; end if;

  v_status := join_match_queue_tx(p_org_id, p_invitee, p_queue, 'invite');
  update match_queue_players set invited_by = v_from
   where queue_id = p_queue and member_id = p_invitee and left_at is null and invited_by is null;
  return v_status;
end $function$;

-- E. 通知清單：table_req 也回 invite_status
create or replace function public.list_notifications_tx(p_org_id uuid, p_member uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'type', n.type, 'payload', n.payload, 'ref_id', n.ref_id,
      'unread', (n.read_at is null), 'done', (n.done_at is not null), 'created_at', n.created_at,
      /* 這則邀請回覆了沒。null = 不適用（純告知類）或查不到對應邀請。
         前端把 null 與 'pending' 都當成待處理。 */
      'invite_status', case
        when n.type = 'buddy_req' then (
          select bi.status
            from buddy_invites bi
           where bi.inviter_id = n.ref_id
             and bi.invitee_id = n.member_id
           order by bi.created_at desc
           limit 1)
        /* 🆕 團的申請與邀請。`ref_id` 直接就是 team_requests.id。
           ⚠ 過期的要說「過期」不要說「待處理」—— 清理是在別的動作
             順手做的（沒有排程），所以這裡一定會看到還沒被收掉的 pending。 */
        when n.type = 'team_req' then (
          select case when r.status = 'pending' and r.expires_at <= now()
                      then 'expired' else r.status end
            from team_requests r
           where r.id = n.ref_id)
        /* 🆕 2026-10-30 揪桌（ref_id ＝ 那一房）：這則通知之後他進過那一房 ⇒ 已接受；
           按過拒絕（done_at）⇒ 已拒絕；那一房已經不在等人 ⇒ 已過期；其餘 ⇒ 待處理 */
        when n.type = 'table_req' then (
          select case
                   when exists (select 1 from match_queue_players qp
                                 where qp.queue_id = n.ref_id and qp.member_id = n.member_id
                                   and qp.joined_at >= n.created_at) then 'accepted'
                   when n.done_at is not null then 'rejected'
                   when q.id is null or q.status <> 'waiting'
                        or (q.expires_at is not null and q.expires_at < now()) then 'expired'
                   else 'pending' end
            from (select 1) one
            left join match_queues q on q.id = n.ref_id)
        end,
      /* 2026-10-20：這則通知「是誰」的頭像（前端畫真的頭像，不再一律預設小熊）
           牌咖邀請 ref_id ＝ 邀請人；接受了你的牌咖邀請 ref_id ＝ 接受的人（2026-10-21 補）；
           入團申請（給團長）＝ 申請的人；入團邀請（給被邀的人）＝ 邀請的人；
           某某加入了團／用邀請連結加入了 ref_id ＝ 加入的人（2026-10-21 補，其他牌咖團告知類 ref_id 是 null）；
           邀你入桌 ＝ payload.from_id 的邀請人（ref_id 是那一房，2026-10-21 補）。
           其他類型沒有「誰」，回 null */
      'actor', (
        select jsonb_build_object('avatar_url', a.avatar_url, 'avatar_bear', a.avatar_bear,
                                  'avatar_source', a.avatar_source, 'avatar_photo_path', a.avatar_photo_path,
                                  'rank', a.rank)
          from members a
         where a.id = case
                 when n.type = 'buddy_req' then n.ref_id
                 when n.type = 'buddy_ok' then n.ref_id
                 when n.type = 'team_ok' then n.ref_id
                 when n.type = 'table_req' then (n.payload->>'from_id')::uuid
                 when n.type = 'team_req' then (
                   select case when r.kind = 'invite' then r.created_by else r.member_id end
                     from team_requests r where r.id = n.ref_id)
               end)
    ) order by n.created_at desc)
    from app_notifications n
    where n.member_id = p_member and n.org_id = p_org_id
      and n.created_at > now() - interval '30 days'
  ), '[]'::jsonb);
end $function$;

-- F. 拿這一房的邀請連結
create or replace function public.create_queue_invite_link_tx(p_queue uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_q     record;
  v_token text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  select q.id, q.status, q.expires_at, q.play_at, q.game_type, q.flower, q.rounds,
         st.name as store_name, sl.label as stake_label
    into v_q
    from match_queues q
    left join stores st on st.id = q.store_id
    left join stake_levels sl on sl.id = q.stake_level_id
   where q.id = p_queue and q.org_id = v_org;
  if v_q.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌局');
  end if;
  if v_q.status <> 'waiting' or (v_q.expires_at is not null and v_q.expires_at < now()) then
    return jsonb_build_object('ok', false, 'reason', 'closed', 'message', '這一房已經不在等人了');
  end if;
  if not exists (select 1 from match_queue_players
                  where queue_id = p_queue and member_id = v_me and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_in_queue', 'message', '你不在這一房裡，不能邀請別人');
  end if;

  /* 同一個人對同一房按幾次都是同一條（使用者 2026-10-30：一房共用一條） */
  select token into v_token from queue_invite_links where queue_id = p_queue and created_by = v_me;
  if v_token is null then
    v_token := replace(gen_random_uuid()::text, '-', '');   -- 32 個 16 進位字元
    insert into queue_invite_links (org_id, queue_id, token, created_by)
    values (v_org, p_queue, v_token, v_me);
  end if;

  return jsonb_build_object('ok', true, 'token', v_token,
    'my_name', (select display_name from members where id = v_me),
    'store_name', v_q.store_name, 'stake_label', v_q.stake_label, 'play_at', v_q.play_at,
    'game_type', v_q.game_type, 'flower', v_q.flower, 'rounds', v_q.rounds);
end $function$;

-- G. 用連結報名
create or replace function public.redeem_queue_invite_tx(p_token text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me     uuid := public.current_member_id();
  v_org    uuid := public.current_org_id();
  v_l      record;
  v_q      record;
  v_status text;
  v_host   text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  select l.* into v_l from queue_invite_links l where l.token = p_token and l.org_id = v_org;
  if v_l.id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid', 'message', '這條邀請連結不存在，請朋友重新傳一次');
  end if;
  select display_name into v_host from members where id = v_l.created_by;

  -- 已經在這一房：成功，不重複報名（包含點了自己傳的）
  if exists (select 1 from match_queue_players
              where queue_id = v_l.queue_id and member_id = v_me and left_at is null) then
    return jsonb_build_object('ok', true, 'joined', false, 'already', true, 'queue_id', v_l.queue_id,
                              'message', '你已經在這一房了');
  end if;

  select q.id, q.status, q.expires_at into v_q from match_queues q where q.id = v_l.queue_id;
  if v_q.status <> 'waiting' or (v_q.expires_at is not null and v_q.expires_at < now()) then
    return jsonb_build_object('ok', false, 'reason', 'closed',
      'message', coalesce(v_host, '朋友') || ' 的這一房已經湊滿或取消了，可以到配桌頁找別的牌局');
  end if;

  /* 報名走跟一般報名同一支（類型上限、6 小時間隔、黑名單、好友練習賽互斥都在裡面）。
     那些擋牆是 raise 出來的 ⇒ 接住、原話回給前端，不讓整個 App 跳「系統錯誤」 */
  begin
    v_status := join_match_queue_tx(v_org, v_me, v_l.queue_id, 'link');
  exception when others then
    if sqlstate = '28000' then raise; end if;
    return jsonb_build_object('ok', false, 'reason', 'cannot_join', 'message', sqlerrm);
  end;
  update match_queue_players set invited_by = v_l.created_by
   where queue_id = v_l.queue_id and member_id = v_me and left_at is null and invited_by is null;

  return jsonb_build_object('ok', true, 'joined', true, 'status', v_status, 'queue_id', v_l.queue_id,
    'message', case when v_status = 'matched' then '成桌了！已加入 ' || coalesce(v_host, '朋友') || ' 的牌局'
                    else '已加入 ' || coalesce(v_host, '朋友') || ' 的配桌' end);
end $function$;

-- H. 授權
revoke execute on function public.create_queue_invite_link_tx(uuid) from public, anon;
revoke execute on function public.redeem_queue_invite_tx(text) from public, anon;
grant  execute on function public.create_queue_invite_link_tx(uuid) to authenticated;
grant  execute on function public.redeem_queue_invite_tx(text) to authenticated;
revoke execute on function public.send_table_invite_tx(uuid, uuid, uuid, uuid) from public, anon;
revoke execute on function public.respond_table_invite_tx(uuid, uuid, uuid, boolean) from public, anon;
grant  execute on function public.send_table_invite_tx(uuid, uuid, uuid, uuid) to authenticated;
grant  execute on function public.respond_table_invite_tx(uuid, uuid, uuid, boolean) to authenticated;

-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- ⚠ 這是「交易內」的狀態；跑完之後另外查一次線上才算數
-- ============================================================
with fn as (
  select p.proname, p.oid, p.prosecdef,
         exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE') as auth_ok,
         exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE') as anon_has,
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')) as public_has
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('send_table_invite_tx', 'respond_table_invite_tx', 'list_notifications_tx',
                       'create_queue_invite_link_tx', 'redeem_queue_invite_tx')
), checks as (
  select 1 k, '① match_queue_players.invited_by 有了' t,
         exists (select 1 from information_schema.columns where table_schema = 'public'
                  and table_name = 'match_queue_players' and column_name = 'invited_by') ok
  union all
  select 2, '② queue_invite_links：RLS 開著、0 policy、(房, 邀請人) 唯一',
         (select relrowsecurity from pg_class where oid = 'public.queue_invite_links'::regclass)
         and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'queue_invite_links')
         and exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'uq_queue_invite_links_owner')
  union all
  -- 五支各一個版本（沒有長出多載）
  select 3, '③ 五支函式各一個版本',
         (select count(*) from fn) = 5 and (select count(distinct proname) from fn) = 5
  union all
  select 4, '④ 五支都是 DEFINER',
         not exists (select 1 from fn where not prosecdef)
  union all
  -- 四支前端叫的：authenticated 明確有、anon 明確沒有、PUBLIC 沒有（硬規則 2.6／2.6b，兩邊都要看）
  select 5, '⑤ 前端四支：authenticated 有、anon 沒有、PUBLIC 沒有',
         (select count(*) from fn where proname <> 'list_notifications_tx' and auth_ok and not anon_has and not public_has) = 4
  union all
  -- 問「有沒有真的拿來查」，不是「有沒有提到」（硬規則 3.5）
  select 6, '⑥ 發揪桌：真的查了牌咖關係與房裡的人',
         (select pg_get_functiondef(oid) from fn where proname = 'send_table_invite_tx') ~ 'from mahjong_buddies b'
         and (select pg_get_functiondef(oid) from fn where proname = 'send_table_invite_tx') ~ 'queue_id = p_queue and member_id = p_inviter'
  union all
  select 7, '⑦ 回覆揪桌：真的記 done_at 與 invited_by',
         (select pg_get_functiondef(oid) from fn where proname = 'respond_table_invite_tx') ~ 'done_at = coalesce\(done_at'
         and (select pg_get_functiondef(oid) from fn where proname = 'respond_table_invite_tx') ~ 'set invited_by = v_from'
  union all
  select 8, '⑧ 通知清單：table_req 有自己的 invite_status 分支，牌咖與牌咖團的分支還在',
         (select pg_get_functiondef(oid) from fn where proname = 'list_notifications_tx') ~ 'from match_queue_players qp'
         and (select pg_get_functiondef(oid) from fn where proname = 'list_notifications_tx') ~ 'from buddy_invites bi'
         and (select pg_get_functiondef(oid) from fn where proname = 'list_notifications_tx') ~ 'from team_requests r'
  union all
  select 9, '⑨ 用連結報名：走 join_match_queue_tx、來源 link',
         (select pg_get_functiondef(oid) from fn where proname = 'redeem_queue_invite_tx') ~ 'join_match_queue_tx\(v_org, v_me, v_l\.queue_id, ''link''\)'
)
select string_agg(case when ok then '✅ ' else '🔴 ' end || t, E'\n' order by k)
       || E'\n' || (select count(*) filter (where ok) from checks) || ' / ' || (select count(*) from checks)
       as "配桌揪桌與邀請連結 · 驗證"
  from checks;
