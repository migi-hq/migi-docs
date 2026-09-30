/* ============================================================
   賽季自動結算 ＋ 成就賽季區（賽季榮耀 7 枚 ＋ 整季不降階）
   2026-09-30 · MIGI 咪吉麻將
   行為測試：sql/checks/2026-09-30_驗賽季結算與賽季成就.sql（跑完這份再跑）

   ── 為什麼 ─────────────────────────────────────────────
   reset_season_ratings_tx（記雀神、存每個人的最終名次、全員降兩大階）早就在線上，
   但**沒有任何東西會叫它**：pg_cron 六個排程裡沒有、只有 service_role 叫得動、文件也沒寫誰按。
   ⇒ 2027-01-01 00:00 本季結束那一刻什麼都不會發生，而且不報錯。
   使用者 2026-09-30 選「自動排程」。

   ── 做了什麼 ────────────────────────────────────────────
   ① season_start_ratings：每一季開始時每個人的段位分（結算上一季、降階完的那一刻存）
      —— 「賽季進步」「整季不降階」要知道起點。
      ⚠ 不能用「第一場結算後的段位分 − 那一場的變動」倒推：降階保護夾住時
        session_players.score_points 記的是夾之前的數字（實查 47 列有 4 列對不上）。
      本季（2026H2）沒有快照 ⇒ 退回用「本季開始前最後一場結算後的段位分」；
      之前一場都沒打過的人沒有起點，不算賽季進步。
   ② _ach_season_close_events(org, season)：結算完發賽季成就（前端叫不到）
   ③ sweep_season_close_tx()：找「已經結束、還沒結算」的賽季 → 結算 → 存下一季起點 → 發成就。
      每一季各自包起來，失敗寫 season_close_error 埋點（錯誤儀表 ⑲ 也會盯），下一輪再試。
      只有 postgres（pg_cron）叫得到。
   ④ pg_cron `season-close` 每 10 分鐘：賽季 00:00 結束，最晚 00:10 結算完。
      ⚠ 不用「每天一次」：結算前那段時間打完的牌會用舊的段位分算，間隔越短越少。
   ⑤ 收桌時多判一件：「賽季首戰」（上一季以前打過、這是本季第一場）
   ⑥ 成就主檔：賽季榮耀 7 枚上架；「整季不降階」上架（本季至少 10 場）
      名人堂那一枚不建（與賽季雀神同一件事，使用者 09-30 拍板）
   ⑦ 修正上一批：「升上大師熊」改成公開；「雀神對局」照 09-22 的拍板搬進彩蛋區（easter_13）
      —— 規則是「只有 easter_* 可以隱藏」，上一批匯入時漏看了

   ── 判定細節 ────────────────────────────────────────────
   · 名次、雀神都讀結算當下寫進 season_standings／season_champions 的 ⇒ 與排行榜、名人堂同一份
   · 賽季進步：結束段位（結算前的段位分）比起點高一個級距以上（段位文字不同而且分數較高）
   · 整季不降階：起點（有的話）＋ 本季每一場結算後的段位分，前後兩點之間沒有「段位文字變了而且分數變低」；
     本季至少 10 場（少於 10 場的「整季」沒有意義，而它是史詩）
   · 賽季全勤：本季每一個月（台北時間）都至少結算過一場
   · 二度稱王：當過 2 次以上賽季冠軍
   · 測試帳號本來就不進 season_standings（結算只排真人）⇒ 賽季成就測試帳號拿不到，那是對的
   ============================================================ */

-- ① 每一季的起點
create table if not exists public.season_start_ratings (
  org_id     uuid not null references public.orgs(id),
  season     text not null,
  member_id  uuid not null references public.members(id),
  rating     integer not null,
  created_at timestamptz not null default now(),
  primary key (org_id, season, member_id)
);
comment on table public.season_start_ratings is
  '每一季開始時每個人的段位分。結算上一季、降完階的那一刻由 sweep_season_close_tx 寫入；賽季進步與整季不降階用它當起點';
alter table public.season_start_ratings enable row level security;
revoke all on table public.season_start_ratings from public, anon, authenticated;

