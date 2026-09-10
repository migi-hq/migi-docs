/* ============================================================
   首店餐飲 32 項商品建檔
   2026-09-10 · 來源：`docs/07-營運商業/首店餐飲籌備.md` 第 1 節
   📌 那份文件的第 11 節「中期（開幕前）」有一條就是「商品資料建檔（32 項）」

   ── 🔴 先講三件會影響判斷的事 ────────────────────────
   ① **價格是暫定的。** 文件只有 4 項給了單一數字
      （焦糖布丁 60／提拉米蘇 90／巴斯克 90／拼盤 150），
      其餘是**區間**（60–90 這種）或**完全空白**（飲料 8 項一項都沒有）。
      ⇒ 下面每一列的價格都標了來源：`文件` / `區間下限` / `區間取中` / `暫定`。
      ⚠ 定價表定案本來就還在待辦裡。**開幕前要逐項在後台核一次。**
      🟢 改價成本是零：後台商品管理頁改完立刻生效，不用部署
        （`checkout_tx` 是即時查主檔的）。

   ② **POS 上這 32 項會擠在同一個「餐飲」分頁。**
      實查 `OpenCheckoutPage.jsx:820`：分頁讀的是 `catLabel(p.category)`，
      而 `category` 只有 fnb／merch／service 三值 ⇒ 五個分頁
      （飲料／甜點／零嘴／炸物／主食）**要等 `display_group` 欄位**，
      那是餐飲籌備文件第 10-1 節的提議，今天不存在。
      🔴 **這份不順便加那個欄位** —— 前端還沒有五個分頁要讀它，
        加了就是又一個「建了沒人讀」。

   ③ **進銷存不存在，所以 `stock_qty` 一律 0、`unit_cost` 一律 0。**
      🔴 不要填一個看起來合理的庫存數字 —— 既有的「水餃 50、厚片 50」
        就是那樣來的，而 202 筆品項賣掉之後它一次都沒動過。
        **一個永遠不準的數字會訓練人忽略它。** 見待辦 44 與
        `docs/07-營運商業/進銷存系統設計.md`。

   ── 為什麼直接 INSERT 不走 `admin_upsert_product_tx` ──
   那支的第一行是 `can('product.write')`，而它靠 `current_staff()`；
   SQL Editor 是 postgres 角色、沒有 JWT ⇒ **必定回 forbidden**。
   ⚠ 代價：`created_by` / `updated_by` 會是 null（沒有操作者可解析）。
     這是**建檔**不是店員改價，可以接受 —— 但日後改價請走後台，
     那條路會記名字。

   ⚠ 冪等：`on conflict (org_id, sku) where deleted_at is null do nothing`。
     🔴 那個 `where` 不可以省 —— `uq_products_sku` 是**部分索引**，
       不帶述詞的話 Postgres 匹配不到它，會直接報錯說沒有對應的約束。
   ============================================================ */

/* ── ① 三個新的子分類 ───────────────────────────────
   `subcategory` 是**毛利維度**（貨號第二段）。餐飲底下現在只有
   DRK 飲料與 MEAL 餐點，而甜點／零嘴／炸物的成本結構跟主食完全不同
   （甜點外購、零嘴大包分裝、炸物冷凍半成品）。
   ⚠ 這**不是**畫面分頁 —— 分頁看的是 `category`（見檔頭第 ② 點）。 */
insert into public.product_taxonomy (dimension, code, label, parent_code, sku_prefix, sort, is_active, note)
select v.* from (values
  ('subcategory', 'DES',  '甜點', 'fnb', 'DES',  22, true, '冷凍調理甜點為主，外購成本高、毛利結構與主食不同'),
  ('subcategory', 'FRY',  '炸物', 'fnb', 'FRY',  24, true, '全部走氣炸烤箱，不裝油炸鍋（油煙味與女性友善定位衝突）'),
  ('subcategory', 'SNK',  '零嘴', 'fnb', 'SNK',  26, true, '大包裝進貨、店內分裝。🔴 一律無調味 —— 粉會沾手污染牌具')
) as v(dimension, code, label, parent_code, sku_prefix, sort, is_active, note)
where not exists (
  select 1 from public.product_taxonomy t
   where t.dimension = v.dimension and t.code = v.code);

