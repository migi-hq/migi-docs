/* ============================================================
   2026-11-05 · 牌桌商城：上架「冰川峽灣的極光」（code aurora，一般 · 20 個碎片）
   · 使用者 2026-11-05 選定：名稱照《小熊宇宙》設定集（冰川峽灣是全咪吉海姆離大熊星座最近的地方，極光是眾熊之母的披肩）、
     一般款 20 個碎片（使用者同日從 10 改成 20，照文件的三級：入門 10／一般 20／稀有 40；歐拉小鎮維持 5）；極光保留原圖（含綠色），只讓它動（第三版；前兩版用程式重畫，使用者不要）
   · 🔴 **前端推上線之後才跑**：計分板 bg.jsx 與會員 App tablebg.jsx 的 BACKGROUNDS／ANIM 要先有 aurora、
     商城縮圖樣式 .shopbg-aurora 要先在 —— 先上架的話，舊版前端認不得代碼會畫預設背景、縮圖是一塊空白
   · 排序 25：歐拉小鎮的星空（20）後面、已下架的兩款前面
   · 預覽：https://claude.ai/artifact/1CBSHruwQrqaPnRftx7RN8
   ============================================================ */

insert into public.shop_items (code, kind, name, tier, price, sort, is_active, description)
values ('aurora', 'table_bg', '冰川峽灣的極光', 'normal', 20, 25, true,
        '全咪吉海姆離大熊星座最近的地方，極光是眾熊之母披在天上的披肩。')
on conflict (code) do update
   set name = excluded.name, tier = excluded.tier, price = excluded.price,
       sort = excluded.sort, is_active = excluded.is_active, description = excluded.description;

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when exists (select 1 from shop_items where code = 'aurora' and kind = 'table_bg' and tier = 'normal'
                      and price = 20 and is_active and coalesce(description, '') <> '')
       then '✅ ① 冰川峽灣的極光上架（一般 · 20 個碎片，有說明）'
       else '🔴 ① aurora 那一列不對：' || coalesce((select name || ' ' || tier || ' ' || price || ' ' || is_active::text from shop_items where code = 'aurora'), '（找不到）') end,
  case when (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active)
            = 'starry 大熊星座的啟示 0、town 歐拉小鎮的星空 5、aurora 冰川峽灣的極光 20'
       then '✅ ② 上架中：大熊星座的啟示（免費）、歐拉小鎮的星空（5）、冰川峽灣的極光（20）'
       else '🔴 ② 上架中的商品不對：' || coalesce((select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active), '（空的）') end
) as "驗證";
