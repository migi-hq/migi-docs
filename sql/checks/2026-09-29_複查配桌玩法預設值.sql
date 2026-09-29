-- 2026-09-29 複查：match_queues.game_type 的預設值真的提交了（硬規則 1.8：驗證段看的是交易內，提交後要另外查一次）
-- 跑在 sql/applied/2026-09-29_配桌玩法拿掉預設值.sql 之後。唯讀，一支 SELECT。
select case when column_default like '''台麻''%' then '✅ 已提交：預設值是台麻'
            else '🔴 沒有提交，現在是 ' || coalesce(column_default, 'null') end as "複查"
  from information_schema.columns
 where table_schema = 'public' and table_name = 'match_queues' and column_name = 'game_type';
