-- ============================================================
-- 純娛樂局用 30/10 算分（2026-09-20 使用者拍板）
--
-- 🔴 先講結論：**不加欄位。**
--   《桌邊記分板設計》原本寫「`stake_levels` 要加 score_base / score_tai」，
--   而那句是沒查就寫的 —— 撈了 information_schema 才知道
--   **`base` 與 `tai` 早就存在而且可為 null**。
--   （同踩坑第 29 條的反向版：先查再說「沒有」。）
--
-- 改的是**一列資料**：
--   純娛樂  base 0 → 30 ／ tai 0 → 10 ／ is_hygiene **維持 true**
--
-- 🎯 兩個欄位回答兩個不同的問題，不要混：
--   base / tai   「這桌**怎麼算**分」
--   is_hygiene   「這桌的分數**算不算數**」
--   純娛樂要的正是「照 30/10 算分，但不算數」，而 0/0 表達不出那件事 ——
--   它讓每一把都算成 0 ⇒ 記分板對純娛樂桌沒有任何東西可以顯示 ⇒ 排不出名次。
--
-- 🔴 **不可以在記分板寫死 `if 純娛樂 then 30/10`** ——
--   30/10 本來就是另一列，寫死就是「一個事實兩個名字」第八次。
--
-- ✅ 這次改動**零行為影響**，而那是查出來的不是猜的：
--   · 全庫讀 `sl.base` 的只有 `placeholder_ranks_tx` 一支，
--     而它那一行是 `case when sl.is_hygiene then null else ... end`
--     ⇒ 純娛樂在碰到 base 之前就被短路成 null，改 base 動不到它
--   · 全庫讀 `sl.tai` 的是 **0 支** ⇒ 那一欄今天還沒有任何讀者
--
-- ### 🔴 真正的分岔點在「記分板上線那天」，不是今天
--   記分板會產生真的分數 ⇒ 那時要決定寫不寫進 `session_players.final_score`。
--   **寫的話，`get_my_stats_tx` 必須在同一批改**：它第 76／104 行用的是
--   `sp.final_score is not null` 來排除純娛樂，而不是 `is_hygiene`
--   ⇒ 純娛樂一旦有分數，勝率／連勝／單場最多積分會**靜默把它算進去**，
--     而第 62 行那句「純娛樂與舊資料都不該進來」的註解會變成一句謊話，
--     **程式照跑、數字照樣看起來合理**。
--   （各級距那一段本來就讀 `is_hygiene`，只有總計那兩行沒有。）
--
-- ⚠ 這份**要留下資料變更** ⇒ 驗證段一個字都不准 `raise`（硬規則 1.8）。
-- ============================================================

update stake_levels
   set base = 30,
       tai  = 10,
       updated_at = now()
 where label = '純娛樂'
   and is_hygiene
   and deleted_at is null;


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare
  v_msg  text := '';
  v_n    int;
  v_line text;
begin
  -- ① 🔴 兩半都要驗：值改了，而且 is_hygiene 沒有被誤關
  --    只驗 base/tai 的話，把 is_hygiene 順手關掉也會全綠 ——
  --    而那會讓純娛樂的分數開始進段位與報表。
  select count(*) into v_n
    from stake_levels
   where label = '純娛樂' and deleted_at is null
     and base = 30 and tai = 10 and is_hygiene;
  v_msg := case when v_n = 1
    then '✅ ① 純娛樂 = 底 30 / 台 10，而且 is_hygiene 仍然是 true'
    else '🔴 ① 純娛樂那一列不對，符合條件的有 ' || v_n || ' 列（應為 1）' end;

  -- ② 負對照：其餘六級一個數字都不准動
  --    期望值當場算出來，不要憑印象（硬規則 3.56）
  select count(*) into v_n
    from stake_levels
   where deleted_at is null and not is_hygiene;
  v_msg := v_msg || E'\n' || case when v_n = 6
    then '✅ ② 非純娛樂仍然是 6 級（10/10 · 30/10 · 50/20 · 100/20 · 200/50 · 300/100）'
    else '🔴 ② 非純娛樂變成 ' || v_n || ' 級，應為 6' end;

  v_msg := v_msg || E'\n' || coalesce(
    (select '　　實際：' || string_agg(label || '=' || base || '/' || tai, '　' order by sort_order)
       from stake_levels where deleted_at is null and not is_hygiene),
    '⚪ 這一格取不到（0 列）');   -- 🔴 字串 || NULL 是 NULL，會吃掉前面四格（硬規則 3.555）

  -- ③ 讀 base 的函式只有一支，而且它先看 is_hygiene
  --    ⇒ 這次改動零行為影響的證明
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'                         -- 🔴 聚合會讓 functiondef 直接拋錯（硬規則 3.7）
     and pg_get_functiondef(p.oid) ~ '\msl\.base\M';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ③ 全庫讀 sl.base 的仍然只有 1 支'
    else '🔴 ③ 讀 sl.base 的函式變成 ' || v_n || ' 支，要逐支看一遍' end;

  -- 逐行印出來讓人判讀，不要回一個是非題（硬規則 3.5）
  select trim(l) into v_line
    from pg_proc p,
         lateral regexp_split_to_table(pg_get_functiondef(p.oid), E'\n') l
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'placeholder_ranks_tx'
     and l ~ '\msl\.base\M'
   limit 1;
  v_msg := v_msg || E'\n' || '　　placeholder_ranks_tx：' ||
           coalesce(v_line, '⚪ 找不到那一行 —— 它被改過了，要重看');

  -- ④ tai 今天還是沒有讀者 ⇒ 記分板會是第一個
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ '\msl\.tai\M';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ④ 全庫還是沒有函式讀 sl.tai —— 記分板會是第一個讀者'
    else '⚠ ④ 已經有 ' || v_n || ' 支在讀 sl.tai，那些要一起看' end;

  -- ⑤ 真的沒有行為改變：純娛樂的場次 final_score 仍然全是 null
  select count(*) into v_n
    from session_players sp
    join table_sessions ts on ts.id = sp.session_id
    join stake_levels  sl on sl.id = ts.stake_level_id
   where sl.is_hygiene and sp.final_score is not null;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑤ 純娛樂的場次仍然一筆 final_score 都沒有（改 base 沒有回頭動到資料）'
    else '🔴 ⑤ 竟然有 ' || v_n || ' 筆純娛樂帶著 final_score —— 那不該發生' end;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