-- ② 結算完發賽季成就
create or replace function public._ach_season_close_events(p_org uuid, p_season text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_from timestamptz; v_to timestamptz; v_prev_code text;
  v_champ uuid; v_idem text := 'season:' || p_season;
  v_r record; v_start int; v_ev text[]; v_e text; v_fired int := 0;
  v_seq int[]; v_ok boolean; i int; v_months int; v_hit int;
begin
  select starts_at, ends_at into v_from, v_to from rank_seasons where org_id = p_org and code = p_season;
  if v_from is null then return jsonb_build_object('ok', false, 'reason', 'season_not_found'); end if;
  select member_id into v_champ from season_champions where org_id = p_org and season = p_season;

  -- 這一季有幾個月（台北時間）
  select count(*) into v_months
    from generate_series(date_trunc('month', v_from at time zone 'Asia/Taipei'),
                         (v_to at time zone 'Asia/Taipei') - interval '1 second', interval '1 month') g;

  for v_r in
    select st.member_id, st.rating as end_rating, st.rank_no, st.games
      from season_standings st
     where st.org_id = p_org and st.season = p_season
  loop
    v_ev := '{}';

    -- 起點：快照優先；沒有就用本季開始前最後一場結算後的段位分
    select s.rating into v_start from season_start_ratings s
     where s.org_id = p_org and s.season = p_season and s.member_id = v_r.member_id;
    if v_start is null then
      select sp.rating_after into v_start
        from session_players sp
       where sp.member_id = v_r.member_id and sp.settled_at is not null and sp.rating_after is not null
         and sp.settled_at < v_from
       order by sp.settled_at desc limit 1;
    end if;

    if v_r.rank_no <= 100 then v_ev := array_append(v_ev, 'season_top100'); end if;
    if v_r.rank_no <= 10  then v_ev := array_append(v_ev, 'season_top10');  end if;
    if v_champ = v_r.member_id then
      v_ev := array_append(v_ev, 'season_champion');
      if (select count(*) from season_champions c where c.org_id = p_org and c.member_id = v_r.member_id) >= 2 then
        v_ev := array_append(v_ev, 'season_champion_2');
      end if;
    end if;

    -- 賽季進步
    if v_start is not null and v_r.end_rating > v_start
       and public.rank_from_rating(v_r.end_rating) <> public.rank_from_rating(v_start) then
      v_ev := array_append(v_ev, 'season_progress');
    end if;

    -- 賽季全勤：每個月都結算過一場
    select count(distinct date_trunc('month', sp.settled_at at time zone 'Asia/Taipei')) into v_hit
      from session_players sp
     where sp.member_id = v_r.member_id and sp.settled_at >= v_from and sp.settled_at < v_to
       and sp.finish_rank is not null;
    if v_months > 0 and v_hit >= v_months then v_ev := array_append(v_ev, 'season_all_months'); end if;

    -- 整季不降階：至少 10 場
    if v_r.games >= 10 then
      select array_agg(x.r order by x.o) into v_seq
        from (select v_start as r, 0 as o where v_start is not null
              union all
              select sp.rating_after, row_number() over (order by sp.settled_at, sp.session_id)
                from session_players sp
               where sp.member_id = v_r.member_id and sp.settled_at >= v_from and sp.settled_at < v_to
                 and sp.rating_after is not null) x;
      v_ok := true;
      for i in 2 .. coalesce(array_length(v_seq, 1), 0) loop
        if v_seq[i] < v_seq[i-1] and public.rank_from_rating(v_seq[i]) <> public.rank_from_rating(v_seq[i-1]) then
          v_ok := false;
        end if;
      end loop;
      if v_ok then v_ev := array_append(v_ev, 'rank_no_drop_season'); end if;
    end if;

    foreach v_e in array v_ev loop
      perform public.fire_event_tx(v_r.member_id, v_e, 1, null, v_idem);
      v_fired := v_fired + 1;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'season', p_season, 'fired', v_fired);
end $fn$;
revoke execute on function public._ach_season_close_events(uuid, text) from public, anon, authenticated;

-- ③ 找出該結算的賽季並結算
create or replace function public.sweep_season_close_tx()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_s record; v_res jsonb; v_out jsonb := '[]'::jsonb; v_next text; v_ach jsonb;
begin
  for v_s in
    select rs.org_id, rs.code, rs.ends_at
      from rank_seasons rs
     where rs.ends_at <= now()
       and not exists (select 1 from season_champions c where c.org_id = rs.org_id and c.season = rs.code)
     order by rs.ends_at
  loop
    begin
      v_res := public.reset_season_ratings_tx(v_s.org_id, v_s.code);
      if not coalesce((v_res ->> 'ok')::boolean, false) then
        raise exception 'reset_season_ratings_tx 回 %', v_res;
      end if;

      -- 下一季的起點 ＝ 剛降完階的段位分
      select rs2.code into v_next from rank_seasons rs2
       where rs2.org_id = v_s.org_id and rs2.starts_at >= v_s.ends_at
       order by rs2.starts_at limit 1;
      if v_next is not null then
        insert into season_start_ratings (org_id, season, member_id, rating)
        select m.org_id, v_next, m.id, m.rating
          from members m
         where m.org_id = v_s.org_id and m.deleted_at is null and m.rank is not null
        on conflict do nothing;
      end if;

      -- 成就失敗不影響結算（結算已經做完、不可重來）
      begin
        v_ach := public._ach_season_close_events(v_s.org_id, v_s.code);
      exception when others then
        v_ach := jsonb_build_object('ok', false, 'code', sqlstate, 'message', left(sqlerrm, 300));
        begin
          perform public.log_app_event_tx(v_s.org_id, null, 'ach_error',
            jsonb_build_object('where', '_ach_season_close_events', 'season', v_s.code,
                               'code', sqlstate, 'message', left(sqlerrm, 300)), now(), null);
        exception when others then null;
        end;
      end;

      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'season', v_s.code, 'result', v_res, 'next_season', v_next, 'achievements', v_ach));
    exception when others then
      -- 這一季整個退回（沒有記冠軍 ⇒ 下一輪會再試），而且要讓人看得到
      v_out := v_out || jsonb_build_array(jsonb_build_object('season', v_s.code, 'error', left(sqlerrm, 300)));
      begin
        perform public.log_app_event_tx(v_s.org_id, null, 'season_close_error',
          jsonb_build_object('season', v_s.code, 'code', sqlstate, 'message', left(sqlerrm, 300)), now(), null);
      exception when others then null;
      end;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'closed', v_out);
