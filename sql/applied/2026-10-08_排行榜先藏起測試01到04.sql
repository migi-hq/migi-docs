-- ════════════════════════════════════════════════════════════════════
-- 2026-10-08 排行榜先藏起測試01～04
-- ════════════════════════════════════════════════════════════════════
-- 使用者：「把目前所有測試01~04的排行先隱藏」
--
-- 現況：上線前（orgs.live_from 還沒設）排行榜會連測試帳號一起排，
--       所以賽季排行榜第 1～3、5 名都是測試01～04。
--
-- 🔴 不能直接改成「不排測試帳號」：創辦人自己（本狩 岡五郎）也是測試帳號，
--    那樣會連他一起消失，而封測客人還沒上榜時整張榜就空了。
--    ⇒ 只排除這四個固定的測試帳號（id 2026-10-08 從線上查出來，
--      對應 test01～04@migi.invalid、手機 0910000001～4）。
--
-- 影響範圍：只改「看」的那一支 season_rank_rows_display_tx
--   · 會員 App 賽季排行榜、成績頁「全國排名」都讀它
--   · 測試01～04 自己登入時，成績頁的全國排名會是「—」（沒上榜）
--   · 🔴 賽季結算用的 season_rank_rows_tx 不動 —— 它本來就排除所有測試帳號
--   · 上線（設 live_from）之後這四個本來就不會出現，這段排除自然沒作用
--
-- 簽名不變 ⇒ create or replace，不丟權限（目前只有 postgres／service_role，給內部包裝叫）
-- ════════════════════════════════════════════════════════════════════

create or replace function public.season_rank_rows_display_tx(
  p_org_id uuid, p_from timestamptz, p_to timestamptz default null)
returns table(member_id uuid, rating integer, rank_no integer, games integer)
language sql stable security definer
set search_path to 'public'
as $function$
  /* 排行榜與成績頁「全國排名」用。**只用在「看」，不可以拿去結算。**
     上線前（live_from 未設或未到）連測試帳號一起排，讓畫面有東西可以看；
     上線那一刻自動變回只排真客人。
     🆕 2026-10-08：四個固定的測試帳號（測試01～04）不上榜（使用者要求）。
       名次在排除之後重新算，不會出現「第 1 名不見、從第 2 名開始」。 */
  select c.member_id, c.rating,
         rank() over (order by c.rating desc, m.created_at)::int as rank_no,
         c.games
    from public._season_rank_rows_core(
           p_org_id, p_from, p_to,
           not exists (select 1 from orgs o where o.id = p_org_id
                        and o.live_from is not null and now() >= o.live_from)) c
    join members m on m.id = c.member_id
   where c.member_id not in (
           'd73fdac2-d6b9-4b8a-bcff-b19c2786056f',   -- 測試01
           '218378e1-fb6c-43fb-b642-99fdbf5c52b1',   -- 測試02
           'd0db928e-5a75-4535-90d4-93ede67790a8',   -- 測試03
           '526aa8b9-cc93-4327-b878-6d21d399af8e')   -- 測試04
$function$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
with o as (select id from orgs order by created_at limit 1),
     disp as (select r.*, m.display_name, m.phone
                from o cross join lateral public.season_rank_rows_display_tx(o.id, null, null) r
                join members m on m.id = r.member_id)
select concat_ws(E'\n',
  -- ① 只有一個版本
  case when (select count(*) from pg_proc where pronamespace='public'::regnamespace
              and proname='season_rank_rows_display_tx') = 1
       then '✅ ① 函式只有一個版本' else '🔴 ① 出現多個版本' end,
  -- ② 測試01～04 不在榜上
  case when (select count(*) from disp where phone in ('0910000001','0910000002','0910000003','0910000004')) = 0
       then '✅ ② 測試01～04 都不在榜上' else '🔴 ② 還有測試帳號在榜上' end,
  -- ③ 正對照：創辦人（手機 0910768736）還在，而且是第 1 名
  coalesce((select case when rank_no = 1 then '✅ ③ 創辦人還在榜上，第 1 名（段位分 ' || rating || '）'
                        else '🟡 ③ 創辦人在榜上但是第 ' || rank_no || ' 名' end
              from disp where phone = '0910768736'),
           '🔴 ③ 創辦人也不見了（排除過頭）'),
  -- ④ 名次從 1 開始連續（排除之後有重算）
  case when (select min(rank_no) from disp) = 1 or not exists (select 1 from disp)
       then '✅ ④ 名次從 1 開始' else '🔴 ④ 名次沒有重算' end,
  -- ⑤ 結算那一支沒被動到：仍然一個測試帳號都不排
  case when (select count(*) from o cross join lateral public.season_rank_rows_tx(o.id, null, null) r
               join members m on m.id = r.member_id where m.is_test) = 0
       then '✅ ⑤ 結算用的排名仍然不含測試帳號' else '🔴 ⑤ 結算用的排名混進測試帳號' end,
  -- ⑥ 權限沒變（仍然只有內部叫得到）
  case when (select not has_function_privilege('anon', p.oid, 'execute')
                and not has_function_privilege('authenticated', p.oid, 'execute')
               from pg_proc p where p.pronamespace='public'::regnamespace
                and p.proname='season_rank_rows_display_tx')
       then '✅ ⑥ 權限沒變（前端叫不到，只經由排行榜函式）' else '🔴 ⑥ 權限被打開了' end
) as "驗證";
