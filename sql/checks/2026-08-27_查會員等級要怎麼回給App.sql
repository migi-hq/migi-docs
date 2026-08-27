/* ============================================================
   查：會員 App 的「會員等級」要怎麼接
   2026-08-27 · 唯讀

   ── 為什麼 ──────────────────────────────────────────
   待辦 31：`wallet.jsx` 錢包 hero 的「會員等級: 焦糖布丁」是**寫死的**，
   而同一個回傳裡的 `balance` 是真的。
   任何不是焦糖布丁的會員看到的都是錯的 —— 而那是已承諾的權益層級。

   🔴 這是待辦 0（分類主檔建了沒人讀）的 App 版：
     POS 已經接上 `list_member_tiers_tx`，會員 App 還在寫死。

   ── 要決定的事 ──────────────────────────────────────
   `get_wallet_tx` 目前只回 `balance` / `coupons` / `txns`（從前端用法反推）。
   加等級有兩條路：
     ① `get_wallet_tx` 多回一個 key（**簽名不變** → `CREATE OR REPLACE`，
        不用 DROP、不會丟 GRANT）
     ② 另開一支 `get_my_tier_tx`（多一次往返）
   → ① 明顯較好，**但前提是它真的只要加 key**。所以要先看全文。

   ⚠ 硬規則 3：`sql/applied/` 與文件都是二手傳聞，只有 `pg_proc` 算數。
   ⚠ 硬規則 3.7：掃函式內文一定要 `prokind = 'f'`（聚合會直接拋錯）。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① get_wallet_tx 全文 —— 要確認：
        · 回傳型別是 jsonb 物件嗎（能不能直接多塞一個 key）
        · 它有沒有已經 join 到 members
        · SECURITY DEFINER 嗎 */
  select 1 as 序, '① get_wallet_tx 定義' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'get_wallet_tx'
                    limit 1), '🔴 不存在') as 內容

  union all
  /* ② members 上跟等級有關的欄位（名稱不要猜）。
        CLAUDE.md 提過 tier 與 tier_override 兩個，但沒寫型別與預設值。 */
  select 2, '② members 的等級欄位',
         coalesce(string_agg(column_name || ' ' || data_type ||
                             coalesce(' default ' || column_default, '') ||
                             ' ' || is_nullable, '　' order by column_name),
                  '🔴 一個都沒有')
    from information_schema.columns
   where table_schema = 'public' and table_name = 'members'
     and column_name ilike '%tier%'

  union all
  /* ③ 那些欄位的 CHECK —— 允許值不要猜（硬規則 3.8.5）。 */
  select 3, '③ 等級欄位的 CHECK',
         coalesce(string_agg(c.conname || '　' || pg_get_constraintdef(c.oid), E'\n'), '（沒有）')
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where t.relnamespace = 'public'::regnamespace
     and t.relname = 'members' and c.contype = 'c'
     and pg_get_constraintdef(c.oid) ilike '%tier%'

  union all
  /* ④ 三支主檔／方案 RPC 的狀態。
        🔴 硬規則 2.5：讓前端第一次直接呼叫某支既有 RPC 之前，
          必須確認它有 anon EXECUTE —— 在 DEFINER 包裝裡跑得動不代表前端叫得動。
        ⚠ list_topup_plans_tx 一起查：wallet.jsx:311 已經在呼叫它，
          若它其實不存在／沒授權，那是一個現在就壞掉而沒人發現的功能。 */
  select 4, '④ 相關 RPC 的存在與授權',
         coalesce(string_agg(
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')　' ||
           case p.prosecdef when true then 'DEFINER' else '🔴 INVOKER' end || '　anon=' ||
           case when has_function_privilege('anon', p.oid, 'EXECUTE') then '✅' else '🔴 無' end,
           E'\n' order by p.proname), '🔴 三支都不存在')
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and p.proname in ('list_member_tiers_tx', 'list_topup_plans_tx', 'get_wallet_tx')

  union all
  /* ⑤ member_tiers 主檔現況 —— 等級名稱與折抵幅度是不是真的在裡面。
        （POS 讀的就是這張，App 接上之後兩端才會一致。） */
  select 5, '⑤ member_tiers 內容',
         coalesce(string_agg(code || '＝' || coalesce(label, '（無中文名）') ||
                             '　折抵 ' || coalesce(discount_pct::text, '-') || '%' ||
                             '　門檻 ' || coalesce(threshold_amount::text, 'null（邀請制）') ||
                             case when is_active then '' else '　⚠ 停用' end,
                             E'\n' order by sort), '🔴 主檔是空的')
    from member_tiers

  union all
  /* ⑥ 四個測試會員目前各是什麼等級 —— 接上之後畫面該顯示什麼，先知道答案。
        ⚠ 用 v_real_members 會濾掉測試帳號，這裡要看的正是測試帳號，所以查原表。 */
  select 6, '⑥ 現有會員的等級',
         coalesce(string_agg(display_name || '：' || coalesce(tier, '（null）'),
                             E'\n' order by display_name), '（沒有會員）')
    from members
   where deleted_at is null

) x order by 序, 項目;
