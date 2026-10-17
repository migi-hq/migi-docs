-- ============================================================
-- 2026-10-17 遊戲BOY 的傳奇頭銜改成「傳奇玩家」
-- MIGI 咪吉麻將
--
-- 起因：上一份（2026-10-17_傳奇玩家標記_牌局詳情.sql）我自己填了「台灣麻將傳奇」，沒有先問。
--   使用者選「改成『傳奇玩家』，以後做個人檔案時就用它當頭銜」。
-- ⚠ 牌局詳情目前只看這一格有沒有填，不顯示內容 —— 改了畫面不會變。
-- ============================================================

update public.members
   set legend_title = '傳奇玩家'
 where id = 'dfe22038-ffe1-4561-be05-d9cfa2247d67'
   and legend_title is distinct from '傳奇玩家';

-- 驗證（單一 SELECT；不 raise，跑完我會另外查一次線上）
select concat_ws(E'\n',
  coalesce((select case when legend_title = '傳奇玩家' then '✅ ① 遊戲BOY 頭銜：' || legend_title
                        else '🔴 ① 遊戲BOY 頭銜是 ' || coalesce(legend_title, 'null') end
              from public.members where id = 'dfe22038-ffe1-4561-be05-d9cfa2247d67'), '🔴 ① 找不到遊戲BOY'),
  (select case when count(*) = 1 then '✅ ② 全庫只有 1 位傳奇玩家'
               else '🔴 ② 傳奇玩家有 ' || count(*) || ' 位' end
     from public.members where legend_title is not null)
) as "驗證";
