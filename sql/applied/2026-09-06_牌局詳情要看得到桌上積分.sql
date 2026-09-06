/* ============================================================
   `get_my_games_tx` 回傳桌上積分
   2026-09-06 · MIGI 咪吉麻將 · 一支 CREATE OR REPLACE，簽名不變

   ── 為什麼 ────────────────────────────────────────────
   `session_players.final_score` 是同一天新增的（隨機零和積分），
   但**沒有任何地方讀得到它** —— 前端拿不到就等於沒有。

   ── 只加一個鍵 ────────────────────────────────────────
   玩家陣列從 12 個鍵變 13 個：多 `final_score`。
   ⚠ **不另外加一個 top-level 的 `my_final_score`** ——
     `mapGame` 本來就會從 `players` 裡挑出 `is_me` 那一位
     （`const me = players.find(p => p.is_me)`），
     多開一個欄位就是同一份資料兩個來源，日後一定會漂。

   ⚠ 值可能是 **null**，而那是有意義的：純娛樂的桌不計積分
     （`stake_levels.is_hygiene`）。**前端要分辨 null 與 0** ——
     0 是「打平」，null 是「這桌沒有這回事」。
   ============================================================ */

do $mig$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'get_my_games_tx' and p.prokind = 'f';

  if v_def is null then raise exception '找不到 get_my_games_tx'; end if;

  /* ⚠ 錨點用 `'score_points', p.score_points,` 這一整串 ——
     只抓 `score_points` 的話，`mine` 那個 CTE 裡的
     `sp.score_points as my_score` 也會被掃到。 */
  v_new := replace(v_def,
    E'''score_points'', p.score_points,',
    E'''score_points'', p.score_points,\n                   /* 桌上積分（2026-09-06）。⚠ null 是有意義的：\n                      純娛樂的桌不計積分，那與「打平（0）」不同。 */\n                   ''final_score'',  p.final_score,');

  if v_new = v_def then
    raise exception '🔴 沒有替換到 —— 線上版本跟預期不同，先撈出來看';
  end if;

  execute v_new;
end $mig$;

/* ── 驗證 ────────────────────────────────────────────────
   🎯 直接看**實際回傳的鍵**，不要掃函式內文（硬規則 3.5：
     內文比對會被自己寫的註解觸發）。
   ⚠ 期望值當場算，不寫死（硬規則 3.56）。 */
with 我 as (
  select sp.member_id, sp.session_id
    from session_players sp
    join table_sessions ts on ts.id = sp.session_id
   where ts.status = 'completed'
   order by ts.ended_at desc nulls last
   limit 1
),
回傳 as (
  select e.v
    from 我, jsonb_array_elements(
           get_my_games_tx((select id from orgs limit 1), 我.member_id, 20)) e(v)
   where (e.v ->> 'session_id')::uuid = 我.session_id
),
玩家 as (
  select p.pv from 回傳, jsonb_array_elements(回傳.v -> 'players') p(pv)
)
select
  case when not exists (select 1 from 我)
       then '🔴 ⓪ 找不到任何已收桌的場次 —— 這份驗證等於沒跑'
       else '✅ ⓪ 樣本場次取到了' end as ⓪樣本,

  /* ① 鍵在不在 */
  /* ⚠ 用 `jsonb_exists()` 不用 `?` 運算子 —— 同一天才踩過：
     SQL client 把 `?` 當參數佔位符，語句邊界被弄亂，
     而錯誤訊息會指向最後那句 select（完全指不到原因）。
     `??` 是 JDBC 的跳脫寫法，**PostgreSQL 沒有這個運算子**。 */
  case when exists (select 1 from 玩家 where jsonb_exists(pv, 'final_score'))
       then '✅ ① 玩家欄位裡有 final_score'
       else '🔴 ① 沒有' end as ①有這個鍵,

  /* ② 值要跟資料表對得上（包含 null 也要一致）。
     🎯 用 `is distinct from` —— `=` 遇到 null 會回 null 而不是 false，
       那樣「全部都是 null」也會被算成沒有差異。 */
  (select case when count(*) = 0 then '✅ ② 每一位的值都與 session_players 一致'
               else '🔴 ② 有 ' || count(*)::text || ' 位對不上' end
     from 玩家 j
     join session_players sp
       on sp.member_id = (j.pv ->> 'member_id')::uuid
      and sp.session_id = (select session_id from 我)
    where sp.final_score is distinct from nullif(j.pv ->> 'final_score', '')::int
  ) as ②值對得上,

  /* ③ 🎯 正對照：鍵的總數。
     期望 13 = 12 原本 ＋ final_score（12 是 2026-09-06 當場數出來的）。
     ⚠ 少了這一格，一支「把整個 players 換掉」的實作也會讓①②變綠。 */
  (select case when count(distinct k) = 13
               then '✅ ③ 玩家欄位共 13 個（12 原本 ＋ final_score）'
               else '🔴 ③ 變成 ' || count(distinct k)::text || ' 個' end
     from 玩家, jsonb_object_keys(玩家.pv) k) as ③鍵數,

  /* ④ 🎯 正對照：純娛樂的桌**仍然是 null**，不可以被填成 0。 */
  (select case when count(*) = 0 then '⚪ ④ 今天沒有純娛樂的已收桌場次可以對照'
               when count(*) filter (where sp.final_score is not null) = 0
               then '✅ ④ 純娛樂的場次 final_score 仍然是 null'
               else '🔴 ④ 純娛樂的場次被填了數字' end
     from session_players sp
     join table_sessions ts on ts.id = sp.session_id
     join stake_levels sl on sl.id = ts.stake_level_id
    where ts.status = 'completed' and sl.is_hygiene) as ④純娛樂仍是null;
