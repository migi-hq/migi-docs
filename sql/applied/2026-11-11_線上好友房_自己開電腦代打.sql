-- 線上好友房：自己開「電腦代打」，另外三家也看得到（2026-11-11 使用者：「要動後端 開始做」）
-- 在 Supabase SQL Editor 執行。
--
-- 為什麼要動後端
--   牌桌左下角的「電腦代打」原本只是自己手機上的開關，後端不知道 ⇒ 另外三家看不到「某某 電腦代打中」
--   （那顆標籤原本只標「逾時之後被後端代打」的人，看的是 online_seats.auto_since）。
--
-- 做了什麼
--   ① online_seats 多一欄 auto_on（自己開的代打；預設關）。跟 auto_since 分開記：
--        auto_since ＝ 逾時了、後端替他出手（本人再動一次就清掉）
--        auto_on    ＝ 他自己按了「電腦代打」（要自己關，或再按一次才會關；出牌不會把它清掉）
--      一欄一個意思 —— 混在同一欄的話，開著代打的人自己的手機每送一個動作就會把標籤清掉
--   ② 🆕 online_set_auto_tx(場次, 座位, 開或關)：牌桌後端替客人寫這一欄。只有後端叫得到，
--      座位由後端從登入身分認好傳進來（同 online_bust_decide_tx 的做法），這一支不收會員編號
--   ③ _online_ctx：presence 每個座位多回 auto_on；session 多回 game_type、started_at（牌桌右下角要寫「台麻 無花 50/20 3將 使用時間」）。
--      其餘一個字沒動（本體是今天歸檔的那一版）
--
-- 跑完之後還要做一件事：重新部署 Edge Function online-game（多一個動作 auto）。沒部署之前按那顆開關不會壞，只是別人看不到。

-- ① 欄位
alter table public.online_seats add column if not exists auto_on boolean not null default false;
comment on column public.online_seats.auto_on is
  '這個座位的人自己開了「電腦代打」（牌桌左下角那顆）。跟 auto_since 是兩件事：auto_since 是逾時之後後端替他出手、本人一動就清掉；auto_on 要他自己關。';

-- ② 開／關
create or replace function public.online_set_auto_tx(p_session uuid, p_seat smallint, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare s table_sessions;
begin
  select * into s from table_sessions where id = p_session;
  if s.id is null or s.mode <> 'friendly'
     or not exists (select 1 from friendly_games g where g.session_id = s.id and g.play_mode = 'online') then
    return jsonb_build_object('ok', false, 'reason', 'not_online');
  end if;
  -- 座位要真的有人坐著（還沒開第一將、座位還沒排的時候是 null ⇒ 回 bad_seat，畫面那時也還沒有這顆開關）
  if p_seat is null or not exists (select 1 from session_players sp where sp.session_id = s.id and sp.seat = p_seat and sp.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_seat');
  end if;
  insert into online_seats (session_id, seat, org_id, auto_on)
  values (s.id, p_seat, s.org_id, coalesce(p_on, false))
  on conflict (session_id, seat) do update set auto_on = excluded.auto_on;
  perform public._tbl_ping(s.id);      -- 通知四支手機重讀（別人的畫面才會馬上出現／消失那顆標籤）
  return jsonb_build_object('ok', true, 'auto_on', coalesce(p_on, false));
end $function$;

-- 2026-09-29 起新函式預設就是關的；這裡明寫一次，日後有人把預設改回去也不會漏
revoke execute on function public.online_set_auto_tx(uuid, smallint, boolean) from public, anon, authenticated;
grant  execute on function public.online_set_auto_tx(uuid, smallint, boolean) to service_role;

-- ③ 牌桌的整包資料：presence 多回 auto_on
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
                                  'game_type', s.game_type, 'started_at', s.started_at),
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
  f_set regprocedure := 'public.online_set_auto_tx(uuid, smallint, boolean)'::regprocedure;
  f_ctx regprocedure := 'public._online_ctx(uuid)'::regprocedure;
begin
  -- ① 欄位：布林、不可空、預設關
  select data_type || '／可空 ' || is_nullable || '／預設 ' || coalesce(column_default, '無') into v_txt
    from information_schema.columns where table_schema = 'public' and table_name = 'online_seats' and column_name = 'auto_on';
  v_msg := v_msg || case when v_txt = 'boolean／可空 NO／預設 false' then ok else ng end || '① online_seats.auto_on：' || coalesce(v_txt, '沒有這一欄');

  -- ② 既有的座位紀錄全部是關的（加欄位不該讓任何人突然變成代打中）
  select count(*) filter (where auto_on), count(*) into v_n, v_txt from online_seats;
  v_msg := v_msg || case when v_n = 0 then ok else ng end || '② 既有 ' || v_txt || ' 列座位紀錄裡開著的 ' || v_n || ' 列';

  -- ③ 新函式：只有一個版本、以擁有者身分執行
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'online_set_auto_tx';
  v_msg := v_msg || case when v_n = 1 and (select prosecdef from pg_proc where oid = f_set) then ok else ng end
        || '③ online_set_auto_tx：' || v_n || ' 個版本、以擁有者身分執行';

  -- ④ 前端叫不到它（明確授權與 PUBLIC 兩條路都看），後端叫得到
  v_msg := v_msg || case when not has_function_privilege('anon', f_set, 'execute') and not has_function_privilege('authenticated', f_set, 'execute')
                              and has_function_privilege('service_role', f_set, 'execute')
                              and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = f_set and a.grantee = 0)
                         then ok else ng end || '④ online_set_auto_tx：anon 與登入的人都叫不到、PUBLIC 沒有、後端叫得到';

  -- ⑤ 它沒有任何會員編號的參數（身分不由呼叫端宣告）
  v_txt := pg_get_function_identity_arguments(f_set);
  v_msg := v_msg || case when v_txt !~* 'member' then ok else ng end || '⑤ 參數裡沒有會員編號（' || v_txt || '）';

  -- ⑥ 牌桌整包資料：presence 帶 auto_on；小熊配件那一行還在（沒被這次蓋掉）；仍然只有後端叫得到、只有一個版本
  v_msg := v_msg || case when pg_get_functiondef(f_ctx) ~ '''auto_on'',\s*o\.auto_on'
                              and pg_get_functiondef(f_ctx) ~ '''game_type'',\s*s\.game_type,\s*''started_at'',\s*s\.started_at'
                              and pg_get_functiondef(f_ctx) ~ '''outfit'',\s*public\._member_outfit\(m\.id\)'
                              and not has_function_privilege('anon', f_ctx, 'execute') and not has_function_privilege('authenticated', f_ctx, 'execute')
                              and has_function_privilege('service_role', f_ctx, 'execute')
                              and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_online_ctx') = 1
                         then ok else ng end || '⑥ _online_ctx：presence 帶 auto_on、session 帶玩法與開始時間、配件那一行還在、仍然只有後端叫得到';

  -- ⑦ 不是線上好友房的場次 ⇒ 拒絕（不會憑空寫一列座位紀錄）
  v_txt := public.online_set_auto_tx(gen_random_uuid(), 1::smallint, true) ->> 'reason';
  v_msg := v_msg || case when v_txt = 'not_online' then ok else ng end || '⑦ 不存在的場次 ⇒ ' || coalesce(v_txt, '?');

  perform set_config('migi.chk', ltrim(v_msg, E'\n'), true);
exception when others then
  -- 驗證自己出錯也不往外丟（丟了上面的東西會被退掉）：把原因印出來
  perform set_config('migi.chk', ltrim(v_msg, E'\n') || E'\n🔴 驗證段自己出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 7 格全綠）";
