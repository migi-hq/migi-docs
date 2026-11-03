/* ============================================================
   2026-11-03 · 牌桌商城：暴風雨上架、熊熊賞櫻下架、兩款改名
   使用者：「把賞櫻改成暴風雨，然後用 5 個碎片就能交換」；名稱同日定案（北歐 ＋ 可愛風格）
     starry  熊熊星空  → 歐拉小鎮的星空（預設、免費，不變）
     storm   🆕 燈塔島的暴風雨（入門、5 碎片）
     sakura  熊熊賞櫻  → 下架（is_active = false）
   ── 為什麼這樣做 ──
   · 賞櫻是下架不是刪除：shop_items 被 member_items／member_equips 外鍵指著；
     今天沒有人擁有它（2026-11-03 查 member_items 0 筆），日後重新上架只要改回 true
   · 下架之後：商城不列出（沒人擁有）；萬一有人正在用，計分板退回預設（_member_table_bg 只認上架的款）
   · 5 碎片低於原本的入門價 10（使用者指定），等級仍放「入門」
   ⚠ 前端要先部署再跑這一份（migi-table f24a8a2、migi-web 267812f 已推）：
     先跑的話舊版 App 會出現一款它不認得的背景（沒有縮圖、動畫畫成星空）
   ============================================================ */

update public.shop_items set name = '歐拉小鎮的星空' where code = 'starry';
update public.shop_items set is_active = false where code = 'sakura';
insert into public.shop_items (code, kind, name, tier, price, sort)
values ('storm', 'table_bg', '燈塔島的暴風雨', 'basic', 5, 20)
on conflict (code) do update set name = excluded.name, tier = excluded.tier, price = excluded.price,
                                 sort = excluded.sort, is_active = true;
update public.shop_items set sort = 30 where code = 'sakura';

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active)
            = 'starry 歐拉小鎮的星空 0、storm 燈塔島的暴風雨 5'
       then '✅ ① 上架中：歐拉小鎮的星空（免費）、燈塔島的暴風雨（5）'
       else '🔴 ① 上架中的商品不對：' || coalesce((select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active), '（空的）') end,
  case when (select not is_active from shop_items where code = 'sakura')
       then '✅ ② 熊熊賞櫻已下架（資料還在）' else '🔴 ② 熊熊賞櫻沒有下架' end,
  case when (select tier from shop_items where code = 'storm') = 'basic'
       then '✅ ③ 暴風雨是入門款' else '🔴 ③ 暴風雨的等級不對' end,
  '⚪ ④ 擁有賞櫻的人：' || (select count(*) from member_items where item_code = 'sakura')
     || '、正在用賞櫻的人：' || (select count(*) from member_equips where item_code = 'sakura') || '（應該都是 0）'
) as "驗證";
