-- ════════════════════════════════════════════════════════════════════
-- 2026-11-12　好友練習賽：線上開打可以「公開到佇列」，好友練習賽主頁列出來，任何會員按加入
-- ════════════════════════════════════════════════════════════════════
-- 使用者拍板（2026-11-12）：
--   · 開局時自己選要不要公開（預設不公開）；只有線上開打可以公開
--   · 所有會員看得到、都能加入（跟房裡任何一人有封鎖的看不到那一場）
--   · 積分不限（公開的也可以選任何級距）
--   · 主頁的佇列照配桌頁做（同一顆 GameCard）
--
-- 動到的東西：
--   friendly_games.is_public            🆕 欄位（預設 false）＋ 約束：公開的一定是線上開打
--   friendly_game_players.join_source   允許值多一個 'queue'（從佇列加入；跟 'link' 分開，日後看得出人是從哪裡來的）
--   _friendly_join(game, source)        🆕 加入的本體（原本寫在 join_friendly_game_tx 裡，一字不改搬過來，只多「從佇列加入要是公開的」）
--   join_friendly_game_tx(token)        ✏️ 改成找到那一場之後叫 _friendly_join(…, 'link')。簽名不變 ⇒ 授權不會掉
--   join_public_friendly_tx(game)       🆕 從佇列加入
--   list_friendly_queue_tx()            🆕 佇列清單
--   create_friendly_game_tx             ✏️ 多一個參數 p_public（放最後、有預設值 ⇒ 舊版前端照樣叫得動）。
--                                          改簽名 ⇒ 先 DROP 再建（硬規則 2），GRANT 在下面補回
--   _friendly_view                      ✏️ 多回 is_public（等人卡要畫「已公開」）
-- ════════════════════════════════════════════════════════════════════

-- ── ① 欄位與約束 ─────────────────────────────────────────────────
alter table public.friendly_games add column if not exists is_public boolean not null default false;
comment on column public.friendly_games.is_public is
  '公開到好友練習賽主頁的佇列（任何會員可以從那裡加入）。只有線上開打可以公開。2026-11-12';
alter table public.friendly_games drop constraint if exists friendly_games_public_online_check;
alter table public.friendly_games add constraint friendly_games_public_online_check
  check (not is_public or play_mode = 'online');

alter table public.friendly_game_players drop constraint if exists friendly_game_players_join_source_check;
alter table public.friendly_game_players add constraint friendly_game_players_join_source_check
  check (join_source = any (array['open', 'link', 'buddy', 'bot', 'queue']));

