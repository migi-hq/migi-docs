-- ============================================================
-- 2026-10-17 遊戲BOY 的頭銜改成「名人玩家」
-- MIGI 咪吉麻將
--
-- 起因：使用者把牌局詳情的「傳奇同桌／傳奇玩家」改名成「名人同桌／名人玩家」（migi-web 53cb732）。
--   這一格（members.legend_title）是日後個人檔案要顯示的頭銜，跟畫面用同一個名字。
-- ⚠ 牌局詳情目前只看這一格有沒有填，膠囊上的字寫在前端 —— 改了畫面不會變。
-- ⚠ 欄位名 legend_title 是代號，不跟著改名。
-- ============================================================

update public.members
   set legend_title = '名人玩家'
 where id = 'dfe22038-ffe1-4561-be05-d9cfa2247d67'
   and legend_title is distinct from '名人玩家';

-- 驗證（單一 SELECT；不 raise，跑完我會另外查一次線上）
select concat_ws(E'\n',
  coalesce((select case when legend_title = '名人玩家' then '✅ ① 遊戲BOY 頭銜：' || legend_title
                        else '🔴 ① 遊戲BOY 頭銜是 ' || coalesce(legend_title, 'null') end
              from public.members where id = 'dfe22038-ffe1-4561-be05-d9cfa2247d67'), '🔴 ① 找不到遊戲BOY'),
  (select case when count(*) = 1 then '✅ ② 全庫只有 1 位有頭銜'
               else '🔴 ② 有頭銜的有 ' || count(*) || ' 位' end
     from public.members where legend_title is not null)
) as "驗證";
