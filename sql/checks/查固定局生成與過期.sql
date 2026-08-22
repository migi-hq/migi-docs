-- 【這是什麼】唯讀盤點：固定牌局的「生成」與「過期」兩端。
-- 【何時讀】接在 sql/checks/查固定牌局.sql 之後。
--
-- ═══ 已知事實（2026-08-22 盤點）═══
--   · match_queues 有 31 筆 recurring：30 expired + 1 matched，**0 筆等待中**
--     → 前端不是壞了，是真的沒有可加入的房
--   · 🔴 有兩個 cron job 都在生成固定局：
--       gen-recurring-instances  → 0 */6 * * *
--       migi_generate_recurring  → 0 19 * * *
--     同一件事兩個排程，不是備援 —— 是有人加了第二個沒刪第一個。
--     可能互相產生重複列，或其中一個一直在失敗而沒人發現。
--   · 🟡 最後一筆 expired 是 2026-08-22 13:00 UTC（台北 21:00）。
--     若現在還沒到 21:00，代表它在開打前就被標成過期了。
--
-- 這支要回答：兩個 job 各自跑什麼、生成到哪一天為止、過期是用什麼判準、最近跑成功了嗎。

select 項目, 結果
from (
  -- ── 一、兩個排程各自在做什麼 ─────────────────────────────
  select 1 as ord, '兩個生成排程的實際指令' as 項目,
    coalesce((select string_agg(jobname || ' [' || schedule || '] → ' || command, chr(10) order by jobname)
                from cron.job
               where jobname in ('gen-recurring-instances', 'migi_generate_recurring')),
             '（讀不到 cron.job）') as 結果

  union all select 2, '過期掃描排程的指令',
    coalesce((select command from cron.job where jobname = 'migi_sweep_expired'), '（沒有）')

  -- ── 二、最近跑得怎麼樣（失敗會在這裡看到）───────────────
  union all select 10, '生成排程最近 5 次執行結果',
    coalesce((select string_agg(line, chr(10) order by st desc)
                from (select j.jobname || ' ' || d.start_time::text || ' → ' || d.status
                             || coalesce(' ｜ ' || nullif(d.return_message, ''), '') as line,
                             d.start_time as st
                        from cron.job_run_details d
                        join cron.job j on j.jobid = d.jobid
                       where j.jobname in ('gen-recurring-instances', 'migi_generate_recurring')
                       order by d.start_time desc limit 5) t),
             '（沒有近三天的執行紀錄 —— 排程可能沒在跑）')

  union all select 11, '近三天各排程的成功/失敗次數',
    coalesce((select string_agg(jobname || ': ' || status || ' × ' || n, '   ' order by jobname, status)
                from (select j.jobname, d.status, count(*) as n
                        from cron.job_run_details d
                        join cron.job j on j.jobid = d.jobid
                       where d.start_time > now() - interval '3 days'
                       group by j.jobname, d.status) t),
             '（沒有執行紀錄）')

  -- ── 三、生成的來源：固定局的母表 ─────────────────────────
  union all select 20, 'recurring_id 指向哪張表（外鍵）',
    coalesce((select string_agg(pg_get_constraintdef(oid), ' ｜ ')
                from pg_constraint
               where conrelid = 'match_queues'::regclass and contype = 'f'
                 and pg_get_constraintdef(oid) ilike '%recurring_id%'),
             '（沒有外鍵 —— recurring_id 只是個沒有母表的欄位）')

  union all select 21, '有沒有叫 recurring 的表',
    coalesce((select string_agg(table_name, '、' order by table_name)
                from information_schema.tables
               where table_schema = 'public' and table_name ilike '%recurring%'),
             '（沒有這樣的表）')

  -- ── 四、生成函式做什麼（生成到哪一天為止）───────────────
  union all select 30, 'generate_recurring_instances_tx 的簽名',
    coalesce((select pg_get_function_identity_arguments(oid)
                from pg_proc where pronamespace = 'public'::regnamespace
                 and proname = 'generate_recurring_instances_tx' limit 1),
             '（函式不存在）')

  union all select 31, '生成函式裡的時間視窗（抓 interval 字樣）',
    coalesce((select string_agg(m[1], ' / ')
                from pg_proc p,
                     lateral regexp_matches(p.prosrc, '(interval\s*''[^'']+'')', 'g') m
               where p.pronamespace = 'public'::regnamespace
                 and p.proname = 'generate_recurring_instances_tx'),
             '（找不到 interval —— 視窗可能寫成別的形式）')

  union all select 32, '過期函式的判準（play_at 還是 expires_at）',
    coalesce((select case
                when prosrc ilike '%expires_at%' and prosrc ilike '%play_at%' then '兩個都用到'
                when prosrc ilike '%expires_at%' then 'expires_at'
                when prosrc ilike '%play_at%'    then 'play_at'
                else '兩個都沒用到（要撈全文看）' end
                from pg_proc where pronamespace = 'public'::regnamespace
                 and proname = 'sweep_expired_queues_tx' limit 1),
             '（函式不存在）')

  -- ── 五、expires_at 到底比 play_at 早多久 ─────────────────
  union all select 40, 'recurring 的 expires_at 與 play_at 差距（最近 5 筆）',
    coalesce((select string_agg(play_at::text || ' 開打，' || expires_at::text || ' 到期（差 '
                                || round(extract(epoch from (play_at - expires_at)) / 60) || ' 分）', chr(10) order by play_at desc)
                from (select play_at, expires_at from match_queues
                       where source = 'recurring' and expires_at is not null
                       order by play_at desc limit 5) t),
             '（expires_at 全是 null）')

  union all select 41, '現在時間（UTC / 台北）',
    now()::text || '　｜　' || (now() at time zone 'Asia/Taipei')::text
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 1 項：兩個 job 的 command 若指向同一支函式 → 純重複，刪掉一個。
--          若指向不同函式 → 有兩套生成邏輯並存，那更糟，要先確認哪一套是對的。
-- 第 10/11 項：若有 failed → 生成一直在報錯而沒人知道，那就是固定局斷掉的原因。
--          若完全沒有執行紀錄 → 排程沒在跑（pg_cron 沒啟用，或 job 被停用）。
-- 第 20/21 項：若沒有母表 → 「固定局」沒有設定的來源，實例是一次性塞進去的，
--          用完就沒了。那不是 bug，是這個功能本來就沒做完。
-- 第 40 項：若 expires_at 比 play_at 早很多 → 固定局會在開打前就從畫面消失。
--          正常應該是「開打時間之後」才算過期，或至少留到開打當下。
