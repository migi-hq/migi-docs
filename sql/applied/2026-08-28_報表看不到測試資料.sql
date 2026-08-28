/* ============================================================
   目標：總部後台的報表看不到任何 POS 或 WEB 的測試資料
   2026-08-28

   ── 現況（2026-08-28 查證，不是推測）────────────────
   ✅ 根實體的標記是好的：門市 7/7、會員 4/4、訂單 153/153 都是 is_test=true。
   ✅ 旗標放在根實體、下游用 join 推導 —— **那是對的設計**，
     沒有要同步的重複旗標（`order_items` 等不需要自己的 is_test）。

   🔴 但有三個實際漏洞：

   | view | 現在的條件 | 漏洞 |
   |---|---|---|
   | `v_real_orders` | 只看 `orders.is_test` | 不看門市／會員 —— 未來哪條路徑漏設就漏 |
   | `v_real_wallet_txns` | 只看會員 | **不看門市** |
   | `v_real_app_events` | 看 is_test ＋ 會員 | 🔴 **2847 筆通過**（見下） |

   🔴 **而且缺 7 個**：`order_items`／`order_payments`／`topup_orders`／
     `table_sessions`／`session_players`／`invoices`／`match_queues`。
     報表要算品項銷售、付款方式、使用率**只能直接查原表**，一點保護都沒有。

   ── 那 2847 筆是怎麼回事 ────────────────────────────
   2026-08-26 之前，`log_app_event_tx` 只從**會員**推導 `is_test`
   （`app_events` 當時沒有 `store_id`），而 POS 事件的 `member_id` 一律是 null
   → `is_test` 恆為 false。
   ⚠ 而且**改不掉**：`trg_app_events_no_mutate` 同時擋 DELETE 與 UPDATE。

   🔴 **更正（跑完之後用正對照查出來的）**：我一度說「那 2847 筆會原樣通過」，
     **那是錯的**。舊 view 本來就有「會員是測試」那一道，擋掉 2845 筆，
     **實際漏出去的只有 2 筆**：
         2026-07-13  test_event  門市=null 會員=null  {"ok": true}
         2026-08-19  app_error   門市=null 會員=null  "Script error."
     ⚠ 兩筆都**沒有門市也沒有會員** —— 任何關聯都認不出它們是測試。
     那正是第三層唯一擋得住、前兩層永遠擋不住的那一類。
     → 所以這支 SQL 仍然該做，只是**它修的洞比我原本說的小**。

   ── 🎯 解法：加第三層「時間下限」──────────────────
   前兩層（根實體 is_test、自己的 is_test）都**依賴標記被正確設定**，
   而歷史已經證明那會壞 —— 那 2847 筆就是證據。

   → 加一個**不依賴任何標記**的防線：

       orgs.live_from   營運起始時間（null = 還沒上線）

   每個 view 都加 `created_at >= coalesce(o.live_from, 'infinity')`。

   🎯 **關鍵在那個 `'infinity'`：沒設定 = 什麼都不算營運資料。**
     所以忘記設的後果是「**報表全空**」，不是「**報表錯的**」。
   ⚠ 這跟這個專案一再踩的坑正好相反 —— `is_test` 恆為 false、
     RLS 濾成空陣列、`|| []` 讓數字通過，全都是「壞掉了但看起來正常」。
     **這個設計刻意讓失敗吵。** 同 Postgres RLS 的哲學：預設拒絕，逐條開。

   ── 為什麼現在做而不是上線後 ────────────────────────
   **那五個 view 現在沒有任何報表在用**（migi-admin 還沒有報表頁），
   而且查證過**它們一個授權都沒有**（只有 service_role／Dashboard 讀得到）。
   > 改一個沒人用的東西是免費的；改一個有人用的東西要協調。

   ── 子表直接引用父表的 view ────────────────────────
   `order_items` / `order_payments` / `session_players` 不自己寫過濾條件，
   而是 `exists (select 1 from v_real_orders ...)`。
   🎯 **規則只定義一次，不可能漂。**
   ⚠ 代價是 view-on-view 的查詢計畫較複雜 —— 這個資料量無關緊要。

   ── 刻意不做 ────────────────────────────────────────
   · **per-store 的 `live_from`** —— 七間店不會同一天開，理論上該放 `stores`。
     但 `app_events.store_id` 可以是 null（08-26 才補），那些事件歸不了店。
     **等第二間店開幕再說。**
   · **回頭標記那 2847 筆** —— 改不掉，也不需要：時間下限自然把它們擋在外面。
   · **撤銷報表角色對原表的 SELECT** —— 那需要角色系統（待辦 20／29），
     現在沒有人有身分可以被限制。
   ============================================================ */

