# MIGI 資料庫現況快照

> 產生日期：2026-08-14
> 來源：Supabase Dashboard 唯讀盤點查詢（pg_proc / pg_class / pg_constraint / information_schema）
> 用途：符合 CLAUDE.md 硬規則 3 —— 動 RPC / schema 前先讀這份，不要線上猜欄位名稱或約束值。
> 這份是**當時的快照**，改過 schema 後要重跑盤點更新，不然它會慢慢失真。

---

## ⚠️ 最容易踩的坑：`void` 還是 `voided`？

**不同表用不同值，沒有統一。** 這是已經害過一次的地方（`dev_reset_test_data_tx` 寫錯）。

| 表 | 作廢狀態值 | 完整允許值 |
|---|---|---|
| `table_sessions.status` | **`voided`** | `open` / `completed` / `voided` |
| `orders.status` | `void` | `open` / `preparing` / `served` / `paid` / `void` |
| `topup_orders.status` | `void` | `pending` / `paid` / `void` / `refunded` |
| `invoices.status` | `void` | `pending` / `issued` / `void` / `failed` |

**只有 `table_sessions` 用 `voided`，其餘一律 `void`。** 寫 SQL 前先回來看這張表。

---

## 已知待修問題

### 1. `leave_match_queue_tx` 有多載版本（硬規則 2 被違反過）

```
leave_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid)            ← 舊版，孤兒
leave_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_reason text)  ← 新版，實際使用中
```

`migi-web/src/lib/social.js` 的 `leaveMatchQueue()` 一律傳四個具名參數，
PostgREST 依參數名解析，只會打到新版；全專案無其他呼叫點。
→ 舊版可安全刪除，見 `sql/pending/2026-08-14_drop_leave_match_queue_overload.sql`

### 2. `members` 兩條 tier CHECK 互相打架

```
members_tier_check  → bubble_tea / caramel_pudding / tiramisu          （舊，較嚴）
members_tier_chk    → 上述三種 + chef_special + NULL                    （新，較寬）
```

兩條同時生效 = 取交集 → **`chef_special` 永遠寫不進 `members.tier`**。
但 `members_tier_override_chk` 允許 `chef_special`，所以只要有邏輯把 `tier_override` 套回 `tier` 就會失敗。
目前前端未使用 `chef_special`，屬潛伏問題；後台做會員分級時會踩到。
→ 修法見 `sql/pending/2026-08-14_fix_members_tier_constraint.sql`

### 3. 金流函式是 INVOKER，POS 不能直接呼叫

以下為 `SECURITY INVOKER`（其餘絕大多數 `_tx` 函式都是 DEFINER）：

```
_charge_core        charge_fnb_tx      charge_matched_tx    charge_private_tx
checkout_tx         reverse_txn_tx     wallet_topup_tx      settle_session_tx
```

被其他 DEFINER 函式內部呼叫沒問題；但 POS 用 anon key 且無 auth session，
**直接呼叫會被 RLS 擋成空結果且不報錯**（CLAUDE.md 硬規則 4 描述的情境）。

→ 實作 `settle_session_tx` 時必須改成 `SECURITY DEFINER`，
   且依硬規則 2，改屬性/簽名要在同一份 SQL 開頭附 `DROP FUNCTION IF EXISTS`。

### 4. ~~清理無人入座的 session 尚未實作~~ → 2026-08-14 已完成

`cleanup_empty_sessions_tx(p_minutes)` 已建立，pg_cron 每 10 分鐘跑一次（參數 30 分鐘）。

注意 `sweep_expired_queues_tx` 是清**配對房間**（`match_queues`），
不是清桌況 session，兩者別搞混。

---

## 關鍵表結構

### `tables`（桌子本體）
```
id, org_id, store_id, label, area, seats, sort_order,
is_active, note, created_at/by, updated_at/by, deleted_at
```
**沒有 `status` 欄位。** 桌況是從 `table_sessions` 動態算出來的。停用桌子看 `is_active`。

