-- ============================================================
-- 2026-10-28 好友練習賽 · 第 ① 批：地基
-- 規格：docs/03-會員App與社交/好友練習賽.md（第二～四節）
--
-- 這一份做的事
--   A. 每個機構一間虛擬門市「好友練習賽」（stores.is_virtual），一場用一張虛擬桌
--      ⇒ 計分板 17 支用「桌」找場次的函式一行都不用改；虛擬桌不會有平板 ⇒ 只能用手機
--   B. table_sessions.mode 多一個值 friendly
--   C. app_notifications 多三種類型：friendly_ok（成桌）／friendly_invite（牌咖邀請）／friendly_out（取消、沒湊滿）
--      ⚠ 三種都**不在** LINE 推播白名單裡（_push_enqueue 只推 table_ok、settle）⇒ 成桌不推 LINE（使用者 10-28）
--   D. 兩張新表：friendly_games（一場）、friendly_game_players（誰在這一場）
--   E. 前端叫的六支：開一場／用邀請連結加入／離開／取消／邀牌咖／我的好友練習賽
--   F. 四人到齊那一刻開打：挑一張空的虛擬桌、建場次、四列 session_players（座位由手機定）
--   G. 互斥（後端擋）：_check_join_conflict 加掃好友練習賽；好友練習賽這邊掃配桌與正在打的正式段位賽
--   H. 排程：過了最晚開打時間還沒湊滿 ⇒ 取消並通知
--
-- ⚠ 這一份**不含**結算（第 ② 批）：在第 ② 批跑之前不要開放前端入口 ——
--   打完的好友練習賽會照正式段位賽的規則結算（算段位分、發成就）。
--   今天沒有任何畫面叫得到這幾支，所以先跑這一份是安全的。
--
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格。驗證段不 raise（硬規則 1.8）。
-- 行為測試另外跑：sql/checks/2026-10-28_驗好友練習賽地基.sql
-- ============================================================

-- ── A. 虛擬門市 ───────────────────────────────────────────
alter table public.stores add column if not exists is_virtual boolean not null default false;
comment on column public.stores.is_virtual is
  '好友練習賽用的虛擬門市（每個機構一間）。底下的桌是系統自己建的虛擬桌，一場好友練習賽用一張。
   所有門市清單都要藏它；判斷一律看這一欄，不看店名或代碼。2026-10-28';

-- is_active = false：今天所有「列出營業中的門市」的地方自然看不到它（第 ② 批再逐支明確排除）
insert into public.stores (org_id, name, code, is_active, is_virtual, is_test, note)
select o.id, '好友練習賽', 'FRIENDLY', false, true, false, '系統建立，請勿修改或刪除（好友練習賽的虛擬桌放在這裡）'
  from public.orgs o
 where not exists (select 1 from public.stores s where s.org_id = o.id and s.is_virtual)
on conflict do nothing;

