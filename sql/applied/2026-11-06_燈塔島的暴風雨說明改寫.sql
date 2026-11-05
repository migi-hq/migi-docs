/* ============================================================
   2026-11-06 · 牌桌商城：「燈塔島的暴風雨」的說明改寫
     使用者：「燈塔島的說明重寫」→ 從九種選 H →「應該要介紹咪吉海姆外海有一座燈塔島」→ 照 H 的語氣寫三種，選 2
     舊：主島最外面的岩石上有一座燈塔。暴風雨的晚上看不見星星，燈塔就替海上的船點一顆不會被雨遮住的星。（47 字）
     新：咪吉海姆的外海有一座燈塔島。暴風雨的晚上，燈塔的光一圈一圈轉著，告訴海上的船：家在這裡。
   · 「光一圈一圈轉著」對得上計分板上左右輪流亮暗的光束；手機抽屜裡兩行
   · 預覽：https://claude.ai/artifact/PbV1ubv7oq6tnhgj31jTMq
   · 只改 description，名稱、價格、動畫都不動；App 抽屜直接讀這一欄，不用重新部署
   ============================================================ */

update public.shop_items
   set description = '咪吉海姆的外海有一座燈塔島。暴風雨的晚上，燈塔的光一圈一圈轉著，告訴海上的船：家在這裡。'
 where code = 'storm';

/* ── 驗證（單一 SELECT）── */
select case when (select description from shop_items where code = 'storm')
                 = '咪吉海姆的外海有一座燈塔島。暴風雨的晚上，燈塔的光一圈一圈轉著，告訴海上的船：家在這裡。'
            then '✅ 燈塔島的暴風雨的說明已更新（' || (select char_length(description) from shop_items where code = 'storm') || ' 字）'
            else '🔴 說明不對：' || coalesce((select description from shop_items where code = 'storm'), '（找不到 storm）') end as "驗證";
