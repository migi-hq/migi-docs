-- 【這是什麼】唯讀盤點：POS 要做配桌列表與「官方開桌」，現有 RPC 夠不夠用。
-- 【何時讀】動手改 migi-pos 的 QueuePage 之前。
--
-- ═══ 背景 ═══
--   · POS 的配桌列表整頁假資料（App.jsx:198 寫死四個房間），
--     「＋ 官方開桌」按下去只 flash「配桌功能尚未開放」
--   · CLAUDE.md 待辦 5 記著：list_match_queues_tx 帶 p_member 是為會員端設計的，
--     POS 要的是「本店所有進行中的房」，得先確認 p_member 傳 null 會怎樣
--   · 決定改成店員在 POS 開局，不靠 cron 生成（2026-08-22）
--
-- 這支要回答：查詢用哪支、p_member 傳 null 安不安全、開房用哪支、source 能不能標 'pos'。

select 項目, 結果
from (
  select 1 as ord, 'list_match_queues_tx 簽名' as 項目,
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace = 'public'::regnamespace and proname = 'list_match_queues_tx' limit 1),
             '（不存在）') as 結果

  union all select 2, 'list_match_queues_tx 是否 SECURITY DEFINER',
    -- POS 用 anon 沒有 auth session，INVOKER 的話 RLS 會把結果濾成空陣列而且不報錯（硬規則 4）
    coalesce((select case when prosecdef then '✅ DEFINER' else '❌ INVOKER —— POS 會拿到空陣列且不報錯' end
                from pg_proc where pronamespace = 'public'::regnamespace
                 and proname = 'list_match_queues_tx' limit 1), '（不存在）')

  union all select 3, 'list_match_queues_tx 全文（看 p_member 怎麼用）',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace = 'public'::regnamespace and proname = 'list_match_queues_tx' limit 1),
             '（不存在）')

  union all select 10, 'create_match_queue_tx 簽名',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace = 'public'::regnamespace and proname = 'create_match_queue_tx' limit 1),
             '（不存在）')

  union all select 11, 'create_match_queue_tx 是否 DEFINER',
    coalesce((select case when prosecdef then '✅ DEFINER' else '❌ INVOKER' end
                from pg_proc where pronamespace = 'public'::regnamespace
                 and proname = 'create_match_queue_tx' limit 1), '（不存在）')

  union all select 12, 'create_match_queue_tx 全文（看 source / opened_by 怎麼寫）',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace = 'public'::regnamespace and proname = 'create_match_queue_tx' limit 1),
             '（不存在）')

  -- POS 開的房 opened_by 要放誰？店員登入還沒做（staffId 一律 null），
  -- 而 opened_by 若有外鍵指向 members，塞 null 以外的值會失敗
  union all select 20, 'match_queues.opened_by 的外鍵與可否為 null',
    coalesce((select string_agg(
                'nullable=' || (select is_nullable from information_schema.columns
                                 where table_schema='public' and table_name='match_queues' and column_name='opened_by')
                || '　' || pg_get_constraintdef(oid), ' ｜ ')
                from pg_constraint
               where conrelid = 'match_queues'::regclass and contype = 'f'
                 and pg_get_constraintdef(oid) ilike '%opened_by%'),
             (select 'nullable=' || is_nullable || '（沒有外鍵）' from information_schema.columns
               where table_schema='public' and table_name='match_queues' and column_name='opened_by'))

  union all select 21, 'source 目前實際出現過哪些值',
    coalesce((select string_agg(coalesce(source,'<null>') || '=' || n, '   ' order by source)
                from (select source, count(*) n from match_queues group by source) t), '（沒有資料）')

  union all select 30, '其他跟 queue 有關的 RPC',
    coalesce((select string_agg(proname, '、' order by proname) from pg_proc
               where pronamespace = 'public'::regnamespace and prokind = 'f'
                 and proname ilike '%queue%'), '（無）')
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 2 / 11 項若是 INVOKER → POS 呼叫會拿到空陣列且不報錯（硬規則 4 的形狀），
--   要先改成 DEFINER 才動前端。
-- 第 3 項：看 p_member 是只用來標「我在不在這桌」，還是有 where 條件依賴它。
--   若是後者，傳 null 會濾掉全部 —— 那就得為 POS 另開一支或加分支。
-- 第 10 項：看有沒有 p_source 參數。沒有的話 POS 開的房會被標成 'member'，
--   之後分不出「官方開的」與「客人開的」。
-- 第 20 項：opened_by 若 NOT NULL 且有外鍵指向 members，POS 開房會卡住
--   —— 店員登入還沒做，沒有 member id 可放。
