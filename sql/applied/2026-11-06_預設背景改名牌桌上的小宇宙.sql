/* ============================================================
   2026-11-06 · 牌桌商城：預設背景改名「牌桌上的小宇宙」（使用者從五個名稱裡選）
     starry  大熊星座的啟示 → 牌桌上的小宇宙（預設、免費）
   · 起因：同日說明改成「在咪吉海姆有一個傳說，牌桌就是宇宙的中心。所有的星星都從這裡出發，飛向夜空的盡頭。」
     ⇒ 說明已經不提大熊星座，使用者：「是不是不用叫大熊星座的啟示」
   · 沒選的四個：宇宙中心的星海、群星出發的地方、飛向夜空的盡頭、咪吉海姆的傳說（都是 7 個字，跟另外三款一樣長）
   · 只改名字，代碼 starry、說明、動畫都不動；App 與計分板都從資料庫讀名字，不用重新部署
   ============================================================ */

update public.shop_items set name = '牌桌上的小宇宙' where code = 'starry';

/* ── 驗證（單一 SELECT）── */
select case when (select name from shop_items where code = 'starry') = '牌桌上的小宇宙'
            then '✅ 預設款改名：牌桌上的小宇宙（說明：' || (select description from shop_items where code = 'starry') || '）'
            else '🔴 預設款名字不對：' || coalesce((select name from shop_items where code = 'starry'), '（找不到 starry）') end as "驗證";