-- ── B. 場次多一種模式 ─────────────────────────────────────
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.table_sessions'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ~ '\mmode\M'
  loop
    execute format('alter table public.table_sessions drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.table_sessions add constraint table_sessions_mode_check
  check (mode = any (array['matched'::text, 'private'::text, 'friendly'::text]));

-- ── C. 通知多三種類型 ─────────────────────────────────────
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.app_notifications'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ~ '\mtype\M'
  loop
    execute format('alter table public.app_notifications drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.app_notifications add constraint app_notifications_type_check
  check (type = any (array['settle','buddy_req','buddy_ok','table_req','table_ok','system','table_expired',
                           'team_req','team_ok','team_out','friendly_ok','friendly_invite','friendly_out']::text[]));

-- ── D. 兩張新表 ───────────────────────────────────────────
create table if not exists public.friendly_games (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.orgs(id) on delete restrict,
  opened_by      uuid not null references public.members(id) on delete restrict,
  stake_level_id uuid not null references public.stake_levels(id) on delete restrict,
  game_type      text not null check (game_type in ('台麻','美麻')),
  flower         text not null check (flower in ('無花','有花')),
  rounds         smallint not null check (rounds between 1 and 3),
  prefs          jsonb not null default '{}'::jsonb,
  play_at        timestamptz not null,
  status         text not null default 'waiting' check (status in ('waiting','playing','finished','cancelled')),
  cancel_reason  text check (cancel_reason is null or cancel_reason in ('host','expired','stale')),
  invite_token   text not null unique,
  session_id     uuid references public.table_sessions(id) on delete restrict,
  started_at     timestamptz,
  ended_at       timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table public.friendly_games is
  '好友練習賽（2026-10-28）。waiting 等朋友 → playing 四人到齊、已建場次 → finished 打完／cancelled。
   牌局本身在 table_sessions（mode = friendly、虛擬門市的虛擬桌），session_id 指過去。
   invite_token 給 LINE 分享卡片用：那一場還在 waiting 就能一直用到滿。';

create table if not exists public.friendly_game_players (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.orgs(id) on delete restrict,
  game_id      uuid not null references public.friendly_games(id) on delete restrict,
  member_id    uuid not null references public.members(id) on delete restrict,
  join_source  text not null check (join_source in ('open','link','buddy')),
  joined_at    timestamptz not null default now(),
  left_at      timestamptz,
  leave_reason text check (leave_reason is null or leave_reason in ('quit','cancelled','expired'))
);
create unique index if not exists uq_friendly_player_active
  on public.friendly_game_players (game_id, member_id) where left_at is null;
create index if not exists idx_friendly_player_member
  on public.friendly_game_players (member_id) where left_at is null;
create index if not exists idx_friendly_games_status
  on public.friendly_games (org_id, status, play_at);

alter table public.friendly_games        enable row level security;
alter table public.friendly_game_players enable row level security;
-- 0 條 policy：只有下面那幾支 DEFINER 函式進得去（同 match_queues）

-- ── E～H. 函式 ────────────────────────────────────────────

-- 這個人現在在哪一場好友練習賽（等朋友或在打）；沒有就是 null
create or replace function public._friendly_active_game(p_member uuid)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select g.id
    from friendly_game_players fp join friendly_games g on g.id = fp.game_id
   where fp.member_id = p_member and fp.left_at is null and g.status in ('waiting', 'playing')
   order by g.created_at desc limit 1;
$$;

-- 這個人現在是不是在配桌（等人／已成桌／已帶到桌且那桌還開著）或正在打正式段位賽
create or replace function public._friendly_in_match(p_org uuid, p_member uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
           select 1 from match_queue_players qp join match_queues q on q.id = qp.queue_id
            where qp.member_id = p_member and qp.left_at is null and q.org_id = p_org
              and (q.status in ('waiting', 'matched')
                   or (q.status = 'seated' and public.migi_seat_is_live(q.matched_session_id))))
      or exists (
           select 1 from session_players sp join table_sessions ts on ts.id = sp.session_id
            where sp.member_id = p_member and sp.left_at is null
              and ts.status = 'open' and ts.deleted_at is null and ts.mode <> 'friendly');
$$;

-- 一場好友練習賽給前端的樣子（玩家形狀跟配桌進度卡 get_my_active_queue_tx 一樣，座位列可以直接用）
create or replace function public._friendly_view(p_game uuid, p_member uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'id', g.id, 'status', g.status, 'is_host', (g.opened_by = p_member),
    'game_type', g.game_type, 'flower', g.flower, 'rounds', g.rounds, 'prefs', g.prefs,
    'play_at', g.play_at, 'started_at', g.started_at,
    'stake_level_id', g.stake_level_id, 'stake_label', sl.label, 'is_hygiene', sl.is_hygiene,
    -- 邀請連結只給這一場裡的人
    'invite_token', case when exists (select 1 from friendly_game_players x
                                       where x.game_id = g.id and x.member_id = p_member and x.left_at is null)
                         then g.invite_token end,
    'host', (select jsonb_build_object('member_id', h.id, 'nickname', h.display_name)
               from members h where h.id = g.opened_by),
    'players', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'member_id', m.id, 'nickname', m.display_name, 'rank', m.rank,
               'avatar_url', m.avatar_url, 'avatar_source', m.avatar_source,
               'avatar_photo_path', m.avatar_photo_path, 'avatar_bear', m.avatar_bear,
               'joined_at', fp.joined_at, 'is_host', (m.id = g.opened_by))
             order by (m.id = g.opened_by) desc, fp.joined_at), '[]'::jsonb)
        from friendly_game_players fp join members m on m.id = fp.member_id
       where fp.game_id = g.id and fp.left_at is null),
    'player_count', (select count(*) from friendly_game_players
                      where game_id = g.id and left_at is null),
    -- 正在打：打到第幾將第幾局（咔啦碰、分紅不算一局）
    'live', case when g.status = 'playing' then (
      select jsonb_build_object(
               'round_no', r.round_no,
               'hand_no', 1 + (select count(*) from hands h
                                where h.round_id = r.id and h.status = 'confirmed'
                                  and h.result not in ('kala', 'bonus')))
        from session_rounds r
       where r.session_id = g.session_id
       order by r.round_no desc limit 1) end
  )
  from friendly_games g
  left join stake_levels sl on sl.id = g.stake_level_id
  where g.id = p_game;
