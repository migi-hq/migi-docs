/* ============================================================
   會員隱藏帳號（取代「刪除帳號」）
   2026-09-25 · MIGI 咪吉麻將

   ── 使用者拍板（同日三次修正後的定案）────────────────────
   · **沒有人能刪除帳號**，會員 App 與總部**最多只能隱藏**
   · 隱藏之後**他自己打不開會員 App**，要回來**找櫃檯、由總部在後台恢復**
   · 隱藏後：排名消失、牌咖消失、曾經的互動紀錄變成問號頭像
   · 點數**保留**，到店裡照樣能用（POS 用會員 id 結帳，不經過他的登入身分）

   ── 🎯 做法：把「對外顯示的欄位」搬進保險箱，原位換成問號 ──────
   對別人顯示會員的函式有 20 多支（牌局紀錄、同桌、團員、配桌、邀請、平板…），
   逐支加判斷一定會漏一支，而漏的那一支會把名字照樣秀出去。
   ⇒ 隱藏時把 名字／頭像（三種來源）／自介／稱號／打法／作息／寶貝牌
     搬進 `member_hidden`，members 那一列換成「隱藏的會員」＋ avatar_source='hidden'。
     **那 20 多支一行都不用改，自動全部變成問號**；恢復時原封不動搬回來。
   ⚠ 手機、生日、LINE 綁定**留在原位**（對外本來就看不到）——
     手機要留著，客人到櫃檯時店員才找得到他；LINE 要留著，恢復之後才登得回來。

   ── 只有這幾處要另外「整個濾掉」（問號不夠，要消失）────────
   _season_rank_rows_core      排行榜、全國排名、賽季冠軍（三者共用這一支）
   get_season_leaderboard_tx   名人堂那一段自己 join 了 members
   list_buddies_tx             牌咖名單（關係列**不刪**，恢復後自動回來）
   list_recent_players_tx      「最近同桌、可以加牌咖」—— 加一個打不開 App 的人沒有意義
   send_buddy_invite_tx        擋掉對隱藏會員送邀請

   ── 讓他打不開 App：兩道 ─────────────────────────────
   current_member_id()     多一個條件 `hidden_at is null` ⇒ 所有會員端 RPC 認不出他
                           （就算他手上還有一張沒過期的 session 也一樣）
   get_member_by_line_tx   回 `hidden: true` ⇒ App 開機看到就畫「帳號已隱藏」

   ── 會擋下的四種（回 ok:false ＋ 一句人話，不寫入任何東西）──
   is_staff / in_session / queue_matched / leader_must_transfer
   ⚠ **不擋「還有點數」**：隱藏不動錢包，點數到店裡照樣能用。

   ── 會自動收掉的（恢復時**不會**回來）──────────────────
   等待中的配桌、團（只剩自己的團解散）、待審的入團申請與邀請、
   之後的包桌預約、還沒回的牌咖邀請。
   ⚠ 牌咖、封鎖、按讚、通知、成就、段位都**保留不動**，恢復後原樣回來。

   ── 權限 ──────────────────────────────────────────────
   hide_my_account_tx()              authenticated；身分一律 current_member_id()，不收任何 id
   admin_hide_member_tx(id, 原因)    authenticated ＋ can('member.hide')（總部）
   admin_unhide_member_tx(id, 原因)  同上 —— **恢復只有總部能做**
   admin_find_members_tx(手機)       同上；隱藏中的人回保險箱裡的真名，店員才認得出來
   兩支 _core                        只有 owner 叫得動
   ============================================================ */

-- ── ① 欄位與約束 ──
alter table public.members add column if not exists hidden_at timestamptz;
comment on column public.members.hidden_at is
  '帳號被隱藏的時間。有值＝他打不開會員 App、別人看到的是問號頭像；對外顯示的欄位暫存在 member_hidden。null＝正常。';

alter table public.members drop constraint if exists members_avatar_source_chk;
alter table public.members add constraint members_avatar_source_chk
  check (avatar_source = any (array['bear', 'photo', 'line', 'hidden']));