end $fn$;
revoke execute on function public.sweep_season_close_tx() from public, anon, authenticated;

-- ④ 排程（已經有就不重建）
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'season-close') then
    perform cron.schedule('season-close', '*/10 * * * *', 'select public.sweep_season_close_tx()');
  end if;
end $$;

-- ⑤ 收桌時判「賽季首戰」（插在發事件的迴圈前面；錨點必須剛好一處，已經插過就跳過）
do $$
declare
  v_def text; v_n int;
  v_anchor text := '    foreach v_e in array v_ev loop';
  v_add text := $b$    /* ── 賽季首戰（2026-09-30）：本季以前打過，這是本季第一場 ── */
    if exists (select 1 from public.rank_seasons rs
                where rs.org_id = v_s.org_id and v_end >= rs.starts_at and v_end < rs.ends_at
                  and not exists (select 1 from public.session_players sp2
                                    join public.table_sessions ts on ts.id = sp2.session_id
                                   where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
                                     and ts.id <> p_session_id and ts.ended_at >= rs.starts_at and ts.ended_at < v_end)
                  and exists (select 1 from public.session_players sp2
                                join public.table_sessions ts on ts.id = sp2.session_id
                               where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
                                 and ts.ended_at < rs.starts_at)) then
      v_ev := array_append(v_ev, 'season_first_game');
    end if;

$b$;
begin
  v_def := pg_get_functiondef('public._ach_session_events(uuid)'::regprocedure);
  if position('season_first_game' in v_def) > 0 then return; end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then
    -- 故意中止、整份不提交（錨點對不上就不可以亂插）
    raise exception '🔴 _ach_session_events 的錨點出現 % 次（期望 1），整份不提交', v_n;
  end if;
  execute replace(v_def, v_anchor, v_add || v_anchor);
end $$;

-- ⑥ 成就主檔：賽季榮耀 7 枚（重跑不重複插）＋ 整季不降階上架
insert into public.achievements
  (org_id, code, name, description, condition_text, group_key, ui_category,
   struct, motivation, rarity, visibility, trigger, sort, grants_title, is_active)
select o.org_id, v.code, v.name, v.description, v.condition_text, '賽季榮耀', 'game',
       v.struct, v.motivation, v.rarity, 'visible', v.trigger::jsonb, v.sort, null, true
  from (select org_id from public.achievements where code = 'rank_17' and deleted_at is null limit 1) o
 cross join (values
  ('season_01','賽季首戰','新賽季開始了','上一季以前打過，新賽季第一次完成牌局','specific','completion','norm','{"event":"season_first_game"}',114),
  ('season_02','賽季全勤','這一季你每個月都在','賽季內每個月都有完成牌局','specific','habit','rare','{"event":"season_all_months"}',115),
  ('season_03','賽季進步','這一季你變強了','賽季結束時的段位比賽季開始時高','specific','competition','norm','{"event":"season_progress"}',116),
  ('season_04','榜上有名','你進榜了','賽季排名進入前 100','specific','prestige','rare','{"event":"season_top100"}',117),
  ('season_05','前十強','這一季你很猛','賽季排名進入前 10','specific','prestige','epic','{"event":"season_top10"}',118),
  ('season_06','賽季雀神','這一季的第一名','賽季結算取得全店第一','specific','prestige','epic','{"event":"season_champion"}',119),
  ('season_08','二度稱王','不是偶然','累積 2 次賽季冠軍','prestige','prestige','epic','{"event":"season_champion_2"}',121)
 ) as v(code, name, description, condition_text, struct, motivation, rarity, trigger, sort)
 where not exists (select 1 from public.achievements a where a.org_id = o.org_id and a.code = v.code and a.deleted_at is null);