/* ── ①之二 分頁順序與「主食」正名 ────────────────────
   POS 的商品分頁改成讀**子分類**（見 ①之三），而分頁的左右順序
   就是 `sort` —— 使用者指定：飲料 · 甜點 · 炸物 · 零嘴 · 主食。
   ```
   DRK 20 飲料   DES 22 甜點   FRY 24 炸物   SNK 26 零嘴   MEAL 28 主食
   ```
   📌 順序不是隨便排的，它對得上餐飲籌備文件第 2 節的「兩層時機」：
     **牌局中吃得到的排前面**（飲料／甜點／零嘴），趁熱吃的排後面。

   🔴 `MEAL` 的中文從「餐點」改成「主食」—— 現在餐飲底下有五類，
     再叫「餐點」會跟上一層的「餐飲」撞名，而它實際裝的是麵飯那一類。 */
update public.product_taxonomy set sort = 20 where dimension='subcategory' and code='DRK';
update public.product_taxonomy set sort = 28, label = '主食'
 where dimension='subcategory' and code='MEAL';

/* ── ①之三 POS 的商品清單要回子分類 ──────────────────
   🔴 `list_products_tx` 今天**不回 `subcategory`** ⇒ 前端拿不到就分不了頁。
   ⚠ 簽名沒變，`CREATE OR REPLACE`，不用 DROP 也不掉 GRANT（硬規則 2）。 */
create or replace function public.list_products_tx(p_org_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'sku', sku, 'name', name, 'category', category,
      'subcategory', subcategory,
      'unit_price', unit_price,
      'revenue_type', revenue_type,
      'discountable', discountable,
      'spec', spec
    ) order by category, sku)
    from products
    where org_id = p_org_id and is_active and coalesce(is_available, true)
      and deleted_at is null
      and sku not like 'SVC-TBL-%'   -- 檯費不列入加購清單，避免店員手動點錯
  ), '[]'::jsonb);
end $function$;

/* ── ② 厚片歸位：MEAL → DES ─────────────────────────
   它今天是 `FNB-MEAL-TOAST`，而文件把厚片吐司列在**甜點**。
   ⚠ 改貨號是安全的：`order_items` 存的是**快照**（name／unit_price），
     歷史訂單不會跟著變；而它 `is_system = false`，
     沒有任何後端邏輯用固定貨號查它（檯費那七支才是）。 */
update public.products
   set sku = 'FNB-DES-TOAST', subcategory = 'DES',
       spec = '奶酥／花生／草莓／巧克力，同價',
       updated_at = now()
 where sku = 'FNB-MEAL-TOAST' and deleted_at is null;

/* ── ③ 30 個新品項 ─────────────────────────────────
   ⚠ 水餃（FNB-MEAL-DUMP）與厚片已經在線上，不在這批。
     30 ＋ 2 = 32，與文件的 8＋7＋1＋6＋10 對得上。 */
insert into public.products
  (org_id, sku, name, spec, category, subcategory, revenue_type,
   unit_price, unit_cost, tracks_stock, stock_qty,
   is_active, is_available, is_system, discountable)