-- ── ② 保險箱與紀錄 ──
create table if not exists public.member_hidden (
  member_id         uuid primary key references public.members(id),
  org_id            uuid not null,
  display_name      text not null,
  avatar_source     text not null,
  avatar_bear       text,
  avatar_url        text,
  avatar_photo_path text,
  about             text,
  title             text,
  style             jsonb,
  baby_tile         jsonb,
  sched             text,
  hidden_at         timestamptz not null default now()
);
comment on table public.member_hidden is
  '隱藏中的會員原本對外顯示的欄位。隱藏時搬進來、恢復時搬回去並刪掉這一列。';
alter table public.member_hidden enable row level security;   -- 0 條 policy：只有 DEFINER 讀得到

create table if not exists public.member_hide_log (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  member_id   uuid not null references public.members(id),
  action      text not null check (action in ('hide', 'unhide')),
  source      text not null check (source in ('self', 'hq')),
  by_staff_id uuid references public.staff(id),
  reason      text,
  at          timestamptz not null default now()
);
comment on table public.member_hide_log is '隱藏與恢復的紀錄（誰、何時、誰按的、為什麼）。只增不改。';
alter table public.member_hide_log enable row level security;  -- 0 條 policy


-- ── ③ 核心：隱藏 ──
create or replace function public._member_hide_core(
  p_member uuid, p_source text, p_staff uuid, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_m members%rowtype;
  r   record;
begin
  select * into v_m from members
   where id = p_member and deleted_at is null
     for update;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個會員');
  end if;
  if v_m.hidden_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_hidden', 'message', '這個帳號已經是隱藏狀態');
  end if;

  /* 擋牆（全部在寫入之前）*/
  if exists (select 1 from staff s where s.member_id = p_member and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'is_staff',
      'message', '這個帳號是店員，請總部先在「店員管理」移除店員身分');
  end if;
  if exists (select 1 from session_players sp
               join table_sessions ts on ts.id = sp.session_id
              where sp.member_id = p_member and sp.left_at is null
                and ts.status = 'open' and ts.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'in_session',
      'message', '正在牌桌上，收桌之後才能隱藏帳號');
  end if;
  /* ⚠ 只看 matched 不看 seated：帶到桌之後房會一直停在 seated，
     看它的話打完的每一局都會永遠擋住。桌上有沒有人由上一格判斷。 */
  if exists (select 1 from match_queue_players qp
               join match_queues q on q.id = qp.queue_id
              where qp.member_id = p_member and qp.left_at is null and q.status = 'matched') then
    return jsonb_build_object('ok', false, 'reason', 'queue_matched',
      'message', '配桌已經成桌，這一局結束之後才能隱藏帳號');
  end if;
  if exists (select 1 from team_members tm
              where tm.member_id = p_member and tm.left_at is null and tm.role = 'leader'
                and exists (select 1 from team_members o
                             where o.team_id = tm.team_id and o.left_at is null
                               and o.member_id <> p_member)) then
    return jsonb_build_object('ok', false, 'reason', 'leader_must_transfer',
      'message', '你是牌咖團團長，請先把團長轉給其他團員');
  end if;

  /* 收掉「進行中」的東西 —— 能用既有函式的就用既有的（不寫第二份規則）*/
  for r in select q.id from match_queue_players qp
             join match_queues q on q.id = qp.queue_id
            where qp.member_id = p_member and qp.left_at is null and q.status = 'waiting'
  loop
    perform public.leave_match_queue_tx(v_m.org_id, p_member, r.id, '帳號隱藏');
  end loop;
  for r in select tm.team_id from team_members tm
            where tm.member_id = p_member and tm.left_at is null and tm.role = 'leader'
  loop
    perform public._team_disband(r.team_id, p_member);   -- 走到這裡一定是「團裡只剩自己」
  end loop;
  update team_members set left_at = now(), left_reason = 'quit'
   where member_id = p_member and left_at is null;
  update team_requests set status = 'cancelled', decided_at = now()
   where status = 'pending' and (member_id = p_member or created_by = p_member);
  update bookings set status = 'cancelled', cancelled_reason = '會員隱藏帳號', updated_at = now()
   where member_id = p_member and status = 'booked';
  delete from buddy_invites
   where status = 'pending' and (inviter_id = p_member or invitee_id = p_member);

  /* 對外顯示的欄位搬進保險箱，原位換成問號 */
  insert into member_hidden (member_id, org_id, display_name, avatar_source, avatar_bear,
                             avatar_url, avatar_photo_path, about, title, style, baby_tile, sched)
  values (v_m.id, v_m.org_id, v_m.display_name, v_m.avatar_source, v_m.avatar_bear,
          v_m.avatar_url, v_m.avatar_photo_path, v_m.about, v_m.title, v_m.style, v_m.baby_tile, v_m.sched);

  update members set
    display_name = '隱藏的會員',
    avatar_source = 'hidden', avatar_bear = null, avatar_url = null, avatar_photo_path = null,
    about = null, title = '新手上路', style = null, baby_tile = null, sched = null,
    hidden_at = now()
  where id = p_member;

  insert into member_hide_log (org_id, member_id, action, source, by_staff_id, reason)
  values (v_m.org_id, p_member, 'hide', p_source, p_staff, p_reason);

  return jsonb_build_object('ok', true, 'member_id', p_member);
end $function$;

revoke execute on function public._member_hide_core(uuid, text, uuid, text) from public;
revoke execute on function public._member_hide_core(uuid, text, uuid, text) from anon, authenticated, service_role;


-- ── ④ 核心：恢復 ──
create or replace function public._member_unhide_core(p_member uuid, p_staff uuid, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_h member_hidden%rowtype;
  v_at timestamptz;
begin
  select hidden_at into v_at from members where id = p_member and deleted_at is null for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個會員');
  end if;
  if v_at is null then
    return jsonb_build_object('ok', false, 'reason', 'not_hidden', 'message', '這個帳號沒有被隱藏');
  end if;
  select * into v_h from member_hidden where member_id = p_member;
  if v_h.member_id is null then
    /* 不應該發生（兩張表同一個交易寫的）—— 發生了就大聲說，不要把問號當成真名搬回去 */
    return jsonb_build_object('ok', false, 'reason', 'vault_missing',
      'message', '找不到這個帳號原本的資料，請聯絡系統管理員');
  end if;

  update members set
    display_name = v_h.display_name,
    avatar_source = v_h.avatar_source, avatar_bear = v_h.avatar_bear,
    avatar_url = v_h.avatar_url, avatar_photo_path = v_h.avatar_photo_path,
    about = v_h.about, title = v_h.title, style = v_h.style,
    baby_tile = v_h.baby_tile, sched = v_h.sched,
    hidden_at = null
  where id = p_member;
  delete from member_hidden where member_id = p_member;

  insert into member_hide_log (org_id, member_id, action, source, by_staff_id, reason)
  values (v_h.org_id, p_member, 'unhide', 'hq', p_staff, p_reason);

  return jsonb_build_object('ok', true, 'member_id', p_member);
end $function$;

revoke execute on function public._member_unhide_core(uuid, uuid, text) from public;
revoke execute on function public._member_unhide_core(uuid, uuid, text) from anon, authenticated, service_role;


-- ── ⑤ 入口 ──
create or replace function public.hide_my_account_tx()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_me uuid := public.current_member_id();
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '登入狀態已過期，請關閉 MIGI 再重新開啟');
  end if;
  return public._member_hide_core(v_me, 'self', null, null);
end $function$;
revoke execute on function public.hide_my_account_tx() from public;
revoke execute on function public.hide_my_account_tx() from anon;
grant  execute on function public.hide_my_account_tx() to authenticated;

create or replace function public.admin_hide_member_tx(p_member_id uuid, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not public.can('member.hide') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以隱藏會員帳號');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required', 'message', '請寫下原因（例：客人來電要求）');
  end if;
  return public._member_hide_core(p_member_id, 'hq',
           (select staff_id from public.current_staff()), btrim(p_reason));
end $function$;
revoke execute on function public.admin_hide_member_tx(uuid, text) from public;
revoke execute on function public.admin_hide_member_tx(uuid, text) from anon;
grant  execute on function public.admin_hide_member_tx(uuid, text) to authenticated;

create or replace function public.admin_unhide_member_tx(p_member_id uuid, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not public.can('member.hide') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以恢復會員帳號');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required', 'message', '請寫下原因（例：客人到櫃檯要求恢復）');
  end if;
  return public._member_unhide_core(p_member_id,
           (select staff_id from public.current_staff()), btrim(p_reason));
end $function$;
revoke execute on function public.admin_unhide_member_tx(uuid, text) from public;
revoke execute on function public.admin_unhide_member_tx(uuid, text) from anon;
grant  execute on function public.admin_unhide_member_tx(uuid, text) to authenticated;

/* 後台找人。🔴 隱藏中的人 members 上的名字是「隱藏的會員」，
   總部要恢復時得認得出是誰 ⇒ 回保險箱裡的真名。所以一定要走 RPC（保險箱 0 policy）。 */
create or replace function public.admin_find_members_tx(p_phone text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_p text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if not public.can('member.hide') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以查詢');
  end if;
  if length(v_p) < 4 then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  end if;
  /* ⚠ limit 要放在子查詢裡 —— 寫在 jsonb_agg 那一層的話它限制的是
     「聚合完的那一列」，等於沒限制。 */
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', x.id,
             'name', x.name,
             'phone', x.phone,
             'line_bound', x.line_bound,
             'created_at', x.created_at,
             'hidden_at', x.hidden_at,
             'hidden_source', (select l.source from member_hide_log l
                                where l.member_id = x.id and l.action = 'hide'
                                order by l.at desc limit 1),
             'hidden_reason', (select l.reason from member_hide_log l
                                where l.member_id = x.id and l.action = 'hide'
                                order by l.at desc limit 1))
           order by x.created_at)
      from (
        select m.id, coalesce(h.display_name, m.display_name) as name, m.phone,
               m.line_user_id is not null as line_bound, m.created_at, m.hidden_at
          from members m
          left join member_hidden h on h.member_id = m.id
         where m.org_id = (select s.org_id from staff s
                            where s.id = (select staff_id from public.current_staff()))
           and m.deleted_at is null
           and m.phone like '%' || v_p || '%'
         order by m.created_at
         limit 20
      ) x), '[]'::jsonb));
