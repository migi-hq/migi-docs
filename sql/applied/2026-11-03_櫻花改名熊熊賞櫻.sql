/* ============================================================
   2026-11-03 · 牌桌商城的櫻花背景改名「熊熊賞櫻」
   使用者：「櫻花也要取小熊宇宙應景的名稱」—— 跟「熊熊星空」配成一對
   ⚠ 只改 name；code 'sakura' 不動（計分板與 App 縮圖靠它認背景，改了就認不得）
   畫面都讀 shop_items.name，前端不用改
   ============================================================ */

update public.shop_items set name = '熊熊賞櫻' where code = 'sakura';

/* ── 驗證（單一 SELECT）── */
select case
  when (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items) = 'starry 熊熊星空 0、sakura 熊熊賞櫻 40'
  then '✅ 商品：熊熊星空（免費）、熊熊賞櫻（40），代碼沒變'
  else '🔴 商品不對：' || (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items)
end as "驗證";
