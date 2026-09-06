/* ============================================================
   把「隨機名次」上線之前就收掉的桌補上名次
   2026-09-06 · MIGI 咪吉麻將 · 一次性回填

   ── 為什麼 ────────────────────────────────────────────
   `placeholder_ranks_tx` 是今天才接進 `settle_session_tx` 的，
   所以**在那之前收的桌** `finish_rank` 仍然是 null。
   而「等待結算」那個狀態同一天被拿掉了
   ⇒ 那些列在 App 上變成方塊「—」、沒有分數 —— **看起來像壞掉**。

   ── 範圍（動手前查過，不是估的）────────────────────
   `status = 'completed'` ＋ 剛好四位玩家 ＋ 一個名次都沒有 → **1 場**
   （09-06 11:45 開、12:59 收）。
   ⚠ 另外三場是 `open`（還在打）**不補** —— 它們收桌時自然會拿到名次，
     現在給了反而會讓 `settle_session_tx` 那一步變成 `already_applied`。
   ⚠ 只有 1 位玩家的那場也不補（`apply_session_rounds_tx` 硬性要四人）。

   ── 🔴 順序有意義，不可以亂跑 ─────────────────────────
   `apply_session_rounds_tx` 用「**這個人有沒有別的已結算場次**」判斷
   定位賽（人生第一場 `+30/+15/+10/+5`）。
   ⇒ 回填**一定要照時間由舊到新**，否則定位賽的加成會落在錯的那一場。
   📌 今天只有一場，順序不影響結果 —— 但這份 SQL 之後可能被再用一次，
     所以 `order by` 不是裝飾。

   ⚠ **這一份會真的寫進去**（改 `members.rating`、`session_players`），
     不像驗證那種交易內回滾。對象全是測試帳號。
   ============================================================ */

do $bf$
declare
  r         record;
  v_res     jsonb;
  v_done    int := 0;
  v_skip    int := 0;
  v_msg     text := '';
begin
  for r in
    select ts.id, ts.ended_at
      from table_sessions ts
     where ts.deleted_at is null
       and ts.status = 'completed'
       and (select count(*) from session_players sp where sp.session_id = ts.id) = 4
       and not exists (select 1 from session_players sp
                        where sp.session_id = ts.id and sp.finish_rank is not null)
     order by ts.started_at            -- 🔴 由舊到新（定位賽判斷靠它）
  loop
    v_res := placeholder_ranks_tx(r.id);

    if coalesce((v_res ->> 'ok')::boolean, false) then
      v_done := v_done + 1;
      /* 🎯 `apply_session_rounds_tx` 寫的是 `settled_at = now()`，
         而這些是**歷史**場次 —— 全部蓋成今天會讓段位走勢圖
         把好幾天的成績疊在同一個點上。改回那一場真正的收桌時間。
         ⚠ 只動 `settled_at`，`rating_after` 不動：
           分數確實是**現在**才算出來的，那個值是對的。 */
      update session_players
         set settled_at = r.ended_at
       where session_id = r.id;
    else
      v_skip := v_skip + 1;
      v_msg := v_msg || E'\n  ⚠ 跳過 ' || r.id || '：' || coalesce(v_res ->> 'reason', '?');
    end if;
  end loop;

  raise notice '補了 % 場，跳過 % 場%', v_done, v_skip, v_msg;
end $bf$;

/* ── 驗證 ────────────────────────────────────────────────
   🔴 這一份**真的寫進去了**，所以驗證是事後查，不是交易內回滾。
   ⚠ 期望值一律當場算（硬規則 3.56），不寫死「1 場」。 */