end $function$;
revoke execute on function public.admin_find_members_tx(text) from public;
revoke execute on function public.admin_find_members_tx(text) from anon;
grant  execute on function public.admin_find_members_tx(text) to authenticated;


-- ── ⑥ 讓他打不開 App ──
create or replace function public.current_member_id()
 returns uuid
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  /* ⚠ **完全沒有 org 過濾，而那是必然的不是疏漏** ——
     org 是從 member 查出來的，不可能先用 org 縮小範圍（雞生蛋）。
     🔴 所以 `uq_members_line_user`（全域唯一）是**承重牆**：
       只有它能保證「我是誰」有唯一答案。
     ⚠ 這裡有 `limit 1` ⇒ 重複時**不會報錯，會靜默選錯**。
     🆕 2026-09-25：**隱藏中的會員認不出來** ⇒ 所有會員端 RPC 都擋住他，
       就算他手上還有一張沒過期的 session。POS 用會員 id 結帳，不受影響。 */
  select m.id from members m
   where m.line_user_id = public.migi_jwt_line_id()
     and m.deleted_at is null
     and m.hidden_at is null
   limit 1;
$function$;

create or replace function public.get_member_by_line_tx(p_org_id uuid, p_line_user_id text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_m members%rowtype;
begin
  if p_org_id is null or coalesce(trim(p_line_user_id), '') = '' then
    return jsonb_build_object('found', false);
  end if;

  select * into v_m from members
   where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null
   limit 1;

  if v_m.id is null then
    return jsonb_build_object('found', false);
  end if;

  /* 🆕 2026-09-25：隱藏中 ⇒ 只回「找到了、但被隱藏」，其他什麼都不給。
     ⚠ 一定要是 found:true —— 回 found:false 的話 App 會把他丟進註冊，
       而註冊會用同一個 LINE 找回這個帳號，繞一圈又回到這裡。 */
  if v_m.hidden_at is not null then
    return jsonb_build_object('found', true, 'hidden', true, 'member_id', v_m.id);
  end if;

  return jsonb_build_object(
    'found', true,
    'hidden', false,
    'member_id', v_m.id,
    'display_name', v_m.display_name,
    /* 🎯 遮罩顯示：`0910***736`。
       客人認得出是不是自己的號碼，但這串**打不通** ——
       所以就算 member_id 哪天外流，也不會連帶交出一支可聯絡的門號。 */
    'phone_masked', case when v_m.phone is null then null
                         else left(v_m.phone, 4) || '***' || right(v_m.phone, 3) end,
    'phone_verified', v_m.phone_verified_at is not null);
end $function$;


-- ── ⑦ 排名消失（排行榜、全國排名、賽季冠軍共用這一支）──
create or replace function public._season_rank_rows_core(
  p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_include_test boolean)
 returns table(member_id uuid, rating integer, rank_no integer, games integer)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  /* 母體：這個視窗內至少打過一場「已結算」牌局的會員。
     🔴 **不能拿全部會員排** —— `members.rating` 是 `NOT NULL DEFAULT 0`，
       沒打過的人也有 0 分，那樣分母會變成「開過帳號的人數」。
     ⚠ `p_to` 為 null = 沒有上限（現場排名用）。結算時要給那一季的
       `ends_at` —— 否則**結算晚了幾天，那幾天的牌局會被算進上一季**。
     ⚠ 測試帳號排不排由呼叫端決定（`p_include_test`），不要在這裡判斷上線了沒 ——
       結算與顯示要的答案不一樣。
     🆕 2026-09-25：**隱藏中的會員不排**（使用者：隱藏後排名會消失）。
       ⚠ 這一支也是賽季結算用的 ⇒ 隱藏中的人不會拿到冠軍；恢復之後自然回到榜上。 */
  with played as (
    select sp.member_id, count(*) as games
      from session_players sp
      join table_sessions s   on s.id   = sp.session_id
      join members         mem on mem.id = sp.member_id
     where sp.org_id = p_org_id
       and s.org_id  = p_org_id
       and s.deleted_at is null
       and s.status  = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and (p_from is null or sp.settled_at >= p_from)
       and (p_to   is null or sp.settled_at <  p_to)
       and mem.deleted_at is null
       and mem.hidden_at is null
       and (p_include_test or mem.is_test = false)
     group by sp.member_id
  )
  /* 同分時用 `created_at` —— **要有一個穩定的第二鍵**，
     不然同分的人每次查到的名次順序都不一樣。 */
  select p.member_id, mem.rating,
         rank() over (order by mem.rating desc, mem.created_at)::int,
         p.games::int
    from played p
    join members mem on mem.id = p.member_id
$function$;

create or replace function public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer default 10)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_season jsonb;
  v_rows   jsonb;
  v_champ  jsonb;
  v_n      int;
