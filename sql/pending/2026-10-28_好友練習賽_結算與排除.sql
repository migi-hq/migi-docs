-- ============================================================
-- 2026-10-28 好友練習賽 · 第 ② 批：結算與排除
-- 規格：docs/03-會員App與社交/好友練習賽.md（第三節 7、第五、六節）
--
-- 一、結算（_score_settle_tx 多一個分支）
--   好友練習賽打完：照樣寫名次與桌上積分（好友練習賽的數據要用），
--   **不算段位分**（不叫 apply_session_rounds_tx ⇒ settled_at、rating_after、score_points 都留空）、
--   **不發成就**，friendly_games 標成 finished。
--   場次先不關：手機還要看牌局結束卡；15 分鐘後由排程收掉（第四節）。
--
-- 二、通知與 LINE 結算卡
--   通知文字「好友練習賽結束了」、payload 多帶 mode；
--   結算卡沒有段位分、目前段位、門市、桌號，多一列「類型：好友練習賽」，按鈕連到 App 的好友練習賽頁（?go=friendly）。
--   成桌仍然不推（第 ① 批已定）。
--
-- 三、排除（每一支都撈過線上全文；只改「找得到、而且剛好出現那麼多次」的那一段，對不上就整份不提交）
--   ⚠ 先查過的事實：settled_at **只有** apply_session_rounds_tx 會寫 ⇒ 好友練習賽的 settled_at 永遠是空的，
--     凡是要求它有值的讀取（每一局統計、最近亮點、賽季排名、本季對手數、賽季成就）**自動排除，不用改**。
--   要明確加條件的：
--     _member_stats_core（6 處）、get_my_games_tx、get_member_card_tx、_pair_history、
--     _member_home_store、_team_session_ids、list_recent_players_tx、
--     like_player_tx／dislike_player_tx（好友練習賽不做評價，也擋刷讚刷餅乾）
--   其他：_game_row 的 kind 多一個 friendly（好友練習賽的紀錄列直接共用它）、
--     _tbl_state_for_device 的 session 多回 mode（計分板據此標「好友練習賽」）、好友練習賽不標全國第一、
--     後台門市清單藏虛擬門市、平板配對擋虛擬桌
--
-- 四、排程 sweep_friendly_tx 改寫（原本只處理「過時沒湊滿」）
--   · 打完 15 分鐘 ⇒ 收掉場次（玩家離座、放掉手機、場次 completed）
--   · 開打後 6 小時沒有任何一局 ⇒ 打完 1 將以上照打完的將結算再收；一將都沒打完 ⇒ 作廢、通知
--
-- 五、計分板換人上桌：好友練習賽的名單跟著換（觸發器），不然換上來的人不算在這一場裡
--
-- 六、get_my_friendly_tx 多回 stats（打了幾場、單場最多積分、局數、胡牌、自摸、規定局數）、trend（近 10 場積分）、records（紀錄列）
--
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格。驗證段不 raise（硬規則 1.8）。
-- 行為測試另外跑：sql/checks/2026-10-28_驗好友練習賽結算與排除.sql
-- ============================================================

-- ── 改既有函式用的小工具：只換「剛好出現 n 次」的原文，對不上就整份失敗（不提交任何東西）
create or replace function pg_temp.migi_patch(p_fn regprocedure, p_old text, p_new text, p_expect int default 1)
returns void language plpgsql as $$
declare d text; n int;
begin
  d := pg_get_functiondef(p_fn);
  n := (length(d) - length(replace(d, p_old, ''))) / greatest(length(p_old), 1);
  if n <> p_expect then
    raise exception '改 % 失敗：原文出現 % 次，預期 % 次 —— 線上版本跟寫這份 SQL 時看到的不一樣，整份不提交。原文：%',
      p_fn, n, p_expect, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ============================================================
-- 一、結算
-- ============================================================
select pg_temp.migi_patch('public._score_settle_tx(uuid)'::regprocedure,
  'v_totals jsonb; v_res jsonb; v_rated boolean := false;',
  'v_totals jsonb; v_res jsonb; v_rated boolean := false; v_mode text;');
select pg_temp.migi_patch('public._score_settle_tx(uuid)'::regprocedure,
  'select coalesce(sl.is_hygiene, false) into v_hyg',
  'select coalesce(sl.is_hygiene, false), ts.mode into v_hyg, v_mode');