select o.org_id, v.sku, v.name, v.spec, 'fnb', v.sub, 'fnb',
       v.price, 0, true, 0,
       true, true, false, true
  from (select org_id from public.products
         where sku = 'SVC-TBL-DAY' and deleted_at is null limit 1) o,
       (values
  /* ── 飲料 8 項 · 出餐站 bar ────────────────────────
     🔴 文件對飲料**一個價格都沒有**，下面八個全是暫定。
     ⚠ 甜度／冰塊／加珍珠 +10 **刻意不寫進 spec** ——
       `addons` 表與 `option_schema` 都不存在，寫了店員會以為系統收得到那 10 元。
       茶湯基底只有紅茶／綠茶／烏龍／冬瓜四種（奶茶＝紅茶＋奶精）。 */
  /* ⚠ 第一列的 spec 要標型別：多列 VALUES 的型別是從第一列推的，
     而這一欄的第一個值是 null ⇒ 不標會被推成 unknown 而插不進去。 */
  ('FNB-DRK-BLCK',  '紅茶',       null::text, 'DRK',  50),   -- 暫定
  ('FNB-DRK-GRN',   '綠茶',       null, 'DRK',  50),   -- 暫定
  ('FNB-DRK-WNTM',  '冬瓜茶',     null, 'DRK',  50),   -- 暫定
  ('FNB-DRK-OOLG',  '烏龍茶',     null, 'DRK',  50),   -- 暫定
  ('FNB-DRK-PEAR',  '珍珠奶茶',   null, 'DRK',  70),   -- 暫定 ★ 會員等級名品項
  ('FNB-DRK-YKGR',  '多多綠',     null, 'DRK',  65),   -- 暫定（綠茶＋養樂多）
  ('FNB-DRK-AMER',  '美式',       null, 'DRK',  70),   -- 暫定（自動咖啡機）
  ('FNB-DRK-LATT',  '拿鐵',       null, 'DRK',  80),   -- 暫定（自動咖啡機）

  /* ── 甜點 6 項（厚片已存在，見第 ② 段）· 出餐站 none，蛋塔走 kitchen ── */
  ('FNB-DES-PUDD',  '焦糖布丁',   '杯裝',        'DES',  60),   -- 文件 ★ 等級名品項
  ('FNB-DES-TIRA',  '提拉米蘇',   '杯裝',        'DES',  90),   -- 文件 ★ 等級名品項
  ('FNB-DES-BSKQ',  '巴斯克乳酪', '切片',        'DES',  90),   -- 文件
  ('FNB-DES-MILL',  '千層蛋糕',   '切片',        'DES', 120),   -- 區間下限（120–150）
  ('FNB-DES-TART',  '蛋塔',       null,          'DES',  40),   -- 區間下限（40–60）
  ('FNB-DES-COOK',  '手工餅乾盒', null,          'DES',  60),   -- 文件

  /* ── 零嘴 1 項 · 出餐站 none ───────────────────────
     ⚠ spec 留空：一碟幾克要等叫貨規格確定（文件：大包裝進貨、店內分裝小陶碟）。
     🔴 必須無調味 —— 粉會沾手污染牌具。那寫在 taxonomy 的 note 裡。 */
  ('FNB-SNK-NUTS',  '綜合堅果',   null, 'SNK',  80),   -- 暫定

  /* ── 炸物 6 項 · 出餐站 kitchen（氣炸烤箱）────────── */
  ('FNB-FRY-NUGG',  '雞塊',       null, 'FRY',  70),   -- 區間取中（60–90）
  ('FNB-FRY-FRIE',  '薯條',       null, 'FRY',  70),   -- 區間取中。⚠ 務必指定粗切或波浪薯
  ('FNB-FRY-POPC',  '雞米花',     null, 'FRY',  70),   -- 區間取中
  ('FNB-FRY-CHEZ',  '起司條',     null, 'FRY',  70),   -- 區間取中
  ('FNB-FRY-TEND',  '雞柳條',     null, 'FRY',  70),   -- 區間取中
  ('FNB-FRY-COMB',  '拼盤',       '雞塊＋薯條＋起司條', 'FRY', 150),  -- 文件

  /* ── 主食 9 項（水餃已存在）· 出餐站 kitchen（IH 隔水加熱）── */
  ('FNB-MEAL-PSTW', '白醬培根義大利麵', null, 'MEAL', 110),  -- 區間取中（90–130）
  ('FNB-MEAL-PSTG', '青醬燻雞義大利麵', null, 'MEAL', 110),  -- 區間取中
  ('FNB-MEAL-PSTR', '紅醬香腸義大利麵', null, 'MEAL', 110),  -- 區間取中
  ('FNB-MEAL-RMNT', '日式豚骨拉麵',     null, 'MEAL', 120),  -- 區間取中
  ('FNB-MEAL-RMNM', '日式味噌拉麵',     null, 'MEAL', 120),  -- 區間取中
  ('FNB-MEAL-BEEF', '牛肉麵',           null, 'MEAL', 160),  -- 文件（可至 160）
  ('FNB-MEAL-GUOS', '鍋燒意麵',         null, 'MEAL', 110),  -- 區間取中
  ('FNB-MEAL-ZHAJ', '炸醬麵',           null, 'MEAL', 100),  -- 區間取中
  ('FNB-MEAL-MALA', '椒麻乾麵',         null, 'MEAL', 100)   -- 區間取中
       ) as v(sku, name, spec, sub, price)
on conflict (org_id, sku) where deleted_at is null do nothing;

