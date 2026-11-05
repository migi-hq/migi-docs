/* ============================================================
   2026-11-05 · 牌桌商城：預設背景「大熊星座的啟示」的說明加長一點（使用者：「說明略長一點」）
     舊：迷路的船抬頭找到它，就知道家在哪個方向。（20 字）
     新：霧再大、夜再長，抬頭總找得到那七顆星。迷路的船看見它，就知道家在哪個方向。（A 指路，使用者從六種裡選的）
   · 使用者指定不要寫「勺口那兩顆永遠指著北方」那一類
   · 六種寫法的預覽：https://claude.ai/artifact/5ifubyLJMGVrkiqFtvUcjk
   · 只改 description，名稱、價格、動畫都不動；App 抽屜直接讀這一欄，不用重新部署
   ============================================================ */

update public.shop_items
   set description = '霧再大、夜再長，抬頭總找得到那七顆星。迷路的船看見它，就知道家在哪個方向。'
 where code = 'starry';

/* ── 驗證（單一 SELECT）── */
select case when (select description from shop_items where code = 'starry')
                 = '霧再大、夜再長，抬頭總找得到那七顆星。迷路的船看見它，就知道家在哪個方向。'
            then '✅ 大熊星座的啟示的說明已更新（' || (select char_length(description) from shop_items where code = 'starry') || ' 字）'
            else '🔴 說明不對：' || coalesce((select description from shop_items where code = 'starry'), '（找不到 starry）') end as "驗證";
