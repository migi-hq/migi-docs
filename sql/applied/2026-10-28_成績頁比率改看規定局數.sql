/* ============================================================
   成績頁的胡牌率／放槍率／自摸率改看「規定局數」（跟排行榜同一個數字）
   2026-10-28 · MIGI 咪吉麻將

   ── 起因 ────────────────────────────────────────────────
   使用者：「成績頁的胡牌率、放槍率、自摸率沒顯示」。
   查證：創辦人帳號已結算 3 場、計分板記了 152 局；成績頁的門檻是「場數滿 5 場」（_member_stats_core 的 min_games）
   ⇒ 三個比率一直是「—」。那條門檻是給平均勝率、名次分布用的（以「場」為單位），
   而這三個率以「局」為單位，152 局早就有意義。
   使用者拍板：這三個率改成「局數滿規定局數就顯示」，規定局數跟排行榜「數據排行」同一個（30 局）。

   ── 這份做四件事 ──────────────────────────────────────────
   ① _hand_min_count()：規定局數**唯一一份**（30）。前端叫不到，後端函式內部用
   ② get_season_leaderboard_tx：原本寫在函式裡的常數改叫 ①（數字不變，排行榜行為不變）
   ③ _member_stats_core：回傳多一個 'min_hands'（＝①），成績頁拿它判斷三個率要不要顯示
   ④ get_my_stats_range_tx：把 ③ 的 'min_hands' 一起帶出去（歷史累積數據選日期那一頁）
   ⚠ 三支都只做字串替換（簽名不變、CREATE OR REPLACE、不掉授權）；任何一處換不到就整份退回，不留半套
   ⚠ 平均勝率、名次分布仍然看 min_games（5 場），不動
   ============================================================ */

-- ① 規定局數（唯一一份）
create or replace function public._hand_min_count()
returns int
language sql
immutable
set search_path = public
as $$
  /* 規定局數（同職棒規定打席）：排行榜「數據排行」上榜、成績頁顯示胡牌率／放槍率／自摸率，都看這一個數字。
     要調整只改這裡。 */
  select 30;
$$;

revoke execute on function public._hand_min_count() from public, anon, authenticated;

-- ②③④ 三支改叫 ①（只換那幾個字；找不到就整份退回）
do $$
declare
  v_def text;
  v_new text;
begin
  -- ② 排行榜：常數改叫 ①
  v_def := pg_get_functiondef('public.get_season_leaderboard_tx(uuid,integer)'::regprocedure);
  v_new := replace(v_def, 'v_min_hands constant int := 30;', 'v_min_hands constant int := public._hand_min_count();');
  if v_new = v_def then
    raise exception '找不到排行榜的規定局數那一行，整份退回（請找開發者重新撈線上版）';
  end if;
  execute v_new;

  -- ③ 成績統計：多回 min_hands
  v_def := pg_get_functiondef('public._member_stats_core(uuid,uuid,timestamptz,timestamptz)'::regprocedure);
  if (length(v_def) - length(replace(v_def, $o$'min_games', v_min_games,$o$, ''))) / length($o$'min_games', v_min_games,$o$) <> 1 then
    raise exception '成績統計裡 min_games 那一行不是剛好一處，整份退回';
  end if;
  v_new := replace(v_def, $o$'min_games', v_min_games,$o$, $n$'min_games', v_min_games, 'min_hands', public._hand_min_count(),$n$);
  execute v_new;

  -- ④ 歷史累積（選日期）：把 min_hands 帶出去
  v_def := pg_get_functiondef('public.get_my_stats_range_tx(uuid,timestamptz,timestamptz)'::regprocedure);
  v_new := replace(v_def, $o$'min_games', v -> 'min_games',$o$, $n$'min_games', v -> 'min_games', 'min_hands', v -> 'min_hands',$n$);
  if v_new = v_def then
    raise exception '找不到歷史累積那一支的 min_games，整份退回';
  end if;
  execute v_new;
end $$;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise 印訊息 —— 硬規則 1.8）
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_m   int;
  v_lb  jsonb;
  v_st  jsonb;
  v_mem uuid;
begin
  -- ① 規定局數是 30
  v_msg := v_msg || case when public._hand_min_count() = 30 then '✅' else '🔴' end
        || ' ① 規定局數 ' || public._hand_min_count() || E'（要 30）\n';

  -- ② 三支都真的叫了 ①（問「有沒有呼叫」，不是「有沒有提到」）
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('get_season_leaderboard_tx', '_member_stats_core')
     and pg_get_functiondef(p.oid) ~ 'public\._hand_min_count\(\)';
  select count(*) into v_m from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'get_my_stats_range_tx'
     and pg_get_functiondef(p.oid) ~ $r$'min_hands', v -> 'min_hands'$r$;
  v_msg := v_msg || case when v_n = 2 and v_m = 1 then '✅' else '🔴' end
        || ' ② 叫規定局數的 ' || v_n || ' 支（要 2）、歷史累積帶出去 ' || v_m || E'（要 1）\n';

  -- ③ 排行榜回的規定局數仍是 30（行為不變的正對照）
  v_lb := public.get_season_leaderboard_tx('11111111-1111-1111-1111-111111111111'::uuid, 10);
  v_msg := v_msg || case when (v_lb -> 'hand_leaders' ->> 'min_hands')::int = 30 then '✅' else '🔴' end
        || ' ③ 排行榜回的規定局數 ' || coalesce(v_lb -> 'hand_leaders' ->> 'min_hands', '（沒有）') || E'（要 30）\n';

  -- ④ 成績統計回 min_hands；拿一位有打過計分板的會員看「局數 vs 場數」
  select sp.member_id into v_mem
    from session_players sp join hands h on h.session_id = sp.session_id and h.status = 'confirmed'
   where sp.finish_rank is not null and sp.seat is not null
   group by sp.member_id order by count(*) desc limit 1;
  v_st := public._member_stats_core('11111111-1111-1111-1111-111111111111'::uuid, v_mem);
  v_msg := v_msg || case when (v_st ->> 'min_hands')::int = 30 and (v_st ->> 'min_games')::int = 5 then '✅' else '🔴' end
        || ' ④ 成績統計 min_hands ' || coalesce(v_st ->> 'min_hands', '（沒有）') || '、min_games ' || coalesce(v_st ->> 'min_games', '（沒有）')
        || '（要 30、5）例：生涯 ' || coalesce(v_st -> 'all' ->> 'games', '?') || ' 場 ' || coalesce(v_st -> 'all' ->> 'hand_count', '?') || E' 局\n';

  -- ⑤ 授權：① 前端叫不到；三支原本的授權沒變（authenticated 叫得動讀的那兩支）
  select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.pronamespace = 'public'::regnamespace and p.proname = '_hand_min_count'
     and a.privilege_type = 'EXECUTE' and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid);
  select count(*) into v_m from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('get_season_leaderboard_tx', 'get_my_stats_range_tx', 'get_my_stats_tx')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v_msg := v_msg || case when v_n = 0 and v_m = 3 then '✅' else '🔴' end
        || ' ⑤ 規定局數前端叫得到的 ' || v_n || ' 個（要 0）、三支讀的登入的人叫得到 ' || v_m || '（要 3）';

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 驗證段沒有跑到') as "驗證";
