/* ============================================================
   2026-11-04 · 牌桌商城：歐拉小鎮的星空換掉暴風雨、預設款改名「宇宙」
   使用者：「歐拉小鎮的星空 換掉現有暴風雨；現有的預設歐拉小鎮的星空 改名宇宙」
     starry  歐拉小鎮的星空 → 宇宙（預設、免費，動畫不變：星點從中間往外飛）
     town    🆕 歐拉小鎮的星空（入門、5 碎片；插畫底圖 ＋ 流星雨）—— 接手暴風雨的位置與價格
     storm   燈塔島的暴風雨 → 下架（is_active = false）
   ── 為什麼這樣做 ──
   · 新開一個代碼 town，不把 storm 那一列改成小鎮：代碼就是計分板認背景的鍵，
     storm 的意思一直是暴風雨，拿它裝小鎮就是「一個名字兩個意思」
   · 暴風雨是下架不是刪除（同 11-03 的熊熊賞櫻）：2026-11-04 查 member_items／member_equips 都是 0 筆
   ⚠ 前端要先部署再跑這一份（migi-table、migi-web 都要推）：
     先跑的話舊版 App 會出現一款它不認得的背景（沒有縮圖、動畫畫成宇宙）
   ============================================================ */

update public.shop_items set name = '宇宙' where code = 'starry';
update public.shop_items set is_active = false where code = 'storm';
insert into public.shop_items (code, kind, name, tier, price, sort)
values ('town', 'table_bg', '歐拉小鎮的星空', 'basic', 5, 20)
on conflict (code) do update set name = excluded.name, tier = excluded.tier, price = excluded.price,
                                 sort = excluded.sort, is_active = true;
update public.shop_items set sort = 40 where code = 'storm';

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when (select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active)
            = 'starry 宇宙 0、town 歐拉小鎮的星空 5'
       then '✅ ① 上架中：宇宙（免費）、歐拉小鎮的星空（5）'
       else '🔴 ① 上架中的商品不對：' || coalesce((select string_agg(code || ' ' || name || ' ' || price, '、' order by sort) from shop_items where is_active), '（空的）') end,
  case when (select not is_active from shop_items where code = 'storm')
       then '✅ ② 燈塔島的暴風雨已下架（資料還在）' else '🔴 ② 暴風雨沒有下架' end,
  case when (select tier from shop_items where code = 'town') = 'basic' and (select kind from shop_items where code = 'town') = 'table_bg'
       then '✅ ③ 歐拉小鎮的星空是入門款、桌邊背景' else '🔴 ③ 歐拉小鎮的星空的等級或種類不對' end,
  '⚪ ④ 擁有暴風雨的人：' || (select count(*) from member_items where item_code = 'storm')
     || '、正在用暴風雨的人：' || (select count(*) from member_equips where item_code = 'storm') || '（應該都是 0）'
) as "驗證";
