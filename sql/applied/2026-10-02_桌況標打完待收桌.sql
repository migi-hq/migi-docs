/* ============================================================
   POS 桌況多回「這場打完了沒」· 2026-10-02
   📄 使用者 2026-10-02：「POS 的 A1 也還是顯示中」→ 拍板：桌況標「已打完 · 待收桌」

   打完最後一將，成績當下就自動結算；但桌子要等店員在 POS 按收桌才放出來（CLAUDE.md 13.9c，兩件事分開是對的）。
   問題只在**店員看不出來**：打完的桌跟還在打的桌一樣是「使用中」。
   ✅ list_tables_tx 多回 game_over：這一場已經有人有名次 ＝ 打完了、等收桌。
     判斷用既有的 _session_scored(場次)（「這場算過了沒」全系統只有這一份定義），不另外寫一份。
   ⚠ status 維持 off／use／idle 三值不動 —— 舊版 POS 遇到沒見過的值會畫成灰卡（函式裡的註解）。
     新欄位舊版 POS 看不到就當沒有，不會壞。
   ⚠ 改的是線上全文，錨點必須剛好出現一次（可重跑）。CREATE OR REPLACE、簽名不變 ⇒ 授權不會掉。
   ============================================================ */

do $$
declare
  v_def text;
  v_old text := $a$      'pkg_phase', (public._pkg_time(ts.id, false) ->> 'phase'),   /* ⏰ 包桌續時（2026-10-01） */$a$;
  v_new text := $b$      'pkg_phase', (public._pkg_time(ts.id, false) ->> 'phase'),   /* ⏰ 包桌續時（2026-10-01） */
      /* 打完了、等店員收桌（2026-10-02）：這一場已經有人有名次。判斷只有 _session_scored 這一份 */
      'game_over', (ts.id is not null and public._session_scored(ts.id)),$b$;
  v_n int;
begin
  v_def := pg_get_functiondef('public.list_tables_tx(uuid,uuid)'::regprocedure);
  if position('''game_over''' in v_def) > 0 then
    return;   -- 已經改過（可重跑）
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then
    raise exception 'list_tables_tx 的錨點出現 % 次（要剛好 1 次），整份不執行', v_n;
  end if;
  execute replace(v_def, v_old, v_new);
end $$;

/* ── 驗證（單一 SELECT）──
   ③ 打完沒收桌的那一張桌：game_over ＝ true
   ④ 反向：還在打（開著、沒有人有名次）的桌：game_over ＝ false；空桌也是 false
     （只驗 ③ 的話，一個永遠回 true 的寫法也會全綠） */
with
fn as (select count(*) as n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'list_tables_tx'),
df as (select pg_get_functiondef('public.list_tables_tx(uuid,uuid)'::regprocedure) as d),
done as (   -- 打完沒收桌的場次所在的門市與桌
  select s.org_id, t.store_id, t.id as table_id from table_sessions s join tables t on t.id = s.table_id
   where s.status = 'open' and s.deleted_at is null and public._session_scored(s.id) limit 1),
playing as (
  select s.org_id, t.store_id, t.id as table_id from table_sessions s join tables t on t.id = s.table_id
   where s.status = 'open' and s.deleted_at is null and not public._session_scored(s.id) limit 1),
r1 as (select (x ->> 'game_over')::boolean as v from done d, jsonb_array_elements(public.list_tables_tx(d.org_id, d.store_id)) x where (x ->> 'id')::uuid = d.table_id),
r2 as (select (x ->> 'game_over')::boolean as v from playing p, jsonb_array_elements(public.list_tables_tx(p.org_id, p.store_id)) x where (x ->> 'id')::uuid = p.table_id),
r3 as (select count(*) filter (where x ->> 'session_id' is null and (x ->> 'game_over')::boolean) as bad, count(*) filter (where x ->> 'session_id' is null) as n
         from done d, jsonb_array_elements(public.list_tables_tx(d.org_id, d.store_id)) x)
select concat_ws(E'\n',
  case when (select n from fn) = 1 then '✅ ① list_tables_tx 版本數 1' else '🔴 ① 版本數 ' || (select n from fn) end,
  case when (select d from df) ~ '''game_over'', \(ts\.id is not null and public\._session_scored\(ts\.id\)\)'
       then '✅ ② 多回 game_over，判斷用 _session_scored' else '🔴 ② 函式體沒有改到' end,
  coalesce((select case when v then '✅ ③ 打完沒收桌的那一張：game_over ＝ true' else '🔴 ③ 打完沒收桌的那一張：game_over 不是 true' end from r1),
           '⚪ ③ 現在沒有「打完還沒收桌」的桌，這一格測不了'),
  coalesce((select case when v = false then '✅ ④ 還在打的那一張：game_over ＝ false' else '🔴 ④ 還在打的那一張被標成打完了' end from r2),
           '⚪ ④ 現在沒有「還在打」的桌，這一格測不了'),
  coalesce((select case when bad = 0 then '✅ ⑤ 空桌 ' || n || ' 張都不是打完' else '🔴 ⑤ 有 ' || bad || ' 張空桌被標成打完' end from r3),
           '⚪ ⑤ 測不了')
) as "驗證";
