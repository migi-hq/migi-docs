/* ============================================================
   2026-11-05 · 牌桌商城：預設背景改名「大熊星座的啟示」（使用者指定）
     starry  大熊星的指引 → 大熊星座的啟示（預設、免費）
   · 動畫不變（粉色光點從中間往外飛）。同日試過在左上角加星座（真實大熊座／小熊頭像兩款），使用者決定維持原本的
     —— 預覽留在 docs/_資產/大熊星座的啟示_預覽/（https://claude.ai/artifact/XAz1BAsrwiXCJa4cpdzpCh）
   · ⚠ 11-04 定名時「大熊星的啟示」曾因「啟示是宗教用語」被排除（見 2026-11-04_預設背景改名大熊星的指引.sql）；
     這次是使用者明確指定，照改
   · 只改名字，代碼 starry 不動
   ============================================================ */

update public.shop_items set name = '大熊星座的啟示' where code = 'starry';

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when (select name from shop_items where code = 'starry') = '大熊星座的啟示'
       then '✅ ① 預設款改名：大熊星座的啟示' else '🔴 ① 預設款名字不對：' || coalesce((select name from shop_items where code = 'starry'), '（找不到）') end,
  case when (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active)
            = 'starry 大熊星座的啟示 0、town 歐拉小鎮的星空 5'
       then '✅ ② 上架中：大熊星座的啟示（免費）、歐拉小鎮的星空（5）'
       else '🔴 ② 上架中的商品不對：' || coalesce((select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active), '（空的）') end
) as "驗證";
