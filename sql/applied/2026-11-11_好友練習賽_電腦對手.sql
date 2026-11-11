-- 好友練習賽（線上開打）：可以加電腦對手，最多 3 位（2026-11-11 使用者：「線上開打的 邀牌咖 新增可以邀請3個電腦對手」）
-- 在 Supabase SQL Editor 執行。
--
-- 做法：電腦對手是三個系統帳號（每個機構一組：電腦一號、二號、三號），坐進牌局的方式跟真人一模一樣
--       （friendly_game_players → 成桌時進 session_players → 有座位、有積分、會被算名次）。
--       這樣牌局、計分、爆卡、結算、回放那一整條路一行都不用為它另外寫。
--       替它出牌的是牌桌後端（Edge Function online-game）：電腦對手的座位等同一直開著「電腦代打」。
--
-- 做了什麼
--   ① members 多一欄 is_bot；建三個電腦對手帳號（is_test = true ⇒ 排行、報表、v_real_* 本來就不會算到它們）
--   ② friendly_game_players.join_source 多一個值 bot
--   ③ 🆕 add_friendly_bots_tx(場次, 幾位)：開這一場的人替等人中的線上開打加電腦對手；湊滿四位就直接成桌
--   ④ _friendly_start：成桌通知不發給電腦
--   ⑤ _settle_notify_on_rank：牌局結束的通知（與後面的 LINE 推播）不發給電腦
--   ⑥ _friendly_view、_online_ctx：players 每人多回 is_bot
--
-- 跑完還要重新部署 Edge Function online-game（它要認得 is_bot，替電腦出牌、替電腦決定爆卡）。
--   沒部署之前：加了電腦對手的牌局開得出來，但輪到電腦時要等滿倒數才會被代打（不會壞，只是慢）。
--
-- 既有函式的本體：_friendly_start、_settle_notify_on_rank 是 2026-11-11 用 pg_get_functiondef 從線上撈的；
--   _friendly_view、_online_ctx 是今天歸檔的版本。都只加了標 🆕 的地方。

-- ① 欄位與三個電腦帳號
alter table public.members add column if not exists is_bot boolean not null default false;
comment on column public.members.is_bot is
  '電腦對手（系統帳號，不是真人）。只會出現在好友練習賽的線上開打；一律同時是 is_test = true。沒有 LINE、沒有手機，登不進 App。';

insert into public.members (org_id, display_name, is_test, is_bot, title, avatar_source, avatar_bear)
select o.id, n.name, true, true, '電腦對手', 'bear', n.bear
  from public.orgs o
 cross join (values ('電腦一號', 'silver'), ('電腦二號', 'gold'), ('電腦三號', 'platinum')) as n(name, bear)
 where not exists (select 1 from public.members m where m.org_id = o.id and m.is_bot and m.display_name = n.name);

-- ② 加入方式多一個值
alter table public.friendly_game_players drop constraint if exists friendly_game_players_join_source_check;
alter table public.friendly_game_players add constraint friendly_game_players_join_source_check
  check (join_source = any (array['open'::text, 'link'::text, 'buddy'::text, 'bot'::text]));

