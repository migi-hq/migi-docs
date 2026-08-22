-- 【這是什麼】唯讀盤點：要做「湊滿四人自動帶桌 + POS 幫現場客人登記」之前的前置確認。
-- 【何時讀】動手寫 SQL 之前。
--
-- ═══ 要做什麼 ═══
--   · 湊滿 4 人 → 系統自動挑一張空桌開下去（CLAUDE.md 待辦 5 的自動配桌）
--   · POS 在空位按「＋」把現場客人加進同一個隊列（那條 🔴「現場客人與 App 不在同一條隊」）
--
-- ⚠ 自動帶桌要塞進**成桌的那一刻**，而成桌可能由兩條路造成：
--     ① App 報名 → join_match_queue_tx
--     ② POS 幫現場客人加入 → 新的 pos_add_queue_member_tx
--   所以 join_match_queue_tx 要改，改之前先撈全文（硬規則 3：檔案不是鏡像）。

select 項目, 結果
from (
  select 1 as ord, 'join_match_queue_tx 全文（自動帶桌要接在成桌那一刻）' as 項目,
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='join_match_queue_tx' limit 1),
             '（不存在）') as 結果

  union all select 2, 'pos_search_members_tx 簽名（POS 選客人用）',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_search_members_tx' limit 1),
             '（不存在）')

  union all select 3, 'pos_search_members_tx 回傳哪些欄位',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_search_members_tx' limit 1),
             '（不存在）')

  union all select 10, 'match_queue_players 欄位',
    (select string_agg(column_name, ', ' order by ordinal_position)
       from information_schema.columns
      where table_schema='public' and table_name='match_queue_players')

  union all select 11, 'match_queue_players 的約束（有沒有擋同一人重複在座）',
    coalesce((select string_agg(conname || ' → ' || pg_get_constraintdef(oid), chr(10))
                from pg_constraint where conrelid='match_queue_players'::regclass),
             '（沒有任何約束）')

  union all select 12, 'match_queue_players 的唯一索引',
    coalesce((select string_agg(indexname || ' → ' || indexdef, chr(10))
                from pg_indexes where tablename='match_queue_players' and indexdef ilike '%unique%'),
             '（沒有唯一索引 —— 同一人可能在同一房出現兩筆在座紀錄）')

  union all select 20, 'tables 已經有 auto_assign 了嗎',
    coalesce((select ' 有：' || data_type || ' nullable=' || is_nullable
                from information_schema.columns
               where table_schema='public' and table_name='tables' and column_name='auto_assign'),
             '沒有 —— 這批要新增')

  union all select 21, 'join_source 允許哪些值（POS 加人要用哪一個）',
    coalesce((select string_agg(pg_get_constraintdef(oid), ' ｜ ')
                from pg_constraint
               where conrelid='match_queue_players'::regclass and contype='c'
                 and pg_get_constraintdef(oid) ilike '%join_source%'),
             '（沒有 CHECK）')
    || '　｜實際出現過：' ||
    coalesce((select string_agg(distinct coalesce(join_source,'<null>'), '、')
                from match_queue_players), '（無資料）')
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 1 項：看它在滿員時做了什麼（應該有 status='matched' 的更新）。
--   自動帶桌要接在那之後，而且**必須在同一個交易裡** ——
--   分開做的話，成桌成功但帶桌失敗會留下一個沒有桌的成桌房，客人以為有位子了。
-- 第 11／12 項：若沒有唯一約束 → POS 加人要自己擋「同一人已經在這房」，
--   不然 player_count 會多算，四個座位只有三個人。
-- 第 21 項：POS 幫現場客人加入要用哪個 join_source。
--   沒有合適的值就要加一個（例如 'pos'）—— 這個欄位是之後分析
--   「現場登記 vs App 自己報名」佔比的唯一依據，混用就分不出來了。