-- ── ② 加入的本體 ─────────────────────────────────────────────────
-- 原本 join_friendly_game_tx 的內容一字不改搬過來；差別只有：用 id 找那一場、
-- 來源由呼叫的人給、從佇列加入時那一場一定要是公開的（不是的話當作找不到，不透露有這一場）
create or replace function public._friendly_join(p_game uuid, p_source text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_me uuid; v_org uuid; g friendly_games; v_host jsonb; v_other uuid; v_n int; v_sid uuid; r record;
begin
  v_me := public.current_member_id();
  if v_me is null then return jsonb_build_object('ok', false, 'reason', 'not_logged_in'); end if;
  select org_id into v_org from members where id = v_me;

  select * into g from friendly_games where id = p_game and org_id = v_org for update;
  if g.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if p_source = 'queue' and not g.is_public then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
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

  insert into friendly_game_players (org_id, game_id, member_id, join_source) values (v_org, g.id, v_me, p_source);
  update app_notifications set read_at = coalesce(read_at, now())   -- 牌咖邀請一起當作看過了
   where member_id = v_me and type = 'friendly_invite' and ref_id = g.id;

  if v_n + 1 = 4 then v_sid := public._friendly_start(g.id); end if;
  return jsonb_build_object('ok', true, 'game_id', g.id, 'host', v_host, 'started', v_sid is not null);
end $function$;

-- ── ③ 用邀請連結加入：找到那一場，交給本體（行為跟原本一樣）──────────────
create or replace function public.join_friendly_game_tx(p_token text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_me uuid; v_gid uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then return jsonb_build_object('ok', false, 'reason', 'not_logged_in'); end if;
  select g.id into v_gid from friendly_games g
   where g.invite_token = p_token and g.org_id = (select org_id from members where id = v_me);
  if v_gid is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  return public._friendly_join(v_gid, 'link');
end $function$;

-- ── ④ 從佇列加入 ─────────────────────────────────────────────────
create or replace function public.join_public_friendly_tx(p_game uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
begin
  return public._friendly_join(p_game, 'queue');
end $function$;

-- ── ⑤ 佇列清單 ───────────────────────────────────────────────────
-- 公開、線上開打、還在等人、還沒過最晚開打時間；我不在裡面；跟房裡任何一人有封鎖的不列。
-- 最晚開打時間早的排前面（同配桌）。欄位照配桌清單的名字（前端直接用同一顆 GameCard）
create or replace function public.list_friendly_queue_tx()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_me uuid; v_org uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me;
  return coalesce((
    select jsonb_agg(x.j order by x.play_at, x.created_at)
      from (
        select g.play_at, g.created_at, jsonb_build_object(
                 'id', g.id, 'play_at', g.play_at, 'game_type', g.game_type, 'flower', g.flower,
                 'rounds', g.rounds, 'special_rules', to_jsonb(g.special_rules),
                 'stake_level_id', g.stake_level_id, 'stake_label', sl.label,
                 'player_count', (select count(*) from friendly_game_players p where p.game_id = g.id and p.left_at is null),
                 'seats', 4,
                 'host', (select jsonb_build_object('member_id', h.id, 'nickname', h.display_name) from members h where h.id = g.opened_by)
               ) as j
          from friendly_games g
          left join stake_levels sl on sl.id = g.stake_level_id
         where g.org_id = v_org and g.is_public and g.play_mode = 'online'
           and g.status = 'waiting' and g.play_at >= now()
           and not exists (select 1 from friendly_game_players p where p.game_id = g.id and p.member_id = v_me and p.left_at is null)
           and not exists (select 1 from friendly_game_players p where p.game_id = g.id and p.left_at is null
                              and public._blocked_between(v_org, v_me, p.member_id))
           and (select count(*) from friendly_game_players p where p.game_id = g.id and p.left_at is null) < 4
         limit 50
      ) x), '[]'::jsonb);
end $function$;

-- ── ⑥ 開一場：多一個參數 p_public ───────────────────────────────────
drop function if exists public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text, text[]);
create function public.create_friendly_game_tx(
  p_stake uuid, p_play_at timestamptz, p_game_type text default '台麻', p_flower text default '無花',
  p_rounds text default '2 將', p_prefs jsonb default '{}'::jsonb, p_invite uuid[] default '{}'::uuid[],
  p_play_mode text default 'scoreboard', p_special_rules text[] default '{}'::text[], p_public boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_me uuid; v_org uuid; v_rounds int; v_gid uuid; v_tok text; v_inv uuid; v_sent int := 0; v_mode text; v_rules text[];
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
  -- 🆕 2026-11-12：只有線上開打可以公開到佇列（我有麻將桌的那一種要坐在一起，陌生人加入了也到不了）
  if coalesce(p_public, false) and v_mode <> 'online' then raise exception '只有線上開打可以公開'; end if;
  -- 特殊規則：沒送 ＝ 都不開。不認得的代碼直接擋（不安靜略過 —— 客人以為開了、實際沒開，會在算台的時候才發現）；重複的收成一個、順序固定
  if exists (select 1 from unnest(coalesce(p_special_rules, '{}'::text[])) x where x is null or x not in ('quanhong', 'shaigui', 'baozi')) then
    raise exception '特殊規則只有 骰龜、豹子、全紅';
  end if;
  select coalesce(array_agg(x order by array_position(array['quanhong', 'shaigui', 'baozi']::text[], x)), '{}'::text[]) into v_rules
    from (select distinct unnest(coalesce(p_special_rules, '{}'::text[])) as x) u;
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
  insert into friendly_games (org_id, opened_by, stake_level_id, game_type, flower, rounds, prefs, play_at, invite_token, play_mode, special_rules, is_public)
  values (v_org, v_me, p_stake, p_game_type, p_flower, v_rounds, coalesce(p_prefs, '{}'::jsonb), p_play_at, v_tok, v_mode, v_rules, coalesce(p_public, false))
  returning id into v_gid;
  insert into friendly_game_players (org_id, game_id, member_id, join_source) values (v_org, v_gid, v_me, 'open');

  -- 「＋ 邀牌咖加入」選的人（不是牌咖、有封鎖的會被安靜略過）
  foreach v_inv in array coalesce(p_invite, '{}'::uuid[]) loop
    if public._friendly_invite(v_gid, v_me, v_inv) then v_sent := v_sent + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'game_id', v_gid, 'token', v_tok, 'invited', v_sent, 'play_mode', v_mode,
                            'special_rules', to_jsonb(v_rules), 'is_public', coalesce(p_public, false));
end $function$;

-- ── ⑦ 等人卡讀的那一支：多回 is_public（其餘一字不改）────────────────────
create or replace function public._friendly_view(p_game uuid, p_member uuid)
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'id', g.id, 'status', g.status, 'is_host', (g.opened_by = p_member),
    'game_type', g.game_type, 'flower', g.flower, 'rounds', g.rounds, 'prefs', g.prefs,
    'play_mode', g.play_mode,
    -- 🆕 2026-11-12：有沒有公開到佇列
    'is_public', g.is_public,
    -- 這一場開了哪幾個特殊規則（空的 ＝ 都不開）
    'special_rules', to_jsonb(g.special_rules),
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
               'joined_at', fp.joined_at, 'is_host', (m.id = g.opened_by),
               'is_bot', m.is_bot)                                              -- 🆕 電腦對手
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
$function$;

-- ── ⑧ 授權：09-29 起新建的預設全關 ⇒ 給前端叫的要明寫 ───────────────────
grant execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text, text[], boolean) to authenticated;
grant execute on function public.join_public_friendly_tx(uuid) to authenticated;
grant execute on function public.list_friendly_queue_tx() to authenticated;
revoke execute on function public._friendly_join(uuid, text) from public, anon, authenticated;
revoke execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text, text[], boolean) from public, anon;
revoke execute on function public.join_public_friendly_tx(uuid) from public, anon;
revoke execute on function public.list_friendly_queue_tx() from public, anon;