-- ③ 加電腦對手
create or replace function public.add_friendly_bots_tx(p_game uuid, p_count integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid; g friendly_games; v_n int; v_added int := 0; v_sid uuid; r record;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select * into g from friendly_games where id = p_game for update;
  if g.id is null or not exists (select 1 from friendly_game_players where game_id = p_game and member_id = v_me and left_at is null) then
    raise exception '你不在這一場好友練習賽裡';
  end if;
  if g.opened_by <> v_me then raise exception '只有開這一場的人可以加電腦對手'; end if;
  if g.status <> 'waiting' then raise exception '這一場已經開始了，不能再加電腦對手'; end if;
  if g.play_mode <> 'online' then raise exception '只有線上開打可以加電腦對手'; end if;
  if coalesce(p_count, 0) < 1 or p_count > 3 then raise exception '電腦對手一次加 1 到 3 位'; end if;
  select count(*) into v_n from friendly_game_players where game_id = p_game and left_at is null;
  if p_count > 4 - v_n then raise exception '只剩 % 個空位', 4 - v_n; end if;

  -- 還沒在這一場裡的電腦，照一號、二號、三號的順序補
  for r in
    select m.id from members m
     where m.org_id = g.org_id and m.is_bot and m.deleted_at is null
       and not exists (select 1 from friendly_game_players fp where fp.game_id = p_game and fp.member_id = m.id and fp.left_at is null)
     order by array_position(array['電腦一號', '電腦二號', '電腦三號']::text[], m.display_name), m.created_at
     limit p_count
  loop
    insert into friendly_game_players (org_id, game_id, member_id, join_source) values (g.org_id, p_game, r.id, 'bot');
    v_added := v_added + 1;
  end loop;
  if v_added < p_count then raise exception '電腦對手的設定不存在（請找總部）'; end if;   -- 整筆退回，不留半套

  if v_n + v_added = 4 then v_sid := public._friendly_start(p_game); end if;
  return jsonb_build_object('ok', true, 'added', v_added, 'started', v_sid is not null);
end $$;

-- 2026-09-29 起新函式預設就是關的；要給登入的客人叫 ⇒ 明確開；兩個方向都收乾淨
revoke execute on function public.add_friendly_bots_tx(uuid, integer) from public;
revoke execute on function public.add_friendly_bots_tx(uuid, integer) from anon;
grant  execute on function public.add_friendly_bots_tx(uuid, integer) to authenticated, service_role;

-- ④ 成桌：通知不發給電腦
create or replace function public._friendly_start(p_game uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  -- 🆕 電腦對手不發（它沒有 App）
  for r in select fp.member_id from friendly_game_players fp join members m on m.id = fp.member_id
            where fp.game_id = p_game and fp.left_at is null and not m.is_bot loop
    insert into app_notifications (org_id, member_id, type, ref_id, payload)
    values (g.org_id, r.member_id, 'friendly_ok', p_game,
            jsonb_build_object('text', case when g.play_mode = 'online'
                                            then '好友練習賽成桌了！打開牌桌開始線上打牌'
                                            else '好友練習賽成桌了！打開 MIGI 智慧計分板開始記分' end,
                               'game_id', p_game, 'play_mode', g.play_mode));
  end loop;
  return v_sid;
end $function$;

-- ⑤ 牌局結束的通知：不發給電腦（那一則通知後面還會排 LINE 推播，電腦沒有 LINE，發了只會在寄件匣留一筆「不送」）
create or replace function public._settle_notify_on_rank()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  begin
    insert into app_notifications (org_id, member_id, type, payload, ref_id)
    select ts.org_id, sp.member_id, 'settle',
           jsonb_build_object(
             'text',       case when ts.mode = 'friendly' then '好友練習賽結束了' else '牌局結算完成' end,
             'mode',       ts.mode,
             'session_id', ts.id,
             'store',      st.name,
             'stake',      sl.label,
             'at',         coalesce(ts.activated_at, ts.started_at)),   -- payload 跟 settle_session_tx 那段逐欄相同
           ts.id
      from (select distinct n.session_id
              from new_rows n join old_rows o on o.id = n.id
             where o.finish_rank is null and n.finish_rank is not null) x
      join table_sessions ts on ts.id = x.session_id
      join session_players sp on sp.session_id = ts.id and sp.org_id = ts.org_id and sp.member_id is not null
      join members         mb on mb.id = sp.member_id and not mb.is_bot       -- 🆕 電腦對手不發
      left join stores       st on st.id = ts.store_id       and st.org_id = ts.org_id
      left join stake_levels sl on sl.id = ts.stake_level_id and sl.org_id = ts.org_id
    on conflict (member_id, ref_id) where type = 'settle' do nothing;
  exception when others then
    /* 通知失敗不可以讓成績回滾；但不安靜吞掉，留一筆錯誤給錯誤儀表 */
    begin
      perform public.log_app_event_tx(null, null, 'push_error',
        jsonb_build_object('where', '_settle_notify_on_rank', 'code', sqlstate, 'message', left(sqlerrm, 300)),
        now(), null);
    exception when others then null;
    end;
  end;
  return null;
end $function$;

-- ⑥ 等人卡／進行中：players 多回 is_bot
create or replace function public._friendly_view(p_game uuid, p_member uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', g.id, 'status', g.status, 'is_host', (g.opened_by = p_member),
    'game_type', g.game_type, 'flower', g.flower, 'rounds', g.rounds, 'prefs', g.prefs,
    'play_mode', g.play_mode,
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
$$;

-- ⑥ 牌桌的整包資料：players 多回 is_bot
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
                                  -- 這一場開了哪幾個特殊規則（全紅／骰龜／豹子）。牌桌後端照它算台；空的 ＝ 都不算
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
                         -- 🆕 電腦對手：牌桌後端替它出牌（等同一直開著電腦代打）、爆卡時替它決定
                         'is_bot', m.is_bot,
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
declare v_msg text := ''; v_n int; v_m int; v_txt text;
  ok constant text := E'\n✅ '; ng constant text := E'\n🔴 ';
  f_add regprocedure := 'public.add_friendly_bots_tx(uuid, integer)'::regprocedure;
begin
  -- ① 欄位
  select data_type || '／可空 ' || is_nullable || '／預設 ' || coalesce(column_default, '無') into v_txt
    from information_schema.columns where table_schema = 'public' and table_name = 'members' and column_name = 'is_bot';
  v_msg := v_msg || case when v_txt = 'boolean／可空 NO／預設 false' then ok else ng end || '① members.is_bot：' || coalesce(v_txt, '沒有這一欄');

  -- ② 每個機構剛好三個電腦對手，而且全部是測試帳號、沒有 LINE、沒有手機（登不進 App、進不了任何報表）
  select count(*), count(*) filter (where n <> 3) into v_n, v_m
    from (select o.id, (select count(*) from members m where m.org_id = o.id and m.is_bot) as n from orgs o) x;
  select count(*) into v_m from (select o.id from orgs o where (select count(*) from members m where m.org_id = o.id and m.is_bot) <> 3) y;
  v_msg := v_msg || case when v_m = 0 and not exists (select 1 from members where is_bot and (not is_test or line_user_id is not null or phone is not null))
                         then ok else ng end || '② ' || v_n || ' 個機構各有三個電腦對手（不是三個的 ' || v_m || ' 個）；全部是測試帳號、沒有 LINE 與手機';

  -- ③ 負對照：真人一個都沒被標成電腦
  select count(*) into v_n from members where is_bot and display_name not in ('電腦一號', '電腦二號', '電腦三號');
  v_msg := v_msg || case when v_n = 0 then ok else ng end || '③ 被標成電腦的只有那三個名字（其他人被誤標 ' || v_n || ' 位）';

  -- ④ 加入方式的約束收 bot，原本的三個值還在
  select pg_get_constraintdef(oid) into v_txt from pg_constraint where conrelid = 'public.friendly_game_players'::regclass and conname = 'friendly_game_players_join_source_check';
  v_msg := v_msg || case when v_txt ~ 'bot' and v_txt ~ 'open' and v_txt ~ 'link' and v_txt ~ 'buddy' then ok else ng end || '④ 加入方式收 open／link／buddy／bot';

  -- ⑤ 新函式：一個版本、以擁有者身分執行、登入的人叫得動、沒登入的叫不動、PUBLIC 沒有、沒有會員編號的參數
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'add_friendly_bots_tx';
  v_msg := v_msg || case when v_n = 1 and (select prosecdef from pg_proc where oid = f_add)
                              and has_function_privilege('authenticated', f_add, 'execute') and not has_function_privilege('anon', f_add, 'execute')
                              and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = f_add and a.grantee = 0)
                              and pg_get_function_identity_arguments(f_add) !~* 'member'
                         then ok else ng end || '⑤ add_friendly_bots_tx：1 個版本、登入的人叫得動、沒登入的叫不動、不收會員編號';

  -- ⑥ 沒登入 ⇒ 拒絕（身分從登入來，不是參數）
  begin
    perform public.add_friendly_bots_tx(gen_random_uuid(), 1);
    v_msg := v_msg || ng || '⑥ 沒登入竟然叫得動';
  exception when others then
    v_msg := v_msg || case when sqlstate = '28000' then ok else ng end || '⑥ 沒登入 ⇒ 拒絕（' || sqlstate || '）';
  end;

  -- ⑦ 兩支通知函式都排除電腦；各只有一個版本
  v_msg := v_msg || case when pg_get_functiondef('public._friendly_start(uuid)'::regprocedure) ~ 'not m\.is_bot'
                              and pg_get_functiondef('public._settle_notify_on_rank()'::regprocedure) ~ 'not mb\.is_bot'
                              and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('_friendly_start', '_settle_notify_on_rank')) = 2
                         then ok else ng end || '⑦ 成桌通知與結束通知都不發給電腦';

  -- ⑧ 等人卡與牌桌整包資料都帶 is_bot；今天前幾份加的東西都還在；牌桌那支仍然只有後端叫得到
  v_txt := pg_get_functiondef('public._online_ctx(uuid)'::regprocedure);
  v_msg := v_msg || case when pg_get_functiondef('public._friendly_view(uuid, uuid)'::regprocedure) ~ '''is_bot'',\s*m\.is_bot'
                              and pg_get_functiondef('public._friendly_view(uuid, uuid)'::regprocedure) ~ '''special_rules'''
                              and v_txt ~ '''is_bot'',\s*m\.is_bot' and v_txt ~ '_member_outfit' and v_txt ~ 'o\.auto_on' and v_txt ~ 's\.game_type' and v_txt ~ 'g\.special_rules'
                              and not has_function_privilege('authenticated', 'public._online_ctx(uuid)'::regprocedure, 'execute')
                              and has_function_privilege('service_role', 'public._online_ctx(uuid)'::regprocedure, 'execute')
                         then ok else ng end || '⑧ _friendly_view 與 _online_ctx 帶 is_bot；配件、代打旗標、玩法、特殊規則都還在';

  perform set_config('migi.chk', ltrim(v_msg, E'\n'), true);
exception when others then
  -- 驗證自己出錯也不往外丟（丟了上面的東西會被退掉）：把原因印出來
  perform set_config('migi.chk', ltrim(v_msg, E'\n') || E'\n🔴 驗證段自己出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 8 格全綠）";
