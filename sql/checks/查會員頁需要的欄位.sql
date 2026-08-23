-- 【這是什麼】唯讀：撈 POS 會員頁要用的兩支 RPC 的全文與回傳形狀。
-- 【何時讀】做 POS「會員」頁之前（硬規則 3：不要線上猜欄位名）。
--
-- ═══ 為什麼要做這一頁 ═══
--
-- 🔴 pos_search_members_tx、pos_member_detail_tx、topup_tx **三支都已經存在**，
--    但 POS 只在「開桌結帳頁」裡用得到 ——
--    客人進來只想儲值、或問「我還剩多少點／我的暢打到幾點」，
--    **店員現在得先開一張桌才查得到**。
--    這是後端明明有、櫃檯卻做不到的最典型一個洞。
--
-- ⚠ getMemberDetail() 這個包裝在 api.js:369 已經寫好，但**全專案沒有任何地方呼叫它**。
--   所以它的回傳形狀從來沒有被驗證過 —— 照踩坑第 7 條，
--   「從未成功執行過的函式，它的每一行邏輯都從未被驗證」。
--   要把它接到畫面上之前，先看它到底回什麼。

select 項目, 結果
from (
  select 1 as ord, '① pos_member_detail_tx 全文' as 項目,
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_member_detail_tx' limit 1),
             '❌ 不存在') as 結果

  union all select 2, '② pos_search_members_tx 全文',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_search_members_tx' limit 1),
             '❌ 不存在')

  union all select 3, '③ 實測 pos_member_detail_tx 回傳（挑一位有餘額的會員）',
    coalesce((
      select pos_member_detail_tx(m.org_id, m.id)::text
        from members m
        join wallets w on w.member_id = m.id
       where m.deleted_at is null
       order by w.balance desc nulls last
       limit 1
    ), '（沒有會員資料）')

  union all select 4, '④ 實測 pos_search_members_tx（關鍵字「測試」）',
    coalesce((
      select pos_search_members_tx(o.id, '測試')::text
        from orgs o limit 1
    ), '（查不到 org）')

  union all select 5, '⑤ topup_tx 簽名（儲值要接這支）',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='topup_tx' limit 1),
             '❌ 不存在')

  union all select 6, '⑥ topup_tx 是 DEFINER 嗎（POS 用 anon，必須是）',
    coalesce((select case when prosecdef then '是（DEFINER）' else '❌ INVOKER —— POS 呼叫會被 RLS 擋成 0 列' end
                from pg_proc
               where pronamespace='public'::regnamespace and proname='topup_tx' limit 1),
             '❌ 不存在')

  union all select 7, '⑦ has_daypass_tx 簽名（會員頁要顯示「今天有沒有暢打」）',
    coalesce((select string_agg(pg_get_function_identity_arguments(oid), chr(10))
                from pg_proc
               where pronamespace='public'::regnamespace and proname='has_daypass_tx'),
             '❌ 不存在')

  union all select 8, '⑧ 儲值方案主檔存在嗎（1000 送 150 那種）',
    coalesce((select string_agg(table_name, '、' order by table_name)
                from information_schema.tables
               where table_schema='public'
                 and (table_name ilike '%topup%plan%' or table_name ilike '%recharge%'
                      or table_name ilike '%topup_option%')),
             '（沒有 —— 贈點規則目前是誰在決定？）')
) x
order by ord;

-- ── 讀完之後要決定的 ──────────────────────────────────────
-- 1. ③ 的回傳有哪些鍵，就決定會員頁畫得出什麼（餘額／等級／券／暢打）。
-- 2. ⑤⑥ 決定儲值能不能在這一頁做。
--    ⚠ topup_tx 有 p_bonus_points —— 贈點是**前端算的還是後端算的**？
--      若是前端送，那就跟 checkout_tx 的價格一樣是可竄改的（待辦 2 同一個病）。
-- 3. ⑧ 若沒有儲值方案主檔，「1000 送 150」現在是寫死在哪裡？
--    那會是下一個「同一個規則兩個地方」的候選。
