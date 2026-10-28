/* ============================================================
   牌局回放：讀這一場智慧計分板的每一局（會員 App「牌局詳情 → ▶ 牌局回放」）
   2026-10-28 · MIGI 咪吉麻將

   ── 起因 ────────────────────────────────────────────────
   使用者：「目前牌局回放放的是第四階段影像辨識的模擬資料，改成目前計分板的牌局紀錄」。
   原本那一頁（stats.jsx 的 MatchDetail）是寫死的逐手牌譜與「本局重點」，那要等牌譜辨識。
   計分板 09-25 起每一局都記在 hands，可以直接接。版面 10-28 定案：
   返回標題 → 我的積分走勢 → 逐局紀錄（篩第 N 將／跟我有關）。

   ── 這份做兩件事 ──────────────────────────────────────────
   ① _session_hands(session)：這一場已入帳、沒有撤銷的每一局，由舊到新（後端用，前端叫不到）
      · 牌型帶中文名（scoring_patterns.label），前端不用另外讀主檔
      · tai_total 用 _hand_tai_total（「這一局幾台」唯一一份，跟平板、成績頁一樣）
      · 咔啦碰、分紅、包牌也列（跟計分板紀錄頁一樣，都是這一場發生過的加減）
      · 被拒絕、撤銷的不列（那些沒有入帳）
   ② get_my_game_hands_tx(session)：會員 App 讀
      · 身分一律 current_member_id()（不收「你是誰」）
      · 🔴 只有坐過這一場的人讀得到（不在 session_players 裡回 not_in_session，不給資料）
      · 回 my_seat，前端拿它算「這一局你加減多少」

   ⚠ 新建的函式預設全關（硬規則 2.7）⇒ ② 一定要 grant authenticated，否則前端一叫就 permission denied
   ============================================================ */

-- ① 這一場的每一局（後端用）
create or replace function public._session_hands(p_session_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'round_no',       r.round_no,
           'hand_no',        h.hand_no,
           'wind',           h.wind,
           'dealer_seat',    h.dealer_seat,
           'renzhuang',      coalesce(h.renzhuang, 0),
           'result',         h.result,
           'winner_seat',    h.winner_seat,
           'deal_in_seat',   h.deal_in_seat,
           'submitted_seat', h.submitted_seat,
           'patterns',       coalesce((
              select jsonb_agg(jsonb_build_object('code', x->>'code',
                                                  'n',    coalesce((x->>'n')::int, 1),
                                                  'label', coalesce(sp.label, x->>'code'))
                               order by sp.sort nulls last)
                from jsonb_array_elements(coalesce(h.patterns, '[]'::jsonb)) x
                left join scoring_patterns sp on sp.code = x->>'code'), '[]'::jsonb),
           'tai_pattern',    coalesce(h.tai_pattern, 0),
           'tai_total',      public._hand_tai_total(h.result, h.tai_pattern, h.patterns,
                                                    h.winner_seat, h.deal_in_seat, h.dealer_seat, h.renzhuang),
           'manual_tai',     coalesce(h.manual_tai, false),
           'score_delta',    coalesce(h.score_delta, '{}'::jsonb),
           'at',             coalesce(h.confirmed_at, h.created_at)
         ) order by r.round_no, coalesce(h.confirmed_at, h.created_at), h.created_at), '[]'::jsonb)
    from hands h
    join session_rounds r on r.id = h.round_id
   where h.session_id = p_session_id
     and h.status = 'confirmed'
     and h.undone_at is null
$$;

revoke execute on function public._session_hands(uuid) from public, anon, authenticated;