$$;

-- 發一則牌咖邀請（App 內通知，不推 LINE）。沒有權限檢查：只給同檔裡的函式叫
create or replace function public._friendly_invite(p_game uuid, p_from uuid, p_to uuid)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare g friendly_games; v_name text;
begin
  select * into g from friendly_games where id = p_game;
  if g.id is null or g.status <> 'waiting' or p_to is null or p_to = p_from then return false; end if;
  -- 只能邀自己的牌咖（兩個方向都算）、沒有封鎖、對方不在這一場
  if not exists (select 1 from mahjong_buddies b
                  where b.deleted_at is null
                    and ((b.member_id = p_from and b.buddy_id = p_to) or (b.member_id = p_to and b.buddy_id = p_from))) then
    return false;
  end if;
  if public._blocked_between(g.org_id, p_from, p_to) then return false; end if;
  if exists (select 1 from friendly_game_players where game_id = p_game and member_id = p_to and left_at is null) then
    return false;
  end if;
  -- 同一場同一個人還沒讀的邀請只留一則
  if exists (select 1 from app_notifications
              where member_id = p_to and type = 'friendly_invite' and ref_id = p_game and read_at is null) then
    return true;
  end if;
  select display_name into v_name from members where id = p_from;
  insert into app_notifications (org_id, member_id, type, ref_id, payload)
  values (g.org_id, p_to, 'friendly_invite', p_game,
          jsonb_build_object('text', coalesce(v_name, '牌咖') || '邀你一起打好友練習賽',
                             'game_id', p_game, 'token', g.invite_token, 'from', p_from));
  return true;
end $$;