### `table_sessions`（開桌紀錄）
```
id, org_id, store_id, table_id, mode, stake_level_id,
planned_rounds, planned_minutes, fee_points,
status, open_method, opened_by_staff_id, promoted_by_staff_id,
started_at, activated_at, ended_at, idempotency_key, is_test,
game_type, flower,                    ← 2026-08-15 新增（牌規：台麻/美麻、有花/無花）
created_at/by, updated_at/by, deleted_at
```
- `mode` ∈ `matched` / `private`
- `open_method` ∈ `auto` / `manual` / NULL
- `status` ∈ `open` / `completed` / **`voided`**

### `session_players`（入座紀錄）
```
id, org_id, session_id, member_id, seat, join_type, status,
charged_points, paid_by, order_id,
score_points, finish_rank, joined_at, left_at, settled_at, created_at/by
```
- `join_type` ∈ `opener` / `mid_join` / `sub`
- `status` ∈ `playing` / `completed` / `late` / `forfeit`
- 代付：被代付者仍建立記錄，`charged_points = 0`、`paid_by = 付款人`
- 判斷用：有 `order_id` = 已結帳、有 `paid_by` = 被代付

### `orders`（訂單）
金額有強制恆等式約束 `orders_amount_balance`，寫入前必須自己算對：
```
payable  = subtotal - coupon_discount - tier_discount
cash_due = payable - points_used
且 subtotal / coupon_discount / tier_discount / points_used / cash_due 皆 >= 0
```
- `channel` ∈ `counter` / `table_qr` / `online`

### `app_events`（埋點）
```
id, org_id, member_id, event, props, client_ts, created_at, is_test
```
- `event` 必須符合 `^[a-z][a-z0-9_]{0,49}$`
- `props` 大小上限 8192 bytes（`pg_column_size`）

---

## 測試資料隔離

四個過濾測試資料的檢視表（CLAUDE.md 原本只記了前兩個）：

```
v_real_app_events    v_real_wallet_txns    v_real_members    v_real_stores
```

**做報表/分析一律查 `v_real_*`，不要直接查原表**，否則自己的測試資料會混進營運數據，
而且不會報錯，很晚才會發現。

`is_test` 欄位由觸發器 `set_is_test_from_store()` 依門市自動帶入。

---

## RPC 函式清單

依用途分類。**簽名以此為準，不要憑印象呼叫。**
未特別標註者皆為 `SECURITY DEFINER`；標 `[INVOKER]` 者見上方問題 3。

### 開桌 / 桌況
```
open_session_tx(p_table_id, p_mode, p_stake_level_id, p_planned_rounds, p_planned_minutes, p_staff_id, p_open_method, p_idempotency_key)
activate_session_tx(p_session_id, p_staff_id)
get_session_tx(p_session_id)
calc_session_fee_tx(p_session_id, p_join_type, p_member_id)
join_session_tx(p_session_id, p_member_id, p_join_type, p_coupon_ids, p_points_used, p_payments, p_staff_id, p_idempotency_key, p_pay_for)
check_session_blocks_tx(p_session_id, p_member_id)
settle_session_tx(p_session_id)                                   [INVOKER] 仍是空殼
list_tables_tx(p_org_id, p_store_id)
set_table_active_tx(p_table_id, p_active, p_note)
cleanup_empty_sessions_tx(p_minutes)                              ← 2026-08-14 新增，pg_cron 每 10 分鐘
```
代付透過 `join_session_tx` 的 `p_pay_for uuid[]` 參數，沒有獨立函式。

### 金流 / 錢包
```
topup_tx(p_member_id, p_store_id, p_points, p_amount_twd, p_pay_method, p_idempotency_key, p_bonus_points, p_external_ref, p_staff_id, p_note)
topup_void_tx(p_topup_id, p_idempotency_key, p_staff_id, p_reason)
get_wallet_tx(p_member_id, p_txn_limit)
checkout_tx(p_member_id, p_store_id, p_items, p_coupon_ids, p_points_used, p_payments, p_idempotency_key, p_staff_id)   [INVOKER]
charge_matched_tx / charge_private_tx / charge_fnb_tx / wallet_topup_tx / reverse_txn_tx / _charge_core                  [INVOKER]
pos_addon_checkout_tx(...)                  ← 2026-08-15 新增，DEFINER 包 checkout_tx，POS 加購用（只收商品不收檯費）
fix_wallet_balance_tx(p_org_id, p_member_id)
reconcile_wallets_tx(p_org_id)
daily_wallet_audit_tx(p_org_id)
```