-- ── 一、營運起始時間 ────────────────────────────────
alter table public.orgs
  add column if not exists live_from timestamptz;

comment on column public.orgs.live_from is
  '營運起始時間。null = 還沒上線 → 所有 v_real_* 一律回 0 列（預設拒絕）。
   上線當天設定它。⚠ 不要拿它當「修 bug 的日期」—— 它是「真實客人開始使用」的時間。';

/* ── 二、重建 12 個 v_real_* ──────────────────────────
   ⚠ 五個既有的 view 一個授權都沒有（查證過），所以 DROP 重建不會弄丟東西。
   ⚠ 用 DROP 而不是 CREATE OR REPLACE：後者要求欄位清單是舊的前綴，
     而表加過欄位，硬要相容反而容易出錯。 */

drop view if exists public.v_real_session_players;
drop view if exists public.v_real_order_items;
drop view if exists public.v_real_order_payments;
drop view if exists public.v_real_invoices;
drop view if exists public.v_real_topup_orders;
drop view if exists public.v_real_wallet_txns;
drop view if exists public.v_real_app_events;
drop view if exists public.v_real_match_queues;
drop view if exists public.v_real_orders;
drop view if exists public.v_real_table_sessions;
drop view if exists public.v_real_members;
drop view if exists public.v_real_stores;

-- ── 根實體 ──────────────────────────────────────────

create view public.v_real_stores as
select s.*
  from public.stores s
  join public.orgs o on o.id = s.org_id
 where s.is_test = false
   and s.deleted_at is null
   and s.created_at >= coalesce(o.live_from, 'infinity'::timestamptz);

create view public.v_real_members as
select m.*
  from public.members m
  join public.orgs o on o.id = m.org_id
 where m.is_test = false
   and m.deleted_at is null
   and m.created_at >= coalesce(o.live_from, 'infinity'::timestamptz);

-- ── 交易 ────────────────────────────────────────────

create view public.v_real_orders as
select x.*
  from public.orders x
  join public.orgs o on o.id = x.org_id
 where not coalesce(x.is_test, false)
   and x.deleted_at is null
   and x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
   -- ★ 補上門市與會員：原本只看 orders.is_test，未來哪條路徑漏設就漏
   and not exists (select 1 from public.stores s  where s.id = x.store_id  and s.is_test)
   and not exists (select 1 from public.members m where m.id = x.member_id and m.is_test);

create view public.v_real_order_items as
select x.*
  from public.order_items x
 where exists (select 1 from public.v_real_orders ro where ro.id = x.order_id);

create view public.v_real_order_payments as
select x.*
  from public.order_payments x
 where exists (select 1 from public.v_real_orders ro where ro.id = x.order_id);

create view public.v_real_topup_orders as
select x.*
  from public.topup_orders x
  join public.orgs o on o.id = x.org_id
 where x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
   and not exists (select 1 from public.stores s  where s.id = x.store_id  and s.is_test)
   and not exists (select 1 from public.members m where m.id = x.member_id and m.is_test);

create view public.v_real_wallet_txns as
select x.*
  from public.wallet_txns x
  join public.orgs o on o.id = x.org_id
 where x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
   -- ★ 補上門市：原本只看會員
   and not exists (select 1 from public.stores s  where s.id = x.store_id  and s.is_test)
   and not exists (select 1 from public.members m where m.id = x.member_id and m.is_test);

create view public.v_real_invoices as
select x.*
  from public.invoices x
  join public.orgs o on o.id = x.org_id
 where x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
   and not exists (select 1 from public.stores s where s.id = x.store_id and s.is_test);

-- ── 桌與配桌 ────────────────────────────────────────

create view public.v_real_table_sessions as
select x.*
  from public.table_sessions x
  join public.orgs o on o.id = x.org_id
 where not coalesce(x.is_test, false)
   and x.deleted_at is null
   and x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
   and not exists (select 1 from public.stores s where s.id = x.store_id and s.is_test);

