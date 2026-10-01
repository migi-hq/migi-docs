/* ============================================================
   牌局詳情的結束時間與花費時間不等收桌 · 2026-10-02
   📄 使用者 2026-10-02（App 牌局詳情截圖）：「沒顯示結束時間與花費時間」

   _game_row（會員 App 牌局清單與牌局詳情都經過它）的 ended_at 讀的是 table_sessions.ended_at ＝ **收桌時間**，
   花費時間也用它算 ⇒ 打完了、店員還沒收桌的那一場，兩格都是空的。
   而同一天才把「我的牌局」改成打完就列（2026-10-02_我的牌局只認登入身分.sql）⇒ 這種場次現在會出現在 App 上。

   ✅ 改成：結束時間 ＝ coalesce(收桌時間, 這個人這一場的結算時間 session_players.settled_at)
     · 已經收桌的：跟以前一樣（收桌時間）—— 舊紀錄一筆都不變
     · 打完還沒收桌的：用最後一將打完、成績算好的那一刻
     花費時間用同一個結束時間算，兩格不會一個有一個沒有。
   ⚠ 改的是線上全文，三個錨點都必須剛好出現一次；全部改完才重建一次（可重跑）。CREATE OR REPLACE、簽名不變 ⇒ 授權不會掉。
   ============================================================ */

do $$
declare
  v_def text;
  v_old text[] := array[
    $a$    'ended_at',   m.ended_at,$a$,
    $a$      case when m.ended_at is not null$a$,
    $a$                  (m.ended_at - coalesce(m.activated_at, m.started_at))) / 60)::int)$a$];
  v_new text[] := array[
    $b$    -- 結束時間：收桌時間；還沒收桌就用打完、成績算好的那一刻（2026-10-02）
    'ended_at',   coalesce(m.ended_at, sp.settled_at),$b$,
    $b$      case when coalesce(m.ended_at, sp.settled_at) is not null$b$,
    $b$                  (coalesce(m.ended_at, sp.settled_at) - coalesce(m.activated_at, m.started_at))) / 60)::int)$b$];
  v_n int; i int;
begin
  v_def := pg_get_functiondef('public._game_row(uuid,uuid,uuid)'::regprocedure);
  if position('coalesce(m.ended_at, sp.settled_at)' in v_def) > 0 then
    return;   -- 已經改過（可重跑）
  end if;
  for i in 1 .. array_length(v_old, 1) loop
    v_n := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    if v_n <> 1 then
      raise exception '_game_row 的第 % 個錨點出現 % 次（要剛好 1 次），整份不執行：%', i, v_n, left(v_old[i], 40);
    end if;
  end loop;
  for i in 1 .. array_length(v_old, 1) loop
    v_def := replace(v_def, v_old[i], v_new[i]);
  end loop;
  execute v_def;
end $$;

/* ── 驗證（單一 SELECT；_game_row 是 STABLE、只讀，在 SELECT 裡叫不會寫入任何東西）──
   ③ 打完沒收桌的：結束時間 ＝ 結算時間、花費時間有值
   ④ 正對照：已收桌的那一場，結束時間仍然 ＝ 收桌時間（舊紀錄一筆都不能變） */
with
fn as (select count(*) as n from pg_proc where pronamespace = 'public'::regnamespace and proname = '_game_row'),
df as (select pg_get_functiondef('public._game_row(uuid,uuid,uuid)'::regprocedure) as d),
o as (   -- 打完、還沒收桌
  select sp.settled_at, public._game_row(sp.org_id, sp.session_id, sp.member_id) as g
    from session_players sp join table_sessions s on s.id = sp.session_id
   where s.status = 'open' and s.deleted_at is null and sp.finish_rank is not null limit 1),
c as (   -- 已經收桌
  select s.ended_at, public._game_row(sp.org_id, sp.session_id, sp.member_id) as g
    from session_players sp join table_sessions s on s.id = sp.session_id
   where s.status = 'completed' and s.ended_at is not null and s.deleted_at is null and sp.member_id is not null
   order by s.ended_at desc limit 1)
select concat_ws(E'\n',
  case when (select n from fn) = 1 then '✅ ① _game_row 版本數 1' else '🔴 ① 版本數 ' || (select n from fn) end,
  case when (select (length(d) - length(replace(d, 'coalesce(m.ended_at, sp.settled_at)', ''))) / length('coalesce(m.ended_at, sp.settled_at)') from df) = 3
       then '✅ ② 結束時間與花費時間都改用「收桌時間，沒有就用結算時間」（3 處）' else '🔴 ② 函式體沒有改齊' end,
  coalesce((select case when (g ->> 'ended_at')::timestamptz = settled_at and (g ->> 'duration_minutes') is not null
                        then '✅ ③ 打完沒收桌的：結束時間 ＝ 結算時間，花費時間 ' || (g ->> 'duration_minutes') || ' 分'
                        else '🔴 ③ 打完沒收桌的：結束時間 ' || coalesce(g ->> 'ended_at', '空') || '、花費時間 ' || coalesce(g ->> 'duration_minutes', '空') end from o),
           '⚪ ③ 現在沒有「打完還沒收桌」的場次，這一格測不了'),
  coalesce((select case when (g ->> 'ended_at')::timestamptz = ended_at
                        then '✅ ④ 已收桌的：結束時間仍然是收桌時間（舊紀錄沒變）'
                        else '🔴 ④ 已收桌的結束時間變了：' || coalesce(g ->> 'ended_at', '空') end from c),
           '⚪ ④ 找不到已收桌的場次，這一格測不了')
) as "驗證";
