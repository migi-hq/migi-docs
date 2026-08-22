-- 【這是什麼】唯讀盤點：要寫 get_my_games_tx（會員 App 的牌局紀錄）之前，
--   確認 table_sessions / session_players 線上實際有哪些欄位、有沒有資料可測。
-- 【何時讀】動手寫那支 RPC 之前。
--
-- 【為什麼要查】docs/01-資料庫/db-現況快照.md 有列這兩張表，但它會漂 ——
--   例如 2026-08-18 加的 session_players.fee_waived_amount / fee_waived_reason
--   就沒出現在那份清單裡。只有 information_schema 算數（硬規則 3）。
--
-- 【要回答的問題】
--   ① 欄位到底有哪些（尤其 score_points / finish_rank 是否真的存在）
--   ② table_sessions 有沒有欄位連到 match_queues（配桌 → 開桌的接縫在哪）
--   ③ 有沒有已收桌（completed）且有玩家的場次可以測
--   ④ get_my_games_tx 是不是已經存在（別重複造）
--
-- 單一 SELECT，整段貼進 SQL Editor。

select 項目, 內容
from (
  -- ── 一、欄位清單 ─────────────────────────────────────────
  select 1 as ord, 'table_sessions 欄位' as 項目,
    (select string_agg(column_name, ', ' order by ordinal_position)
       from information_schema.columns
      where table_schema = 'public' and table_name = 'table_sessions') as 內容

  union all select 2, 'session_players 欄位',
    (select string_agg(column_name, ', ' order by ordinal_position)
       from information_schema.columns
      where table_schema = 'public' and table_name = 'session_players')

  union all select 3, 'stake_levels 欄位',
    (select coalesce(string_agg(column_name, ', ' order by ordinal_position), '（表不存在）')
       from information_schema.columns
      where table_schema = 'public' and table_name = 'stake_levels')

  union all select 4, 'members 欄位（找段位／暱稱用）',
    (select string_agg(column_name, ', ' order by ordinal_position)
       from information_schema.columns
      where table_schema = 'public' and table_name = 'members')

  -- ── 二、配桌 → 開桌的接縫 ───────────────────────────────
  union all select 10, 'table_sessions 有沒有欄位提到 queue',
    (select coalesce(string_agg(column_name, ', '), '（沒有 —— 配桌與開桌沒有直接關聯欄位）')
       from information_schema.columns
      where table_schema = 'public' and table_name = 'table_sessions'
        and column_name ilike '%queue%')

  union all select 11, 'match_queues 有沒有欄位提到 session',
    (select coalesce(string_agg(column_name, ', '), '（沒有）')
       from information_schema.columns
      where table_schema = 'public' and table_name = 'match_queues'
        and column_name ilike '%session%')

  -- ── 三、有沒有資料可測 ───────────────────────────────────
  union all select 20, 'table_sessions 各狀態筆數',
    (select coalesce(string_agg(status || '=' || n, ' / ' order by status), '（無資料）')
       from (select status, count(*) as n from table_sessions
              where deleted_at is null group by status) t)

  union all select 21, '已收桌（completed）且有 ended_at 的筆數',
    (select count(*)::text from table_sessions
      where status = 'completed' and ended_at is not null and deleted_at is null)

  union all select 22, 'session_players 總筆數',
    (select count(*)::text from session_players)

  union all select 23, '已收桌場次裡有玩家的場次數（真正可測的）',
    (select count(distinct s.id)::text
       from table_sessions s
       join session_players sp on sp.session_id = s.id
      where s.status = 'completed' and s.deleted_at is null)

  union all select 24, '有 finish_rank 或 score_points 的入座紀錄數',
    (select count(*)::text from session_players
      where finish_rank is not null or score_points is not null)

  -- ⚠ 上一列若為 0，代表 M4 結算完全沒有資料 —— 那是預期的，
  --   牌局紀錄第一版本來就只顯示「打過哪些局」，戰績留空。

  union all select 25, '最近一場已收桌的場次（給下面測試用）',
    (select coalesce(
        (select s.id::text || '  ' || coalesce(s.ended_at::text, '(無 ended_at)')
           from table_sessions s
          where s.status = 'completed' and s.deleted_at is null
          order by s.ended_at desc nulls last limit 1),
        '（沒有已收桌的場次，要先在 POS 開一桌再收桌）'))

  union all select 26, '那場次的入座者（member_id）',
    (select coalesce(string_agg(sp.member_id::text, ', '), '（那場沒有入座紀錄）')
       from session_players sp
      where sp.session_id = (select s.id from table_sessions s
                              where s.status = 'completed' and s.deleted_at is null
                              order by s.ended_at desc nulls last limit 1))

  -- ── 四、別重複造 ─────────────────────────────────────────
  union all select 30, 'get_my_games_tx 是否已存在',
    (select case when count(*) = 0 then '不存在，可以新建'
                 else count(*)::text || ' 個版本 —— 先撈定義再說' end
       from pg_proc where pronamespace = 'public'::regnamespace
        and proname = 'get_my_games_tx')

  union all select 31, '名字裡有 game 或 session 的既有 RPC',
    (select coalesce(string_agg(proname, '、' order by proname), '（無）')
       from pg_proc
      where pronamespace = 'public'::regnamespace and prokind = 'f'
        and (proname ilike '%game%' or proname ilike '%session%'))
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 項目 10／11 若都是「沒有」→ 配桌與開桌之間沒有關聯欄位。
--   這對牌局紀錄「不是問題」：紀錄是從 session_players 反查「我坐過哪些桌」，
--   不需要知道那桌是怎麼開的。但這代表**配桌成桌後不會自動開桌**，
--   而那是另一件事（M4 的範圍）。
-- 項目 23 若為 0 → 沒有可測的資料。先在 POS 走一次「開桌 → 結帳帶桌 → 收桌」。
-- 項目 24 若為 0 → 正常。第一版紀錄只顯示「打過哪些局」，戰績欄位留空等 M4。
-- 項目 25／26 → 寫完 RPC 之後拿這兩個值做煙霧測試。
