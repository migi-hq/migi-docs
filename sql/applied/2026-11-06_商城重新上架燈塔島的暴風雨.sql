/* ============================================================
   2026-11-06 · 牌桌商城：重新上架「燈塔島的暴風雨」（code storm，入門 · 5 個碎片）
   · 使用者 2026-11-05 給了一張插畫（docs/_資產/燈塔島_原圖.webp），照它重做計分板背景，2026-11-06 說「上架」
     —— 原本程式畫的版本 2026-11-04 下架；代碼、名稱、等級、價格、說明都沿用，只把 is_active 改回 true
   · 🔴 **前端推上線之後才跑**：計分板 bg.jsx 與會員 App tablebg.jsx 的新版 storm、商城縮圖 bg-storm.webp 要先在 ——
     先上架的話，舊版前端畫的是 11-04 下架的那一版程式畫暴風雨
   · 排序維持 40（排在冰川峽灣的極光後面）
   · 預覽：https://claude.ai/artifact/JQEBsBT5ywVwLBAgrCZJPH
   ============================================================ */

update public.shop_items set is_active = true where code = 'storm';

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when exists (select 1 from shop_items where code = 'storm' and kind = 'table_bg' and tier = 'basic'
                      and price = 5 and is_active and name = '燈塔島的暴風雨' and coalesce(description, '') <> '')
       then '✅ ① 燈塔島的暴風雨重新上架（入門 · 5 個碎片，有說明）'
       else '🔴 ① storm 那一列不對：' || coalesce((select name || ' ' || tier || ' ' || price || ' ' || is_active::text from shop_items where code = 'storm'), '（找不到）') end,
  case when (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active)
            = 'starry 大熊星座的啟示 0、town 歐拉小鎮的星空 5、aurora 冰川峽灣的極光 20、storm 燈塔島的暴風雨 5'
       then '✅ ② 上架中：大熊星座的啟示（免費）、歐拉小鎮的星空（5）、冰川峽灣的極光（20）、燈塔島的暴風雨（5）'
       else '🔴 ② 上架中的商品不對：' || coalesce((select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active), '（空的）') end
) as "驗證";
