-- 好友練習賽：開一場時可以選「特殊規則」（骰龜／豹子／全紅），預設都不開（2026-11-11 使用者）
-- 在 Supabase SQL Editor 執行。
--
-- 為什麼
--   線上打的牌局原本三個骰子規則一律都算。使用者要在「開一場好友練習賽」最下面加「特殊規則」：
--   預設勾「沒有」，另外有 骰龜、豹子、全紅 可以勾 ⇒ 要記在這一場上，牌桌後端照它算台。
--
-- 做了什麼
--   ① friendly_games 多一欄 special_rules（文字陣列，只收 quanhong 全紅／shaigui 骰龜／baozi 豹子；預設空的 ＝ 都不開）。
--      代碼用牌型主檔 scoring_patterns 的同一組（不另外發明一套字）
--   ② create_friendly_game_tx 多一個參數 p_special_rules（放最後、有預設值 ⇒ 沒送的舊版 App 照樣叫得動，等於都不開）。
--      改簽名 ⇒ 先 DROP 舊的再重建，GRANT 補回去
--   ③ _friendly_view（等人卡、成桌彈窗、邀請卡片讀的）多回 special_rules
--   ④ _online_ctx（牌桌後端讀的整包資料）的 session 多回 special_rules
--
-- 🔴 行為會變的地方：這份跑完之後，**新開的線上打預設三個骰子規則都不算**（以前是都算）。
--    線上打目前只有本機開發開得出來，線上沒有任何一場正在打的線上牌局，所以沒有既有的牌局受影響。
-- 跑完之後還要重新部署 Edge Function online-game（它要把這一欄交給引擎）。
--    沒部署之前：後端不認得這一欄，照舊三個都算（不會壞，只是選了「沒有」也還是會算）。
--
-- 三支既有函式的本體是今天歸檔的版本（2026-11-11_線上好友房_開一場選線上打.sql、…_自己開電腦代打.sql），只加了標 🆕 的地方。

-- ① 欄位
alter table public.friendly_games add column if not exists special_rules text[] not null default '{}'::text[];
alter table public.friendly_games drop constraint if exists friendly_games_special_rules_check;
alter table public.friendly_games add constraint friendly_games_special_rules_check
  check (special_rules <@ array['quanhong', 'shaigui', 'baozi']::text[]);
comment on column public.friendly_games.special_rules is
  '這一場開了哪幾個特殊規則：quanhong 全紅／shaigui 骰龜／baozi 豹子（代碼同 scoring_patterns）。空的 ＝ 都不開（預設）。線上打的牌桌後端照它算台。';

-- ② 開一場：多一個參數
drop function if exists public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text);

create or replace function public.create_friendly_game_tx(
  p_stake uuid, p_play_at timestamptz, p_game_type text default '台麻', p_flower text default '無花',
  p_rounds text default '2 將', p_prefs jsonb default '{}'::jsonb, p_invite uuid[] default '{}'::uuid[],
  p_play_mode text default 'scoreboard', p_special_rules text[] default '{}'::text[])
returns jsonb language plpgsql security definer set search_path = public as $$
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
  -- 🆕 特殊規則：沒送 ＝ 都不開。不認得的代碼直接擋（不安靜略過 —— 客人以為開了、實際沒開，會在算台的時候才發現）；重複的收成一個、順序固定
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
  insert into friendly_games (org_id, opened_by, stake_level_id, game_type, flower, rounds, prefs, play_at, invite_token, play_mode, special_rules)
  values (v_org, v_me, p_stake, p_game_type, p_flower, v_rounds, coalesce(p_prefs, '{}'::jsonb), p_play_at, v_tok, v_mode, v_rules)
  returning id into v_gid;
  insert into friendly_game_players (org_id, game_id, member_id, join_source) values (v_org, v_gid, v_me, 'open');

  -- 「＋ 邀牌咖加入」選的人（不是牌咖、有封鎖的會被安靜略過）
  foreach v_inv in array coalesce(p_invite, '{}'::uuid[]) loop
    if public._friendly_invite(v_gid, v_me, v_inv) then v_sent := v_sent + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'game_id', v_gid, 'token', v_tok, 'invited', v_sent, 'play_mode', v_mode, 'special_rules', to_jsonb(v_rules));