/* ── 驗證段（唯讀，一個字都不 raise —— 硬規則 1.8）────── */
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  select count(*) into v_n from products
   where category='fnb' and deleted_at is null;
  v_msg := v_msg || case when v_n = 32
    then '① ✅ 餐飲品項共 32 項（8 飲料 ＋ 7 甜點 ＋ 1 零嘴 ＋ 6 炸物 ＋ 10 主食）'
    else '① 🔴 餐飲品項是 ' || v_n || ' 項，不是 32' end;

  /* ② 逐類清點。期望值直接抄文件第 2 節的出餐站對照表。 */
  select string_agg(t.sub || ' ' || t.n, '　' order by t.sub) into v_t
    from (select subcategory as sub, count(*) as n from products
           where category='fnb' and deleted_at is null group by 1) t;
  v_msg := v_msg || E'\n' || case
    when v_t = 'DES 7　DRK 8　FRY 6　MEAL 10　SNK 1'
      then '② ✅ 五類的分佈對得上文件：' || v_t
    else '② 🔴 分佈不對：' || coalesce(v_t, '(一項都沒有)')
         || '　期望 DES 7　DRK 8　FRY 6　MEAL 10　SNK 1' end;

  select count(*) into v_n from product_taxonomy
   where dimension='subcategory' and code in ('DES','SNK','FRY');
  v_msg := v_msg || E'\n' || case when v_n=3
    then '③ ✅ 三個新子分類進主檔了（甜點／零嘴／炸物）'
    else '③ 🔴 只有 ' || v_n || ' 個進去' end;

  select coalesce(sku || ' ／ ' || subcategory || ' ／ ' || coalesce(spec,'(null)'), '(找不到)')
    into v_t from products where sku='FNB-DES-TOAST' and deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_t like 'FNB-DES-TOAST%'
    then '④ ✅ 厚片歸到甜點了：' || v_t
    else '④ 🔴 厚片沒搬到：' || coalesce(v_t,'(找不到)') end;

  /* ⑤ 🔴 正對照：這批不可以碰到檯費那七支。
        只驗「新的進去了」的話，一份順手改壞既有商品的 SQL 也會全綠。 */
  select count(*) into v_n from products
   where category='service' and is_system and deleted_at is null
     and revenue_type='venue_fee';
  v_msg := v_msg || E'\n' || case when v_n=7
    then '⑤ ✅ 檯費那七支原封不動（正對照）'
    else '⑤ 🔴 檯費變成 ' || v_n || ' 支 —— 這批動到了不該動的東西' end;

  /* ⑥ 分桶。寫錯桶不會報錯，只會讓報表安靜地算錯。 */
  select count(*) into v_n from products
   where category='fnb' and deleted_at is null and revenue_type is distinct from 'fnb';
  v_msg := v_msg || E'\n' || case when v_n=0
    then '⑥ ✅ 32 項全部進餐飲桶，沒有一項跑錯' else '⑥ 🔴 有 ' || v_n || ' 項的營收類別不是餐飲' end;

  /* ⑦ 庫存與成本刻意留 0 —— 進銷存不存在。
        ⚠ 既有的水餃與厚片是 50，那是以前後台手打的，這一格會抓到它們。 */
  select count(*) into v_n from products
   where category='fnb' and deleted_at is null and stock_qty <> 0;
  v_msg := v_msg || E'\n' || case when v_n=0
    then '⑦ ✅ 庫存全是 0（誠實：沒有進貨紀錄就不要有數字）'
    else '⑦ ⚠ 有 ' || v_n || ' 項庫存不是 0（水餃 50／厚片 50 是舊的手打值，見待辦 44）' end;

  /* ⑧ 貨號規則：三段、第二段等於 subcategory。 */
  select count(*) into v_n from products
   where category='fnb' and deleted_at is null
     and sku is distinct from ('FNB-' || subcategory || '-' || split_part(sku, '-', 3));
  v_msg := v_msg || E'\n' || case when v_n=0
    then '⑧ ✅ 每一個貨號的第二段都等於它的子分類'
    else '⑧ 🔴 有 ' || v_n || ' 個貨號與子分類對不上' end;

  /* ⑨ 分頁順序。這一格就是「POS 上五個分頁由左到右長什麼樣」。 */
  select string_agg(label, ' · ' order by sort, code) into v_t
    from product_taxonomy
   where dimension='subcategory' and parent_code='fnb' and is_active;
  v_msg := v_msg || E'\n' || case when v_t = '飲料 · 甜點 · 炸物 · 零嘴 · 主食'
    then '⑨ ✅ POS 分頁順序：' || v_t
    else '⑨ 🔴 順序不對：' || coalesce(v_t,'(空的)') end;

  /* ⑩ 前端拿不到子分類就分不了頁 —— 這一格盯那支 RPC。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='list_products_tx'
     and position('''subcategory''' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || E'\n' || case when v_n=1
    then '⑩ ✅ list_products_tx 會回子分類了（POS 才分得了頁）'
    else '⑩ 🔴 list_products_tx 沒回子分類' end;

  /* ⑪ 正對照：那支同時還要繼續回 spec 與擋掉檯費，
        不要為了加一個鍵而把上一批的成果覆蓋掉。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='list_products_tx'
     and position('''spec''' in pg_get_functiondef(p.oid)) > 0
     and position('SVC-TBL-%' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || E'\n' || case when v_n=1
    then '⑪ ✅ 它原本的兩件事都還在（回 spec ＋ 檯費不入清單）'
    else '⑪ 🔴 覆蓋掉了上一批的成果 —— spec 或檯費過濾不見了' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