begin
  /* ⚠ 上限保護：前端送 100000 的話這支會把整個榜撈出來。
     `least` 而不是 raise —— 那是筆誤不是攻擊，靜靜收斂即可。 */
  v_n := greatest(1, least(coalesce(p_limit, 10), 100));

  v_season := public.current_season_tx(p_org_id);

  /* 🔴 沒有進行中的賽季時 **不要回 `ok:false`** ——
     那是**正常狀態**（兩季之間的空檔），不是錯誤。
     回空清單讓前端畫空狀態就好。 */
  if v_season is null then
    return jsonb_build_object('ok', true, 'season', null,
                              'rows', '[]'::jsonb, 'champions', '[]'::jsonb);
  end if;

  /* 本季排行。`p_to` 給 null = 沒有上限（現場排名），
     與 `get_my_stats_tx` 算「我在全國第幾」時同一個用法。 */
  select coalesce(jsonb_agg(x order by x.rank_no), '[]'::jsonb) into v_rows
    from (
      select r.rank_no, r.rating, r.games,
             m.display_name        as name,
             public.rank_from_rating(r.rating) as rank_label
             -- 🔴 **沒有 member_id**，理由見檔頭
        from public.season_rank_rows_display_tx(
               p_org_id, (v_season ->> 'starts_at')::timestamptz, null) r
        join members m on m.id = r.member_id
       order by r.rank_no
       limit v_n
    ) x;

  /* 名人堂：歷代雀神熊。
     ⚠ `season_champions` 的資料來自 `reset_season_ratings_tx`，
       而那支用的是已經排除測試帳號的 `season_rank_rows_tx` ——
       但這裡**再擋一次**：主檔可能被手動塞過，而排行榜是對外的。
     🆕 2026-09-25：隱藏中的冠軍也不列（冠軍紀錄保留，恢復之後回來）。 */
  select coalesce(jsonb_agg(x order by x.awarded_at desc), '[]'::jsonb) into v_champ
    from (
      select c.season, c.rating, c.awarded_at,
             s.label               as season_label,
             m.display_name        as name,
             public.rank_from_rating(c.rating) as rank_label
        from season_champions c
        join members m on m.id = c.member_id
                      and m.deleted_at is null
                      and m.hidden_at is null
                      and m.is_test = false
        left join rank_seasons s on s.org_id = c.org_id and s.code = c.season
       where c.org_id = p_org_id
       order by c.awarded_at desc
       limit 20
    ) x;

  return jsonb_build_object(
    'ok', true, 'season', v_season, 'rows', v_rows, 'champions', v_champ);
