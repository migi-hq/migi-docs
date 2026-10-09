-- 2026-10-10 A1 現場故障：分紅之後的下一局，最後一位按確認一律「系統忙碌中」
--
-- 原因：uq_hands_confirmed_no（同一將、已入帳的局號不可重複）只排除咔啦碰，**漏了分紅**。
--   分紅跟咔啦碰一樣「不算一局」，送出時拿的局號 ＝ 下一局的局號（這次兩筆都是第 20 局）
--   ⇒ 下一局最後一人確認、狀態改成 confirmed 那一刻撞唯一索引 ⇒ 整筆回滾 ⇒ 平板只看到「系統忙碌中」
--   （10-09 分紅接上後端時沒有想到這條索引）
--
-- 修法：索引條件改成排除咔啦碰與分紅。表很小，重建是瞬間的事。
-- 跑完之後 A1 停在等確認的那一局（769258d1…），請座位 1 再按一次確認就會入帳。

drop index if exists public.uq_hands_confirmed_no;
create unique index uq_hands_confirmed_no on public.hands (round_id, hand_no)
  where status = 'confirmed' and result not in ('kala', 'bonus');

-- 驗證（單一 SELECT）
select
  (select case when indexdef ~ 'bonus' and indexdef ~ 'kala' then '✅ 索引已排除咔啦碰與分紅' else '🔴 索引條件不對：' || indexdef end
     from pg_indexes where indexname = 'uq_hands_confirmed_no')                                     as "① 索引",
  (select case when count(*) = 0 then '✅ 沒有重複的局號' else '🔴 有 ' || count(*) || ' 組重複' end
     from (select round_id, hand_no from public.hands
            where status = 'confirmed' and result not in ('kala', 'bonus')
            group by 1, 2 having count(*) > 1) x)                                                     as "② 現有資料",
  (select '等確認：' || status || ' · 已確認 ' || confirmed_seats::text || ' / 要確認 ' || need_confirm::text
     from public.hands where id = '769258d1-3a73-4650-829b-1dd7025cb455')                            as "③ A1 那一局";
