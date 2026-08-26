/* ============================================================
   刪掉重複的牌咖唯一索引 uq_buddy_pair
   2026-08-26

   ✅ 已執行並驗證通過（2026-08-26）
      uq_buddy_pair 已刪除／uq_buddies 仍在且唯一且有效／
      沒有任何外鍵參照 mahjong_buddies／資料回滾乾淨（0 列）。
      ⚠ 第 ⑤ 項當時失敗（我猜錯 origin 的值），
        補驗見 sql/checks/2026-08-26_補驗牌咖唯一性.sql：
        **uq_buddies 確實擋住了重複**（用 origin='pre_existing' 測）。

   📌 補驗順帶查到 origin 的允許值，而它比索引本身重要：
        origin ∈ ('pre_existing', 'matched')
      對應《牌搭關係與護城河戰略》的兩種牌咖關係 ——
      pre_existing 是自帶團、**matched 是 MIGI 配桌認識的（護城河）**。
      → **護城河深度可以直接數**：count(*) where origin = 'matched'。

   ── 兩個索引的來歷（2026-08-26 查證）──────────────────
   ```
   -- 00a_M0建表_資料骨架.sql:502（地基）
   create unique index uq_buddies
     on mahjong_buddies(member_id, buddy_id) where deleted_at is null;

   -- MA1B-牌咖與通知.sql:33（後來）
   -- mahjong_buddies 補防重複唯一鍵        ← 註解這樣寫
   create unique index if not exists uq_buddy_pair
     on mahjong_buddies(member_id, buddy_id) where deleted_at is null;
   ```
   **定義逐字相同。** 寫 MA1B 的人不知道 M0 已經有了，所以「補」了一個。

   🔴 **真正的教訓：`IF NOT EXISTS` 只檢查名字，不檢查定義。**
     換一個名字就會靜靜建出第二個一模一樣的索引，而且**沒有任何警告**。
     → 要「補一個唯一鍵」之前，先查那張表現有的索引，
       不要靠 `if not exists` 當保險 —— 它保的是名字不是意圖。

   ⚠ 這與 `members` 那兩個索引**不同**：那兩個定義不一樣、意圖也不一樣
     （`(org_id, line_user_id)` 允許跨 org vs `(line_user_id)` 全域唯一），
     而且全域那個是身分解析的承重牆。**那兩個都要留。**
     這裡是真的重複。

   ── 刪哪一個 ────────────────────────────────────────
   刪 `uq_buddy_pair`（後來補的），留 `uq_buddies`（M0 地基、文件引用的那個）。

   ── 影響 ────────────────────────────────────────────
   ⚠ 少一個索引 = 少一份寫入成本。在目前的資料量下差異可忽略，
     但它是「同一件事做了兩次」的清理，不是效能優化。
   ⚠ `sql/tools/重置社交關係.sql:27` 的註解提到 uq_buddy_pair ——
     刪掉之後那句會過期，已一併更新。
   ⚠ `sql/_設計稿未落地/MA1C-配桌黑名單設計稿.sql:77` 也有同一行 ——
     那份若日後執行會把它建回來，已在該檔加警告。
   ============================================================ */

drop index if exists public.uq_buddy_pair;


/* ============================================================
   驗證段（單一 SELECT）

   ⚠ 硬規則 7：不能只確認「索引不見了」，
     要確認**剩下那個真的還在擋**。
     所以這裡真的試插一筆重複的牌咖關係，預期被擋下來。
   ⚠ 硬規則 3.9：訊息設在 exception 處理器裡。

   🔴 **第 ⑤ 項在 2026-08-26 執行時失敗，而且原因與本次改動無關**：
       violates check constraint "mahjong_buddies_origin_check"
     —— 下面寫死的 `origin = 'manual'` 不在允許值裡（我猜的，沒查）。
     ①②③④⑥ 全部通過，只有唯一性沒被驗到。
   → **修正版另開一支**（不改這裡，保留當時真正跑過的內容）：
     `sql/checks/2026-08-26_補驗牌咖唯一性.sql`
     那支從 `pg_get_constraintdef` 把合法值抓出來，不猜。
   ⚠ 這份重跑是安全的（`drop index if exists` 冪等），
     但第 ⑤ 項會一直失敗 —— **那是預期的，不要再修它**。
   ============================================================ */

