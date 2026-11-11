-- 刪掉舊的加電腦對手函式 add_friendly_bots_tx（一次加幾位、照固定順序加）（2026-11-11 使用者：「刪掉」）
-- 在 Supabase SQL Editor 執行。
--
-- 為什麼可以刪
--   邀牌咖抽屜改成三隻熊各一顆「邀請」，叫的是新的 add_friendly_bot_tx（指定哪一隻）。
--   動手前查過（2026-11-11）：
--     · 正式站的會員 App（v1111-1943）已經是新版，打包檔裡找不到舊函式的名字
--     · 三個前端與 Edge Function 的程式碼裡都沒有人叫它
--     · 資料庫裡沒有別的函式叫它，排程裡也沒有
--   留著的話就是「一件事兩支函式」，下一個人不知道該用哪一支。
--
-- 已知代價：手機上還開著舊版 App、一直沒有重新整理的人，按舊畫面的「加 N 位」會失敗一次；
--           App 自己會比對版本並重新載入，重載之後就是新畫面。
-- 可以重跑（if exists）。

drop function if exists public.add_friendly_bots_tx(uuid, integer);

-- ─── 驗證（單一 SELECT）───
select string_agg(case when ok then '✅ ' else '🔴 ' end || item, E'\n' order by ord) as "驗證（應該 4 格全綠）"
  from (
    select 1 as ord,
           not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'add_friendly_bots_tx') as ok,
           '① 舊的那支（一次加幾位）已經不在了' as item
    union all
    -- ② 正對照：新的那支沒有被一起刪掉，而且登入的人還叫得動（少了這一格，把兩支都刪光也會全綠）
    select 2,
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'add_friendly_bot_tx') = 1
             and has_function_privilege('authenticated', 'public.add_friendly_bot_tx(uuid, text)'::regprocedure, 'execute')
             and not has_function_privilege('anon', 'public.add_friendly_bot_tx(uuid, text)'::regprocedure, 'execute'),
           '② 新的那支（指定哪一隻）還在：一個版本、登入的人叫得動、沒登入的叫不動'
    union all
    -- ③ 全庫沒有任何函式還在呼叫舊的那支（掃的是「呼叫」的形狀：名字後面接左括號）
    select 3,
           not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                          and pg_get_functiondef(p.oid) ~ 'add_friendly_bots_tx\s*\('),
           '③ 資料庫裡沒有任何函式還在叫它'
    union all
    select 4,
           not exists (select 1 from cron.job where command ~ 'add_friendly_bots_tx'),
           '④ 排程裡也沒有'
  ) c;
