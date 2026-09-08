/* ============================================================
   舊場次補上桌上積分（fixture 回填 · **可選**）
   2026-09-07

   ── 為什麼需要 ──────────────────────────────────
   `session_players.final_score` 是 **2026-09-06 才建立**的，
   所以在那之前收的桌全部是 null。而那讓成績頁的
   「各積分級距勝率」出現一種**看起來像壞掉的狀態**：

   ```
   10/10   12 場   0 場有積分     ← 🔴 舊資料
   純娛樂  20 場   0 場有積分     ← ✅ 設計（那桌不計積分）
   ```
   兩列在數字上一模一樣。前端已經靠 `hygiene` 旗標分開它們了
   （另一份 SQL），但下面那一列會永遠說「—」，
   **而它其實只是缺一次回填**。

   ── 範圍：6 場，全部是 fixture ──────────────────
   `d0000000-0000-0000-0000-00000000000{2,3,5,6,8,9}`
   —— `sql/_工具/測試戰績_造.sql` 造的，不是真實消費。
   ⚠ 這一份**不挑 id**，靠條件圈：非純娛樂 ＋ 已收桌 ＋ 四人 ＋
     `final_score` 四個全是 null ＋ 這個 org 還沒上線。
     挑 id 的話下次有人再造一批就不能用了。

   ── 🔴 為什麼不能直接呼叫 `placeholder_ranks_tx` ──────
   那一支最後會跑 `apply_session_rounds_tx` ——
   **段位分會被再套用一次**。這些場次的名次與段位分
   2026-09-06 已經回填過了（`_把已收的桌補上名次.sql`），
   再跑一次等於**憑空多給每個人一輪段位分**，
   而且 `rating_after` 會變成一個對不上任何一場的數字。
   ⇒ 這一份**只寫 `final_score`，一個別的欄位都不碰**。

   ── ⚠ 各將名次沒有落地，所以是「重演」不是「還原」──────
   查過 `apply_session_rounds_tx`（6635 字元，沒有任何 `insert into`）：
   它只把**最後一將的名次**、段位分總和、`rating_after` 寫回
   `session_players` —— **每一將各自的名次是過路的，不存**。
   ⇒ 回填只能用同一個生成過程重演一次，並讓**最後一將對齊
     已經存著的 `finish_rank`**，這樣「名次」與「積分」才不會互相矛盾。
   📌 順帶記著：M4 電子計分要做「逐將明細」時，那張表現在還不存在。

   ── 零和是**構造上的**不是事後修正的 ──────────────
   每一將四家吃 `+3 / +1 / −1 / −3` 個單位 ⇒ 每一將加總必為 0
   ⇒ 整場加總必為 0。不需要挑一家去補差額（那一家會很怪）。

   ── 🔴 自動失效 ────────────────────────────────
   `orgs.live_from` 已到就整份不做（同 `placeholder_ranks_tx`）。
   上線那天設 `live_from` 的那個動作**順便關掉它**，
   不需要有人記得回來刪（硬規則 5.7）。
   ============================================================ */

do $$
declare
  r_sess   record;
  v_live   timestamptz;
  v_unit   int;
  v_w      int;
  v_score  jsonb;
  v_ranks  uuid[];
  r        record;
  i        int;
  v_done   int := 0;