-- 四人到齊：開打（挑虛擬桌、建場次、四列玩家、通知）。只給同檔裡的函式叫
create or replace function public._friendly_start(p_game uuid)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare g friendly_games; v_store uuid; v_table uuid; v_sid uuid; n int; r record;
begin
  select * into g from friendly_games where id = p_game for update;
  if g.id is null or g.status <> 'waiting' then return g.session_id; end if;
  if (select count(*) from friendly_game_players where game_id = p_game and left_at is null) <> 4 then
    return null;
  end if;

  select id into v_store from stores where org_id = g.org_id and is_virtual and deleted_at is null limit 1;
  if v_store is null then raise exception '好友練習賽的虛擬門市不存在（請找總部）'; end if;

  -- 一張沒有開著場次的虛擬桌；沒有就建一張（打完放回去重用，所以桌數 ＝ 同時在打的最多場數）
  select t.id into v_table
    from tables t
   where t.store_id = v_store and t.is_active and t.deleted_at is null
     and not exists (select 1 from table_sessions s
                      where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.sort_order, t.created_at
   limit 1 for update skip locked;
  if v_table is null then
    select count(*) into n from tables where store_id = v_store;
    insert into tables (org_id, store_id, label, is_active, seats, sort_order, auto_assign, note)
    values (g.org_id, v_store, 'F' || lpad((n + 1)::text, 4, '0'), true, 4, n + 1, false, '好友練習賽虛擬桌（系統建立）')
    returning id into v_table;
  end if;

  insert into table_sessions (org_id, store_id, table_id, mode, stake_level_id, status, planned_rounds,
                              game_type, flower, started_at, idempotency_key)
  values (g.org_id, v_store, v_table, 'friendly', g.stake_level_id, 'open', g.rounds,
          g.game_type, g.flower, now(), 'friendly-' || g.id::text)
  returning id into v_sid;

  -- 座位留空：四支手機在計分板「定座位」時決定（同店裡）
  insert into session_players (org_id, session_id, member_id, join_type, status, charged_points)
  select g.org_id, v_sid, fp.member_id, 'opener', 'playing', 0
    from friendly_game_players fp
   where fp.game_id = p_game and fp.left_at is null;

  update friendly_games set status = 'playing', session_id = v_sid, started_at = now(), updated_at = now()
   where id = p_game;

  -- 成桌通知：App 內（成桌彈窗），不推 LINE
  for r in select fp.member_id from friendly_game_players fp where fp.game_id = p_game and fp.left_at is null loop
    insert into app_notifications (org_id, member_id, type, ref_id, payload)
    values (g.org_id, r.member_id, 'friendly_ok', p_game,
            jsonb_build_object('text', '好友練習賽成桌了！打開 MIGI 智慧計分板開始記分', 'game_id', p_game));
  end loop;
  return v_sid;
end $$;

-- ① 開一場
create or replace function public.create_friendly_game_tx(
  p_stake uuid, p_play_at timestamptz, p_game_type text default '台麻', p_flower text default '無花',
  p_rounds text default '2 將', p_prefs jsonb default '{}'::jsonb, p_invite uuid[] default '{}'::uuid[])
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_me uuid; v_org uuid; v_rounds int; v_gid uuid; v_tok text; v_inv uuid; v_sent int := 0;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me;

  if p_stake is null or not exists (select 1 from stake_levels
                                     where id = p_stake and org_id = v_org and is_active and deleted_at is null) then
    raise exception '請選擇想打多少積分';
  end if;
  if coalesce(p_game_type, '') not in ('台麻', '美麻') then raise exception '請選擇遊戲規則'; end if;
  if coalesce(p_flower, '') not in ('無花', '有花') then raise exception '請選擇有沒有花牌'; end if;
  v_rounds := case when p_rounds ilike '%三%' or p_rounds like '%3%' then 3
                   when p_rounds ilike '%二%' or p_rounds like '%2%' then 2
                   when p_rounds ilike '%一%' or p_rounds like '%1%' then 1 end;
  if v_rounds is null then raise exception '請選擇要打幾將'; end if;
  -- 開打時間：同配桌（create_match_queue_tx）—— 必填、不可以在過去、留 5 分鐘寬限
  if p_play_at is null then raise exception '請選擇最晚開打時間'; end if;
  if p_play_at < now() - interval '5 minutes' then
    raise exception '最晚開打時間（%）已經過了，請重新選擇',
      to_char(p_play_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI');
  end if;

  -- 互斥（後端擋）
  if public._friendly_active_game(v_me) is not null then
    raise exception '你已經在一場好友練習賽裡，同時只能參加一場';
  end if;
  if public._friendly_in_match(v_org, v_me) then
    raise exception '你正在配桌或在打正式段位賽，結束後才能開好友練習賽';
  end if;

  v_tok := encode(extensions.gen_random_bytes(16), 'hex');
  insert into friendly_games (org_id, opened_by, stake_level_id, game_type, flower, rounds, prefs, play_at, invite_token)
  values (v_org, v_me, p_stake, p_game_type, p_flower, v_rounds, coalesce(p_prefs, '{}'::jsonb), p_play_at, v_tok)
  returning id into v_gid;
  insert into friendly_game_players (org_id, game_id, member_id, join_source) values (v_org, v_gid, v_me, 'open');

  -- 「＋ 邀牌咖加入」選的人（不是牌咖、有封鎖的會被安靜略過）
  foreach v_inv in array coalesce(p_invite, '{}'::uuid[]) loop
    if public._friendly_invite(v_gid, v_me, v_inv) then v_sent := v_sent + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'game_id', v_gid, 'token', v_tok, 'invited', v_sent);
end $$;

-- ② 用邀請連結加入。加入不了回原因（前端畫「加入不了」那一頁），不 raise
create or replace function public.join_friendly_game_tx(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_me uuid; v_org uuid; g friendly_games; v_host jsonb; v_other uuid; v_n int; v_sid uuid; r record;
begin
  v_me := public.current_member_id();
  if v_me is null then return jsonb_build_object('ok', false, 'reason', 'not_logged_in'); end if;
  select org_id into v_org from members where id = v_me;

  select * into g from friendly_games where invite_token = p_token and org_id = v_org for update;
  if g.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  select jsonb_build_object('member_id', m.id, 'nickname', m.display_name, 'avatar_url', m.avatar_url,
                            'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
                            'avatar_bear', m.avatar_bear)
    into v_host from members m where m.id = g.opened_by;

  -- 已經在這一場：直接回去（自己點自己的連結也走這裡）
  if exists (select 1 from friendly_game_players where game_id = g.id and member_id = v_me and left_at is null) then
    return jsonb_build_object('ok', true, 'already', true, 'game_id', g.id, 'host', v_host);
  end if;

  if g.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'cancelled', 'host', v_host); end if;
  if g.status <> 'waiting' then return jsonb_build_object('ok', false, 'reason', 'full', 'host', v_host); end if;
  if g.play_at < now() then return jsonb_build_object('ok', false, 'reason', 'expired', 'host', v_host); end if;
  select count(*) into v_n from friendly_game_players where game_id = g.id and left_at is null;
  if v_n >= 4 then return jsonb_build_object('ok', false, 'reason', 'full', 'host', v_host); end if;

  v_other := public._friendly_active_game(v_me);
  if v_other is not null then
    return jsonb_build_object('ok', false, 'reason', 'in_other_friendly', 'other_game_id', v_other, 'host', v_host);
  end if;
  if public._friendly_in_match(v_org, v_me) then
    return jsonb_build_object('ok', false, 'reason', 'in_match', 'host', v_host);
  end if;
  -- 跟這一場任何一個人有封鎖 ⇒ 不加（不說是誰）
  for r in select member_id from friendly_game_players where game_id = g.id and left_at is null loop
    if public._blocked_between(v_org, v_me, r.member_id) then
      return jsonb_build_object('ok', false, 'reason', 'blocked', 'host', v_host);
    end if;
  end loop;

  insert into friendly_game_players (org_id, game_id, member_id, join_source) values (v_org, g.id, v_me, 'link');
  update app_notifications set read_at = coalesce(read_at, now())   -- 牌咖邀請一起當作看過了
   where member_id = v_me and type = 'friendly_invite' and ref_id = g.id;

  if v_n + 1 = 4 then v_sid := public._friendly_start(g.id); end if;
  return jsonb_build_object('ok', true, 'game_id', g.id, 'host', v_host, 'started', v_sid is not null);
end $$;

-- ③ 離開（加入的人，等朋友時才可以）
create or replace function public.leave_friendly_game_tx(p_game uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_me uuid; g friendly_games;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select * into g from friendly_games where id = p_game for update;
  if g.id is null or not exists (select 1 from friendly_game_players
                                  where game_id = p_game and member_id = v_me and left_at is null) then
    raise exception '你不在這一場好友練習賽裡';
  end if;
  if g.opened_by = v_me then raise exception '開局的人請用「取消這一場」'; end if;
  if g.status <> 'waiting' then raise exception '已經開打，不能離開'; end if;
  update friendly_game_players set left_at = now(), leave_reason = 'quit'
   where game_id = p_game and member_id = v_me and left_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- ④ 取消（開局的人，等朋友時才可以）
create or replace function public.cancel_friendly_game_tx(p_game uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_me uuid; g friendly_games; v_name text; r record;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select * into g from friendly_games where id = p_game for update;
  if g.id is null or g.opened_by <> v_me then raise exception '只有開局的人可以取消這一場'; end if;
  if g.status <> 'waiting' then raise exception '已經開打，不能取消'; end if;
  select display_name into v_name from members where id = v_me;

  for r in select member_id from friendly_game_players
            where game_id = p_game and left_at is null and member_id <> v_me loop
    insert into app_notifications (org_id, member_id, type, ref_id, payload)
    values (g.org_id, r.member_id, 'friendly_out', p_game,
            jsonb_build_object('text', coalesce(v_name, '開局的人') || '取消了這一場好友練習賽', 'game_id', p_game));
  end loop;
  update friendly_game_players set left_at = now(), leave_reason = 'cancelled' where game_id = p_game and left_at is null;
  update friendly_games set status = 'cancelled', cancel_reason = 'host', ended_at = now(), updated_at = now()
   where id = p_game;
  return jsonb_build_object('ok', true);
end $$;

-- ⑤ 邀牌咖（建立之後再補邀；建立當下選的人走 create 的 p_invite）
create or replace function public.send_friendly_invite_tx(p_game uuid, p_buddy uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if not exists (select 1 from friendly_game_players where game_id = p_game and member_id = v_me and left_at is null) then
    raise exception '你不在這一場好友練習賽裡';
  end if;
  return jsonb_build_object('ok', public._friendly_invite(p_game, v_me, p_buddy));
end $$;

-- ⑥ 我的好友練習賽（切頁最上面那一塊）。沒有在等也沒有在打 ⇒ game 是 null
--    第 ② 批會再多回 stats 與 records
create or replace function public.get_my_friendly_tx()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_me uuid; v_gid uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  v_gid := public._friendly_active_game(v_me);
  return jsonb_build_object('game', case when v_gid is null then null else public._friendly_view(v_gid, v_me) end);
end $$;

-- ⑦ 排程：過了最晚開打時間還沒湊滿 ⇒ 取消並通知（第 ② 批再加「打到一半沒人動」）
create or replace function public.sweep_friendly_tx()
returns int language plpgsql security definer set search_path to 'public' as $$
declare g record; r record; n int := 0;
begin
  for g in select * from friendly_games where status = 'waiting' and play_at < now() for update skip locked loop
    for r in select member_id from friendly_game_players where game_id = g.id and left_at is null loop
      insert into app_notifications (org_id, member_id, type, ref_id, payload)
      values (g.org_id, r.member_id, 'friendly_out', g.id,
              jsonb_build_object('text', '好友練習賽到了最晚開打時間還沒湊滿四人，已自動取消', 'game_id', g.id));
    end loop;
    update friendly_game_players set left_at = now(), leave_reason = 'expired' where game_id = g.id and left_at is null;
    update friendly_games set status = 'cancelled', cancel_reason = 'expired', ended_at = now(), updated_at = now()
     where id = g.id;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'friendly-sweep') then
    perform cron.unschedule('friendly-sweep');
  end if;
  perform cron.schedule('friendly-sweep', '*/5 * * * *', 'select public.sweep_friendly_tx()');
end $$;

-- ── G. 配桌那一邊的互斥：_check_join_conflict 開頭多一道（簽名不變 ⇒ 授權保留）
create or replace function public._check_join_conflict(p_org_id uuid, p_member uuid, p_play_at timestamp with time zone, p_source text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  r record;
  v_target_is_fix boolean := (p_source = 'recurring');
  v_row_is_fix boolean;
begin
  /* ★ 2026-10-28：在好友練習賽裡（等朋友或在打）就不能報名、也不能開正式段位賽的配桌（使用者拍板，後端擋） */
  if public._friendly_active_game(p_member) is not null then
    raise exception '你正在好友練習賽裡，結束後才能報名配桌';
  end if;

  /* 掃身上所有「還沒結束」的場。
     ★ 2026-09-06：加入 `seated`（已經帶到桌、正要去店裡）——
       在此之前成桌之後還能再開一桌，而這支的規則本身寫著
       「同時只能參加一場」。
     🔴 但**必須綁「那張桌還開著」** —— `seated` 是終點狀態，
       打完收桌之後房仍然是 seated，無條件擋的話
       **打過一場的人從此永遠報不了名**。 */
  for r in
    select q.play_at, q.source
      from match_queue_players qp
      join match_queues q on q.id = qp.queue_id
     where qp.member_id = p_member
       and qp.left_at is null
       and q.org_id = p_org_id
       and (
         q.status in ('waiting', 'matched')
         or (q.status = 'seated' and public.migi_seat_is_live(q.matched_session_id))
       )
  loop
    v_row_is_fix := (r.source = 'recurring');
    -- ① 即時局最多一場：目標是即時局、身上已有即時局
    if not v_target_is_fix and not v_row_is_fix then
      raise exception '你已報名即時牌局，同時只能參加一場';
    end if;
    -- ② 固定局最多一場：目標是固定局、身上已有固定局
    if v_target_is_fix and v_row_is_fix then
      raise exception '你已報名固定牌局，同時只能參加一場';
    end if;
    -- ③ 任一場 play_at 跟目標場差 < 6 小時 → 擋（跨類型也要守）
    if abs(extract(epoch from (r.play_at - p_play_at))) < 6 * 3600 then
      raise exception '你已有一場 % 的牌局，時間太近無法同時報名（需間隔 6 小時以上）',
        to_char(r.play_at, 'MM/DD HH24:MI');
    end if;
  end loop;
end $function$;

-- ── 授權（2026-09-29 起預設全關：前端要叫的明確給 authenticated，內部的收乾淨）
grant execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[]) to authenticated;
grant execute on function public.join_friendly_game_tx(text)            to authenticated;
grant execute on function public.leave_friendly_game_tx(uuid)           to authenticated;
grant execute on function public.cancel_friendly_game_tx(uuid)          to authenticated;
grant execute on function public.send_friendly_invite_tx(uuid, uuid)    to authenticated;
grant execute on function public.get_my_friendly_tx()                   to authenticated;
revoke execute on function public._friendly_active_game(uuid)           from public, anon, authenticated;
revoke execute on function public._friendly_in_match(uuid, uuid)        from public, anon, authenticated;
revoke execute on function public._friendly_view(uuid, uuid)            from public, anon, authenticated;
revoke execute on function public._friendly_invite(uuid, uuid, uuid)    from public, anon, authenticated;
revoke execute on function public._friendly_start(uuid)                 from public, anon, authenticated;
revoke execute on function public.sweep_friendly_tx()                   from public, anon, authenticated;

-- ============================================================
-- 驗證（不 raise，跑完另外查一次線上）
-- ============================================================
do $$
declare v text := ''; n int; m int; ok boolean;
begin
  -- ① 每個機構一間虛擬門市，不營業
  select count(*) into n from stores where is_virtual and deleted_at is null and not is_active;
  select count(*) into m from orgs;
  v := v || case when n = m then '✅' else '🔴' end || format(' ① 虛擬門市 %s 間（機構 %s 個）、都不營業', n, m) || E'\n';

  -- ② 場次模式多了 friendly，舊的兩個還在
  select pg_get_constraintdef(oid) ~ 'friendly' and pg_get_constraintdef(oid) ~ 'matched' and pg_get_constraintdef(oid) ~ 'private'
    into ok from pg_constraint where conrelid = 'public.table_sessions'::regclass and conname = 'table_sessions_mode_check';
  v := v || case when coalesce(ok, false) then '✅' else '🔴' end || ' ② table_sessions.mode 收 matched／private／friendly' || E'\n';

  -- ③ 通知類型：三種新的在、舊的十種都還在
  select count(*) into n from unnest(array['settle','buddy_req','buddy_ok','table_req','table_ok','system','table_expired',
                                            'team_req','team_ok','team_out','friendly_ok','friendly_invite','friendly_out']) t(x)
   where (select pg_get_constraintdef(oid) from pg_constraint
           where conrelid = 'public.app_notifications'::regclass and conname = 'app_notifications_type_check') ~ ('''' || x || '''');
  v := v || case when n = 13 then '✅' else '🔴' end || format(' ③ 通知類型 %s／13', n) || E'\n';

  -- ④ 推播白名單沒有被動到（好友練習賽成桌不推 LINE）
  select pg_get_functiondef('public._push_enqueue'::regproc) !~ 'friendly' into ok;
  v := v || case when ok then '✅' else '🔴' end || ' ④ LINE 推播白名單沒有好友練習賽的成桌通知' || E'\n';

  -- ⑤ 兩張新表：RLS 開著、0 條 policy、前端角色沒有表權限
  select count(*) into n from pg_class c
   where c.oid in ('public.friendly_games'::regclass, 'public.friendly_game_players'::regclass) and c.relrowsecurity;
  select count(*) into m from pg_policies where tablename in ('friendly_games', 'friendly_game_players');
  select bool_or(has_table_privilege(r, t, 'SELECT') or has_table_privilege(r, t, 'INSERT'))
    into ok from unnest(array['anon','authenticated']) r, unnest(array['public.friendly_games','public.friendly_game_players']) t;
  v := v || case when n = 2 and m = 0 and not ok then '✅' else '🔴' end
          || format(' ⑤ 新表 RLS %s／2、policy %s 條、前端可讀寫：%s', n, m, case when ok then '是' else '否' end) || E'\n';

  -- ⑥ 前端六支：authenticated 叫得動、anon 叫不動
  select count(*) into n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('create_friendly_game_tx','join_friendly_game_tx','leave_friendly_game_tx',
                       'cancel_friendly_game_tx','send_friendly_invite_tx','get_my_friendly_tx')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and not has_function_privilege('anon', p.oid, 'EXECUTE');
  v := v || case when n = 6 then '✅' else '🔴' end || format(' ⑥ 前端六支 %s／6（登入的人叫得動、沒登入叫不動）', n) || E'\n';

  -- ⑦ 內部六支：前端完全叫不動（明確與 PUBLIC 都沒有）
  select count(*) into n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_friendly_active_game','_friendly_in_match','_friendly_view','_friendly_invite',
                       '_friendly_start','sweep_friendly_tx')
     and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and not has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v := v || case when n = 6 then '✅' else '🔴' end || format(' ⑦ 內部六支 %s／6 前端叫不動', n) || E'\n';

  -- ⑧ 配桌的互斥真的會叫好友練習賽那一道（問「有沒有呼叫」，不是「有沒有提到」—— 硬規則 3.5）
  select pg_get_functiondef('public._check_join_conflict(uuid,uuid,timestamptz,text)'::regprocedure)
         ~ 'if\s+public\._friendly_active_game\(p_member\)\s+is not null' into ok;
  v := v || case when ok then '✅' else '🔴' end || ' ⑧ _check_join_conflict 會先擋「在好友練習賽裡」' || E'\n';

  -- ⑨ 配桌互斥原本那三條規則還在（負對照：沒有被改壞）
  select pg_get_functiondef('public._check_join_conflict(uuid,uuid,timestamptz,text)'::regprocedure)
         ~ '同時只能參加一場' and pg_get_functiondef('public._check_join_conflict(uuid,uuid,timestamptz,text)'::regprocedure) ~ '6 \* 3600'
    into ok;
  v := v || case when ok then '✅' else '🔴' end || ' ⑨ 配桌原本的三條互斥規則還在' || E'\n';

  -- ⑩ 排程在
  select exists (select 1 from cron.job where jobname = 'friendly-sweep' and active) into ok;
  v := v || case when ok then '✅' else '🔴' end || ' ⑩ 排程 friendly-sweep 每 5 分鐘';

  perform set_config('migi.x', v, true);
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "好友練習賽 · 地基";