### 發票
```
create_invoice_draft_tx(p_order_id, p_idempotency_key)
mark_invoice_issued_tx(p_invoice_id, p_invoice_no, p_random, p_period, p_provider, p_provider_ref, p_raw, p_donate_org_name)
mark_invoice_failed_tx(p_invoice_id, p_raw)
void_invoice_tx(p_invoice_id, p_reason, p_reissue, p_idempotency_key)
set_invoice_pref_tx(p_member_id, p_type, p_carrier, p_donate_code, p_tax_id, p_title)
```

### 配對 / 揪團
```
create_match_queue_tx(p_org_id, p_opener, p_store, p_stake, p_play_at, p_game_type, p_rounds, p_seats, p_prefs, p_flower)
join_match_queue_tx(p_org_id, p_member, p_queue, p_join_source)
leave_match_queue_tx(p_org_id, p_member, p_queue, p_reason)        ← 用這個（另有孤兒舊版）
list_match_queues_tx / list_match_queues_by_city_tx / get_my_active_queue_tx
update_play_at_tx(p_org_id, p_queue, p_new_play_at)
sweep_expired_queues_tx(p_org_id)
generate_recurring_instances_tx(p_org_id, p_days_ahead)
_check_join_conflict(p_org_id, p_member, p_play_at, p_source)
```

### 社交
```
send_buddy_invite_tx / respond_buddy_invite_tx / remove_buddy_tx / list_buddies_tx
send_table_invite_tx / respond_table_invite_tx
block_member_tx / unblock_member_tx / list_blocks_tx / _blocked_between
like_player_tx(p_org_id, p_liker, p_target, p_on, p_session)
list_recent_players_tx(p_org_id, p_member)
list_notifications_tx / mark_notifs_read_tx / unread_count_tx
```

### 會員 / 個人檔案
```
register_member_tx(p_org_id, p_display_name, p_phone, p_line_user_id, p_home_store_id, p_created_by)
get_my_profile_tx / set_my_nickname_tx / set_my_about_tx / set_my_avatar_tx / set_my_style_tx
set_my_title_tx / set_my_sched_tx / set_my_see_score_tx / set_my_home_store_tx / set_my_baby_tile_tx
set_my_availability_tx / get_my_availability_tx
set_avatar_tx(p_member_id, p_source, p_path)
admin_remove_avatar_tx(p_member_id, p_reason, p_block)
save_app_state_tx(p_org_id, p_member_id, p_bear, p_titles)
rebind_line_user_tx(p_member_id, p_new_line_user_id, p_staff_id, p_reason)
has_daypass_tx(p_org_id, p_member_id)
```

### POS 專用
```
pos_search_members_tx(p_org_id, p_keyword)
pos_member_detail_tx(p_org_id, p_member_id)
```

### 主檔 / 權限 / 系統
```
list_stores_tx / get_store_detail_tx / list_products_tx / list_stakes_tx / list_stake_levels_tx / list_members_tx
grant_staff_tx(p_member_id, p_store_id, p_role) / revoke_staff_tx(p_staff_id)
current_org_id() / current_member_id() / current_staff() / has_store_access(p_store_id)
next_doc_no(p_org_id, p_store_id, p_doc_type)
log_app_event_tx(p_org_id, p_member_id, p_event, p_props, p_client_ts)
mark_app_active_tx(p_org_id, p_member_id)
dev_reset_test_data_tx(p_reset_balance)     ← 2026-08-15 已依實際 schema 重寫並驗證通過
dev_clear_my_queues_tx(p_org_id, p_member)
```

### 觸發器函式（不要直接呼叫）
```
app_events_no_mutate / payments_no_mutate / block_txn_mutation / prevent_org_change
set_updated_at / set_is_test_from_store / audit_wallet_balance
trg_orders_set_no / trg_topup_set_no / trg_coupon_set_code
```

---

## 其他檢視表

```
v_app_daily_active          v_member_join_hours        v_member_wait_stats
v_order_settlement          v_order_invoice            v_invoice_pending
v_entity_settlement         v_entity_settlement_summary
v_wallet_balance_check      v_payment_store_mismatch
```

做報表時優先看有沒有現成的檢視表，不要重寫彙總邏輯。
