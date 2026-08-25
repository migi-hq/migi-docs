/* ============================================================
   查：快速結帳（session-less 結帳）的後端缺口
   2026-08-25 · 唯讀，不改任何東西

   要回答的問題：
     一筆「沒有桌次」的訂單，資料庫收不收？
     不收的話，卡在哪個欄位／約束／觸發器？

   ⚠ 判斷線上有沒有某個東西，只有 information_schema / pg_proc /
     pg_constraint 算數（硬規則 3）。檔案與文件都是二手傳聞。
   ============================================================ */

with

/* ① 三張訂單表裡「必須給值」的欄位
      = NOT NULL 且沒有預設值。session-less 插入時每一個都得有來源。
      特別看 session_id / member_id / table_id 在不在這張名單上。 */
must_fill as (
  select
    1 as 序,
    '① ' || table_name || ' 必須給值' as 區塊,
    column_name as 項目,
    data_type as 內容
  from information_schema.columns
  where table_schema = 'public'
    and table_name in ('orders', 'order_items', 'order_payments')
    and is_nullable = 'NO'
    and column_default is null
),

/* ② 關鍵欄位的可空性 —— 這四格直接決定做不做得到
      orders.session_id  null → 訂單可以不掛桌
      orders.member_id   null → 可以匿名結帳
      topup_orders.session_id 已知應為可空（2026-08-16 加的） */
key_cols as (
  select
    2 as 序,
    '② 關鍵欄位可空性' as 區塊,
    table_name || '.' || column_name as 項目,
    (case when is_nullable = 'YES' then '✅ 可為 null' else '🔴 NOT NULL — 擋住' end)
      || coalesce('　預設 ' || column_default, '') as 內容
  from information_schema.columns
  where table_schema = 'public'
    and (
      (table_name = 'orders'        and column_name in ('session_id','member_id','table_id','store_id','org_id','staff_id')) or
      (table_name = 'topup_orders'  and column_name in ('session_id','member_id')) or
      (table_name = 'invoices'      and column_name in ('order_id','member_id'))
    )
),

/* ③ orders 上的 CHECK 約束
      可能有「session_id 與 table_id 必須同時有或同時無」這類跨欄約束。 */
checks as (
  select
    3 as 序,
    '③ orders CHECK 約束' as 區塊,
    c.conname as 項目,
    pg_get_constraintdef(c.oid) as 內容
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public' and t.relname = 'orders' and c.contype = 'c'
),

/* ④ orders 的外鍵
      session_id 指向 table_sessions 的話，給 null 是否被允許看 ②。 */
fks as (
  select
    4 as 序,
    '④ orders 外鍵' as 區塊,
    c.conname as 項目,
    pg_get_constraintdef(c.oid) as 內容
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public' and t.relname = 'orders' and c.contype = 'f'
),

/* ⑤ orders 上的觸發器
      trg_orders_set_no 會呼叫 next_doc_no(org, store, 'order')；
      它需要 store_id —— 沒有桌次時 store_id 從哪來要想清楚。 */
trgs as (
  select
    5 as 序,
    '⑤ orders 觸發器' as 區塊,
    tg.tgname as 項目,
    pg_get_triggerdef(tg.oid) as 內容
  from pg_trigger tg
  join pg_class t on t.oid = tg.tgrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public' and t.relname = 'orders' and not tg.tgisinternal
),

/* ⑥ 結帳相關函式的完整簽名（含預設值）
      看 p_session_id 有沒有 DEFAULT —— 有的話也許已經可以不傳。 */
fns as (
  select
    6 as 序,
    '⑥ 結帳函式簽名' as 區塊,
    p.proname as 項目,
    '(' || pg_get_function_arguments(p.oid) || ')' as 內容
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('checkout_tx','join_session_tx','pos_addon_checkout_tx',
                      'pos_checkout_with_topup_tx','topup_tx','create_invoice_draft_tx')
),

/* ⑦ 這些函式的內文有沒有「非碰桌次不可」的地方
      有引用 table_sessions / session_players，就代表不能直接拿來用。 */
fn_body as (
  select
    7 as 序,
    '⑦ 函式內文是否綁桌次' as 區塊,
    p.proname as 項目,
    (case when pg_get_functiondef(p.oid) ilike '%table_sessions%' then '引用 table_sessions　' else '' end) ||
    (case when pg_get_functiondef(p.oid) ilike '%session_players%' then '引用 session_players　' else '' end) ||
    (case when pg_get_functiondef(p.oid) not ilike '%table_sessions%'
            and pg_get_functiondef(p.oid) not ilike '%session_players%'
          then '✅ 完全不碰桌次' else '' end) ||
    '　securit' || (case when p.prosecdef then 'y DEFINER' else 'y INVOKER 🔴' end) as 內容
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('checkout_tx','join_session_tx','pos_addon_checkout_tx',
                      'pos_checkout_with_topup_tx','topup_tx')
),

/* ⑧ 現有資料：已經有沒掛桌次／沒掛會員的訂單嗎
      有的話代表這條路本來就走得通，不是全新的形狀。 */
data as (
  select 8 as 序, '⑧ 現有 orders 資料' as 區塊, '總筆數' as 項目, count(*)::text as 內容 from orders
  union all
  select 8, '⑧ 現有 orders 資料', 'session_id 為 null',
         count(*) filter (where session_id is null)::text from orders
  union all
  select 8, '⑧ 現有 orders 資料', 'member_id 為 null',
         count(*) filter (where member_id is null)::text from orders
  union all
  select 8, '⑧ 現有 orders 資料', 'topup_orders 總筆數', count(*)::text from topup_orders
  union all
  select 8, '⑧ 現有 orders 資料', 'topup_orders session_id 為 null',
         count(*) filter (where session_id is null)::text from topup_orders
)

select 區塊, 項目, 內容
from (
  select * from must_fill
  union all select * from key_cols
  union all select * from checks
  union all select * from fks
  union all select * from trgs
  union all select * from fns
  union all select * from fn_body
  union all select * from data
) x
order by 序, 區塊, 項目;