-- ② 會員 App 讀（只有坐過這一場的人）
create or replace function public.get_my_game_hands_tx(p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mem  uuid := public.current_member_id();
  v_seat smallint;
begin
  if v_mem is null then
    raise exception '未登入，請重新打開 App' using errcode = '28000';
  end if;
  select sp.seat into v_seat
    from session_players sp
    join table_sessions s on s.id = sp.session_id
   where sp.session_id = p_session_id
     and sp.member_id  = v_mem
     and s.deleted_at is null
   limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in_session');
  end if;
  return jsonb_build_object('ok', true, 'my_seat', v_seat, 'hands', public._session_hands(p_session_id));
end $$;

revoke execute on function public.get_my_game_hands_tx(uuid) from public, anon;
grant  execute on function public.get_my_game_hands_tx(uuid) to authenticated;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise 印訊息 —— 硬規則 1.8）
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_m   int;
  v_sid uuid;
  v_arr jsonb;
begin
  -- ① 兩支都在、都是 DEFINER
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('_session_hands', 'get_my_game_hands_tx') and prosecdef;
  v_msg := v_msg || case when v_n = 2 then '✅' else '🔴' end || ' ① 新函式 ' || v_n || E' 支（要 2，都是 DEFINER）\n';

  -- ② 正對照：拿最近一場有入帳局的牌局，回傳的局數要等於直接數出來的
  select h.session_id into v_sid from hands h
   where h.status = 'confirmed' and h.undone_at is null
   order by h.created_at desc limit 1;
  v_arr := public._session_hands(v_sid);
  select count(*) into v_m from hands h
   where h.session_id = v_sid and h.status = 'confirmed' and h.undone_at is null;
  v_msg := v_msg || case when v_sid is not null and jsonb_array_length(v_arr) = v_m and v_m > 0 then '✅' else '🔴' end
        || ' ② 最近一場：回 ' || coalesce(jsonb_array_length(v_arr), 0) || ' 局、直接數 ' || v_m || E' 局（要相等且 > 0）\n';

  -- ③ 負對照：被拒絕、撤銷的局不可以出現（拿一場有那種局的牌局）
  select h.session_id into v_sid from hands h
   where h.status in ('rejected', 'undone') order by h.created_at desc limit 1;
  select count(*) into v_n from hands h
   where h.session_id = v_sid and h.status = 'confirmed' and h.undone_at is null;
  v_msg := v_msg || case when v_sid is null then '⚪'
                         when jsonb_array_length(public._session_hands(v_sid)) = v_n then '✅' else '🔴' end
        || ' ③ 有拒絕／撤銷局的那一場：回 ' || coalesce(jsonb_array_length(public._session_hands(v_sid)), 0)
        || ' 局、入帳 ' || v_n || E' 局（要相等，不含沒入帳的）\n';

  -- ④ 牌型有中文名、台數有算（取一局自摸看）
  select x into v_arr from jsonb_array_elements(public._session_hands(
           (select session_id from hands where status = 'confirmed' and result = 'tsumo' order by created_at desc limit 1))) x
   where x->>'result' = 'tsumo' limit 1;
  v_msg := v_msg || case when v_arr->'patterns'->0->>'label' is not null and (v_arr->>'tai_total')::int > 0 then '✅' else '🔴' end
        || ' ④ 例：自摸 ' || coalesce(v_arr->>'tai_total', '?') || ' 台，牌型 '
        || coalesce((select string_agg(p->>'label', '、') from jsonb_array_elements(v_arr->'patterns') p), '（沒有）') || E'\n';

  -- ⑤ 授權：讀的那支只給登入的人；後端那支前端叫不到；anon／PUBLIC 都叫不到
  select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_session_hands', 'get_my_game_hands_tx')
     and a.privilege_type = 'EXECUTE'
     and (a.grantee in (0, 'anon'::regrole::oid)
          or (p.proname = '_session_hands' and a.grantee = 'authenticated'::regrole::oid));
  select count(*) into v_m from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname = 'get_my_game_hands_tx' and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v_msg := v_msg || case when v_n = 0 and v_m = 1 then '✅' else '🔴' end
        || ' ⑤ 不該叫得到的 ' || v_n || ' 個（要 0）、讀的那支登入的人叫得到 ' || v_m || '（要 1）';

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 驗證段沒有跑到') as "驗證";
