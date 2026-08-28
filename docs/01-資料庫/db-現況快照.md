# MIGI 資料庫現況快照

> **產生日期：2026-08-28**（前一版是 2026-08-14，已整份取代）
> **基準：`sql/applied/` 有 100 個檔案，最後一個是 `測試帳號建立.sql`**
> 來源：`sql/checks/2026-08-28_現況全匯出.sql`（pg_proc / pg_class / pg_constraint / pg_index / information_schema）

## 怎麼用這份

**它是背景事實的鏡像**：這張表有哪些欄位、這個約束在管什麼、這支函式有沒有授權給 anon。
這類問題直接查這裡，不用再跑一次查詢。

🔴 **但它不取代逐次查證。** 硬規則 3 永遠成立：
**改既有函式一律先 `pg_get_functiondef` 撈線上版**，這份只當背景參考。

## 怎麼知道它過期了（硬規則 1.7）

比對現在 `sql/applied/` 的檔案數與上面的基準（100）—— **不同就是過期**。
這個檢查不需要資料庫。

⚠ **但它只能證明「確定過期」，不能證明「還是新的」。**
直接在 Dashboard 手改、沒留檔案的東西抓不到 ——
而那不是假設：`uq_members_line_user` 就是這樣來的（承重牆，`sql/` 裡完全找不到）。

📌 硬規則 1.6：**歸檔 `pending/` → `applied/` 時一併重跑匯出**。
上一版就是因為靠「記得更新」而在兩週內爛掉 —— 它連 `products` 這張表都沒有。

---

## 🔴 授權地雷（2026-08-28 新發現）

硬規則 2.5：**「函式在包裝裡跑得動」不代表「前端叫得動」** ——
權限是在**呼叫點**檢查的，而在 DEFINER 裡呼叫端的權限根本不會被檢查。

| 函式 | 狀況 | 後果 |
|---|---|---|
| `topup_void_tx` | INVOKER 之外 **anon=無**、auth=✅ | 🔴 **POS 用 anon，所以叫不動作廢儲值** —— 真的要用時會 permission denied |
| `charge_matched_tx` | INVOKER、**anon=無 auth=無** | 完全沒授權給任何人 = 不可能被前端呼叫。舊世代收費函式，**死碼候選**（待辦 28） |
| `charge_private_tx` | 同上 | 同上 |
| `checkout_tx` | INVOKER、anon=✅ | ⚠ **有授權但不該被直接呼叫** —— RLS 會濾成「什麼都沒發生而且不報錯」。授權存在本身就是危險（有人會叫） |
| `_charge_core`／`charge_fnb_tx`／`reverse_txn_tx` | INVOKER、anon=✅ | 同上，都是內部函式卻對 anon 開著 |

---

## 🎯 三個待辦其實已經做完了（文件漂移，2026-08-28 發現）

| 待辦 | CLAUDE.md 寫的 | 實際 |
|---|---|---|
| **5**（配桌） | 「⚠ 現在不要先建 `auto_assign` 欄位」 | 🎯 **`tables.auto_assign` 已存在**（NOT NULL default true），還有 `set_table_auto_assign_tx` |
| **5**（收桌保留給現場） | 「收桌彈窗加一個勾選」 | 🎯 **`settle_session_tx` 已有 `p_keep_for_walkin`** —— 後端做好了，只差前端 |
| **17**（贈點級距主檔） | 「建 `topup_plans` 主檔」 | 🎯 **`topup_plans` 表 ＋ `calc_topup_bonus_tx` ＋ `list_topup_plans_tx` 全都在** —— 只差 `topup_tx` 拿它驗證、POS 前端讀它 |

📌 固定牌局的後端也整套都在：`recurring_tables` 表、`pos_create_recurring_tx`、
`generate_recurring_instances_tx`、`pos_set_recurring_enabled_tx`。

---

## ⚠️ 最容易踩的坑：`void` 還是 `voided`？

**不同表用不同值，沒有統一。**（`dev_reset_test_data_tx` 曾因此寫錯）

