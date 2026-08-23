-- 【這是什麼】唯讀盤點：系統裡現在有沒有「人看得懂的流水編號」，在哪幾張表上。
-- 【何時讀】決定「配桌成功要不要給編號」之前。
--
-- ⚠ 為什麼一定要先查：**加第二套編號是這題最糟的結果。**
--    如果 orders 已經有單號、table_sessions 又生一組，那客訴時店員手上會有兩個號碼，
--    而且不知道該報哪一個；報表也會出現兩個都叫「編號」的欄位。
--    寧可讓既有的那一套多蓋一層，也不要並存兩套。
--    （這正是 2026-08-16 的商品分類問題：同一個概念四種拼法。）

select 項目, 結果
from (
  -- ① 哪些表已經有疑似「單號 / 編號 / 序號」的欄位
  select 1 as ord, '① 疑似編號欄位（全庫掃描）' as 項目,
    coalesce((select string_agg(table_name || '.' || column_name || '　' || data_type
                                || case when column_default like 'nextval%' then '　←有序列' else '' end,
                                chr(10) order by table_name, column_name)
                from information_schema.columns
               where table_schema = 'public'
                 and (column_name ~ '(^|_)(no|num|number|code|seq|serial|ref)$'
                      or column_name ~ '(order_no|invoice_no|receipt|display_id|short_id)')
             ), '（一個都沒有）') as 結果

  -- ② 資料庫裡現有的序列（sequence）
  union all select 2, '② 現有 sequence',
    coalesce((select string_agg(sequencename || '　目前 ' ||
                                coalesce(last_value::text, '未使用'), chr(10) order by sequencename)
                from pg_sequences where schemaname = 'public'),
             '（沒有任何 sequence）')

  -- ③ 這三張表現在到底有哪些欄位（決定加在哪一張）
  union all select 3, '③ table_sessions 欄位',
    coalesce((select string_agg(column_name, '、' order by ordinal_position)
                from information_schema.columns
               where table_schema='public' and table_name='table_sessions'), '（表不存在）')

  union all select 4, '④ match_queues 欄位',
    coalesce((select string_agg(column_name, '、' order by ordinal_position)
                from information_schema.columns
               where table_schema='public' and table_name='match_queues'), '（表不存在）')

  union all select 5, '⑤ orders 欄位',
    coalesce((select string_agg(column_name, '、' order by ordinal_position)
                from information_schema.columns
               where table_schema='public' and table_name='orders'), '（表不存在）')

  -- ⑥ 發票已經有字軌配號的設計嗎（那是法規要求的另一套號，不能混用）
  union all select 6, '⑥ invoices 欄位（發票號是法規的另一套，不可混用）',
    coalesce((select string_agg(column_name, '、' order by ordinal_position)
                from information_schema.columns
               where table_schema='public' and table_name='invoices'), '（表不存在）')

  -- ⑦ 現在總共累積多少筆牌局與配桌房（決定編號要幾位數、要不要分店分日）
  union all select 7, '⑦ 目前資料量（決定號碼要幾位數）',
    coalesce((select 'table_sessions ' || (select count(*) from table_sessions)::text || ' 筆'
                  || '　/　match_queues ' || (select count(*) from match_queues)::text || ' 筆'
                  || '　/　orders ' || (select count(*) from orders)::text || ' 筆'), '—')

  -- ⑧ 幾間門市（決定要不要把門市碼放進號碼）
  union all select 8, '⑧ 門市數（決定要不要分店編號）',
    coalesce((select count(*)::text || ' 間：' || string_agg(name, '、' order by name)
                from stores where deleted_at is null), '—')

  -- ⑨ 冪等鍵長什麼樣（既有的「同一次操作」識別方式，可能已經夠用）
  union all select 9, '⑨ 既有冪等鍵欄位',
    coalesce((select string_agg(table_name || '.' || column_name, chr(10) order by table_name)
                from information_schema.columns
               where table_schema='public' and column_name ilike '%idem%'),
             '（沒有）')
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
--
-- ① 若 orders 已經有 order_no 之類的欄位 → **不要再加第二套**，
--    改成讓牌局沿用它，或把牌局編號設計成「能推導出 orders」的關係。
--
-- ② 若完全沒有 → 建議加在 **table_sessions**，理由：
--    - 「配桌成功」在資料上就是「產生了一個 table_sessions」，兩者同一個時刻
--    - POS 直接開的桌也需要同一個號（同樣要追蹤、同樣會被客訴），
--      編在 session 上就自然涵蓋兩種來源，不會長出兩套號
--    - match_queues.matched_session_id 已經是橋，給了 session 號就查得到那一房
--    ⚠ 代價：**沒湊成的配桌房不會有號。** 若之後要追「為什麼一直配不到」，
--      那是另一個問題（要查的是 match_queues 的存活與過期），不靠流水號解決。
--
-- ③ 號碼格式建議 **全域遞增、不要塞語意**（門市碼 / 日期 / 每日重來）：
--    - 每日每店重來的號要嘛靠 count(*)（會撞號），要嘛靠計數表（要鎖，且會成為熱點）
--    - Shopify 的 order_number 就是每個商店一條全域遞增，日期與門市從那一列自己讀
--    - 語意塞進號碼裡，改天多開一間店、或跨日的長桌，號碼就會開始說謊
--    → 用 sequence 拿 bigint，顯示成 `#001234`，門市與日期在卡片上另外顯示