end;
$function$;


-- ── ⑧ 牌咖消失 ──
create or replace function public.list_buddies_tx(p_org_id uuid, p_member uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.buddy_id, 'nickname', m.display_name,
      'rank', m.rank, 'title', m.title, 'likes_count', m.likes_count,
      'avatar_url', m.avatar_url, 'co_play_count', b.co_play_count,
      'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'avatar_bear', m.avatar_bear,
      'linked_at', b.linked_at,
      'last_played_at', x.last_at,
      /* ★ 2026-09-01：常一起打。
         🔴 回**結構**不回句子（`{weekday, slot, n}`）——
           「週五晚上」怎麼組字是顯示規則，不該住在資料庫裡
           （同 `get_my_games_tx` 的 `rounds` 回整數不回「2 將」）。 */
      'play_pattern', x.pattern
    ) order by b.linked_at desc)
    from mahjong_buddies b
    /* 🆕 2026-09-25：隱藏中的牌咖不列。**關係列不刪**，恢復之後自動回來。 */
    join members m on m.id = b.buddy_id and m.deleted_at is null and m.hidden_at is null
    left join lateral (
      with shared as (
        /* 你們兩個都坐過、而且已收桌的場次。
           ⚠ 用開打時間（`activated_at`）不是收桌時間 ——
             凌晨兩點收桌的晚場，問的是「幾點開始打」。 */
        select coalesce(s.activated_at, s.started_at, s.ended_at) as at
        from session_players me
        join session_players op
          on op.session_id = me.session_id and op.member_id = b.buddy_id
        join table_sessions s
          on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
       where me.member_id = p_member and me.org_id = p_org_id
      ), tagged as (
        select extract(dow from (at at time zone 'Asia/Taipei'))::int as wd,
               public.migi_slot_of(at) as slot
          from shared where at is not null
      ), tot as (select count(*) as n from tagged),
      /* 第一層：星期＋時段的眾數 */
      best_ws as (
        select wd, slot, count(*) as n from tagged
         group by wd, slot order by count(*) desc, slot, wd limit 1
      ),
      /* 第二層：只有時段的眾數（星期湊不到 2 次時用） */
      best_s as (
        select slot, count(*) as n from tagged
         group by slot order by count(*) desc, slot limit 1
      )
      select
        (select max(at) from shared) as last_at,
        case
          /* 🔴 「常」的兩個門檻，缺一不可：
             ① **總同桌 ≥ 3 場** —— 打過一次就說「常」是假的
             ② **眾數要過半**（`n × 2 > 總數`）—— 不是「出現 ≥2 次」

             ⚠ 我第一版寫 `>= 2`，它會讓「週六 2 次／週日 2 次」
               宣稱「常一起打 **週六**晚上」—— 一半的場次不是週六。
               **「最多的那一個」不等於「常」**，那是這一格最容易寫錯的地方。 */
          when (select n from tot) < 3 then null
          when (select n from best_ws) * 2 > (select n from tot) then
            jsonb_build_object('weekday', (select wd from best_ws),
                               'slot',    (select slot from best_ws),
                               'n',       (select n from best_ws))
          when (select n from best_s) * 2 > (select n from tot) then
            /* 退化：星期分散但時段集中 → 只講時段。
               🎯 一對固定週末打的人週六週日各半，星期永遠過不了半，
                 但「晚上」是真的 —— 少了這一層他們永遠看到 `—`。 */
            jsonb_build_object('weekday', null,
                               'slot', (select slot from best_s),
                               'n',    (select n from best_s))
          else null      -- 兩層都過不了半 ⇒ 真的沒有規律
        end as pattern
    ) x on true
    where b.member_id = p_member and b.org_id = p_org_id and b.deleted_at is null
  ), '[]'::jsonb);