begin
  for r_sess in
    select ts.id, ts.org_id,
           greatest(coalesce(ts.planned_rounds, 2), 2) as rounds,
           nullif(coalesce(sl.base, 0), 0)             as unit
      from table_sessions ts
      left join stake_levels sl on sl.id = ts.stake_level_id
     where ts.deleted_at is null
       and ts.status = 'completed'
       and coalesce(sl.is_hygiene, false) = false      -- 🔴 純娛樂不補，它本來就該是 null
       and nullif(coalesce(sl.base, 0), 0) is not null -- 沒有台底就算不出積分
       and exists (select 1 from session_players sp
                    where sp.session_id = ts.id and sp.finish_rank is not null)
       and (select count(*) from session_players sp where sp.session_id = ts.id) = 4
       and not exists (select 1 from session_players sp
                        where sp.session_id = ts.id and sp.final_score is not null)
  loop
    /* 閘門逐場檢查（不同場可能屬於不同 org）。 */
    select o.live_from into v_live from orgs o where o.id = r_sess.org_id;
    if v_live is not null and v_live <= now() then
      continue;
    end if;

    v_unit  := r_sess.unit;
    v_score := '{}'::jsonb;

    for i in 1 .. r_sess.rounds loop
      if i = r_sess.rounds then
        /* 🎯 **最後一將用已經存著的 `finish_rank`** ——
           畫面上的名次就是它，重演出來的積分必須跟它是同一場戲。 */
        select array_agg(sp.member_id order by sp.finish_rank)
          into v_ranks
          from session_players sp where sp.session_id = r_sess.id;
      else
        /* 前面幾將洗牌。⚠ 這一步是「第 1 名但總積分是負的」
           會自然出現的原因 —— 少了它，積分會與名次完全同向，
           而那不是這個生成器原本的行為。 */
        select array_agg(sp.member_id order by random())
          into v_ranks
          from session_players sp where sp.session_id = r_sess.id;
      end if;

      /* 倍率逐將隨機（1..4 倍台底），同 `placeholder_ranks_tx`。 */
      v_w := v_unit * (1 + floor(random() * 4)::int);
      for r in select generate_subscripts(v_ranks, 1) as rk loop
        v_score := jsonb_set(v_score, array[v_ranks[r.rk]::text],
          to_jsonb(coalesce((v_score ->> v_ranks[r.rk]::text)::int, 0)
                   + v_w * case r.rk when 1 then 3 when 2 then 1 when 3 then -1 else -3 end));
      end loop;
    end loop;

    update session_players sp
       set final_score = (v_score ->> sp.member_id::text)::int
     where sp.session_id = r_sess.id
       /* 🔴 不要用 jsonb 的 `?` 運算子 —— SQL 客戶端會把它當參數佔位符
          （2026-09-06 因此讓一整份 SQL 在編輯器裡跑不起來）。 */
       and (v_score ->> sp.member_id::text) is not null;

    v_done := v_done + 1;
  end loop;

  raise notice '回填場次：%', v_done;
end $$;


/* ============================================================
   驗證（單一 SELECT）

   ⚠ 刻意**不從 DO 區塊傳值出來**，而是直接問資料庫現在長什麼樣 ——
     那樣驗到的是**事實**，不是「我的迴圈以為自己做了什麼」。
   ⚠ 硬規則 3.55：③④ 是正對照 ——
     只驗「補上了」的那一半，一份把純娛樂也一起寫爆的 SQL 也會全綠。
   ============================================================ */
with base as (
  select ts.id,
         coalesce(sl.is_hygiene, false) as hygiene,
         nullif(coalesce(sl.base, 0), 0) as unit,
         count(*)                        as n,
         count(sp.final_score)           as scored,
         sum(sp.final_score)             as total
    from table_sessions ts
    join session_players sp on sp.session_id = ts.id
    left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.deleted_at is null and ts.status = 'completed'
     and sp.finish_rank is not null and sp.settled_at is not null
   group by ts.id, coalesce(sl.is_hygiene, false), nullif(coalesce(sl.base, 0), 0)
)
select
  -- ① 計分的桌現在有幾場有積分（回填前是 2）
  '① 計分的桌 ' || count(*) filter (where not hygiene and unit is not null)
    || ' 場，其中有積分 '
    || count(*) filter (where not hygiene and unit is not null and scored = 4)
                                                                          as "①覆蓋率",
  -- ② 🔴 零和：每一場四家加總必須是 0。不是 0 就是生成器壞了
  case when count(*) filter (where scored = 4 and coalesce(total, 0) <> 0) = 0
       then '✅ ② 每一場都是零和'
       else '🔴 ② 有 ' || count(*) filter (where scored = 4 and coalesce(total, 0) <> 0)
            || ' 場加總不為 0' end                                        as "②零和",
  -- ③ 正對照：純娛樂**不可以**被寫進積分
  case when count(*) filter (where hygiene and scored > 0) = 0
       then '✅ ③ 純娛樂 ' || count(*) filter (where hygiene) || ' 場全部維持沒有積分'
       else '🔴 ③ 純娛樂有 ' || count(*) filter (where hygiene and scored > 0)
            || ' 場被誤寫' end                                            as "③純娛樂沒被碰",
  -- ④ 正對照：不該有「一場只補了一半」的（2 或 3 個人有積分）
  case when count(*) filter (where scored between 1 and 3) = 0
       then '✅ ④ 沒有補了一半的場次'
       else '🔴 ④ 有 ' || count(*) filter (where scored between 1 and 3)
            || ' 場只有部分人有積分' end                                   as "④沒有半套",
  -- ⑤ 還剩幾場沒補（應為 0；不是 0 表示被閘門或條件擋掉了，要看是不是預期的）
  '⑤ 計分的桌仍無積分：'
    || count(*) filter (where not hygiene and unit is not null and scored = 0) || ' 場'
                                                                          as "⑤剩餘",
  -- ⑥ 冪等：這一份靠 `final_score is null` 圈範圍 ⇒ 再跑一次應該 0 場
  '⑥ 再跑一次會處理 '
    || count(*) filter (where not hygiene and unit is not null and scored = 0)
    || ' 場（冪等）'                                                       as "⑥冪等"
from base;