end $$;

-- DROP 重建 ＝ 新建 ⇒ 預設是關的，要明確開給登入的人；兩個方向都收乾淨（硬規則 2.6／2.7）
revoke execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text, text[]) from public;
revoke execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text, text[]) from anon;
grant  execute on function public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text, text[]) to authenticated, service_role;

-- ③ 等人卡／進行中：多回 special_rules（簽名不變 ⇒ CREATE OR REPLACE，不用 DROP、GRANT 還在）
create or replace function public._friendly_view(p_game uuid, p_member uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', g.id, 'status', g.status, 'is_host', (g.opened_by = p_member),
    'game_type', g.game_type, 'flower', g.flower, 'rounds', g.rounds, 'prefs', g.prefs,
    'play_mode', g.play_mode,
    -- 🆕 這一場開了哪幾個特殊規則（空的 ＝ 都不開）
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

-- ④ 牌桌的整包資料：session 多回 special_rules
create or replace function public._online_ctx(p_session uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare s table_sessions; g friendly_games; sl stake_levels; r session_rounds; h online_hands; v_rs jsonb;
begin
  select * into s from table_sessions where id = p_session;
  if s.id is null or s.mode <> 'friendly' then
    return jsonb_build_object('ok', false, 'reason', 'no_session');
  end if;
  select * into g from friendly_games where session_id = s.id;
  if g.id is null or g.play_mode <> 'online' then
    return jsonb_build_object('ok', false, 'reason', 'not_online');
  end if;
  select * into sl from stake_levels where id = s.stake_level_id;
  select * into r from session_rounds where session_id = s.id and status <> 'voided' order by round_no desc limit 1;
  if r.id is not null then v_rs := public._tbl_round_state(r.id); end if;
  select * into h from online_hands where session_id = s.id order by created_at desc, hand_no desc limit 1;
  return jsonb_build_object(
    'ok', true,
    'session', jsonb_build_object('id', s.id, 'org_id', s.org_id, 'status', s.status, 'flower', (s.flower = '有花'),
                                  'planned_rounds', coalesce(s.planned_rounds, 1), 'base', coalesce(sl.base, 0), 'unit', coalesce(sl.tai, 0),
                                  'stake_label', sl.label, 'is_hygiene', coalesce(sl.is_hygiene, false), 'channel', s.score_channel,
                                  -- 牌桌右下角那一行（玩法、使用時間）要用的：這一場什麼玩法、幾點開始的
                                  'game_type', s.game_type, 'started_at', s.started_at,
                                  -- 🆕 這一場開了哪幾個特殊規則（全紅／骰龜／豹子）。牌桌後端照它算台；空的 ＝ 都不算
                                  'special_rules', to_jsonb(g.special_rules)),
    'game', jsonb_build_object('id', g.id, 'status', g.status),
    'scored', public._session_scored(s.id),
    'rounds_done', (select count(*) from session_rounds where session_id = s.id and status = 'finished'),
    'round', case when r.id is null then null else jsonb_build_object(
               'id', r.id, 'round_no', r.round_no, 'status', r.status,
               'ring', to_jsonb(coalesce(r.seat_ring, '{1,2,3,4}'::smallint[])), 'state', v_rs) end,
    'hand', case when h.id is null then null else jsonb_build_object(
               'id', h.id, 'round_id', h.round_id, 'hand_no', h.hand_no, 'version', h.version, 'status', h.status, 'phase', h.phase,
               'deadline_at', h.deadline_at, 'dealer_seat', h.dealer_seat, 'renzhuang', h.renzhuang,
               'dice', to_jsonb(h.dice), 'seat_dice', to_jsonb(h.seat_dice), 'state', h.state,
               'started_at', h.started_at, 'ended_at', h.ended_at,
               -- 實際入帳的增減（爆卡時只付得出剩下的 ⇒ 可能比引擎算的少）
               'applied', (select hh.score_delta from hands hh where hh.id = h.hand_id)) end,
    'players', (select coalesce(jsonb_agg(jsonb_build_object(
                         'seat', sp.seat, 'member_id', m.id, 'nickname', m.display_name, 'rank', m.rank, 'title', m.title,
                         'avatar_url', m.avatar_url, 'avatar_source', m.avatar_source,
                         'avatar_photo_path', m.avatar_photo_path, 'avatar_bear', m.avatar_bear,
                         -- 這個人養的小熊現在穿什麼（牌桌上對家、上家、下家那三隻照著穿）
                         'outfit', public._member_outfit(m.id),
                         'finish_rank', sp.finish_rank, 'final_score', sp.final_score) order by sp.seat nulls last, sp.joined_at), '[]'::jsonb)
                  from session_players sp join members m on m.id = sp.member_id
                 where sp.session_id = s.id and sp.left_at is null),
    'balances', public._tbl_balances(s.id),
    'bust', (select jsonb_build_object('seat', b.seat) from session_busts b
              where b.session_id = s.id and b.decision = 'pending' order by b.seat limit 1),
    'cat', (select coalesce(jsonb_agg(jsonb_build_object(
                     'code', p.code, 'label', p.label, 'tai', p.tai, 'max_count', p.max_count,
                     'conflicts', to_jsonb(coalesce(p.conflicts, '{}'::text[])),
                     'flower_conflicts', to_jsonb(coalesce(p.flower_conflicts, '{}'::text[]))) order by p.sort), '[]'::jsonb)
              from scoring_patterns p where p.is_active),
    -- auto_since ＝ 逾時後由後端代打；auto_on ＝ 他自己開了「電腦代打」。畫面上兩種都標「某某 電腦代打中」
    'presence', (select coalesce(jsonb_object_agg(o.seat::text, jsonb_build_object('last_seen_at', o.last_seen_at, 'auto_since', o.auto_since, 'auto_on', o.auto_on)), '{}'::jsonb)
                   from online_seats o where o.session_id = s.id));
end $function$;


-- ─── 驗證（單一 SELECT；這一段不丟錯誤，丟了會把上面的東西一起退掉）───
do $$
declare v_msg text := ''; v_n int; v_txt text;
  ok constant text := E'\n✅ '; ng constant text := E'\n🔴 ';
  f_new regprocedure := 'public.create_friendly_game_tx(uuid, timestamptz, text, text, text, jsonb, uuid[], text, text[])'::regprocedure;
  f_view regprocedure := 'public._friendly_view(uuid, uuid)'::regprocedure;
  f_ctx regprocedure := 'public._online_ctx(uuid)'::regprocedure;
begin
  -- ① 欄位：文字陣列、不可空、預設空的
  select udt_name || '／可空 ' || is_nullable || '／預設 ' || coalesce(column_default, '無') into v_txt
    from information_schema.columns where table_schema = 'public' and table_name = 'friendly_games' and column_name = 'special_rules';
  v_msg := v_msg || case when v_txt like '_text／可空 NO／預設 ''{}''%' then ok else ng end || '① friendly_games.special_rules：' || coalesce(v_txt, '沒有這一欄');

  -- ② 約束：只收三個代碼
  select pg_get_constraintdef(oid) into v_txt from pg_constraint where conrelid = 'public.friendly_games'::regclass and conname = 'friendly_games_special_rules_check';
  v_msg := v_msg || case when v_txt ~ 'quanhong' and v_txt ~ 'shaigui' and v_txt ~ 'baozi' and v_txt ~ '<@' then ok else ng end
        || '② 約束只收 quanhong／shaigui／baozi（' || coalesce(v_txt, '沒有這條約束') || '）';

  -- ③ 既有的好友練習賽全部是「都不開」（加欄位不該替任何一場開規則）
  select count(*) filter (where special_rules <> '{}'::text[]), count(*) into v_n, v_txt from friendly_games;
  v_msg := v_msg || case when v_n = 0 then ok else ng end || '③ 既有 ' || v_txt || ' 場裡有開特殊規則的 ' || v_n || ' 場';

  -- ④ 開一場：只有一個版本（舊簽名真的丟掉了，沒有多載）、以擁有者身分執行
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'create_friendly_game_tx';
  v_msg := v_msg || case when v_n = 1 and (select prosecdef from pg_proc where oid = f_new) then ok else ng end
        || '④ create_friendly_game_tx：' || v_n || ' 個版本、以擁有者身分執行';

  -- ⑤ 授權：登入的人叫得動（DROP 重建之後有補回來）、沒登入的叫不動、PUBLIC 沒有
  v_msg := v_msg || case when has_function_privilege('authenticated', f_new, 'execute') and not has_function_privilege('anon', f_new, 'execute')
                              and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = f_new and a.grantee = 0)
                         then ok else ng end || '⑤ create_friendly_game_tx：登入的人叫得動、沒登入的叫不動、PUBLIC 沒有';

  -- ⑥ 新參數放最後而且有預設值（沒送的舊版 App 照樣叫得動）；打法那個參數還在
  v_txt := pg_get_function_arguments(f_new);
  v_msg := v_msg || case when v_txt ~ 'p_special_rules text\[\] DEFAULT ''\{\}''::text\[\]$' and v_txt ~ 'p_play_mode text DEFAULT ''scoreboard''' then ok else ng end
        || '⑥ p_special_rules 在最後、有預設值；p_play_mode 還在';

  -- ⑦ 等人卡的資料帶 special_rules；原本的 play_mode 還在；授權沒變（只有後端與其他函式從內部叫）
  v_msg := v_msg || case when pg_get_functiondef(f_view) ~ '''special_rules'',\s*to_jsonb\(g\.special_rules\)' and pg_get_functiondef(f_view) ~ '''play_mode'',\s*g\.play_mode'
                              and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_friendly_view') = 1
                         then ok else ng end || '⑦ _friendly_view：帶 special_rules、play_mode 還在、只有一個版本';

  -- ⑧ 牌桌整包資料：session 帶 special_rules；今天前兩份加的東西都還在（配件、代打旗標、玩法與開始時間）；仍然只有後端叫得到
  v_msg := v_msg || case when pg_get_functiondef(f_ctx) ~ '''special_rules'',\s*to_jsonb\(g\.special_rules\)'
                              and pg_get_functiondef(f_ctx) ~ '''outfit'',\s*public\._member_outfit\(m\.id\)'
                              and pg_get_functiondef(f_ctx) ~ '''auto_on'',\s*o\.auto_on'
                              and pg_get_functiondef(f_ctx) ~ '''game_type'',\s*s\.game_type'
                              and not has_function_privilege('anon', f_ctx, 'execute') and not has_function_privilege('authenticated', f_ctx, 'execute')
                              and has_function_privilege('service_role', f_ctx, 'execute')
                              and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_online_ctx') = 1
                         then ok else ng end || '⑧ _online_ctx：session 帶 special_rules、配件與代打旗標與玩法都還在、仍然只有後端叫得到';

  perform set_config('migi.chk', ltrim(v_msg, E'\n'), true);
exception when others then
  -- 驗證自己出錯也不往外丟（丟了上面的東西會被退掉）：把原因印出來
  perform set_config('migi.chk', ltrim(v_msg, E'\n') || E'\n🔴 驗證段自己出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 8 格全綠）";
