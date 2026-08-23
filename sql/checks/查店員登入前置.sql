-- 【這是什麼】唯讀：做 POS 店員登入之前，撈 staff 相關的表與四支函式的實況。
-- 【何時讀】動手之前（硬規則 3）。
--
-- ═══ 這題的難處不在畫登入頁 ═══
--
-- 🔴 POS 目前用 **anon key 且沒有 auth session**，所有 RPC 都是 SECURITY DEFINER。
--    而 current_staff() / has_store_access() 這類函式**幾乎一定是靠 auth.uid()**，
--    也就是說：**它們在 POS 現在的呼叫路徑下永遠回 null**。
--    → 先撈全文確認，不要假設「有函式就能用」。
--
-- ⚠ 所以「店員登入」有兩種完全不同的做法，成本差一個數量級：
--
--    【A】真的認證（Supabase Auth）—— 店員有帳號密碼，RLS 自己擋。
--         代價：POS 從 anon 改成 authenticated，所有 DEFINER 的假設要重看，
--         而且會跟待辦 14（會員端 LIFF 換 JWT）撞在一起。
--
--    【B】只做識別（PIN 碼 / 選人）—— 前端記住 staff_id，往每支 RPC 送 p_staff_id。
--         ⚠ **這不是安全機制**，任何人都能宣稱自己是誰。
--         但它解決三件現在真的在痛的事：
--           · updated_by / created_by 全是 null，出事查不到是誰做的
--           · 交班日結不知道是誰的班 → 那一頁做不了
--           · 側邊欄「交班登出」按了沒反應
--
--    ⚠ **B 不是 A 的前置，是另一條路。** 之後要做 A 的話 B 這一層要拆掉重來。
--      所以要先決定，不要「先做 B 之後再說」——
--      那句話在這個專案已經留下過好幾個「建了沒人讀」。

select 項目, 結果
from (
  select 1 as ord, '① staff 相關的表有哪些' as 項目,
    coalesce((select string_agg(table_name, '、' order by table_name)
                from information_schema.tables
               where table_schema='public' and table_name ilike '%staff%'),
             '❌ 沒有 staff 表') as 結果

  union all select 2, '② staff 表欄位',
    coalesce((select string_agg(column_name || ' ' || data_type, '、' order by ordinal_position)
                from information_schema.columns
               where table_schema='public' and table_name='staff'),
             '（沒有 staff 表 —— 看 ① 的實際表名）')

  union all select 3, '③ staff 的角色允許值（CHECK）',
    coalesce((select string_agg(conname || '：' || pg_get_constraintdef(oid), chr(10))
                from pg_constraint
               where conrelid = to_regclass('public.staff')
                 and contype = 'c'),
             '（沒有 CHECK 或表不存在）')

  union all select 4, '④ 目前有幾筆 staff 資料',
    coalesce((select count(*)::text || ' 筆' from staff), '（表不存在或查不到）')

  union all select 5, '⑤ current_staff() 全文　🔴 重點：它靠什麼判斷「我是誰」',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='current_staff' limit 1),
             '❌ 不存在')

  union all select 6, '⑥ has_store_access() 全文',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='has_store_access' limit 1),
             '❌ 不存在')

  union all select 7, '⑦ grant_staff_tx 全文',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='grant_staff_tx' limit 1),
             '❌ 不存在')

  union all select 8, '⑧ 用 anon 身分呼叫時 current_staff() 會回什麼',
    coalesce((select coalesce(current_staff()::text, '(null)')), '(執行失敗)')

  union all select 9, '⑨ auth.uid() 現在是什麼（在 SQL Editor 裡通常是 null 或你的帳號）',
    coalesce(auth.uid()::text, '(null)')

  -- 店員登入之後最直接的用途：這些欄位現在有多少是空的
  union all select 10, '⑩ 有多少筆的 updated_by 是空的（登入要解決的第一件事）',
    coalesce((select 'table_sessions ' ||
                     (select count(*) from table_sessions where updated_by is null)::text || '/' ||
                     (select count(*) from table_sessions)::text ||
                     '　orders ' ||
                     (select count(*) from orders where updated_by is null)::text || '/' ||
                     (select count(*) from orders)::text), '—')

  union all select 11, '⑪ 交班日結會用到的檢視表在不在',
    coalesce((select string_agg(table_name, '、' order by table_name)
                from information_schema.views
               where table_schema='public'
                 and table_name in ('v_order_settlement','v_entity_settlement',
                                    'v_entity_settlement_summary','v_payment_store_mismatch',
                                    'v_wallet_balance_check','v_invoice_pending')),
             '❌ 一張都沒有')

  -- 順帶把牌局編號的答案補完（流水編號那題）
  union all select 20, '⑳ next_doc_no 全文（配桌／牌局要編號的話沿用它）',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='next_doc_no' limit 1),
             '❌ 不存在')

  union all select 21, '㉑ doc_counters 現在有哪些 doc_type',
    coalesce((select string_agg(distinct doc_type, '、') from doc_counters),
             '（沒有資料或表名不同）')
) x
order by ord;

-- ── 讀完之後要拍板的一題 ───────────────────────────────────
-- ⑤ 決定一切：
--   · 若 current_staff() 是靠 auth.uid() → POS 現在的 anon 路徑用不到它，
--     要嘛走 A（真認證），要嘛 B（送 p_staff_id）**完全不碰它**。
--   · 若它另有機制（例如讀 session 變數）→ 可能有第三條路。
--
-- ⚠ 不管走哪條，有一件事現在就可以確定：
--   **POS 的 anon 路徑不能一起壞掉**（硬規則 4）。
--   會員端的 JWT 改造（待辦 14）與 POS 的店員認證是**兩套驗證模型**，
--   它們會從此分家 —— 那不是問題，但要是刻意的分家，不是不小心分開的。