create view public.v_real_session_players as
select x.*
  from public.session_players x
 where exists (select 1 from public.v_real_table_sessions rs where rs.id = x.session_id)
   and not exists (select 1 from public.members m where m.id = x.member_id and m.is_test);

create view public.v_real_match_queues as
select x.*
  from public.match_queues x
  join public.orgs o on o.id = x.org_id
 where x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)
   and not exists (select 1 from public.stores s where s.id = x.store_id and s.is_test);

-- ── 埋點 ────────────────────────────────────────────

create view public.v_real_app_events as
select x.*
  from public.app_events x
  join public.orgs o on o.id = x.org_id
 where x.is_test = false
   and x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)   -- ★ 這一層擋掉那 2847 筆
   and not exists (select 1 from public.stores s  where s.id = x.store_id  and s.is_test)
   and not exists (select 1 from public.members m where m.id = x.member_id and m.is_test);

/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① ✅ 欄位在，而且**是 null**（還沒上線）
   ② 12 個 view 都在
   ③ 🎯 **每一個都回 0 列** —— 那就是「預設拒絕」生效的證據。
      🔴 有任何一個不是 0，就是那個 view 漏掉了時間下限。
   ④ 原表的列數（對照用，證明資料還在、只是被擋在 view 外面）

   ── 🔴 但 ③ 一個人驗不完：一定要跑「正對照」──────────
   **「全部 0 列」同時是「正確阻擋」與「view 寫壞了」的症狀 ——
     兩者長得一模一樣。**
   → 跑完之後必須再跑一次「把時間下限換成很早的日期」的查詢，
     確認 view 的其他條件是好的（`app_events` 應該冒出 2 列、
     `orders` 應該仍是 0 因為 153 筆全是測試）。
   ⚠ 只驗「應該是 0」的那一半，等於沒驗 ——
     2026-08-28 就是靠正對照才發現我把漏出的筆數說成 2847（實際是 2）。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① orgs.live_from' as 項目,
         (select case when count(*) = 0 then '🔴 欄位沒建成功'
                      else '✅ 欄位在　目前值：' ||
                           coalesce((select string_agg(coalesce(live_from::text,'null'), '　') from orgs),
                                    '(沒有 org)') end
            from information_schema.columns
           where table_schema='public' and table_name='orgs' and column_name='live_from') as 內容

  union all
  select 2, '② v_real_* 檢視表',
         (select count(*)::text || ' 個：' || string_agg(c.relname, '　' order by c.relname)
            from pg_class c
           where c.relnamespace='public'::regnamespace and c.relkind='v'
             and c.relname like 'v_real%')

  union all
  /* ③ 這是重點。live_from 還沒設 → 每一個都必須是 0 列。 */
  select 3, '③ live_from 未設時，每個 view 的列數（全部必須是 0）',
         (select 'stores '          || (select count(*) from v_real_stores)::text ||
                 '　members '       || (select count(*) from v_real_members)::text ||
                 '　orders '        || (select count(*) from v_real_orders)::text ||
                 '　order_items '   || (select count(*) from v_real_order_items)::text ||
                 '　order_payments '|| (select count(*) from v_real_order_payments)::text ||
                 '　topup_orders '  || (select count(*) from v_real_topup_orders)::text ||
                 '　wallet_txns '   || (select count(*) from v_real_wallet_txns)::text ||
                 '　invoices '      || (select count(*) from v_real_invoices)::text ||
                 '　table_sessions '|| (select count(*) from v_real_table_sessions)::text ||
                 '　session_players '|| (select count(*) from v_real_session_players)::text ||
                 '　match_queues '  || (select count(*) from v_real_match_queues)::text ||
                 '　app_events '    || (select count(*) from v_real_app_events)::text)

  union all
  select 4, '④ 原表列數（對照：資料還在，只是被擋在 view 外面）',
         (select 'orders '          || (select count(*) from orders)::text ||
                 '　order_items '   || (select count(*) from order_items)::text ||
                 '　wallet_txns '   || (select count(*) from wallet_txns)::text ||
                 '　table_sessions '|| (select count(*) from table_sessions)::text ||
                 '　app_events '    || (select count(*) from app_events)::text)

) x order by 序;