end $function$;

create or replace function public.list_recent_players_tx(p_org_id uuid, p_member uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'id', other.member_id, 'nickname', mm.display_name, 'rank', mm.rank,
      'avatar_url', mm.avatar_url, 'avatar_bear', mm.avatar_bear, 'avatar_source', mm.avatar_source, 'avatar_photo_path', mm.avatar_photo_path
    ))
    from session_players sp
    join session_players other on other.session_id = sp.session_id and other.member_id <> sp.member_id
    /* 🆕 2026-09-25：隱藏中的人不列 —— 這一塊是「加牌咖」的入口，
       加一個打不開 App 的人沒有意義（send_buddy_invite_tx 也會擋）。 */
    join members mm on mm.id = other.member_id and mm.deleted_at is null and mm.hidden_at is null
    where sp.member_id = p_member and sp.org_id = p_org_id
      and sp.created_at > now() - interval '1 day'
      and not exists (select 1 from mahjong_buddies b
                      where b.member_id = p_member and b.buddy_id = other.member_id and b.deleted_at is null)
      and not exists (select 1 from buddy_invites i
                      where i.inviter_id = p_member and i.invitee_id = other.member_id and i.status = 'pending')
  ), '[]'::jsonb);
end $function$;

create or replace function public.send_buddy_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_name text;
begin
  if p_inviter = p_invitee then raise exception '不能加自己'; end if;
  /* 🆕 2026-09-25：隱藏中的會員收不到邀請（他打不開 App，邀請只會一直掛著） */
  if exists (select 1 from members where id = p_invitee and hidden_at is not null) then
    raise exception '這位會員目前無法加為牌咖';
  end if;
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
end $function$;


