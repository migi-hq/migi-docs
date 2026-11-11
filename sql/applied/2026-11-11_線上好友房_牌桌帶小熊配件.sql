-- 線上好友房：牌桌上的三隻小熊穿上每個人自己養的配件（2026-11-11 使用者：「要」）
-- 在 Supabase SQL Editor 執行。三支函式都是 CREATE OR REPLACE、簽名沒變 ⇒ 不用 DROP、原本的授權不會掉。
--
-- 做了什麼
--   ① 新增 _member_outfit(會員)：這個人現在穿什麼（只算目前還擁有的那幾件）。只給後端用，前端叫不到。
--      這段邏輯原本寫在 get_my_closet_tx 裡面；牌桌也要用，所以抽出來，兩邊叫同一支（不寫第二份）。
--   ② get_my_closet_tx：穿搭那一段改叫 ①，回傳的東西跟原本一模一樣。
--   ③ _online_ctx（牌桌後端讀整包資料那一支）：players 每個人多一個 outfit。
--      Edge Function 不用重新部署 —— 它把 players 原樣交給畫面。
--
-- 兩支既有函式的本體是 2026-11-11 用 pg_get_functiondef 從線上撈出來改的（不是拿舊檔案改）。

-- ① 這個人現在穿什麼
create or replace function public._member_outfit(p_member uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  /* 只留目前還擁有的那幾件（配件日後若被收回，讀的時候自動脫掉）。沒存過、沒穿 ⇒ 空的物件，不是 null */
  select coalesce((select jsonb_object_agg(e.key, e.value)
                     from member_app_state s, jsonb_each(coalesce(s.outfit, '{}'::jsonb)) e
                    where s.member_id = p_member
                      and exists (select 1 from public._member_closet(p_member) c where c.item = e.value #>> '{}')), '{}'::jsonb)
$function$;

-- 2026-09-29 起新函式預設就是關的；這裡再明寫一次，日後有人把預設改回去也不會漏
revoke execute on function public._member_outfit(uuid) from public, anon, authenticated;
grant  execute on function public._member_outfit(uuid) to service_role;

-- ② 衣櫃：穿搭改叫共用的那一支
create or replace function public.get_my_closet_tx()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_me uuid; v_org uuid; v_owned jsonb; v_how jsonb; v_outfit jsonb;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me and deleted_at is null;

  select coalesce(jsonb_agg(jsonb_build_object('item', c.item, 'source', c.source, 'got_at', c.got_at) order by c.got_at nulls last), '[]'::jsonb)
    into v_owned from public._member_closet(v_me) c;

  /* 還沒拿到、而且看得到的成就會送的那幾件：點反灰的配件時告訴客人要做什麼
     ⚠ 隱藏或剪影的成就不列 —— 列了等於把隱藏條件講出來（同 get_my_titles_tx） */
  select coalesce(jsonb_agg(jsonb_build_object('item', a.grants_closet, 'achievement', a.name, 'condition', a.condition_text)
                            order by a.sort, a.code), '[]'::jsonb)
    into v_how
    from achievements a
   where a.org_id = v_org and a.deleted_at is null and a.is_active
     and a.grants_closet is not null and a.visibility = 'visible'
     and not exists (select 1 from public._member_closet(v_me) c where c.item = a.grants_closet);

  /* 穿搭：只留目前還擁有的那幾件 —— 規則只有一份，牌桌上的小熊也讀同一支 */
  v_outfit := public._member_outfit(v_me);

  return jsonb_build_object('owned', v_owned, 'how', v_how, 'outfit', coalesce(v_outfit, '{}'::jsonb));
end $function$;

-- ③ 牌桌的整包資料：players 多一個 outfit
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
                                  'stake_label', sl.label, 'is_hygiene', coalesce(sl.is_hygiene, false), 'channel', s.score_channel),
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
    'presence', (select coalesce(jsonb_object_agg(o.seat::text, jsonb_build_object('last_seen_at', o.last_seen_at, 'auto_since', o.auto_since)), '{}'::jsonb)
                   from online_seats o where o.session_id = s.id));
end $function$;


-- ─── 驗證（單一 SELECT；這一段不丟錯誤，丟了會把上面三支一起退掉）───
do $$
declare v_msg text := ''; v_n int; v_m int; v_txt text;
  ok constant text := E'\n✅ '; ng constant text := E'\n🔴 '; na constant text := E'\n⚪ ';
  f_out regprocedure := 'public._member_outfit(uuid)'::regprocedure;
  f_ctx regprocedure := 'public._online_ctx(uuid)'::regprocedure;
  f_clo regprocedure := 'public.get_my_closet_tx()'::regprocedure;
begin
  -- ① 新函式：只有一個版本、以擁有者身分執行
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = '_member_outfit';
  v_msg := v_msg || case when v_n = 1 and (select prosecdef from pg_proc where oid = f_out) then ok else ng end
        || '① _member_outfit：' || v_n || ' 個版本、以擁有者身分執行';

  -- ② 前端叫不到它（明確授權與 PUBLIC 兩條路都看），後端叫得到
  v_msg := v_msg || case when not has_function_privilege('anon', f_out, 'execute') and not has_function_privilege('authenticated', f_out, 'execute')
                              and has_function_privilege('service_role', f_out, 'execute')
                              and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = f_out and a.grantee = 0)
                         then ok else ng end || '② _member_outfit：anon 與登入的人都叫不到、PUBLIC 沒有、後端叫得到';

  -- ③ 衣櫃改叫共用的那一支，而且登入的人照樣叫得動（CREATE OR REPLACE 不該掉授權）
  v_msg := v_msg || case when pg_get_functiondef(f_clo) ~ ':=\s*public\._member_outfit\('
                              and has_function_privilege('authenticated', f_clo, 'execute')
                              and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'get_my_closet_tx') = 1
                         then ok else ng end || '③ get_my_closet_tx：穿搭改叫共用那一支、登入的人照樣叫得動、只有一個版本';

  -- ④ 牌桌整包資料：players 帶 outfit；仍然只有後端叫得到
  v_msg := v_msg || case when pg_get_functiondef(f_ctx) ~ '''outfit'',\s*public\._member_outfit\(m\.id\)'
                              and not has_function_privilege('anon', f_ctx, 'execute') and not has_function_privilege('authenticated', f_ctx, 'execute')
                              and has_function_privilege('service_role', f_ctx, 'execute')
                         then ok else ng end || '④ _online_ctx：players 帶 outfit、仍然只有後端叫得到';

  -- ⑤ 抽出來之後算的跟原本寫在衣櫃裡的那一段一樣：每一位有存過小熊狀態的會員逐一比
  select count(*), count(*) filter (where public._member_outfit(s.member_id) is distinct from
           coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(s.outfit) e
                      where exists (select 1 from public._member_closet(s.member_id) c where c.item = e.value #>> '{}')), '{}'::jsonb))
    into v_n, v_m from member_app_state s;
  v_msg := v_msg || case when v_m = 0 then ok else ng end || '⑤ 跟原本的算法逐人比對：' || v_n || ' 位裡不一樣的 ' || v_m || ' 位';

  -- ⑥ 正對照：真的有人算得出有穿東西（全部都是空的話，⑤ 一支永遠回空物件的函式也會過）
  select count(*), min(public._member_outfit(s.member_id)::text) into v_n, v_txt
    from member_app_state s where public._member_outfit(s.member_id) <> '{}'::jsonb;
  v_msg := v_msg || case when v_n > 0 then ok || '⑥ 正對照：有穿配件的會員 ' || v_n || ' 位（例：' || v_txt || '）'
                         else na || '⑥ 正對照測不了：目前沒有任何會員穿著自己擁有的配件' end;

  -- ⑦ 沒存過狀態的人 ⇒ 空的物件，不是 null（畫面直接當「沒穿」）
  v_msg := v_msg || case when public._member_outfit(gen_random_uuid()) = '{}'::jsonb then ok else ng end || '⑦ 沒有紀錄的人 ⇒ 空的物件';

  perform set_config('migi.chk', ltrim(v_msg, E'\n'), true);
exception when others then
  -- 驗證自己出錯也不往外丟（丟了上面三支會被退掉）：把原因印出來
  perform set_config('migi.chk', ltrim(v_msg, E'\n') || E'\n🔴 驗證段自己出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 7 格；⑥ 沒有人穿配件時會是 ⚪）";
