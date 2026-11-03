/* ============================================================
   2026-11-04 · 牌桌商城：預設背景改名「大熊星的指引」
   使用者同日先改成「宇宙」，再從《小熊宇宙》的守護者「大熊星」取名定案
     starry  宇宙 → 大熊星的指引（預設、免費；動畫不變：粉色光點從中間往外飛）
   ── 為什麼這樣取 ──
   · 前一輪提的三個（咪吉海姆的夜空、麻將館的星光、冰川峽灣的星河）都跟「歐拉小鎮的星空」重疊（使用者）
   · 「大熊星的啟示」不用：啟示是宗教用語，《小熊宇宙》寫明大熊星不是任何宗教的神；
     使用者 2026-09-28 也因為「有點神蹟的感覺」拿掉過計分板的光暈與光束
   · 設定：大熊星「守著方向」，勺口兩顆星永遠指著北方，迷路的船看著祂就找得到家
   · ⚠ 不是「地名的景色」格式 —— 預設款不屬於任何一個地方，當成例外
   · 只改名字，代碼 starry 不動 ⇒ 計分板與會員 App 都不用重新部署
   ============================================================ */

update public.shop_items set name = '大熊星的指引' where code = 'starry';

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when (select name from shop_items where code = 'starry') = '大熊星的指引'
       then '✅ ① 預設款改名：大熊星的指引' else '🔴 ① 預設款名字不對：' || coalesce((select name from shop_items where code = 'starry'), '（找不到）') end,
  case when (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active)
            = 'starry 大熊星的指引 0、town 歐拉小鎮的星空 5'
       then '✅ ② 上架中：大熊星的指引（免費）、歐拉小鎮的星空（5）'
       else '🔴 ② 上架中的商品不對：' || coalesce((select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active), '（空的）') end
) as "驗證";