select
  /* ① 主結果：已收桌又滿四人的場次，現在應該一場都不缺名次。 */
  case when (select count(*) from table_sessions ts
              where ts.deleted_at is null and ts.status = 'completed'
                and (select count(*) from session_players sp
                      where sp.session_id = ts.id) = 4
                and not exists (select 1 from session_players sp
                                 where sp.session_id = ts.id
                                   and sp.finish_rank is not null)) = 0
       then '✅ ① 已收桌且滿四人的場次，全部都有名次了'
       else '🔴 ① 還有 '
            || (select count(*) from table_sessions ts
                 where ts.deleted_at is null and ts.status = 'completed'
                   and (select count(*) from session_players sp
                         where sp.session_id = ts.id) = 4
                   and not exists (select 1 from session_players sp
                                    where sp.session_id = ts.id
                                      and sp.finish_rank is not null))::text
            || ' 場沒補到' end as ①都補上了,

  /* ② 補出來的名次要是 1..4 的排列，不是四個亂數。
     ⚠ 掃**所有**有名次的已收桌場次，不只這次補的 ——
       順便驗到原本就正常的那些沒有被弄壞。 */
  (select case when count(*) filter (where 名次 is distinct from array[1,2,3,4]) = 0
               then '✅ ② ' || count(*)::text || ' 場的名次都是 1..4 的排列'
               else '🔴 ② 有 ' || count(*) filter (where 名次 is distinct from array[1,2,3,4])::text
                    || ' 場不是排列' end
     from (select sp.session_id,
                  array_agg(sp.finish_rank order by sp.finish_rank) as 名次
             from session_players sp
             join table_sessions ts on ts.id = sp.session_id
            where ts.status = 'completed' and sp.finish_rank is not null
            group by 1) t) as ②名次是排列,

  /* ③ 🎯 正對照一：**還在打的場次不可以被補。**
     ⚠ 只驗①的話，一支「把所有場次都補一遍」的實作也會全綠 ——
       而那會讓收桌那一步變成 already_applied，桌還沒打完就有成績了。 */
  case when (select count(*) from session_players sp
              join table_sessions ts on ts.id = sp.session_id
             where ts.status = 'open' and sp.finish_rank is not null) = 0
       then '✅ ③ 還在打的場次沒有被動到'
       else '🔴 ③ 有 open 的場次被補了名次' end as ③沒誤傷進行中,

  /* ④ 🎯 正對照二：**人數不足的場次也不該被補。** */
  case when (select count(*) from table_sessions ts
              where ts.status = 'completed'
                and (select count(*) from session_players sp
                      where sp.session_id = ts.id) <> 4
                and exists (select 1 from session_players sp
                             where sp.session_id = ts.id and sp.finish_rank is not null)) = 0
       then '✅ ④ 不滿四人的場次沒有被補'
       else '🔴 ④ 有不滿四人的場次拿到名次 —— 那不合規則' end as ④人數不足沒被補,

  /* ⑤ `settled_at` 有沒有貼回那一場真正的收桌時間。

     🔴 **這一格第一次是紅的，而錯的是期望值不是函式**（硬規則 3.56）。
       我寫成掃**全部**已收桌的場次 ⇒ 掃到了 `sql/_工具/測試戰績_造.sql`
       在 2026-09-03 造的 8 場 fixture：它們 `ended_at` 是回填的
       （08-25…09-02）而 `settled_at` 全是造的那一刻 09-03 15:18，
       所以「差超過一天」的 32 列**一列都不是這份 SQL 動的**。
     ✅ 這次補的那一場是 0 天。
     📌 順帶查證：走勢圖排序用的是 `endedAt || settledAt`
       （`ranktrend.jsx:83`，註解明寫「用開打日不是結算日」）
       ⇒ 那 8 場的 `settled_at` 相同**不影響任何畫面**。
       使用者 2026-09-06 決定：舊的 fixture 不管，只算最後那一場。

     → 所以範圍縮到「**這份 SQL 補的那些**」：`finish_rank` 有值
       但 `started_at` 在今天之前的不算（那是 fixture）。 */
  (select case when count(*) = 0 then '✅ ⑤ 這次補的場次 settled_at 都貼回收桌時間了'
               else '🔴 ⑤ 有 ' || count(*)::text || ' 列沒貼回去' end
     from session_players sp
     join table_sessions ts on ts.id = sp.session_id
    where ts.status = 'completed' and sp.settled_at is not null
      and ts.started_at::date = current_date
      and abs(extract(epoch from (sp.settled_at - ts.ended_at))) > 86400) as ⑤時間對得上;