| 表 | 作廢值 | 完整允許值 |
|---|---|---|
| `table_sessions.status` | **`voided`** | open / completed / voided |
| `orders.status` | `void` | open / preparing / **served** / paid / void |
| `topup_orders.status` | `void` | pending / paid / void / refunded |
| `invoices.status` | `void` | pending / issued / void / failed |

**只有 `table_sessions` 用 `voided`，其餘一律 `void`。**

📌 `orders.status` 的 `preparing` / `served` **從來沒被用過**（`checkout_tx` 一律寫 `paid`）——
出餐佇列的狀態機地基已經在了，見 `docs/07-營運商業/首店餐飲籌備.md` 12-9。

---

## 一、欄位

> 讀法：`!` = NOT NULL，`=xxx` = 預設值。

| 表 | 欄位 |
|---|---|
| `app_events` | id! │ org_id! │ member_id │ event! │ props jsonb!={} │ client_ts │ created_at! │ **is_test!=false** │ store_id |
| `app_notifications` | id! │ org_id! │ member_id! │ type! │ payload jsonb!={} │ ref_id │ read_at │ created_at! |
| `bonus_rules` | id! │ org_id! │ store_id │ rule_key! │ amount! │ min_spend │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by |
| `buddy_invites` | id! │ org_id! │ inviter_id! │ invitee_id! │ status!=pending │ responded_at │ created_at! |
| `coupons` | id! │ org_id! │ name! │ kind! │ discount_type! │ discount_value │ applies_to │ valid_days │ valid_until │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ min_spend │ max_discount │ **free_product_id** │ cost_bearer!=store |
| `doc_counters` | org_id! │ store_id! │ doc_type! │ doc_date! │ last_no!=0 |
| `invoices` | id! │ org_id! │ entity_id │ store_id │ ref_table! │ ref_id! │ kind!=invoice │ parent_invoice_id │ status!=pending │ invoice_no │ invoice_at │ random_code │ period │ tax_type!='1' │ tax_rate!=0.05 │ sales_amount! │ tax_amount! │ total_amount! │ buyer_type!=B2C │ buyer_tax_id │ buyer_title │ carrier_type │ carrier_no │ donate_code │ donate_org_name │ print_mark!=false │ items jsonb!=[] │ void_at │ void_reason │ provider │ provider_ref │ raw │ idempotency_key │ created_at! │ created_by |
| `legal_entities` | id! │ org_id! │ name! │ tax_id │ kind! │ bank_account jsonb │ is_active!=true │ created_at! │ updated_at! |
| `mahjong_buddies` | id! │ org_id! │ member_id! │ buddy_id! │ **origin!** │ co_play_count!=1 │ **compat_score** │ linked_at! │ deleted_at │ created_at! |
| `match_queue_players` | id! │ org_id! │ queue_id! │ member_id! │ join_source │ joined_at! │ left_at │ leave_reason │ no_show!=false │ leave_detail |
| `match_queues` | id! │ org_id! │ store_id! │ stake_level_id! │ game_type!='16張' │ rounds!='一將' │ seats!=4 │ prefs jsonb!={} │ status!=waiting │ opened_by │ **play_at!** │ **matched_at** │ matched_session_id │ expires_at!=now()+2h │ created_at! │ updated_at! │ source!=member │ tags jsonb!=[] │ recurring_id │ recurring_freq │ flower │ **open_at** |
| `member_app_state` | member_id! │ org_id! │ bear jsonb!={} │ titles jsonb!=[] │ updated_at! |
| `member_availability` | id! │ org_id! │ member_id! │ weekday! │ slot! │ preference!=often │ **source!=stated** │ created_at! │ updated_at! |
| `member_blocks` | id! │ org_id! │ blocker_id! │ blocked_id! │ reason │ created_at! |
| `member_coupons` | id! │ org_id! │ member_id! │ coupon_id! │ status!=active │ granted_at! │ used_at │ used_txn_id │ **expires_at** │ created_at! │ code │ used_order │ discounted_amount │ cost_bearer |
| `member_interactions` | id! │ org_id! │ member_id! │ **staff_id** │ channel!=system │ kind! │ note │ created_at! │ created_by |
| `member_likes` | id! │ org_id! │ liker_id! │ target_id! │ session_id │ created_at! |
| `member_tiers` | **code!**（PK）│ label! │ discount_pct!=0 │ threshold_amount │ sort!=0 │ is_active!=true │ note │ created_at! |
| `members` | id! │ org_id! │ **line_user_id** │ display_name! │ phone │ home_store_id │ **tier!=bubble_tea** │ gender │ **birthday** │ occupation │ district │ acquisition_source │ avatar_url │ **last_visit_at** │ **visit_count!=0** │ lifecycle!=new │ **primary_staff_id** │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **tier_override** │ last_app_active_at │ rank!='銅牌熊 I' │ title!='新手上路' │ likes_count!=0 │ **is_test!=false** │ about │ sched │ style jsonb │ see_score!='牌咖' │ baby_tile jsonb │ avatar_source!=bear │ avatar_photo_path │ avatar_photo_at │ avatar_blocked!=false │ avatar_removed_count!=0 │ inv_type!=member │ inv_carrier │ inv_donate_code │ inv_tax_id │ inv_title |
| `order_items` | id! │ order_id! │ **product_id!** │ qty!=1 │ created_at! │ org_id! │ name │ unit_price! │ line_total │ **revenue_type!** |
| `order_payments` | id! │ org_id! │ store_id! │ order_id! │ method! │ amount! │ cash_received │ change_given │ ref_no │ staff_id │ created_at! |
| `orders` | id! │ org_id! │ store_id! │ member_id │ table_id │ **session_id** │ status!=open │ **channel!=counter** │ total_points!=0 │ deleted_at │ created_at! │ updated_at! │ **created_by** │ **updated_by** │ order_no │ subtotal!=0 │ coupon_discount!=0 │ tier_discount!=0 │ payable!=0 │ points_used!=0 │ cash_due!=0 │ tier_at_order │ **idempotency_key** │ wallet_txn_id │ paid_at │ entity_id │ is_test!=false │ tier_discount_pct │ txn_no |
| `orgs` | id! │ name! │ plan!=self │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by |
| `pricing_tiers` | id! │ org_id! │ store_id │ mode! │ rule_key! │ min_unit │ max_unit │ points! │ sort_order!=0 │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by |
| `product_taxonomy` | **dimension!** │ **code!**（PK 是兩者）│ label! │ parent_code │ sku_prefix │ sort!=0 │ is_active!=true │ note │ created_at! │ default_revenue_type |
| `products` | id! │ org_id! │ **sku!** │ name! │ **category!** │ **unit_price!** │ unit_cost │ **is_active!=true** │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **stock_qty!=0** │ **is_available!=true** │ **revenue_type!** │ **subcategory** │ **tracks_stock!=true** │ **is_system!=false** │ **discountable!=true** |
| `queue_tags` | code!（PK）│ label! │ sort_order!=0 │ is_active!=true │ created_at! |
| `recurring_tables` | id! │ org_id! │ store_id! │ weekday │ start_time! │ stake_level_id! │ game_type!='16張' │ rounds!='一將' │ seats!=4 │ enabled!=true │ note │ created_at! │ frequency!=weekly │ flower │ lead_hours!=24 │ tags jsonb!=[] |
| `session_players` | id! │ org_id! │ session_id! │ member_id! │ join_type!=opener │ status!=playing │ charged_points!=0 │ **joined_at!** │ created_at! │ created_by │ finish_rank │ score_points │ settled_at │ **order_id** │ seat │ **left_at** │ **paid_by** │ **fee_waived_amount!=0** │ **fee_waived_reason** |
| `staff` | id! │ org_id! │ store_id │ **auth_uid** │ name! │ **role!=floor** │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **member_id** |
| `stake_levels` | id! │ org_id! │ store_id │ label! │ base │ tai │ is_hygiene!=false │ sort_order!=0 │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by |
| `stores` | id! │ org_id! │ name! │ address │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **code!** │ city │ district │ lat │ lng │ open_time │ close_time │ **store_type** │ **is_test!=false** │ entity_id │ phone │ parking │ photos jsonb!=[] │ note |
| `table_sessions` | id! │ org_id! │ store_id! │ table_id! │ **mode!** │ stake_level_id │ status!=open │ planned_minutes │ started_at! │ **ended_at** │ fee_points │ promoted_by_staff_id │ open_method │ deleted_at │ created_at! │ updated_at! │ created_by │ **updated_by** │ planned_rounds │ opened_by_staff_id │ activated_at │ idempotency_key │ is_test!=false │ game_type │ flower |
| `tables` | id! │ org_id! │ store_id! │ label! │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ area │ seats!=4 │ sort_order!=0 │ note │ 🎯 **auto_assign!=true** |
| `topup_orders` | id! │ org_id! │ store_id! │ member_id! │ topup_no │ points! │ **bonus_points!=0** │ amount_twd! │ pay_method! │ status!=paid │ external_ref │ idempotency_key │ invoice_no │ invoice_at │ wallet_txn_id │ staff_id │ note │ created_at! │ created_by │ entity_id │ held_by_entity │ **session_id** │ **cash_received** │ **change_given** │ txn_no |
| `topup_plans` | id! │ org_id! │ store_id │ **min_amount!** │ **bonus_points!=0** │ is_quick!=false │ sort_order!=0 │ is_active!=true │ created_at! |
| `wallet_balance_audit` | id bigint!（序列）│ member_id! │ org_id! │ old_balance! │ new_balance! │ delta! │ txn_sum │ is_synced │ db_user │ changed_at! |
| `wallet_txns` | id! │ org_id! │ store_id │ served_store_id │ member_id! │ **type txn_type!**（enum）│ amount! │ status!（enum）=completed │ counter_account │ reverses_txn_id │ idempotency_key │ external_ref │ **ref_table** │ **ref_id** │ staff_id │ note │ created_at! │ created_by |
| `wallets` | member_id!（PK）│ org_id! │ **balance!=0** │ updated_at! |