/* ── 驗證（結構；行為另跑 sql/checks/2026-09-25_驗會員隱藏帳號.sql）
   🔴 不用 raise：這一份要留下 DDL（硬規則 1.8）── */
do $$
declare
  v_msg text := '';
  f text; v_n int;
begin
  -- ① 新函式各一個版本、都是 DEFINER
  foreach f in array array['_member_hide_core', '_member_unhide_core', 'hide_my_account_tx',
                           'admin_hide_member_tx', 'admin_unhide_member_tx', 'admin_find_members_tx'] loop
    select count(*) into v_n from pg_proc
     where pronamespace = 'public'::regnamespace and proname = f and prosecdef;
    v_msg := v_msg || case when v_n = 1 then '✅ ' else '🔴 ' end || '① ' || f || ' 版本數 ' || v_n || E'\n';
  end loop;

  -- ② 改過的七支，每一支都真的帶上了新條件（掃「有沒有拿來判斷」而不是有沒有提到）
  foreach f in array array['current_member_id', '_season_rank_rows_core', 'get_season_leaderboard_tx',
                           'list_buddies_tx', 'list_recent_players_tx', 'send_buddy_invite_tx'] loop
    select count(*) into v_n from pg_proc
     where pronamespace = 'public'::regnamespace and proname = f
       and pg_get_functiondef(oid) ~ '(and|where)\s+\w+\.hidden_at\s+is\s+(not\s+)?null|where\s+id\s*=\s*p_invitee\s+and\s+hidden_at';
    v_msg := v_msg || case when v_n = 1 then '✅ ' else '🔴 ' end || '② ' || f || ' 有隱藏的條件' || E'\n';
  end loop;
  v_msg := v_msg || case when pg_get_functiondef('public.get_member_by_line_tx(uuid,text)'::regprocedure) ~ '''hidden'', true'
    then '✅ ② get_member_by_line_tx 會回 hidden' else '🔴 ② get_member_by_line_tx 沒回 hidden' end || E'\n';

  -- ③ 授權（兩個方向）
  v_msg := v_msg || case when
      not has_function_privilege('authenticated', 'public._member_hide_core(uuid,text,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public._member_hide_core(uuid,text,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public._member_unhide_core(uuid,uuid,text)', 'execute')
    then '✅ ③ 兩支核心前端叫不動' else '🔴 ③ 核心函式授權太寬' end || E'\n';
  v_msg := v_msg || case when
      has_function_privilege('authenticated', 'public.hide_my_account_tx()', 'execute')
      and not has_function_privilege('anon', 'public.hide_my_account_tx()', 'execute')
      and has_function_privilege('authenticated', 'public.admin_unhide_member_tx(uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.admin_unhide_member_tx(uuid,text)', 'execute')
    then '✅ ③ 入口：authenticated 可、anon 不可' else '🔴 ③ 入口授權不對' end || E'\n';
  -- 負對照：刪除版的函式一支都沒有（今天改成只能隱藏）
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('_member_delete_core', 'delete_my_account_tx', 'admin_delete_member_tx');
  v_msg := v_msg || case when v_n = 0 then '✅ ③ 沒有任何刪除帳號的函式' else '🔴 ③ 還有 ' || v_n || ' 支刪除帳號的函式' end || E'\n';

  -- ④ 約束與兩張表（RLS 開、0 policy）
  v_msg := v_msg || case when pg_get_constraintdef((select oid from pg_constraint
        where conname = 'members_avatar_source_chk')) like '%hidden%'
    then '✅ ④ avatar_source 允許 hidden' else '🔴 ④ avatar_source 約束沒改到' end || E'\n';
  select count(*) into v_n from pg_policies where schemaname = 'public'
     and tablename in ('member_hidden', 'member_hide_log');
  v_msg := v_msg || case when v_n = 0
      and (select relrowsecurity from pg_class where oid = 'public.member_hidden'::regclass)
      and (select relrowsecurity from pg_class where oid = 'public.member_hide_log'::regclass)
    then '✅ ④ 保險箱與紀錄表：RLS 開、0 條 policy' else '🔴 ④ 保險箱或紀錄表的 RLS 不對' end || E'\n';

  -- ⑤ 正對照：現在沒有任何人被隱藏時，current_member_id 對一般會員照常認得出來
  perform set_config('request.jwt.claims', '{"sub":"TEST-04","role":"authenticated"}', true);
  v_msg := v_msg || case when public.current_member_id() is not null
    then '✅ ⑤ 一般會員的身分照常解析（新條件沒有誤擋）' else '🔴 ⑤ 測試04 解析不到身分 —— 新條件擋錯人了' end;

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