select pg_temp.migi_patch('public._score_settle_tx(uuid)'::regprocedure,
  'if v_nfin >= 2 or (v_nfin = 1 and (select planned_rounds from table_sessions where id = p_session_id) = 1) then',
  'if v_mode is distinct from ''friendly'' and (v_nfin >= 2 or (v_nfin = 1 and (select planned_rounds from table_sessions where id = p_session_id) = 1)) then');
select pg_temp.migi_patch('public._score_settle_tx(uuid)'::regprocedure,
  '-- ④ 成就（整段吞例外',
  '/* 🤝 好友練習賽（2026-10-28）：名次與桌上積分照寫（上面那段），段位分不算（上面那個 if）、成就不發（這裡就回去）。
     場次先不關 —— 手機還要看牌局結束卡，15 分鐘後由 sweep_friendly_tx 收掉 */
  if v_mode = ''friendly'' then
    update friendly_games set status = ''finished'', ended_at = now(), updated_at = now()
     where session_id = p_session_id and status = ''playing'';
    return jsonb_build_object(''ok'', true, ''rated'', false, ''friendly'', true, ''rounds_finished'', v_nfin,
                              ''hands'', v_nhands, ''fired'', 0, ''hygiene'', v_hyg);
  end if;

  -- ④ 成就（整段吞例外');

-- ============================================================
-- 二、通知與 LINE 結算卡
-- ============================================================
select pg_temp.migi_patch('public._settle_notify_on_rank()'::regprocedure,
  '''text'',       ''牌局結算完成'',',
  '''text'',       case when ts.mode = ''friendly'' then ''好友練習賽結束了'' else ''牌局結算完成'' end,
             ''mode'',       ts.mode,');

select pg_temp.migi_patch('public._push_settle_fields(uuid)'::regprocedure,
  'select ts.game_type, ts.flower, ts.planned_rounds,',
  'select ts.mode, ts.game_type, ts.flower, ts.planned_rounds,');
select pg_temp.migi_patch('public._push_settle_fields(uuid)'::regprocedure,
  '?tab=stats&settle='' || v_sid);',
  '?tab=stats&settle='' || v_sid)
    /* 🤝 好友練習賽（2026-10-28）：沒有段位分、目前段位、門市、桌號；多一列類型；按鈕連到 App 的好友練習賽頁 */
    || case when s.mode = ''friendly'' then jsonb_build_object(
         ''friendly'', true, ''kind_label'', ''好友練習賽'',
         ''rating'', null, ''rating_short'', null, ''tier'', null,
         ''store'', null, ''table'', null, ''place'', ''好友練習賽'',
         ''url'', ''https://liff.line.me/2011312117-Zuul0Ndo?go=friendly'')
       else ''{}''::jsonb end;');

select pg_temp.migi_patch('public._push_settle_flex(uuid)'::regprocedure,
  '(values (1, ''門市'',     f ->> ''store''),',
  '(values (0, ''類型'',     f ->> ''kind_label''),
                 (1, ''門市'',     f ->> ''store''),');
select pg_temp.migi_patch('public._push_settle_flex(uuid)'::regprocedure,
  '''這場牌局結束了！''',
  '(case when (f ->> ''friendly'')::boolean then ''這場好友練習賽結束了！'' else ''這場牌局結束了！'' end)');
select pg_temp.migi_patch('public._push_settle_flex(uuid)'::regprocedure,
  '''牌局結束！第 ''',
  '(case when (f ->> ''friendly'')::boolean then ''好友練習賽結束！第 '' else ''牌局結束！第 '' end)');

select pg_temp.migi_patch('public._push_settle_text(uuid)'::regprocedure,
  '''這場牌局結束了！''',
  '(case when (f ->> ''friendly'')::boolean then ''這場好友練習賽結束了！'' else ''這場牌局結束了！'' end)');
select pg_temp.migi_patch('public._push_settle_text(uuid)'::regprocedure,
  '''門市：'' || (f ->> ''store''),',
  'case when (f ->> ''friendly'')::boolean then ''類型：好友練習賽'' end,
    ''門市：'' || (f ->> ''store''),');

-- ============================================================
-- 三、排除
-- ============================================================
select pg_temp.migi_patch('public._member_stats_core'::regproc::regprocedure,
  'and (s.status = ''completed'' or sp.finish_rank is not null)',
  'and (s.status = ''completed'' or sp.finish_rank is not null) and s.mode <> ''friendly''', 6);   -- 6 段查詢都是 sp／s 別名（2026-10-28 逐行看過）
select pg_temp.migi_patch('public.get_my_games_tx(uuid,uuid,integer)'::regprocedure,
  'and (s.status = ''completed'' or sp.finish_rank is not null)',
  'and (s.status = ''completed'' or sp.finish_rank is not null) and s.mode <> ''friendly''');
select pg_temp.migi_patch('public.get_member_card_tx'::regproc::regprocedure,
  'and (s.status = ''completed'' or me.finish_rank is not null)',
  'and (s.status = ''completed'' or me.finish_rank is not null) and s.mode <> ''friendly''');
select pg_temp.migi_patch('public._pair_history(uuid,uuid,uuid)'::regprocedure,
  's.deleted_at is null and s.status = ''completed''',
  's.deleted_at is null and s.status = ''completed'' and s.mode <> ''friendly''');
select pg_temp.migi_patch('public._member_home_store(uuid)'::regprocedure,
  'and ts.store_id is not null',
  'and ts.store_id is not null
       and ts.mode <> ''friendly''   -- 好友練習賽掛在虛擬門市，不可以變成誰的常去門市');
select pg_temp.migi_patch('public._team_session_ids(uuid)'::regprocedure,
  'where ts.status <> ''voided''',
  'where ts.status <> ''voided''
     and ts.mode <> ''friendly''   -- 牌咖團「一起打了 N 場」只算店裡的（2026-10-28）');
select pg_temp.migi_patch('public.list_recent_players_tx(uuid,uuid)'::regprocedure,
  'join session_players other on other.session_id = sp.session_id and other.member_id <> sp.member_id',
  'join session_players other on other.session_id = sp.session_id and other.member_id <> sp.member_id
    join table_sessions rs on rs.id = sp.session_id and rs.mode <> ''friendly''   -- 最近同桌只列店裡的（2026-10-28）');
select pg_temp.migi_patch('public.like_player_tx(uuid,uuid,uuid,boolean,uuid)'::regprocedure,
  'if p_liker = p_target then raise exception ''不能讚自己''; end if;',
  'if p_liker = p_target then raise exception ''不能讚自己''; end if;
  -- 好友練習賽不做評價（2026-10-28）：在家打一場就能互刷讚數與小熊餅乾
  if p_session is not null and exists (select 1 from table_sessions where id = p_session and mode = ''friendly'') then
    raise exception ''好友練習賽不做評價'';
  end if;');
select pg_temp.migi_patch('public.dislike_player_tx(uuid,boolean,uuid)'::regprocedure,
  'select org_id into v_org from table_sessions where id = p_session;',
  'if exists (select 1 from table_sessions where id = p_session and mode = ''friendly'') then
    return jsonb_build_object(''ok'', false, ''reason'', ''friendly'', ''message'', ''好友練習賽不做評價'');
  end if;
  select org_id into v_org from table_sessions where id = p_session;');

select pg_temp.migi_patch('public._game_row'::regproc::regprocedure,
  'case when m.mode = ''private'' then ''package'' else ''match'' end',
  'case when m.mode = ''private'' then ''package'' when m.mode = ''friendly'' then ''friendly'' else ''match'' end');

select pg_temp.migi_patch('public._tbl_state_for_device(table_devices)'::regprocedure,
  '''id'', s.id, ''channel'', s.score_channel, ''game_type'', s.game_type, ''flower'', s.flower,',
  '''id'', s.id, ''channel'', s.score_channel, ''game_type'', s.game_type, ''flower'', s.flower, ''mode'', s.mode,');
select pg_temp.migi_patch('public._tbl_state_for_device(table_devices)'::regprocedure,
  '''no1'', v_no1 is not null and sp.member_id = v_no1)',
  '''no1'', v_no1 is not null and sp.member_id = v_no1 and s.mode <> ''friendly'')');

select pg_temp.migi_patch('public.admin_list_stores_tx()'::regprocedure,
  'where s.org_id = v_org and s.deleted_at is null), ''[]''::jsonb),',
  'where s.org_id = v_org and s.deleted_at is null and not s.is_virtual), ''[]''::jsonb),');
select pg_temp.migi_patch('public.admin_pair_table_device_tx(uuid,text)'::regprocedure,
  'if nullif(btrim(coalesce(p_label, '''')), '''') is null then',
  'if exists (select 1 from stores where id = t.store_id and is_virtual) then
    return jsonb_build_object(''ok'', false, ''reason'', ''virtual_table'', ''message'', ''好友練習賽的虛擬桌不能配平板'');
  end if;
  if nullif(btrim(coalesce(p_label, '''')), '''') is null then');

-- ============================================================
-- 四、收場次與排程
-- ============================================================
create or replace function public._friendly_close(p_session uuid, p_void boolean default false)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  -- 同店裡收桌：在座的人離座、放掉裝置；虛擬桌在場次不是 open 之後就自動空出來給下一場
  update session_players set left_at = coalesce(left_at, now()), device_id = null where session_id = p_session;
  update table_sessions
     set status = case when p_void then 'voided' else 'completed' end,
         ended_at = coalesce(ended_at, now()), updated_at = now()
   where id = p_session and status = 'open' and mode = 'friendly';
end $$;

create or replace function public.sweep_friendly_tx()
returns int language plpgsql security definer set search_path to 'public' as $$
declare g record; r record; n int := 0; v jsonb; v_last timestamptz;
begin
  -- ① 過了最晚開打時間還沒湊滿 ⇒ 取消、通知
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

  -- ② 打完 15 分鐘 ⇒ 收掉場次（這 15 分鐘讓手機看牌局結束卡）
  for g in select fg.* from friendly_games fg join table_sessions ts on ts.id = fg.session_id
            where fg.status = 'finished' and ts.status = 'open' and fg.ended_at < now() - interval '15 minutes' loop
    perform public._friendly_close(g.session_id);
    n := n + 1;
  end loop;

  -- ③ 開打後 6 小時沒有任何一局 ⇒ 打完 1 將以上照打完的將結算再收；一將都沒打完 ⇒ 作廢、通知
  for g in select * from friendly_games where status = 'playing' for update skip locked loop
    select greatest(g.started_at, max(coalesce(h.confirmed_at, h.created_at))) into v_last
      from hands h where h.session_id = g.session_id;
    if coalesce(v_last, g.started_at) >= now() - interval '6 hours' then continue; end if;

    v := null;
    if exists (select 1 from session_rounds where session_id = g.session_id and status = 'finished') then
      begin
        v := public._score_settle_tx(g.session_id);
      exception when others then v := null;
      end;
    end if;
    if coalesce((v ->> 'ok')::boolean, false) then
      update friendly_games set status = 'finished', ended_at = coalesce(ended_at, now()), updated_at = now()
       where id = g.id and status = 'playing';
      perform public._friendly_close(g.session_id);
    else
      for r in select member_id from friendly_game_players where game_id = g.id and left_at is null loop
        insert into app_notifications (org_id, member_id, type, ref_id, payload)
        values (g.org_id, r.member_id, 'friendly_out', g.id,
                jsonb_build_object('text', '好友練習賽 6 小時沒有記分，已自動結束（沒有打完一將，成績不算）', 'game_id', g.id));
      end loop;
      perform public._friendly_close(g.session_id, true);
      update friendly_game_players set left_at = now(), leave_reason = 'expired' where game_id = g.id and left_at is null;
      update friendly_games set status = 'cancelled', cancel_reason = 'stale', ended_at = now(), updated_at = now()
       where id = g.id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ============================================================
-- 五、計分板換人上桌：好友練習賽的名單跟著換
-- ============================================================
create or replace function public._friendly_sync_member()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  update friendly_game_players fp
     set member_id = new.member_id
    from friendly_games g
   where g.session_id = new.session_id and fp.game_id = g.id
     and fp.member_id = old.member_id and fp.left_at is null;
  return null;
end $$;
drop trigger if exists trg_session_players_friendly_sync on public.session_players;
create trigger trg_session_players_friendly_sync
  after update of member_id on public.session_players
  for each row when (old.member_id is distinct from new.member_id)
  execute function public._friendly_sync_member();

-- ============================================================
-- 六、我的好友練習賽：數據、積分走勢、紀錄
-- ============================================================
create or replace function public._friendly_stats(p_org uuid, p_member uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with mine as (
    select sp.session_id, sp.seat, sp.final_score, coalesce(s.ended_at, s.started_at) as at
      from session_players sp join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member and sp.org_id = p_org and s.org_id = p_org
       and s.mode = 'friendly' and s.deleted_at is null and s.status <> 'voided'
       and sp.finish_rank is not null
  ), hh as (
    -- 一局的定義同 _member_hand_counts：胡、自摸、流局、包牌；咔啦碰與分紅不是一局
    select h.result, coalesce(h.winner_seat = m.seat, false) as won
      from mine m join hands h on h.session_id = m.session_id
     where h.status = 'confirmed' and h.result in ('tsumo', 'ron', 'draw', 'bao')
  )
  select jsonb_build_object(
    'games',      (select count(*) from mine),
    'best_score', (select max(final_score) from mine),
    'hands',      (select count(*) from hh),
    'hu',         (select count(*) from hh where won and result in ('tsumo', 'ron')),
    'tsumo',      (select count(*) from hh where won and result = 'tsumo'),
    'min_hands',  public._hand_min_count(),
    'trend', (select coalesce(jsonb_agg(jsonb_build_object('at', t.at, 'score', t.final_score) order by t.at), '[]'::jsonb)
                from (select at, final_score from mine where final_score is not null order by at desc limit 10) t),
    'records', (select coalesce(jsonb_agg(public._game_row(p_org, x.session_id, p_member) order by x.at desc), '[]'::jsonb)
                  from (select session_id, at from mine order by at desc limit 20) x));
$$;

create or replace function public.get_my_friendly_tx()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_me uuid; v_org uuid; v_gid uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me;
  v_gid := public._friendly_active_game(v_me);
  return jsonb_build_object(
    'game',  case when v_gid is null then null else public._friendly_view(v_gid, v_me) end,
    'stats', public._friendly_stats(v_org, v_me));
end $$;

revoke execute on function public._friendly_close(uuid, boolean) from public, anon, authenticated;
revoke execute on function public._friendly_sync_member()        from public, anon, authenticated;
revoke execute on function public._friendly_stats(uuid, uuid)    from public, anon, authenticated;
revoke execute on function public.sweep_friendly_tx()            from public, anon, authenticated;
grant  execute on function public.get_my_friendly_tx()           to authenticated;

-- ============================================================
-- 驗證（不 raise；改既有函式那幾段若對不上，上面就整份失敗了，不會走到這裡）
-- ============================================================
do $$
declare v text := ''; n int; ok boolean; d text;
begin
  -- ① 結算分支
  d := pg_get_functiondef('public._score_settle_tx(uuid)'::regprocedure);
  ok := d ~ 'v_mode is distinct from ''friendly'' and \(v_nfin >= 2' and d ~ 'if v_mode = ''friendly'' then';
  v := v || case when ok then '✅' else '🔴' end || ' ① 結算：好友練習賽不算段位分、不發成就、標成打完' || E'\n';

  -- ② 排除：每一支都真的帶著條件（數「出現幾次」，不是只看有沒有）
  select count(*) into n from (values
    ('public._member_stats_core'::regproc::regprocedure, 6), ('public.get_my_games_tx(uuid,uuid,integer)'::regprocedure, 1),
    ('public.get_member_card_tx'::regproc::regprocedure, 1), ('public._pair_history(uuid,uuid,uuid)'::regprocedure, 1),
    ('public._member_home_store(uuid)'::regprocedure, 1),    ('public._team_session_ids(uuid)'::regprocedure, 1),
    ('public.list_recent_players_tx(uuid,uuid)'::regprocedure, 1)) t(fn, k)
   where (select count(*) from regexp_matches(pg_get_functiondef(t.fn), 'mode <> ''friendly''', 'g')) = t.k;
  v := v || case when n = 7 then '✅' else '🔴' end || format(' ② 成績、紀錄、個人卡、同桌、常去門市、牌咖團、最近同桌 %s／7 支排除好友練習賽', n) || E'\n';

  -- ③ 評價擋好友練習賽
  ok := pg_get_functiondef('public.like_player_tx(uuid,uuid,uuid,boolean,uuid)'::regprocedure) ~ 'mode = ''friendly'''
    and pg_get_functiondef('public.dislike_player_tx(uuid,boolean,uuid)'::regprocedure) ~ 'mode = ''friendly''';
  v := v || case when ok then '✅' else '🔴' end || ' ③ 按讚、倒讚擋好友練習賽' || E'\n';

  -- ④ 通知與結算卡
  ok := pg_get_functiondef('public._settle_notify_on_rank()'::regprocedure) ~ '好友練習賽結束了'
    and pg_get_functiondef('public._push_settle_fields(uuid)'::regprocedure) ~ 'go=friendly'
    and pg_get_functiondef('public._push_settle_flex(uuid)'::regprocedure) ~ 'kind_label'
    and pg_get_functiondef('public._push_settle_text(uuid)'::regprocedure) ~ '類型：好友練習賽';
  v := v || case when ok then '✅' else '🔴' end || ' ④ 結算通知與 LINE 卡片（四支）有好友練習賽的版本' || E'\n';

  -- ⑤ 計分板：回 mode、不標全國第一
  d := pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure);
  ok := d ~ '''mode'', s.mode' and d ~ 'sp.member_id = v_no1 and s.mode <> ''friendly''';
  v := v || case when ok then '✅' else '🔴' end || ' ⑤ 計分板狀態回 mode、好友練習賽不標全國第一' || E'\n';

  -- ⑥ 紀錄列的種類
  ok := pg_get_functiondef('public._game_row'::regproc::regprocedure) ~ 'when m.mode = ''friendly'' then ''friendly''';
  v := v || case when ok then '✅' else '🔴' end || ' ⑥ 紀錄列 kind 多 friendly' || E'\n';

  -- ⑦ 後台：門市清單藏虛擬門市、平板配對擋虛擬桌
  ok := pg_get_functiondef('public.admin_list_stores_tx()'::regprocedure) ~ 'not s.is_virtual'
    and pg_get_functiondef('public.admin_pair_table_device_tx(uuid,text)'::regprocedure) ~ 'virtual_table';
  v := v || case when ok then '✅' else '🔴' end || ' ⑦ 後台門市清單藏虛擬門市、平板配對擋虛擬桌' || E'\n';

  -- ⑧ 換人上桌的觸發器
  ok := exists (select 1 from pg_trigger where tgname = 'trg_session_players_friendly_sync' and not tgisinternal);
  v := v || case when ok then '✅' else '🔴' end || ' ⑧ 換人上桌時好友練習賽名單跟著換' || E'\n';

  -- ⑨ 改過的函式都只有一個版本、前端叫得動的那幾支授權沒掉（CREATE OR REPLACE 不會掉，這格是確認）
  select count(*) into n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_score_settle_tx','_settle_notify_on_rank','_push_settle_fields','_push_settle_flex','_push_settle_text',
                       '_member_stats_core','get_my_games_tx','get_member_card_tx','_pair_history','_member_home_store',
                       '_team_session_ids','list_recent_players_tx','like_player_tx','dislike_player_tx','_game_row',
                       '_tbl_state_for_device','admin_list_stores_tx','admin_pair_table_device_tx');
  ok := n = 18
    and has_function_privilege('authenticated', 'public.get_my_games_tx(uuid,uuid,integer)'::regprocedure, 'EXECUTE')
    and has_function_privilege('authenticated', 'public.like_player_tx(uuid,uuid,uuid,boolean,uuid)'::regprocedure, 'EXECUTE')
    and has_function_privilege('authenticated', 'public.get_my_friendly_tx()'::regprocedure, 'EXECUTE')
    and not has_function_privilege('anon', 'public.get_my_friendly_tx()'::regprocedure, 'EXECUTE');
  v := v || case when ok then '✅' else '🔴' end || format(' ⑨ 改過的 18 支各一個版本（%s 支）、前端授權沒掉', n) || E'\n';

  -- ⑩ 內部函式前端叫不到
  select count(*) into n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_friendly_close','_friendly_sync_member','_friendly_stats','sweep_friendly_tx')
     and not has_function_privilege('anon', p.oid, 'EXECUTE') and not has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v := v || case when n = 4 then '✅' else '🔴' end || format(' ⑩ 內部四支 %s／4 前端叫不到', n);

  perform set_config('migi.x', v, true);
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "好友練習賽 · 結算與排除";
