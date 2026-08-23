-- 【這是什麼】唯讀盤點：要讓 POS 開桌時能掛「新手友善／網紅在這桌／職業選手桌」之前，
--             先撈 match_queues.tags 的實際型別、三支相關 RPC 的全文、以及現有資料。
-- 【何時讀】動 pos_create_queue_tx 之前（硬規則 3：改既有函式一律先撈線上版）。
--
-- ═══ 這題真正的風險：安靜失敗 ═══
--
-- 🔴 會員 App 的 QUEUE_TAGS 是**寫死的白名單**（migi-web match.jsx:69），
--    只有 newbie / influencer / pro 三個 key，而且 render 時會 filter 掉不認識的：
--        tags.filter((t) => QUEUE_TAGS[t])
--    所以 POS 只要寫進一個 App 沒有的代碼，**客人端什麼都不顯示、也不報錯**。
--    店員以為掛好了、客人什麼都沒看到 —— 這是最難查的那種 bug。
--
--    → 所以「清單放哪裡」不是潔癖問題，是這個功能會不會靜靜失效的問題。
--      兩個選項見檔尾。

select 項目, 結果
from (
  select 1 as ord, '① match_queues.tags 的型別與預設' as 項目,
    coalesce((select data_type
                || case when udt_name is not null then '（' || udt_name || '）' else '' end
                || '　可為 null：' || is_nullable
                || '　預設：' || coalesce(column_default, '(無)')
                from information_schema.columns
               where table_schema='public' and table_name='match_queues' and column_name='tags'),
             '❌ 沒有 tags 這個欄位') as 結果

  union all select 2, '② tags 上有沒有 CHECK 約束（限制可用值）',
    coalesce((select string_agg(conname || '：' || pg_get_constraintdef(oid), chr(10))
                from pg_constraint
               where conrelid = 'public.match_queues'::regclass
                 and pg_get_constraintdef(oid) ilike '%tags%'),
             '（沒有 —— 代表任何字串都寫得進去）')

  union all select 3, '③ pos_create_queue_tx 簽名',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_create_queue_tx' limit 1),
             '❌ 不存在')

  union all select 4, '④ pos_create_queue_tx 全文',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_create_queue_tx' limit 1),
             '❌ 不存在')

  union all select 5, '⑤ pos_list_queues_tx 有沒有回傳 tags（POS 卡片要顯示就得有）',
    coalesce((select case when pg_get_functiondef(oid) ilike '%''tags''%' then '有' else '❌ 沒有回傳' end
                from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_list_queues_tx' limit 1),
             '❌ 函式不存在')

  union all select 6, '⑥ list_match_queues_tx 有沒有回傳 tags（會員端列表要顯示就得有）',
    coalesce((select case when pg_get_functiondef(oid) ilike '%''tags''%' then '有' else '❌ 沒有回傳' end
                from pg_proc
               where pronamespace='public'::regnamespace and proname='list_match_queues_tx' limit 1),
             '❌ 函式不存在')

  -- ⚠ tags 是 jsonb 不是 text[]（2026-08-23 實測 unnest(jsonb) 不存在才確認的）
  -- ⚠ 展開要用 LATERAL，不能把 jsonb_array_elements_text 直接寫在 select 清單裡
  --   跟 count(*) 並列 —— 集合回傳函式不能出現在聚合的同一層。
  -- ⚠ jsonb_typeof 的檢查不能省：這個欄位也可能裝物件或字串，
  --   那時 jsonb_array_elements_text 會直接拋錯而不是回空。
  union all select 7, '⑦ 現在資料庫裡實際出現過哪些 tag 值',
    coalesce((select string_agg(t || '　×' || n::text, chr(10) order by n desc)
                from (select tg.t, count(*) n
                        from match_queues m
                        cross join lateral jsonb_array_elements_text(m.tags) as tg(t)
                       where m.tags is not null
                         and jsonb_typeof(m.tags) = 'array'
                       group by tg.t) x),
             '（目前沒有任何一房有掛標籤）')

  -- 存進去的到底是不是陣列。若出現 object / string，代表某個寫入端形狀不一致，
  -- 那會在 App 端 render 時炸掉或靜靜不顯示。
  union all select 7.5, '⑦-2 tags 的 json 型別分佈（應該只有 array 與 null）',
    coalesce((select string_agg(tt || ' × ' || n::text, '、' order by n desc)
                from (select coalesce(jsonb_typeof(tags), 'null（欄位是空的）') as tt, count(*) n
                        from match_queues group by 1) y),
             '（沒有資料）')

  union all select 8, '⑧ 有沒有現成的標籤主檔表',
    coalesce((select string_agg(table_name, '、' order by table_name)
                from information_schema.tables
               where table_schema='public'
                 and (table_name ilike '%queue_tag%' or table_name ilike '%tag%')),
             '（沒有 —— 目前清單只寫死在 migi-web 的 QUEUE_TAGS）')

  union all select 9, '⑨ recurring_tables（固定牌局範本）有沒有 tags',
    coalesce((select case when count(*) > 0 then '有' else '❌ 沒有' end
                from information_schema.columns
               where table_schema='public' and table_name='recurring_tables' and column_name='tags'),
             '❌ 表不存在')
) x
order by ord;

-- ── 讀完之後要決定的事：清單放哪裡 ─────────────────────────
--
-- 【A 案】兩端各自寫死（POS 加一份，跟 migi-web 的 QUEUE_TAGS 一樣）
--   ✅ 零 migration、最快
--   🔴 代價：**兩份會漂**。加第四個標籤要改兩個 repo、部署兩次，
--      漏掉會員端那次的結果是「店員掛了，客人看不到，沒有錯誤訊息」。
--      這正是 CLAUDE.md 踩坑第 29 條那個形狀。
--
-- 【B 案】建 queue_tags 主檔（code / label / sort_order / is_active）
--         + list_queue_tags_tx()，POS 讀它畫 chip、會員端讀它顯示文字
--   ✅ 加標籤變成改資料，不用部署；兩端**不可能**不同步
--   ✅ 這是主檔真正該存在的情況：**一端寫、另一端讀**
--      （對照 product_taxonomy 的教訓 —— 那張建了卻只有 migi-admin 讀，
--        才是「建了沒人讀」。這裡兩端都會讀。）
--   ⚠ 代價：多兩處 RPC 串接，會員端也要改成讀主檔而不是查 QUEUE_TAGS
--
-- ⚠ 不管哪一案，**標籤都不是必選** —— 開桌不填就是沒有標籤，
--   不要給預設值。標籤是「這桌有什麼特色」，多數桌沒有特色是正常的。
