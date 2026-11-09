/* ============================================================
   成績頁加「平均每將時間」（2026-11-10 使用者：本季數據、歷史數據都要；本季那一格取代「對手平均段位」）

   ① 新增 _member_round_minutes(org, member, from, to)：**平均每將時間只有這一份算法**
      ＝ 這位會員打完的每一將（session_rounds.started_at → finished_at）平均分鐘
      · 不含將與將之間的休息（只加每一將自己的時間）
      · 只算 10～120 分的將（超過 2 小時是忘了結束、不到 10 分不合理）
      · 不算好友練習賽、不算作廢與刪除的場次
      · 時間範圍看那一將打完的時間（finished_at）
      前端叫不到（只給其他 DEFINER 函式用）
   ② _member_stats_core：本季、歷史各叫一次，回 round_min（每將平均分鐘）與 rounds（算了幾將）
      本季 ＝ 賽季起點（或區間起點，取較晚的）到區間終點；歷史 ＝ 區間（沒選區間就是全部）
      ⚠ opp_rank／opp_rating 照舊回（他人個人卡等呼叫端不受影響），只是成績頁不再顯示
   ③ pos_member_detail_tx：昨天的 pace 改叫同一支，兩邊的數字不會不一樣
   ②③ 撈線上全文 → 換那幾處 → 換不到就整份不執行（raise，故意不提交）
   ============================================================ */

create or replace function public._member_round_minutes(
  p_org_id uuid, p_member_id uuid, p_from timestamptz default null, p_to timestamptz default null)
returns table (rounds int, avg_min int)
language sql stable security definer set search_path to 'public'
as $$
  /* 平均每將時間（2026-11-10）：成績頁（_member_stats_core）與 POS 會員查詢（pos_member_detail_tx）共用這一份 */
  select count(*)::int, round(avg(x.mins))::int
    from (select extract(epoch from sr.finished_at - sr.started_at) / 60 as mins
            from session_players sp
            join table_sessions ts on ts.id = sp.session_id
            join session_rounds sr on sr.session_id = sp.session_id
           where sp.member_id = p_member_id
             and ts.org_id = p_org_id
             and ts.mode <> 'friendly'
             and ts.status <> 'voided'
             and ts.deleted_at is null
             and sr.status = 'finished'
             and sr.started_at is not null and sr.finished_at is not null
             and (p_from is null or sr.finished_at >= p_from)
             and (p_to   is null or sr.finished_at <  p_to)) x
   where x.mins between 10 and 120
