-- ════════════════════════════════════════════════════════════════════
-- 線上好友房 · 第 ③ 批：開一場好友練習賽可以選「線上打」（2026-11-11）
-- 規格：docs/03-會員App與社交/線上好友房.md　前兩批：sql/applied/2026-11-11_線上好友房_資料表.sql、…_建局與動作.sql
--
-- 改三支：
--   create_friendly_game_tx   多一個參數 p_play_mode（預設 'scoreboard' ＝ 現在的樣子：實體牌、四支手機記分）
--                             ⚠ 改簽名 ⇒ 先 DROP 舊的（硬規則 2），重建後補 GRANT（預設全關，硬規則 2.7）
--                             舊版 App 沒送這個參數照樣叫得動（有預設值），所以這一份可以在前端上線之前先跑
--   _friendly_view            多回 play_mode（等人卡、成桌之後要知道去計分板還是去牌桌）
--   _friendly_start           成桌通知的文字照打法分：線上打 ⇒「打開牌桌開始打牌」；通知內容多帶 play_mode
--
-- 線上打目前只有台麻（牌局引擎是台灣十六張）；選美麻又選線上打 ⇒ 不給開。
-- ════════════════════════════════════════════════════════════════════

drop function if exists public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[]);

create or replace function public.create_friendly_game_tx(
  p_stake uuid, p_play_at timestamptz, p_game_type text default '台麻', p_flower text default '無花',
  p_rounds text default '2 將', p_prefs jsonb default '{}'::jsonb, p_invite uuid[] default '{}'::uuid[],
  p_play_mode text default 'scoreboard')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid; v_org uuid; v_rounds int; v_gid uuid; v_tok text; v_inv uuid; v_sent int := 0; v_mode text;
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
  -- 怎麼打（2026-11-11）：沒送 ＝ 計分板；線上打目前只有台麻
  v_mode := coalesce(nullif(p_play_mode, ''), 'scoreboard');
  if v_mode not in ('scoreboard', 'online') then raise exception '請選擇怎麼打'; end if;
  if v_mode = 'online' and p_game_type <> '台麻' then raise exception '線上打目前只有台麻'; end if;
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
  insert into friendly_games (org_id, opened_by, stake_level_id, game_type, flower, rounds, prefs, play_at, invite_token, play_mode)
  values (v_org, v_me, p_stake, p_game_type, p_flower, v_rounds, coalesce(p_prefs, '{}'::jsonb), p_play_at, v_tok, v_mode)
  returning id into v_gid;
  insert into friendly_game_players (org_id, game_id, member_id, join_source) values (v_org, v_gid, v_me, 'open');

  -- 「＋ 邀牌咖加入」選的人（不是牌咖、有封鎖的會被安靜略過）
  foreach v_inv in array coalesce(p_invite, '{}'::uuid[]) loop
    if public._friendly_invite(v_gid, v_me, v_inv) then v_sent := v_sent + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'game_id', v_gid, 'token', v_tok, 'invited', v_sent, 'play_mode', v_mode);
end $$;

-- DROP 重建 ＝ 新建 ⇒ 預設是關的，要明確開給登入的人；兩個方向都收乾淨（硬規則 2.6／2.7）
revoke execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text) from public;
revoke execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text) from anon;
grant  execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text) to authenticated, service_role;

