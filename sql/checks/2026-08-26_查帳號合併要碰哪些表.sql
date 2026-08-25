/* ============================================================
   查：帳號合併要碰哪些表
   2026-08-26 · 唯讀

   ── 為什麼現在盤 ────────────────────────────────────
   2026-08-26 修好 register_member_tx 之後，它會回報 `line_conflict`
   （手機對上了、但那個會員已綁另一個 LINE 帳號）——
   🔴 **但店員拿到那個訊息之後沒有任何按鈕可以按。**

   而待辦 15 說得很直白：
   > 合併要逐項決定怎麼併…**有真實資料之後每一項都變成錢的問題。**

   現在 4 個會員、153 筆訂單全是測試 —— **盤點與試做的成本是零**。

   ── 這支不設計，只把地形測出來 ──────────────────────
   ⚠ 「我記得有這幾張表」是不夠的：**漏一張就是資料孤兒**
     （合併後那些列還指向已刪的舊會員，而外鍵是 RESTRICT 的話刪不掉，
       是 CASCADE 的話**資料直接消失且不報錯**）。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 所有指向 members.id 的外鍵 —— 這就是合併的完整範圍。
        ⚠ ON DELETE 行為特別重要：
          RESTRICT → 舊會員刪不掉，必須先搬完每一列
          CASCADE  → 一刪就連坐消失，**而且不會有任何提示** */
  select 1 as 序,
         '① 指向 members 的外鍵（' ||
         (case
            when c.confdeltype = 'a' then 'NO ACTION'
            when c.confdeltype = 'r' then 'RESTRICT'
            when c.confdeltype = 'c' then '🔴 CASCADE'
            when c.confdeltype = 'n' then 'SET NULL'
            when c.confdeltype = 'd' then 'SET DEFAULT'
            else c.confdeltype::text end) || '）' as 項目,
         t.relname || '.' ||
         (select string_agg(a.attname, ',')
            from unnest(c.conkey) k
            join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k) as 內容
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_class rt on rt.oid = c.confrelid
   where c.contype = 'f'
     and rt.relnamespace = 'public'::regnamespace
     and rt.relname = 'members'

  union all
  /* ② 那些表現在各有多少列 —— 決定合併時「有沒有東西要搬」。
        ⚠ 用 reltuples 是估計值，但這裡只要知道量級。
          精確值不重要，「是 0 還是 10 萬」才重要。 */
  select 2, '② 相關表的資料量（估）',
         c.relname || '：' ||
         (case when c.reltuples < 0 then '未統計' else c.reltuples::bigint::text end)
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and c.relname in (
       'wallets','wallet_txns','orders','topup_orders','invoices',
       'member_coupons','session_players','match_queue_members',
       'mahjong_buddies','buddy_invites','member_blocks',
       'member_availability','member_interactions','app_events','staff')

  union all
  /* ③ 🔴 合併時會撞唯一約束的地方。
        例：兩個會員各有一個 wallet（wallets 可能 unique(member_id)）——
        直接把 B 的 wallet 改成指向 A，會撞唯一鍵。
        這一段列出「以 member_id 為唯一鍵一部分」的約束，
        那些都是合併時必須特別處理的。 */
  select 3, '③ 含 member_id 的唯一約束／索引',
         t.relname || '　' || i.relname || '　' || pg_get_indexdef(x.indexrelid)
    from pg_index x
    join pg_class i on i.oid = x.indexrelid
    join pg_class t on t.oid = x.indrelid
   where t.relnamespace = 'public'::regnamespace
     and x.indisunique
     and pg_get_indexdef(x.indexrelid) ilike '%member_id%'

  union all
  /* ④ 現有有沒有任何「合併」相關的函式（可能有人做過一半） */
  select 4, '④ 有沒有現成的合併函式',
         coalesce((select string_agg(p.proname || '(' || pg_get_function_arguments(p.oid) || ')',
                                     '　│　' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and (p.proname ilike '%merge%' or p.proname ilike '%combine%'
                        or p.proname ilike '%dedup%')),
                  '🔴 沒有 —— 完全從零開始')

  union all
  /* ⑤ 發票：合併時最麻煩的一項。
        待辦 15 說「改 member_id 會動到已開的發票」——
        先確認 invoices 現在有沒有資料、以及它怎麼連到會員。 */
  select 5, '⑤ invoices 現況',
         (case when to_regclass('public.invoices') is null then '🔴 表不存在'
               else (select count(*)::text || ' 筆　'
                          || 'status 分佈：' ||
                             coalesce((select string_agg(t2.k, '、')
                                         from (select status || '×' || count(*)::text as k
                                                 from invoices group by status) t2), '（無）')
                       from invoices) end)

  union all
  /* ⑥ 錢包餘額怎麼算的 —— 合併時「相加」還是「重算」取決於這個。
        CLAUDE.md 說 wallet_txns 是 append-only、沒有觸發器同步餘額，
        要靠 fix_wallet_balance_tx 重算。先確認那支還在。 */
  select 6, '⑥ 重算餘額的函式',
         coalesce((select string_agg(p.proname || '(' || pg_get_function_arguments(p.oid) || ')',
                                     '　│　' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and (p.proname ilike '%wallet_balance%' or p.proname ilike '%reconcile%')),
                  '🔴 沒有 —— 合併後餘額只能相加，無法重算驗證')

) x order by 序, 項目, 內容;