$$;
revoke execute on function public._member_round_minutes(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function public._member_round_minutes(uuid, uuid, timestamptz, timestamptz) to service_role;

do $$
declare
  v_old text; v_new text;
begin
  -- ② 成績
  v_old := pg_get_functiondef('public._member_stats_core'::regproc);
  v_new := v_old;
  v_new := replace(v_new, '  v_opp_rating int;',
    '  v_opp_rating int; v_s_rmin int; v_s_rounds int; v_a_rmin int; v_a_rounds int;   -- ★ 2026-11-10 平均每將時間');
  v_new := replace(v_new, '  /* ── 本季全國排名：',
    E'  /* ── ★ 平均每將時間（2026-11-10）：算法只在 _member_round_minutes ── */\r\n'
    || E'  select r.rounds, r.avg_min into v_s_rounds, v_s_rmin from public._member_round_minutes(p_org_id, p_member_id, greatest(v_win, p_from), p_to) r;\r\n'
    || E'  select r.rounds, r.avg_min into v_a_rounds, v_a_rmin from public._member_round_minutes(p_org_id, p_member_id, p_from, p_to) r;\r\n\r\n'
    || '  /* ── 本季全國排名：');
  v_new := replace(v_new, $q$'opp_rating', v_opp_rating,$q$,
    $q$'opp_rating', v_opp_rating, 'round_min', v_s_rmin, 'rounds', coalesce(v_s_rounds, 0),$q$);
  v_new := replace(v_new, $q$'opponents',   coalesce(v_opp, 0),$q$,
    $q$'opponents',   coalesce(v_opp, 0), 'round_min', v_a_rmin, 'rounds', coalesce(v_a_rounds, 0),$q$);
  if (length(v_new) - length(replace(v_new, '_member_round_minutes(', ''))) <> 2 * length('_member_round_minutes(')
     or (length(v_new) - length(replace(v_new, $q$'round_min'$q$, ''))) <> 2 * length($q$'round_min'$q$)
     or v_new !~ 'v_s_rmin int; v_s_rounds int' then
    raise exception '② _member_stats_core 有一處沒換到，整份不執行';
  end if;
  execute v_new;

  -- ③ POS 會員查詢的 pace 改叫同一支
  v_old := pg_get_functiondef('public.pos_member_detail_tx'::regproc);
  v_new := regexp_replace(v_old,
    $q$'pace', \(.*?where x\.mins between 10 and 120\),$q$,
    $q$'pace', (select case when r.rounds = 0 then null else jsonb_build_object('rounds', r.rounds, 'per_round_min', r.avg_min, 'three_min', r.avg_min * 3) end
                from public._member_round_minutes(p_org_id, m.id) r),   -- 2026-11-10 改叫共用算法$q$);
  if v_new = v_old or v_new !~ '_member_round_minutes\(p_org_id, m\.id\)' or v_new ~ 'x\.mins between' then
    raise exception '③ pos_member_detail_tx 的 pace 沒換到，整份不執行';
  end if;
  execute v_new;
end $$;

/* ── 驗證（單一 SELECT；不用 raise）──────────────────────────── */
with top as (   -- 打最多將的那位（正對照：應該有數字）
  select sp.member_id, ts.org_id
    from session_players sp
    join table_sessions ts on ts.id = sp.session_id
    join session_rounds sr on sr.session_id = sp.session_id and sr.status = 'finished'
   where ts.mode <> 'friendly'
   group by 1, 2 order by count(*) desc limit 1),
s as (select public._member_stats_core(t.org_id, t.member_id) d, public.pos_member_detail_tx(t.org_id, t.member_id) p,
             (select r from public._member_round_minutes(t.org_id, t.member_id) r) h
        from top t)
select
  case when (select count(*) from pg_proc where proname in ('_member_round_minutes', '_member_stats_core', 'pos_member_detail_tx')) = 3 then '✅' else '🔴' end || ' ① 三支各只有一個版本' || E'\n' ||
  case when not has_function_privilege('anon', 'public._member_round_minutes(uuid,uuid,timestamptz,timestamptz)', 'execute')
        and not has_function_privilege('authenticated', 'public._member_round_minutes(uuid,uuid,timestamptz,timestamptz)', 'execute') then '✅' else '🔴' end || ' ② 新函式前端叫不到' || E'\n' ||
  coalesce((select case when (d -> 'all' ->> 'round_min')::int between 20 and 100 then '✅' else '🔴' end
                   || ' ③ 歷史：每將 ' || (d -> 'all' ->> 'round_min') || ' 分（' || (d -> 'all' ->> 'rounds') || ' 將）' from s), '🔴 ③ 沒有樣本') || E'\n' ||
  coalesce((select case when d -> 'season' ? 'round_min' then '✅' else '🔴' end
                   || ' ④ 本季有 round_min：' || coalesce(d -> 'season' ->> 'round_min', '（這一季還沒打）') || ' 分（' || (d -> 'season' ->> 'rounds') || ' 將）' from s), '🔴 ④ 沒有樣本') || E'\n' ||
  coalesce((select case when (p -> 'pace' ->> 'per_round_min') = (d -> 'all' ->> 'round_min') then '✅' else '🔴' end
                   || ' ⑤ POS 會員查詢跟成績頁同一個數字（' || (p -> 'pace' ->> 'per_round_min') || ' 分）' from s), '🔴 ⑤ 沒有樣本') || E'\n' ||
  coalesce((select case when d -> 'season' ? 'opp_rank' and d -> 'all' ? 'minutes' then '✅' else '🔴' end || ' ⑥ 原本的鍵都還在' from s), '🔴 ⑥ 沒有樣本') as "驗證";