-- ── 驗證（單一 SELECT；行為另外跑 sql/checks/2026-11-12_驗好友練習賽公開佇列.sql）──────
select concat_ws(E'\n',
  (select case when count(*) = 1 then '✅ ① friendly_games.is_public 在（預設 false、不可空）' else '🔴 ① is_public 欄位不在' end
     from information_schema.columns
    where table_schema = 'public' and table_name = 'friendly_games' and column_name = 'is_public'
      and is_nullable = 'NO' and column_default = 'false'),
  (select case when count(*) = 2 then '✅ ② 兩條約束都在（公開一定是線上開打、加入來源多了 queue）' else '🔴 ② 約束只有 ' || count(*) || ' 條' end
     from pg_constraint
    where (conname = 'friendly_games_public_online_check' and pg_get_constraintdef(oid) ~ 'online')
       or (conname = 'friendly_game_players_join_source_check' and pg_get_constraintdef(oid) ~ 'queue')),
  (select case when count(*) = 5 and count(distinct p.proname) = 5
               then '✅ ③ 五支函式各只有一個版本'
               else '🔴 ③ 函式數不對：' || string_agg(p.proname, '、') end
     from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('create_friendly_game_tx', 'join_friendly_game_tx', 'join_public_friendly_tx', 'list_friendly_queue_tx', '_friendly_join')),
  -- ④ 前端要叫的四支：authenticated 有、anon 與 PUBLIC 沒有（明確授權與 PUBLIC 分開看，硬規則 2.6）
  (select case when count(*) = 4 and bool_and(
                 exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
                 and not exists (select 1 from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE' and (a.grantee = 0 or a.grantee = 'anon'::regrole::oid)))
               then '✅ ④ 開一場、連結加入、佇列加入、佇列清單：登入的人叫得到，沒登入叫不到'
               else '🔴 ④ 授權不對：' || string_agg(p.proname || '=' || coalesce(p.proacl::text, '預設'), '；') end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proacl is not null
      and p.proname in ('create_friendly_game_tx', 'join_friendly_game_tx', 'join_public_friendly_tx', 'list_friendly_queue_tx')),
  (select case when not exists (select 1 from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE'
                                  and (a.grantee = 0 or a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid)))
               then '✅ ⑤ 加入的本體（_friendly_join）前端叫不到'
               else '🔴 ⑤ _friendly_join 開給前端了' end
     from pg_proc p where p.oid = 'public._friendly_join(uuid,text)'::regprocedure),
  -- ⑥ 身分只認登入的人：三支前端入口都問 current_member_id()，沒有收「你是誰」的參數
  (select case when count(*) = 3 and bool_and(pg_get_functiondef(p.oid) ~ 'current_member_id\(\)' or pg_get_functiondef(p.oid) ~ '_friendly_join\(')
               then '✅ ⑥ 三支入口的身分都從登入身分取'
               else '🔴 ⑥ 有入口沒有問登入身分' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('join_friendly_game_tx', 'join_public_friendly_tx', 'list_friendly_queue_tx')),
  -- ⑦ 舊資料：沒有任何一場被誤標成公開
  (select case when count(*) filter (where is_public) = 0 then '✅ ⑦ 既有 ' || count(*) || ' 場都是不公開（新欄位沒有改到舊資料）'
               else '🔴 ⑦ 有 ' || count(*) filter (where is_public) || ' 場舊資料是公開' end
     from friendly_games),
  -- ⑧ 等人卡讀的那一支有回 is_public
  (select case when pg_get_functiondef('public._friendly_view(uuid,uuid)'::regprocedure) ~ '''is_public'''
               then '✅ ⑧ 等人卡讀得到「有沒有公開」' else '🔴 ⑧ _friendly_view 沒有回 is_public' end)
) as "驗證";