do $$
declare
  v_a uuid; v_b uuid; v_org uuid;
begin
  select m.id, m.org_id into v_a, v_org from members m
   where m.deleted_at is null order by m.created_at limit 1;
  select m.id into v_b from members m
   where m.deleted_at is null and m.id <> v_a order by m.created_at limit 1;

  if v_a is null or v_b is null then
    perform set_config('migi.b', '⚠ 跳過：需要至少兩位會員', true);
    return;
  end if;

  begin
    -- 第一筆：應該成功
    insert into mahjong_buddies(org_id, member_id, buddy_id, origin)
    values (v_org, v_a, v_b, 'manual');
    -- 第二筆完全一樣：唯一索引應該擋下來
    insert into mahjong_buddies(org_id, member_id, buddy_id, origin)
    values (v_org, v_a, v_b, 'manual');
    -- 走到這裡代表沒擋 —— 那是最壞的結果
    perform set_config('migi.b', '🔴 重複的牌咖關係竟然插得進去 —— 唯一性沒了', true);
    raise exception 'rollback_on_purpose';
  exception
    when unique_violation then
      /* ⚠ 這個訊息要設在處理器裡（硬規則 3.9）——
         設在成功路徑上再 raise 的話會被 savepoint 回滾掉。 */
      perform set_config('migi.b', '✅ 剩下的 uq_buddies 仍然擋得住重複', true);
    when others then
      if sqlerrm = 'rollback_on_purpose' then
        null;   -- 訊息上面已經設好（那是失敗的情況）
      else
        perform set_config('migi.b', '🔴 測試出錯：' || sqlerrm, true);
      end if;
  end;
end $$;

select 序, 項目, 結果 from (

  select 0 as 序, '① mahjong_buddies 現有的索引' as 項目,
         string_agg(i.relname ||
                    (case when x.indisunique then '（唯一）' else '' end) ||
                    (case when x.indisvalid then '' else ' 🔴INVALID' end),
                    '　' order by i.relname) as 結果
    from pg_index x
    join pg_class i on i.oid = x.indexrelid
    join pg_class t on t.oid = x.indrelid
   where t.relnamespace = 'public'::regnamespace and t.relname = 'mahjong_buddies'

  union all
  select 0, '② uq_buddy_pair 還在嗎',
         (case when to_regclass('public.uq_buddy_pair') is null
               then '✅ 已刪除' else '🔴 還在' end)

  union all
  select 0, '③ uq_buddies 還在且有效嗎',
         coalesce((select (case when x.indisunique then '唯一 ' else '🔴 非唯一 ' end) ||
                          (case when x.indisvalid then '✅ 有效' else '🔴 INVALID' end)
                     from pg_index x
                     join pg_class i on i.oid = x.indexrelid
                    where i.relname = 'uq_buddies' limit 1), '🔴 不存在')

  union all
  /* ④ 有沒有外鍵依賴它 —— Postgres 的外鍵可以參照唯一索引。
        刪之前該問的，這裡回頭確認一次沒有連帶損害。 */
  select 0, '④ 有沒有外鍵參照 mahjong_buddies',
         coalesce((select string_agg(t.relname || '.' || c.conname, '、')
                     from pg_constraint c
                     join pg_class t on t.oid = c.conrelid
                     join pg_class rt on rt.oid = c.confrelid
                    where c.contype = 'f' and rt.relname = 'mahjong_buddies'),
                  '✅ 沒有任何外鍵參照它')

  union all
  select 1, '⑤ 唯一性煙霧測試',
         coalesce(current_setting('migi.b', true), '🔴 DO 區塊沒執行')

  union all
  select 2, '⑥ 牌咖資料筆數（應該沒變）',
         (select count(*)::text || ' 列' from mahjong_buddies)

) x order by 序, 項目;