-- 等人卡／進行中：多回 play_mode（簽名不變 ⇒ CREATE OR REPLACE，不用 DROP、GRANT 還在）
create or replace function public._friendly_view(p_game uuid, p_member uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', g.id, 'status', g.status, 'is_host', (g.opened_by = p_member),
    'game_type', g.game_type, 'flower', g.flower, 'rounds', g.rounds, 'prefs', g.prefs,
    'play_mode', g.play_mode,
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

-- 成桌：通知的文字照打法分（簽名不變 ⇒ CREATE OR REPLACE）
create or replace function public._friendly_start(p_game uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare g friendly_games; v_store uuid; v_table uuid; v_sid uuid; n int; r record;
begin
  select * into g from friendly_games where id = p_game for update;
  if g.id is null or g.status <> 'waiting' then return g.session_id; end if;
  if (select count(*) from friendly_game_players where game_id = p_game and left_at is null) <> 4 then
    return null;
  end if;

  select id into v_store from stores where org_id = g.org_id and is_virtual and deleted_at is null limit 1;
  if v_store is null then raise exception '好友練習賽的設定不存在（請找總部）'; end if;

  -- 一間沒有開著場次的練習賽房間；沒有就建一間（打完放回去重用，所以房間數 ＝ 同時在打的最多場數）
  select t.id into v_table
    from tables t
   where t.store_id = v_store and t.is_active and t.deleted_at is null
     and not exists (select 1 from table_sessions s
                      where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.sort_order, t.created_at
   limit 1 for update skip locked;
  if v_table is null then
    select count(*) into n from tables where store_id = v_store;
    -- 桌名客人會在手機計分板上看到；同一間門市底下不能重名 ⇒ 帶編號（2026-10-30 使用者定名「練習賽房間」）
    insert into tables (org_id, store_id, label, is_active, seats, sort_order, auto_assign, note)
    values (g.org_id, v_store, '練習賽房間 ' || (n + 1)::text, true, 4, n + 1, false, '好友練習賽用（系統建立）')
    returning id into v_table;
  end if;

  insert into table_sessions (org_id, store_id, table_id, mode, stake_level_id, status, planned_rounds,
                              game_type, flower, started_at, idempotency_key)
  values (g.org_id, v_store, v_table, 'friendly', g.stake_level_id, 'open', g.rounds,
          g.game_type, g.flower, now(), 'friendly-' || g.id::text)
  returning id into v_sid;

  -- 座位留空：計分板的是四支手機「定座位」時決定（同店裡）；線上打的是第一個人進牌桌時由系統擲骰子排（online_start_round_tx）
  insert into session_players (org_id, session_id, member_id, join_type, status, charged_points)
  select g.org_id, v_sid, fp.member_id, 'opener', 'playing', 0
    from friendly_game_players fp
   where fp.game_id = p_game and fp.left_at is null;

  update friendly_games set status = 'playing', session_id = v_sid, started_at = now(), updated_at = now()
   where id = p_game;

  -- 成桌通知：App 內（成桌彈窗），不推 LINE。文字照打法分（2026-11-11）
  for r in select fp.member_id from friendly_game_players fp where fp.game_id = p_game and fp.left_at is null loop
    insert into app_notifications (org_id, member_id, type, ref_id, payload)
    values (g.org_id, r.member_id, 'friendly_ok', p_game,
            jsonb_build_object('text', case when g.play_mode = 'online'
                                            then '好友練習賽成桌了！打開牌桌開始線上打牌'
                                            else '好友練習賽成桌了！打開 MIGI 智慧計分板開始記分' end,
                               'game_id', p_game, 'play_mode', g.play_mode));
  end loop;
  return v_sid;
end $$;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT；不 raise —— 硬規則 1.8）
-- 行為（四個測試帳號真的開一場線上打、湊滿、進牌桌）另外跑：sql/checks/2026-11-11_驗開一場選線上打.sql
-- ════════════════════════════════════════════════════════════════════
with p as (select pr.oid, pr.proname, pr.proacl, pg_get_function_identity_arguments(pr.oid) as args
             from pg_proc pr where pr.pronamespace = 'public'::regnamespace
              and pr.proname in ('create_friendly_game_tx', '_friendly_view', '_friendly_start')),
c(item, ok) as (
  select '① create_friendly_game_tx 只有一個版本（舊簽名已經移除），而且有 p_play_mode',
         (select count(*) from p where proname = 'create_friendly_game_tx') = 1
         and coalesce((select args like '%p_play_mode text%' from p where proname = 'create_friendly_game_tx'), false)
  union all
  select '② 正對照：登入的人叫得動（DROP 重建之後 GRANT 有補回來，不然 App 開一場會當場壞）',
         coalesce((select exists (select 1 from aclexplode(proacl) a where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
                     from p where proname = 'create_friendly_game_tx'), false)
  union all
  select '③ anon 與 PUBLIC 叫不動',
         coalesce((select not exists (select 1 from aclexplode(proacl) a where a.grantee in (0, 'anon'::regrole::oid) and a.privilege_type = 'EXECUTE') and proacl is not null
                     from p where proname = 'create_friendly_game_tx'), false)
  union all
  select '④ 身分只認 current_member_id()（沒有把「你是誰」當參數收）',
         coalesce((select args not like '%member%' and pg_get_functiondef(oid) ~ 'v_me := public\.current_member_id\(\)' from p where proname = 'create_friendly_game_tx'), false)
  union all
  select '⑤ _friendly_view 會回 play_mode', coalesce((select pg_get_functiondef(oid) ~ '''play_mode'', g\.play_mode' from p where proname = '_friendly_view'), false)
  union all
  select '⑥ _friendly_start 的通知照打法分、內容帶 play_mode',
         coalesce((select pg_get_functiondef(oid) ~ '打開牌桌開始線上打牌' and pg_get_functiondef(oid) ~ '''play_mode'', g\.play_mode' from p where proname = '_friendly_start'), false)
  union all
  select '⑦ _friendly_view、_friendly_start 仍然各只有一個版本、前端叫不動（沒被這次改動打開）',
         (select count(*) from p where proname in ('_friendly_view', '_friendly_start')) = 2
         and not exists (select 1 from p, aclexplode(p.proacl) a where p.proname in ('_friendly_view', '_friendly_start')
                           and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid) and a.privilege_type = 'EXECUTE')
)
select string_agg(case when ok then '✅ ' else '🔴 ' end || item, E'\n') as "驗證" from c;