update public.achievements
   set is_active = true, condition_text = '一個賽季內未曾降階（本季至少 10 場）', updated_at = now()
 where code = 'rank_12' and deleted_at is null;

-- ⑦ 修正上一批的可見度
update public.achievements set visibility = 'visible', updated_at = now()
 where code = 'rank_06' and deleted_at is null and visibility <> 'visible';
update public.achievements
   set code = 'easter_13', group_key = '彩蛋', updated_at = now()
 where code = 'rank_16' and deleted_at is null;

/* ============================================================
   驗證（不 raise —— 這份要留下東西）
   ============================================================ */
do $$
declare v_msg text := ''; v_n int; v_txt text; v_oid oid;
begin
  -- ① 表在、RLS 開、前端讀不到
  select count(*) into v_n from pg_class c
   where c.oid = 'public.season_start_ratings'::regclass and c.relrowsecurity
     and not has_table_privilege('anon', c.oid, 'SELECT') and not has_table_privilege('authenticated', c.oid, 'SELECT');
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ① season_start_ratings：RLS 開、前端讀不到' || E'\n';

  -- ② 兩支新函式前端都叫不到
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname in ('_ach_season_close_events', 'sweep_season_close_tx')
     and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute');
  v_msg := v_msg || case when v_n = 2 then '✅' else '🔴' end || ' ② 兩支新函式前端叫不到（' || v_n || '/2）' || E'\n';

  -- ③ 排程在
  select count(*) into v_n from cron.job where jobname = 'season-close' and schedule = '*/10 * * * *' and command ~ 'sweep_season_close_tx';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ③ pg_cron season-close 每 10 分鐘' || E'\n';

  -- ④ 賽季首戰接上、收桌那支只有一個版本
  v_txt := pg_get_functiondef('public._ach_session_events(uuid)'::regprocedure);
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = '_ach_session_events';
  v_msg := v_msg || case when position('''season_first_game''' in v_txt) > 0 and v_n = 1 then '✅' else '🔴' end
        || ' ④ 收桌會判賽季首戰（版本數 ' || v_n || '）' || E'\n';

  -- ⑤ 每一枚上架的賽季成就都有發射端（結構性掃描：事件名有沒有被某支函式寫出來）
  select string_agg(a.code, '、' order by a.code) into v_txt
    from achievements a
   where a.deleted_at is null and a.is_active and (a.group_key = '賽季榮耀' or a.code = 'rank_12')
     and not exists (select 1 from pg_proc p
                      where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                        and p.proname in ('_ach_season_close_events', '_ach_session_events')
                        and position('''' || (a.trigger ->> 'event') || '''' in pg_get_functiondef(p.oid)) > 0);
  select count(*) into v_n from achievements where deleted_at is null and is_active and (group_key = '賽季榮耀' or code = 'rank_12');
  v_msg := v_msg || case when v_txt is null and v_n = 8 then '✅' else '🔴' end
        || ' ⑤ 上架 ' || v_n || ' 枚（期望 8 ＝ 賽季榮耀 7 ＋ 整季不降階）；沒有發射端的：' || coalesce(v_txt, '無') || E'\n';

  -- ⑥ 名人堂那一枚沒有建
  select count(*) into v_n from achievements where code = 'season_07' and deleted_at is null;
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ⑥ 名人堂成就沒有建（' || v_n || '）' || E'\n';

  -- ⑦ 只有彩蛋區可以隱藏
  select string_agg(code, '、' order by code) into v_txt from achievements
   where deleted_at is null and visibility <> 'visible' and code not like 'easter\_%';
  select count(*) into v_n from achievements where code = 'easter_13' and group_key = '彩蛋' and deleted_at is null;
  v_msg := v_msg || case when v_txt is null and v_n = 1 then '✅' else '🔴' end
        || ' ⑦ 非彩蛋區沒有隱藏成就（' || coalesce(v_txt, '無') || '）；雀神對局已搬成 easter_13（' || v_n || '）' || E'\n';

  -- ⑧ 本季還沒結束 ⇒ 現在不會被結算（負對照：排程不會提早動手）
  select count(*) into v_n from rank_seasons rs
   where rs.ends_at <= now() and not exists (select 1 from season_champions c where c.org_id = rs.org_id and c.season = rs.code);
  v_msg := v_msg || case when v_n = 0 then '✅' else '🟡' end
        || ' ⑧ 現在該結算而還沒結算的賽季：' || v_n || '（期望 0 —— 本季 2027-01-01 才結束）';

  perform set_config('migi.v', v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