⚠ **`members` 沒有 `points_balance`** —— 餘額在 `wallets.balance`。
⚠ **`tables` 沒有 `status`** —— 桌況是從 `table_sessions` 動態算的。

---

## 二、CHECK 約束（全部）

🔴 硬規則 3.8：**錯誤訊息只給約束名字不給定義**，看到 `xxx_check` 就推論它在管什麼是猜的。

### 金流

| 約束 | 定義 |
|---|---|
| `orders.orders_amount_balance` | `payable = subtotal - coupon_discount - tier_discount` 且 `cash_due = payable - points_used`，且五個金額欄位皆 >= 0 |
| `orders.orders_status_check` | open / preparing / served / paid / void |
| `orders.orders_channel_check` | counter / table_qr / online |
| `order_payments.cash_fields_only_for_cash` | `method<>'cash'` → cash_received 與 change_given **都必須 NULL**；`method='cash'` → cash_received NOT NULL 且 **>= amount**，且 `change_given = cash_received - amount` |
| `order_payments.order_payments_method_check` | cash / credit_card / line_pay |
| `order_payments.order_payments_amount_check` | amount > 0 |
| `order_items.order_items_qty_check` | qty > 0 |
| `order_items.order_items_revenue_type_chk` | NULL 或 venue_fee / fnb / retail / other（⚠ 欄位本身是 NOT NULL，所以 NULL 走不到） |
| `wallets.wallets_balance_check` | balance >= 0 |
| `wallet_txns.chk_amount_direction` | type ∈ topup/refund/reversal/adjust **不限方向**；type ∈ table_fee/fnb/merch/event_fee/**spend** 則 **amount < 0** |

### 商品與券

| 約束 | 定義 |
|---|---|
| `products.products_category_check` | fnb / merch / service |
| `products.products_revenue_type_check` | NULL 或 venue_fee / fnb / retail / other |
| `products.products_unit_price_check` | unit_price >= 0 |
| `products.products_stock_qty_check` | stock_qty >= 0 |
| `product_taxonomy.product_taxonomy_dimension_check` | **category / subcategory / revenue_type** |
| `coupons.coupons_kind_check` | table_discount / unlimited_play / ride / fnb / topup_bonus / generic |
| `coupons.coupons_discount_type_check` | **percent / fixed / free** |
| `coupons.coupons_applies_to_check` | NULL 或 table_fee / fnb / **ride** / **topup** ⚠ 後兩個不是商品分類（待辦 0.8） |
| `coupons.coupons_cost_bearer_chk` | store / hq |
| `coupons.coupons_min_spend_check` / `max_discount_check` | NULL 或 >= 0 |
| `member_coupons.member_coupons_status_check` | active / used / expired |
| `member_coupons.member_coupons_cost_bearer_chk` | NULL 或 store / hq |
| `member_coupons.member_coupons_discounted_amount_check` | NULL 或 >= 0 |

### 會員

| 約束 | 定義 |
|---|---|
| `members.members_tier_chk` | NULL 或 bubble_tea / caramel_pudding / tiramisu / chef_special |
| `members.members_tier_override_chk` | 同上（作用於 `tier_override`）|
| `members.members_display_name_chk` | NOT NULL 且 `= migi_norm_nickname(display_name)` 且長度 **1–12** 且不含 `migi\|官方\|客服\|店長\|管理員\|系統\|admin` |
| `members.members_gender_check` | NULL 或 female / male / other |
| `members.members_lifecycle_check` | new / growing / regular / at_risk / churned |
| `members.members_sched_chk` | NULL 或 早上為主／下午為主／晚上為主／深夜為主／**不一定**（NOT VALID）|
| `members.members_see_score_chk` | 所有人／牌咖／只有自己（NOT VALID）|
| `members.members_avatar_source_chk` | bear / photo |
| `members.members_inv_type_chk` | member / mobile / citizen / donate / company / paper |
| `member_tiers.member_tiers_pct_chk` | 0 <= discount_pct <= 100 |
| `member_availability.*_slot_check` | **morning / afternoon / evening / late** |
| `member_availability.*_preference_check` | **often / sometimes / never** |
| `member_availability.*_source_check` | **stated / inferred** |
| `member_availability.*_weekday_check` | 0–6 |
| `member_interactions.*_channel_check` | system / staff |
| `member_interactions.*_kind_check` | care / birthday / winback / welcome / note |
| `member_blocks` / `member_likes` / `buddy_invites` | 各有「不可對自己」的 CHECK |
| `mahjong_buddies.*_origin_check` | **pre_existing / matched** 🎯 護城河深度 = `count(*) where origin='matched'` |
| `mahjong_buddies.mahjong_buddies_check` | member_id <> buddy_id |
| `buddy_invites.*_status_check` | pending / accepted / rejected |

### 桌與配桌

| 約束 | 定義 |
|---|---|
| `table_sessions.*_status_check` | open / completed / **voided** |
| `table_sessions.*_mode_check` | matched / private |
| `table_sessions.*_open_method_check` | NULL 或 **auto / manual** |
| `table_sessions.*_game_type_chk` | NULL 或 台麻 / 美麻 |
| `table_sessions.*_flower_chk` | NULL 或 無花 / 有花 |
| `session_players.*_join_type_check` | opener / mid_join / sub |
| `session_players.*_status_check` | **playing / completed / late / forfeit**（⚠ 沒有 `left`）|
| `session_players.chk_finish_rank` | NULL 或 1–4（NOT VALID）|
| `match_queues.*_status_check` | waiting / matched / seated / cancelled / expired |
| `match_queues.*_source_check` | member / **pos** / recurring |
| `match_queues.*_seats_check` | 2–4 |
| `match_queues.*_game_type_chk` / `*_flower_chk` | 台麻／美麻、無花／有花（NOT VALID）|
| `match_queue_players.*_leave_reason_check` | quit / cancelled / expired / switched |
| `recurring_tables.*_frequency_check` | daily / weekly |
| `recurring_tables.recurring_lead_hours_chk` | 1–720 |
| `pricing_tiers.*_mode_check` | matched / private |

### 其他

| 約束 | 定義 |
|---|---|
| `app_events.app_events_event_check` | 🔴 **不是白名單，是格式** —— `event ~ '^[a-z][a-z0-9_]{0,49}$'` |
| `app_events.app_events_props_check` | `pg_column_size(props) <= 8192` |
| `app_notifications.*_type_check` | settle / buddy_req / buddy_ok / table_req / table_ok / system / **table_expired** |
| `invoices.invoices_amount_chk` | `sales_amount + tax_amount = total_amount` |
| `invoices.invoices_status_chk` | pending / issued / void / failed |
| `invoices.invoices_kind_chk` | invoice / allowance |
| `invoices.invoices_ref_chk` | ref_table ∈ orders / topup_orders |
| `invoices.invoices_tax_chk` | tax_type ∈ 1/2/3/4/9 |
| `topup_orders.*_status_check` | pending / paid / void / refunded |
| `topup_orders.*_pay_method_check` | cash / credit_card / line_pay / **jko** / other |
| `topup_orders.*_points_check` | points > 0；`bonus_points >= 0`；`amount_twd > 0` |
| `topup_plans.*` | min_amount >= 0；bonus_points >= 0 |
| `staff.staff_role_check` | **floor / manager / hq / owner** |
| `stores.stores_store_type_chk` | NULL 或 直營／加盟／系統授權／自家場 |
| `legal_entities.legal_entities_kind_chk` | hq / franchise / licensed |
| `orgs.orgs_plan_check` | self / franchise / licensed |
| `bonus_rules.*_rule_key_check` | match_made / visit_commission |

---

## 三、唯一性（約束與索引兩邊）

🔴 2026-08-26 的教訓：查「有沒有唯一限制」時 **`pg_constraint` 與 `pg_index` 兩邊都要看** ——
`CREATE UNIQUE INDEX` 建的**不會出現在 `pg_constraint` 裡**。

### 部分唯一索引（有 WHERE 條件 —— 最容易誤判的一類）

| 索引 | 定義 |
|---|---|
| 🔴 `members.uq_members_line_user` | `(line_user_id)` WHERE line_user_id IS NOT NULL AND deleted_at IS NULL —— **全域唯一，承重牆**（`sql/` 裡找不到，Dashboard 手建）|
| `members.uq_members_line` | `(org_id, line_user_id)` 同條件 —— M0 地基，與上者意圖矛盾但兩個都留 |
| `members.uq_members_phone` | `(org_id, phone)` WHERE phone IS NOT NULL AND deleted_at IS NULL |
| `table_sessions.uq_sessions_open_table` | `(table_id)` WHERE **status='open' AND deleted_at IS NULL** 🎯 收桌自動放桌就靠這個 |
| `table_sessions.uq_sessions_idem` | `(idempotency_key)` WHERE NOT NULL |
| `orders.uq_orders_idem` | `(idempotency_key)` WHERE NOT NULL |
| `orders.orders_org_no_uq` | `(org_id, order_no)` |
| `wallet_txns.uq_txn_idempotency` | `(org_id, idempotency_key)` WHERE NOT NULL |
| `topup_orders.topup_orders_idem_uq` | `(org_id, idempotency_key)` WHERE NOT NULL |
| `topup_orders.topup_orders_org_no_uq` | `(org_id, topup_no)` |
| `mahjong_buddies.uq_buddies` | `(member_id, buddy_id)` WHERE deleted_at IS NULL |
| `session_players.uq_session_player` | `(session_id, member_id)` ⚠ **無 WHERE** —— 帳號合併最刺的一個 |
| `staff.uq_staff_member_store` | `(member_id, store_id)` WHERE deleted_at IS NULL —— 一人可多列，同店只能一列 |
| `match_queue_players.uq_queue_member` | `(queue_id, member_id)` WHERE left_at IS NULL |
| `buddy_invites.uq_pending_invite` | `(inviter_id, invitee_id)` WHERE status='pending' |
| `member_blocks.uq_block_pair` | `(blocker_id, blocked_id)` |
| `member_likes.uq_like_per_session` | `(liker_id, target_id, session_id)` WHERE session_id IS NOT NULL |
| `member_availability.uq_availability` | `(member_id, weekday, slot, source)` |
| `member_coupons.member_coupons_org_code_uq` | `(org_id, code)` |
| `products.uq_products_sku` | `(org_id, sku)` WHERE deleted_at IS NULL |
| `tables.uq_tables_store_label` | `(store_id, label)` WHERE deleted_at IS NULL |
| `stores.stores_org_code_uq` | `(org_id, code)` |
| `topup_plans.uq_topup_plans_tier` | `(org_id, coalesce(store_id,'000…'), min_amount)` |

✅ 全部 `indisvalid = true`（INVALID 的索引會存在、看得到、但完全不擋，而且沒有症狀）。

### 約束型唯一

`staff.staff_auth_uid_key` UNIQUE(auth_uid) ⚠ **總部 Email 那條路一人只能一列**
`invoices.invoices_idempotency_key_key` UNIQUE(idempotency_key)

### 複合主鍵

`doc_counters (org_id, store_id, doc_type, doc_date)`｜`product_taxonomy (dimension, code)`
`member_tiers (code)`｜`queue_tags (code)`｜`wallets (member_id)`｜`member_app_state (member_id)`

---

## 四、函式（全部，含授權）

> 讀法：`DEFINER/INVOKER`　`anon=` 是 POS 與會員 App 用的角色。
> 🔴 硬規則 2.5：**讓前端第一次直接呼叫某支既有 RPC 時，必須先確認它有 `anon EXECUTE`。**

### 金流（🔴 全部是 INVOKER —— 前端不可直接呼叫）

```
checkout_tx(p_member_id, p_store_id, p_items jsonb, p_coupon_ids uuid[],
            p_points_used, p_payments jsonb, p_idempotency_key, p_staff_id)   INVOKER anon=✅
_charge_core(...)                                                              INVOKER anon=✅
charge_fnb_tx(...)                                                             INVOKER anon=✅
reverse_txn_tx(p_original_txn_id, p_idempotency_key, p_reason)                 INVOKER anon=✅
charge_matched_tx(...)                                                         INVOKER anon=無 auth=無 🔴 死碼候選
charge_private_tx(...)                                                         INVOKER anon=無 auth=無 🔴 死碼候選
```

### 結帳包裝層（DEFINER，前端呼叫這些）

```
join_session_tx(p_session_id, p_member_id, p_join_type, p_coupon_ids, p_points_used,
                p_payments, p_staff_id, p_idempotency_key, p_pay_for uuid[], p_items)  DEFINER ✅
pos_addon_checkout_tx(p_session_id, p_member_id, p_items, p_coupon_ids,
                      p_points_used, p_payments, p_idempotency_key, p_staff_id)        DEFINER ✅
pos_quick_checkout_tx(p_member_id, p_store_id, p_items, p_coupon_ids, p_points_used,
                      p_payments, p_idempotency_key, p_staff_id, p_topup_points,
                      p_topup_amount, p_topup_method, p_topup_cash_received,
                      p_topup_change_given, p_note)                                    DEFINER ✅
pos_checkout_with_topup_tx(p_session_id, p_member_id, p_join_type, p_items, p_coupon_ids,
                      p_points_used, p_payments, p_pay_for, p_staff_id, p_idempotency_key,
                      p_topup_points, p_topup_bonus, p_topup_amount, p_topup_method,
                      p_topup_cash_received, p_topup_change_given)                     DEFINER ✅
topup_tx(p_member_id, p_store_id, p_points, p_amount_twd, p_pay_method,
         p_idempotency_key, p_bonus_points, p_external_ref, p_staff_id, p_note)        DEFINER ✅
topup_void_tx(p_topup_id, p_idempotency_key, p_staff_id, p_reason)          DEFINER anon=無 🔴
calc_topup_bonus_tx(p_org_id, p_store_id, p_amount_twd)                                DEFINER ✅
calc_session_fee_tx(p_session_id, p_join_type, p_member_id)                             DEFINER ✅
has_daypass_tx(p_org_id, p_member_id, p_store_id)                                       DEFINER ✅
```

### 錢包稽核

```
fix_wallet_balance_tx(p_org_id, p_member_id)      reconcile_wallets_tx(p_org_id)
audit_wallet_balance()                             daily_wallet_audit_tx(p_org_id)
```

### 開桌 / 桌況

```
open_session_tx(p_table_id, p_mode, p_stake_level_id, p_planned_rounds, p_planned_minutes,
                p_staff_id, p_open_method, p_idempotency_key, p_game_type, p_flower)
activate_session_tx(p_session_id, p_staff_id)
settle_session_tx(p_session_id, p_staff_id, 🎯 p_keep_for_walkin)
void_session_tx(p_session_id, p_staff_id)
cleanup_empty_sessions_tx(p_idle_minutes)
get_session_tx(p_session_id)          get_session_member_orders_tx(p_session_id, p_member_id)
list_tables_tx(p_org_id, p_store_id)  set_table_active_tx / 🎯 set_table_auto_assign_tx
check_session_blocks_tx(p_session_id, p_member_id)
```

### 配桌 / 固定局

```
create_match_queue_tx / join_match_queue_tx / leave_match_queue_tx / update_play_at_tx
list_match_queues_tx / list_match_queues_by_city_tx / get_my_active_queue_tx
dev_clear_my_queues_tx / sweep_expired_queues_tx / sweep_auto_seat_tx
_check_join_conflict / _finalize_queue_full_tx / _try_auto_seat_tx
pos_create_queue_tx / pos_list_queues_tx / pos_close_queue_tx / pos_seat_queue_tx
pos_add_queue_member_tx / pos_queue_members_tx / pos_table_forecast_tx
🎯 pos_create_recurring_tx / pos_list_recurring_tx / pos_set_recurring_enabled_tx
🎯 pos_set_recurring_tags_tx / generate_recurring_instances_tx
send_table_invite_tx / respond_table_invite_tx / list_queue_tags_tx
```

### 社交

```
send_buddy_invite_tx / respond_buddy_invite_tx / remove_buddy_tx / list_buddies_tx
list_recent_players_tx / like_player_tx / _blocked_between
block_member_tx / unblock_member_tx / list_blocks_tx
list_notifications_tx / mark_notifs_read_tx / unread_count_tx
```

### 會員 / 個人檔案

```
register_member_tx(p_org_id, p_display_name, p_phone, p_line_user_id, p_home_store_id, p_created_by)
rebind_line_user_tx(p_member_id, p_new_line_user_id, p_staff_id, p_reason)
get_my_profile_tx / get_wallet_tx / get_my_orders_tx / get_my_games_tx
set_my_nickname_tx / set_my_avatar_tx / set_my_title_tx / set_my_about_tx
set_my_sched_tx / set_my_style_tx / set_my_baby_tile_tx / set_my_see_score_tx
set_my_home_store_tx / set_my_birthday_tx / set_my_availability_tx / get_my_availability_tx
set_avatar_tx / admin_remove_avatar_tx / save_app_state_tx / mark_app_active_tx
set_invoice_pref_tx / list_members_tx
```

### POS 專用

```
pos_member_detail_tx / pos_search_members_tx / pos_add_member_note_tx
list_products_tx / list_fee_menu_tx / list_daypass_tx / list_stakes_tx / list_stake_levels_tx
list_stores_tx / get_store_detail_tx / get_order_tx
```

### 主檔 / 身分 / 系統

```
list_member_tiers_tx()          無參數
list_product_taxonomy_tx()      無參數
list_topup_plans_tx(p_org_id, p_store_id)
current_org_id() / current_member_id() / current_staff() / has_store_access(p_store_id)
grant_staff_tx(p_member_id, p_store_id, p_role) / revoke_staff_tx(p_staff_id)
next_doc_no(p_org_id, p_store_id, p_doc_type)
log_app_event_tx(p_org_id, p_member_id, p_event, p_props, p_client_ts, p_store_id)
dev_reset_test_data_tx(p_reset_balance) / dev_set_test_balance_tx(p_display_name, p_balance)
migi_norm_nickname(p text)
```

### 發票

```
create_invoice_draft_tx(p_order_id, p_idempotency_key)
mark_invoice_issued_tx(...) / mark_invoice_failed_tx(...) / void_invoice_tx(...)
```
🔴 全部存在但 **POS 原始碼裡 `invoice` 一次都沒出現**，`invoices` 表 0 筆（待辦 13）。

### 觸發器函式（不要直接呼叫）

```
set_updated_at / prevent_org_change / create_wallet_for_member / set_is_test_from_store
trg_orders_set_no / trg_topup_set_no / trg_coupon_set_code
trg_members_norm_display_name / trg_orders_touch_member_visit
app_events_no_mutate / payments_no_mutate / block_txn_mutation
```
