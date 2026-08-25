/* ============================================================
   查：會員查詢下一批（牌咖 / 互黑 / 常來時段 / 常加購 / 備註）
   2026-08-25 · 唯讀

   五項要補的東西，四項的資料**應該**已經存在，一項要新欄位。
   動手前先確認每一項的實際形狀 —— 猜錯的成本遠高於多問一次（硬規則 3）。

   ⚠ 文件先讀過了，兩條會影響做法：
     · M2技術設計:465「配桌不做合拍度顯示，合拍度只後台用，
       **不在客人前端出現**」→ POS 是平板、客人看得到螢幕，
       所以只顯示牌咖**名單**，不顯示分數。
     · M2技術設計:199 拉黑分「不合拍型／行為問題型」
       → 互黑**只出現警示、不出現對方名字**。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 牌咖：表在不在、有幾列、欄位長什麼樣 */
  select 1 as 序, '① 牌咖／互黑相關表' as 項目,
         c.relname || '　約 ' ||
         (case when c.reltuples < 0 then '未統計' else c.reltuples::bigint::text end) || ' 列' as 內容
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and (c.relname ilike '%buddy%' or c.relname ilike '%buddies%'
       or c.relname ilike '%block%' or c.relname ilike '%availab%'
       or c.relname ilike '%interaction%' or c.relname ilike '%note%')

  union all
  /* ② 那些表的欄位 —— 要知道方向性（誰加誰）、狀態、時間 */
  select 2, '② ' || table_name || ' 欄位',
         string_agg(column_name || ' ' || data_type ||
                    (case when is_nullable = 'NO' then '*' else '' end), '　'
                    order by ordinal_position)
    from information_schema.columns
   where table_schema = 'public'
     and (table_name ilike '%buddy%' or table_name ilike '%buddies%'
       or table_name ilike '%block%' or table_name ilike '%availab%')
   group by table_name

  union all
  /* ③ members 有沒有可以放備註的欄位（沒有的話要新增） */
  select 3, '③ members 可放備註的欄位',
         coalesce((select string_agg(column_name || ' ' || data_type, '　')
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'members'
                      and (column_name ilike '%note%' or column_name ilike '%memo%'
                        or column_name ilike '%remark%' or column_name ilike '%comment%')),
                  '🔴 沒有 —— 備註要新增欄位或新表')

  union all
  /* ④ 常來時段：get_my_availability_tx 的簽名（會員 App 在用） */
  select 4, '④ 常來時段 RPC',
         coalesce((select p.proname || '(' || pg_get_function_arguments(p.oid) || ')'
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f'
                      and p.proname in ('get_my_availability_tx','set_my_availability_tx')
                    order by p.proname limit 1), '🔴 不存在')

  union all
  /* ⑤ 常加購品項：order_items 有沒有足夠的欄位可以聚合
        （要 product_id、name、revenue_type、qty，並且能連回 member） */
  select 5, '⑤ order_items 欄位',
         string_agg(column_name, '　' order by ordinal_position)
    from information_schema.columns
   where table_schema = 'public' and table_name = 'order_items'

  union all
  /* ⑥ 實際試算一次「常加購品項」——
        排除檯費（venue_fee），只看已付款的單，看得出來有沒有東西可讀。
        ⚠ 硬規則 7 的精神：先確認資料算得出來，再決定怎麼包成 RPC。 */
  select 6, '⑥ 試算：全店最常加購的品項',
         coalesce(string_agg(t.nm || ' ×' || t.q::text, '、' order by t.q desc), '（沒有資料）')
    from (select oi.name as nm, sum(oi.qty) as q
            from order_items oi
            join orders o on o.id = oi.order_id
           where o.status = 'paid'
             and oi.revenue_type <> 'venue_fee'
           group by oi.name
           order by 2 desc
           limit 5) t

  union all
  /* ⑦ 互黑：check_session_blocks_tx 的簽名 —— 它要 session_id 的話，
        在會員查詢（沒有桌次）就叫不動，要另一支或改它。 */
  select 7, '⑦ 互黑 RPC 簽名',
         coalesce((select string_agg(p.proname || '(' || pg_get_function_arguments(p.oid) || ')', '　│　')
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f'
                      and (p.proname ilike '%block%')),
                  '🔴 沒有任何 block 相關函式')

  union all
  /* ⑧ 牌咖 RPC：會員 App 用的那幾支叫什麼、要什麼參數 */
  select 8, '⑧ 牌咖 RPC 簽名',
         coalesce((select string_agg(p.proname || '(' || pg_get_function_arguments(p.oid) || ')', '　│　'
                                     order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f'
                      and (p.proname ilike '%budd%' or p.proname ilike '%recent_player%')),
                  '🔴 沒有')

  union all
  /* ⑨ member_interactions 的實際欄位 —— 這是關鍵。
        整合系統開發藍圖:365「不管 MA 自動發或店員手動發，
        **全寫進同一張互動紀錄**」。
        所以「店員備註」不該是 members 的自由欄位，而是這張表的一列。
        要知道它有沒有：類型、內容、作者、時間、以及跟 MA 區分的欄位。 */
  select 9, '⑨ member_interactions 欄位',
         coalesce((select string_agg(column_name || ' ' || data_type ||
                                     (case when is_nullable = 'NO' then '*' else '' end),
                                     '　' order by ordinal_position)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'member_interactions'),
                  '🔴 表不存在 —— 藍圖說 Day 1 已在，那句是錯的')

  union all
  /* ⑩ member_interactions 的 kind 有哪些值（CHECK 約束）
        ⚠ CLAUDE.md 記過：kind 這個欄位在六張表有六種意思。
          這裡要的是「互動類型」那一種，不要跟商品分類搞混。 */
  select 10, '⑩ member_interactions 約束',
         coalesce((select string_agg(c.conname || '　' || pg_get_constraintdef(c.oid), '　│　')
                     from pg_constraint c
                     join pg_class t on t.oid = c.conrelid
                    where t.relnamespace = 'public'::regnamespace
                      and t.relname = 'member_interactions' and c.contype = 'c'),
                  '（沒有 CHECK 約束）')

  union all
  /* ⑪ 藍圖說「結構（RFM/lifecycle/interactions/availability）Day 1 已在」——
        但 01-資料庫/ 的文件只找得到 member_interactions。
        文件不是鏡像（硬規則 3），只有這個查詢算數。 */
  select 11, '⑪ RFM／lifecycle 相關表',
         coalesce((select string_agg(c.relname, '　' order by c.relname)
                     from pg_class c
                    where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
                      and (c.relname ilike '%rfm%' or c.relname ilike '%lifecycle%'
                        or c.relname ilike '%segment%' or c.relname ilike '%campaign%'
                        or c.relname ilike '%rating%' or c.relname ilike '%availability%')),
                  '🔴 一張都沒有')

  union all
  /* ⑫ members 上有沒有 RFM / lifecycle / 指派店員的欄位 */
  select 12, '⑫ members 的 CRM 欄位',
         coalesce((select string_agg(column_name || ' ' || data_type, '　'
                                     order by column_name)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'members'
                      and (column_name ilike '%rfm%' or column_name ilike '%lifecycle%'
                        or column_name ilike '%staff%' or column_name ilike '%segment%'
                        or column_name ilike '%tag%' or column_name ilike '%last_%'
                        or column_name ilike '%visit%')),
                  '🔴 一個都沒有')

  union all
  /* ⑬ 行銷黃金訊號：match_queues.status = 'expired' 的房
        =「某人在某時段想打，但沒湊到人」（會員情報體系.md）
        「成功的配桌是營收，失敗的配桌是情報」——
        先看有沒有在累積，沒有的話那個訊號現在是空的。 */
  select 13, '⑬ match_queues 依 status',
         q.status || '：' || count(*)::text || ' 房'
    from match_queues q group by q.status

) x order by 序, 項目;
