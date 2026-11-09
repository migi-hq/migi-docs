/* ============================================================
   「打了幾將」與「平均每將時間」都照真實打完的將算（2026-11-10 使用者）

   使用者：「不能用排除的，要真實統計打完的將」
   ⇒ _member_round_minutes 不再用時間長短排除任何一將（原本只算 10～120 分鐘的將）：
     rounds   打完的將數
     avg_min  這些將的平均分鐘（每一將自己的時間，不含將與將之間的休息）
   欄位名與型別不變 ⇒ CREATE OR REPLACE、呼叫端（成績頁、POS 會員查詢）不用改

   哪些將算「打完」（2026-11-10 使用者拍板）：
     · ✅ 正常打完
     · ✅ **爆卡結束的那一將**（使用者：「爆卡要算在內」）—— tbl_bust_decide_tx 會把它標成 'finished'
     · ❌ 沒打滿、提前收桌的那一將 —— 停在 status = 'playing'，只數 'finished' 就不會算到
   📌 原本設上限是怕「忘了按結束」的將把平均拉爆；查過線上：超過 2 小時的 6 將裡，
     真客人的是 121／127／133 分（真的打得久），981／1159／6796 分那三將是**測試帳號**（測試01～04）
     在測試門市斷斷續續測計分板留下的 ⇒ 不設排除，那三將只會影響測試帳號自己的數字
   ============================================================ */

create or replace function public._member_round_minutes(
  p_org_id uuid, p_member_id uuid, p_from timestamptz default null, p_to timestamptz default null)
returns table (rounds int, avg_min int)
language sql stable security definer set search_path to 'public'
as $$
  /* 打了幾將與平均每將時間（2026-11-10）：成績頁（_member_stats_core）與 POS 會員查詢（pos_member_detail_tx）共用這一份
     打完的將 ＝ status = 'finished'（正常打完＋爆卡結束；提前收桌還在打的那一將不算）；不用時間長短排除任何一將 */
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
$$;
revoke execute on function public._member_round_minutes(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function public._member_round_minutes(uuid, uuid, timestamptz, timestamptz) to service_role;

/* ── 驗證（單一 SELECT；不用 raise）──────────────────────────── */
with base as (   -- 每位會員直接數：打完的將、平均分鐘、其中幾將是爆卡結束、幾將還停在進行中
  select sp.member_id, ts.org_id,
         count(*) filter (where sr.status = 'finished') n_fin,
         round(avg(extract(epoch from sr.finished_at - sr.started_at) / 60) filter (where sr.status = 'finished'))::int avg_fin,
         count(*) filter (where sr.status = 'finished' and exists (select 1 from session_busts b where b.session_id = sr.session_id and b.decision = 'ended' and b.decided_at = sr.finished_at)) n_bust,
         count(*) filter (where sr.status = 'playing') n_play
    from session_players sp
    join table_sessions ts on ts.id = sp.session_id
    join session_rounds sr on sr.session_id = sp.session_id
   where ts.mode <> 'friendly' and ts.status <> 'voided' and ts.deleted_at is null
     and sr.started_at is not null and (sr.status = 'playing' or sr.finished_at is not null)
   group by 1, 2),
top as (select * from base order by n_fin desc limit 1),
s as (select t.n_fin, t.avg_fin,
             -- ⚠ 各取一欄，不要把整列塞進一個欄位再用「(欄位).rounds」取 —— 那會報「record type has not been registered」（2026-11-10 踩到）
             (select r.rounds  from public._member_round_minutes(t.org_id, t.member_id) r) h_rounds,
             (select r.avg_min from public._member_round_minutes(t.org_id, t.member_id) r) h_avg,
             public._member_stats_core(t.org_id, t.member_id) d, public.pos_member_detail_tx(t.org_id, t.member_id) p
        from top t)
select
  case when (select count(*) from pg_proc where proname = '_member_round_minutes') = 1 then '✅' else '🔴' end || ' ① 只有一個版本' || E'\n' ||
  case when not has_function_privilege('authenticated', 'public._member_round_minutes(uuid,uuid,timestamptz,timestamptz)', 'execute') then '✅' else '🔴' end || ' ② 前端叫不到' || E'\n' ||
  coalesce((select case when h_rounds = n_fin and h_avg = avg_fin then '✅' else '🔴' end
                   || ' ③ 打最多將的那位：' || h_rounds || ' 將、每將 ' || h_avg || ' 分（直接算：' || n_fin || ' 將、' || avg_fin || ' 分）' from s), '🔴 ③ 沒有樣本') || E'\n' ||
  coalesce((select case when (d -> 'all' ->> 'rounds')::int = h_rounds and (p -> 'pace' ->> 'per_round_min')::int = h_avg then '✅' else '🔴' end
                   || ' ④ 成績頁歷史與 POS 同一組數字' from s), '🔴 ④ 沒有樣本') || E'\n' ||
  coalesce((select case when (select r.rounds from public._member_round_minutes(b.org_id, b.member_id) r) = b.n_fin then '✅' else '🔴' end
                   || ' ⑤ 爆卡結束那一將有算：這位打完 ' || b.n_fin || ' 將、其中 ' || b.n_bust || ' 將是爆卡結束'
              from base b where b.n_bust > 0 limit 1), '⚪ ⑤ 沒有爆卡結束的將，這一格測不了') || E'\n' ||
  coalesce((select case when (select r.rounds from public._member_round_minutes(b.org_id, b.member_id) r) = b.n_fin then '✅' else '🔴' end
                   || ' ⑥ 提前收桌、停在進行中的那一將不算：這位打完 ' || b.n_fin || ' 將、另有 ' || b.n_play || ' 將停在進行中'
              from base b where b.n_play > 0 limit 1), '⚪ ⑥ 沒有停在進行中的將，這一格測不了') as "驗證";
