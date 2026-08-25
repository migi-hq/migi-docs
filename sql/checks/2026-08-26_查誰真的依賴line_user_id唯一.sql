/* ============================================================
   查：誰真的依賴「line_user_id 全域唯一」
   2026-08-26 · 唯讀

   ── 要回答的 ────────────────────────────────────────
   `uq_members_line_user (line_user_id)` 是手動建的、沒留紀錄。
   **建它的意圖無從查證**，但「它做什麼」與「什麼依賴它」可以查。

   它做的事只有一件：擋掉「兩個會員共用同一個 LINE 帳號」（跨 org 也擋）。

   關鍵問題：三支身分函式在「兩列符合」時會怎樣？
     · 純量子查詢**沒有 LIMIT** → ERROR: more than one row returned
       → 🔴 每一次 RLS 檢查都失敗 → 全站掛掉
     · **有 LIMIT 1** → 靜靜挑一列
       → 🔴 那位客人可能被分到**錯的 org**，看到別家店的資料

   兩種都很糟，但要修的東西完全不同 ——
   ⚠ 而 CLAUDE.md 今天已經被證明錯過兩次（`app_events.is_test` 的來源、
     事件名白名單），不能拿它當依據。**只有 pg_proc 算數**（硬規則 3）。

   ── 另外要確認的 ────────────────────────────────────
   如果**只有這三支**依賴它，那它的角色就很清楚：
   「讓身分解析不歧義」的守門員，而不是效能索引
   （效能上它也證明不了什麼 —— members 只有 4 列，
     且 0 人綁 LINE，idx_scan 是 0 次）。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 三支身分函式的完整定義 —— 看清楚有沒有 LIMIT 1 */
  select 1 as 序, '① current_org_id' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'current_org_id'
                    limit 1), '🔴 不存在') as 內容

  union all
  select 2, '② current_member_id',
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'current_member_id'
                    limit 1), '🔴 不存在')

  union all
  select 3, '③ current_staff',
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'current_staff'
                    limit 1), '🔴 不存在')

  union all
  /* ④ 還有沒有別的地方依賴「一個 line_user_id 一個會員」——
        例如 RLS policy 直接寫 line_user_id 比對。
        有的話，那些也會受影響。 */
  select 4, '④ 有沒有 policy 直接用 line_user_id',
         coalesce((select string_agg(t.relname || '.' || pol.polname, '、')
                     from pg_policy pol
                     join pg_class t on t.oid = pol.polrelid
                    where t.relnamespace = 'public'::regnamespace
                      and (coalesce(pg_get_expr(pol.polqual, pol.polrelid),'') ilike '%line_user_id%'
                        or coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid),'') ilike '%line_user_id%')),
                  '✅ 沒有 policy 直接比對 —— 都走 current_* 函式')

  union all
  /* ⑤ 這兩個索引各自「擋掉」過幾次違規？
        pg_stat 沒有這個數字，但可以反過來看：
        現在有沒有任何一組 line_user_id 重複（應該是 0，因為索引擋著）。
        ⚠ 這一項的價值不在數字，而在**確認索引真的在生效**
          —— 索引可能是 INVALID 狀態（建立時失敗），而那不會有任何症狀。 */
  select 5, '⑤ 兩個索引是否有效（isvalid）',
         i.relname || '：' ||
         (case when x.indisvalid then '✅ 有效' else '🔴 INVALID —— 沒在擋任何東西' end) ||
         (case when x.indisunique then '　唯一' else '　非唯一' end)
    from pg_index x
    join pg_class i on i.oid = x.indexrelid
    join pg_class t on t.oid = x.indrelid
   where t.relnamespace = 'public'::regnamespace
     and t.relname = 'members'
     and pg_get_indexdef(x.indexrelid) ilike '%line_user_id%'

) x order by 序, 項目;
