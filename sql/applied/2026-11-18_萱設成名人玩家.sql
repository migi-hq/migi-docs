-- 2026-11-18 使用者：「今天加入的 萱 要比照遊戲BOY」
-- 系統裡有兩位叫「萱」：11/17 14:12 加入的這位（打過 2 場）才是「今天加入」的那位；
-- 另一位 11/04 加入（3a97cdf8-…），不動。
-- 只改 members.legend_title，值跟遊戲BOY 一樣（名人玩家）。

update public.members
   set legend_title = '名人玩家'
 where id = '7cd19b11-16e4-4eb7-aebb-32901d077c2d'
   and display_name = '萱';

-- 驗證（單一 SELECT）
select display_name as 名字,
       to_char(created_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') as 加入時間,
       legend_title as 頭銜,
       case when (id = '7cd19b11-16e4-4eb7-aebb-32901d077c2d' and legend_title = '名人玩家')
              or (display_name like '%遊戲BOY%' and legend_title = '名人玩家')
              or (id = '3a97cdf8-13e5-4496-a297-b00655c79b7a' and legend_title is null)
            then '✅' else '🔴' end as 結果
  from public.members
 where id in ('7cd19b11-16e4-4eb7-aebb-32901d077c2d', '3a97cdf8-13e5-4496-a297-b00655c79b7a')
    or display_name like '%遊戲BOY%'
 order by created_at;
