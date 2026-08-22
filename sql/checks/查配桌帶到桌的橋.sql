-- 【這是什麼】唯讀盤點：要做「POS 把成桌的配桌房帶到實體桌」之前，確認可用的零件。
-- 【何時讀】動手寫 pos_seat_queue_tx 之前。
--
-- ═══ 背景 ═══
-- 想測的流程：POS 開固定局 → APP 報名 → 四人成桌 → POS 收桌 → APP 成績頁。
-- 第 4 步（POS 把配桌房帶到實體桌）**完全不存在**：
--   · open_session_tx 的簽名裡沒有任何 queue 參數
--   · match_queues.matched_session_id 這個欄位沒有任何程式在寫
--   · POS 也看不到那四個人是誰（list_match_queues_tx 只回人數 count(*)）
--
-- ⚠ session_players 是**結帳後才建立**的（CLAUDE.md 待辦 3：
--   「系統裡不存在『已入座但未付款』」）。所以「帶到桌」只能開 session，
--   不能直接把四個人塞進 session_players —— 那會建出沒付錢的入座紀錄，
--   檯費就永遠收不到了。人要走既有的結帳流程一個一個進去。
--
-- 這支要回答：queue 帶到桌之後狀態要寫什麼、open_session_tx 能不能重用、空桌怎麼查。

select 項目, 結果
from (
  -- ① 帶到桌之後 queue 要變成什麼狀態？先看允許哪些值
  select 1 as ord, 'match_queues.status 的 CHECK' as 項目,
    coalesce((select string_agg(pg_get_constraintdef(oid), ' ｜ ')
                from pg_constraint
               where conrelid = 'match_queues'::regclass and contype = 'c'
                 and pg_get_constraintdef(oid) ilike '%status%'),
             '（沒有 CHECK —— 那就看實際出現過哪些值）') as 結果

  union all select 2, 'status 實際出現過的值',
    coalesce((select string_agg(coalesce(status, '<null>') || '=' || n, '   ' order by status)
                from (select status, count(*) n from match_queues group by status) t), '（無資料）')

  -- ② open_session_tx 能不能直接重用（它有沒有寫 game_type / flower）
  union all select 10, 'open_session_tx 全文',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='open_session_tx' limit 1),
             '（不存在）')

  -- ③ 空桌怎麼查（tables 沒有 status 欄位，桌況是從 table_sessions 算的）
  union all select 20, 'list_tables_tx 簽名',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='list_tables_tx' limit 1),
             '（不存在）')

  union all select 21, '本店現在有幾張空桌（沒有 open 場次的）',
    (select count(*)::text from tables t
      where t.org_id = '11111111-1111-1111-1111-111111111111'
        and t.store_id = '22222222-2222-2222-2222-222222222222'
        and coalesce(t.is_active, true) = true
        and t.deleted_at is null
        and not exists (select 1 from table_sessions s
                         where s.table_id = t.id and s.status = 'open' and s.deleted_at is null))

  union all select 22, 'tables 欄位',
    (select string_agg(column_name, ', ' order by ordinal_position)
       from information_schema.columns
      where table_schema='public' and table_name='tables')

  -- ④ 那四個人現在在哪一房（給下面帶到桌用）
  union all select 30, '目前已成桌的房與成員',
    coalesce((select string_agg(
                q.id::text || '　' || (q.play_at at time zone 'Asia/Taipei')::text || '　' ||
                (select string_agg(m.display_name, '、' order by m.display_name)
                   from match_queue_players p join members m on m.id = p.member_id
                  where p.queue_id = q.id and p.left_at is null), chr(10))
                from match_queues q where q.status = 'matched'),
             '（目前沒有已成桌的房）')

  union all select 40, '現在時間（台北）',
    (now() at time zone 'Asia/Taipei')::text
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 1／2 項：決定「已帶到桌」要用哪個狀態值。
--   若 CHECK 沒有可用的值 → 要先加，不能硬塞（CHECK 會擋，或更糟：沒 CHECK 就寫進去，
--   然後 list 的 status='waiting' 條件把它濾掉，看起來「成功了但房不見了」）。
-- 第 10 項：看 open_session_tx 有沒有寫 game_type / flower。
--   沒有的話，配桌的牌規帶不進 table_sessions，收桌後的紀錄就少了牌型。
-- 第 21 項：要有空桌才測得下去。是 0 的話先去 POS 收掉一張。
-- 第 30 項：拿那個 queue id 去測「帶到桌」。
