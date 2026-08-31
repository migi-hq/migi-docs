# MIGI 資料庫現況快照

> **產生日期：2026-08-28**（前一版是 2026-08-14，已整份取代）
> **基準：`sql/applied/` 有 136 個檔案**（依檔名排序最後一個是 `門市真實資料.sql`；
> 最後歸檔的是 `2026-08-31_段位補下一大階與我的段位.sql`）
>
> 🔴 **2026-08-30 補記一次漂移**：本文件在此之前**完全沒有 `phone_otps`、
> `members.phone_verified_at`、`otp_*` 那一整批** —— 也就是 08-30 上午的
> 簡訊驗證地基歸檔時**沒有依硬規則 1.6 同步更新**。
> ⚠ 這是這條規則第二次被跳過。**規則本身沒有錯，是執行時沒做。**
>
> 📌 依硬規則 1.6，歷次歸檔已同步更新本文件：
> `p_rounds` 與 `rounds` 欄位預設值、`topup_void_tx` 的 anon 授權、
> `orgs.live_from` 新欄位、`v_real_*` 從 5 個變 12 個、
> `set_my_profile_basics_tx` 與 `migi_norm_phone` 兩支新函式、`members_phone_chk`、
> `register_member_tx` 的暱稱正規化與 `display_name_reserved`、
> **簡訊驗證整批（`phone_otps` ＋ 8 支函式 ＋ `phone_verified_at`）**。
> 來源：`sql/checks/2026-08-28_現況全匯出.sql`（pg_proc / pg_class / pg_constraint / pg_index / information_schema）

## 怎麼用這份

**它是背景事實的鏡像**：這張表有哪些欄位、這個約束在管什麼、這支函式有沒有授權給 anon。
這類問題直接查這裡，不用再跑一次查詢。

🔴 **但它不取代逐次查證。** 硬規則 3 永遠成立：
**改既有函式一律先 `pg_get_functiondef` 撈線上版**，這份只當背景參考。

## 怎麼知道它過期了（硬規則 1.7）

比對現在 `sql/applied/` 的檔案數與上面的基準（**136**）—— **不同就是過期**。
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
| ~~`topup_void_tx`~~ | ✅ **2026-08-28 已補 anon 授權** | 補之前 POS 叫不動，跟 `topup_tx` 同一個形狀，只是提前補掉了 |
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

## 🔴 `rounds` 的值決定帶不帶得了桌

`pos_seat_queue_tx` 解析 `rounds` 時**只吃「三/3」或「二/2」**，其餘一律回
`rounds_not_supported` —— 而且**只是不帶桌，不報錯**。

後果：房間湊滿 → `status='matched'` → 排程每 5 分鐘試一次 → 每次都失敗 →
**客人以為成桌了，桌永遠不會出現，沒有任何人知道。**

✅ **2026-08-28 已把五個地方的預設值從 `'一將'` 改成 `'2 將'`**
（三支建房函式的 `p_rounds` ＋ 兩張表的欄位預設）。
⚠ **既有的 33 個「一將」房沒有被動到**（全部已 expired/cancelled，不是活的問題）。
⚠ 但值本身**沒有 CHECK 約束** —— 明確傳一個不支援的值仍然存得進去。
  真要根治是讓約束與 `pos_seat_queue_tx` 的判準同源，那是另一個決定。

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
| `match_queues` | id! │ org_id! │ store_id! │ stake_level_id! │ game_type!='16張' │ **rounds!='2 將'**（2026-08-28 由 `'一將'` 改，見下）│ seats!=4 │ prefs jsonb!={} │ status!=waiting │ opened_by │ **play_at!** │ **matched_at** │ matched_session_id │ expires_at!=now()+2h │ created_at! │ updated_at! │ source!=member │ tags jsonb!=[] │ recurring_id │ recurring_freq │ flower │ **open_at** |
| `member_app_state` | member_id! │ org_id! │ bear jsonb!={} │ titles jsonb!=[] │ updated_at! |
| `member_availability` | id! │ org_id! │ member_id! │ weekday! │ slot! │ preference!=often │ **source!=stated** │ created_at! │ updated_at! |
| `member_blocks` | id! │ org_id! │ blocker_id! │ blocked_id! │ reason │ created_at! |
| `member_coupons` | id! │ org_id! │ member_id! │ coupon_id! │ status!=active │ granted_at! │ used_at │ used_txn_id │ **expires_at** │ created_at! │ code │ used_order │ discounted_amount │ cost_bearer |
| `member_interactions` | id! │ org_id! │ member_id! │ **staff_id** │ channel!=system │ kind! │ note │ created_at! │ created_by |
| `member_likes` | id! │ org_id! │ liker_id! │ target_id! │ session_id │ created_at! |
| `member_tiers` | **code!**（PK）│ label! │ discount_pct!=0 │ threshold_amount │ sort!=0 │ is_active!=true │ note │ created_at! |
| `members` | id! │ org_id! │ **line_user_id** │ display_name! │ phone │ home_store_id │ **tier!=bubble_tea** │ gender │ **birthday** │ occupation │ district │ acquisition_source │ avatar_url │ **last_visit_at** │ **visit_count!=0** │ lifecycle!=new │ **primary_staff_id** │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **tier_override** │ last_app_active_at │ rank!='銅牌熊 I' │ title!='新手上路' │ likes_count!=0 │ **is_test!=false** │ about │ sched │ style jsonb │ see_score!='牌咖' │ baby_tile jsonb │ avatar_source!=bear │ avatar_photo_path │ avatar_photo_at │ avatar_blocked!=false │ avatar_removed_count!=0 │ inv_type!=member │ inv_carrier │ inv_donate_code │ inv_tax_id │ inv_title │ **phone_verified_at** |
| `order_items` | id! │ order_id! │ **product_id!** │ qty!=1 │ created_at! │ org_id! │ name │ unit_price! │ line_total │ **revenue_type!** |
| `order_payments` | id! │ org_id! │ store_id! │ order_id! │ method! │ amount! │ cash_received │ change_given │ ref_no │ staff_id │ created_at! |
| `orders` | id! │ org_id! │ store_id! │ member_id │ table_id │ **session_id** │ status!=open │ **channel!=counter** │ total_points!=0 │ deleted_at │ created_at! │ updated_at! │ **created_by** │ **updated_by** │ order_no │ subtotal!=0 │ coupon_discount!=0 │ tier_discount!=0 │ payable!=0 │ points_used!=0 │ cash_due!=0 │ tier_at_order │ **idempotency_key** │ wallet_txn_id │ paid_at │ entity_id │ is_test!=false │ tier_discount_pct │ txn_no |
| `orgs` | id! │ name! │ plan!=self │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ 🎯 **live_from**（2026-08-28 新增） |
| `phone_otps` | 🆕 2026-08-30。id! │ org_id! │ phone! │ code_hash! │ purpose! │ line_user_id │ attempts!=0 │ sent_at!=now() │ expires_at! │ verified_at │ consumed_at |
| `rank_tiers` | 🆕 2026-08-31 段位區間主檔。code!（PK）│ label! │ min_rating! │ sub_count!=4 │ **auto!=true** │ **band!='low'** │ sort! │ note。<br>6 列：銅 **910**／銀 1090／金 1270／白金 1450／鑽石 1630／大師 1810（**每階 45 × 4 = 180**）。<br>⚠ **大師熊 `auto=false`** —— 要「最近 50 場 ≥20 個不同對手」，分數到了也只到鑽石熊 I。<br>⚠ `band` 決定順位點：low（銅銀金）/ mid（白金鑽石）/ top（大師）。<br>⚠ RLS 啟用、**0 條 policy**：只被 `rank_detail_tx`（DEFINER）讀。 |
| `rank_points` | 🆕 2026-08-31 順位點主檔。band! │ place!（PK 兩欄）│ points!。<br>12 列，**分段正和**：low `+30/+15/0/−20`（**+25**）／mid `+30/+10/−10/−30`（0）／top `+30/+5/−20/−40`（**−25**）。 |
| `season_champions` | 🆕 2026-08-31。season!（PK）│ org_id! │ member_id │ rating │ awarded_at!。<br>🔴 **降階之前先記冠軍** —— 降完就再也算不出來了（不可回溯）。<br>⚠ 沒有人到大師時 `member_id` 是 **null**（誠實的「本季從缺」）。 |

> 🆕 **2026-08-31 段位那一批新增的欄位**
> · `members.rating!=1000` / `rating_games!=0`
> · `session_players.rating_after`（那一場打完幾分，走勢圖用）
> 🔴 ~~`members.peak_rating`~~ **同日建了又刪掉**：歸零／降階設計不需要它，
>   而降階保護也不需要（規則是「不掉階」的話，當前分數本身就記著他到過哪一階）。
> 🔴 **小級（I–IV）沒有自己的門檻欄位** —— 由 `[min_rating, 下一階 min_rating)`
> 平均切四段算出來。另外存一份就是第二個真相來源。
> **IV 最低、I 最高**（銅牌 IV 910 ／ III 955 ／ **II 1000 起始** ／ I 1045）。
> ⚠ **分數下限 910**（＝銅牌 IV，最低那一階的 `min_rating`）。

> 🔴 **`members.phone_verified_at`（2026-08-30 起才真的有人寫）** ——
> 欄位早就在，但在 `otp_consume_tx` 出現之前**掃全庫 0 支函式會寫它**。
> 也就是客人真的驗過簡訊，卻沒有人在他身上蓋章。
> 🎯 而**自助認領的分級完全建立在那個章上面**（未驗過的帳號只有在
> 沒有訂單也沒有餘額時才放行），所以那不是一個裝飾欄位。
>
> ⚠ `phone_otps` **啟用了 RLS 而且刻意 0 條 policy** ——
> 那不是漏掉：它只能被 service_role（Edge Function）碰到，
> 任何前端角色一律讀不到也寫不到。**驗證碼的雜湊沒有任何人需要看見。**

### 🎯 `orgs.live_from` —— 報表的第三層防線

**營運起始時間。`null` = 還沒上線 → 12 個 `v_real_*` 一律回 0 列。**

前兩層（根實體 `is_test`、自己的 `is_test`）**都依賴標記被正確設定**，
而那會壞 —— 2026-08-28 找到兩筆漏網事件（`test_event` 與一筆 `app_error`），
**兩筆都沒有門市也沒有會員，任何關聯都認不出它們是測試**。

🎯 **`coalesce(live_from, 'infinity')` 讓「忘記設」的後果是「報表全空」，
不是「報表錯的」。** 這個專案一再踩的坑（`is_test` 恆為 false、RLS 濾成空陣列、
`|| []` 讓數字通過）全都是「壞掉了但看起來正常」——**這個設計刻意讓失敗吵。**

⚠ **上線那天要做的唯一一件事**：
```sql
update orgs set live_from = '<真實客人開始使用的時間>';
```
🔴 那不是「修 bug 的日期」，是**真實客人開始使用**的時間。

### 12 個 `v_real_*`（報表一律查這些，不要查原表）

```
根實體  v_real_stores          v_real_members
交易    v_real_orders          v_real_order_items     v_real_order_payments
        v_real_topup_orders    v_real_wallet_txns     v_real_invoices
桌      v_real_table_sessions  v_real_session_players
配桌    v_real_match_queues
埋點    v_real_app_events
```

📌 **子表直接引用父表的 view**（`v_real_order_items` → `exists(v_real_orders)`）
—— 規則只定義一次，不可能漂。
⚠ 這些 view **一個授權都沒有** —— 只有 `service_role`／Dashboard 讀得到，
  跟「只有總部分析數據的人看得到」是一致的。
| `pricing_tiers` | id! │ org_id! │ store_id │ mode! │ rule_key! │ min_unit │ max_unit │ points! │ sort_order!=0 │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by |
| `product_taxonomy` | **dimension!** │ **code!**（PK 是兩者）│ label! │ parent_code │ sku_prefix │ sort!=0 │ is_active!=true │ note │ created_at! │ default_revenue_type |
| `products` | id! │ org_id! │ **sku!** │ name! │ **category!** │ **unit_price!** │ unit_cost │ **is_active!=true** │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **stock_qty!=0** │ **is_available!=true** │ **revenue_type!** │ **subcategory** │ **tracks_stock!=true** │ **is_system!=false** │ **discountable!=true** |
| `queue_tags` | code!（PK）│ label! │ sort_order!=0 │ is_active!=true │ created_at! |
| `recurring_tables` | id! │ org_id! │ store_id! │ weekday │ start_time! │ stake_level_id! │ game_type!='16張' │ **rounds!='2 將'**（同上）│ seats!=4 │ enabled!=true │ note │ created_at! │ frequency!=weekly │ flower │ lead_hours!=24 │ tags jsonb!=[] |
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
| `members.members_avatar_source_chk` | bear / photo　⚠ **只有兩個值** —— LINE 大頭貼要走 `photo`（抓下來存自己的 storage），不要加第三個值 |
| `members.avatar_bear` | 🆕 2026-08-29。會員選用的小熊造型名稱（例：`金牌熊`）。**null = 沒選過，依 `rank` 推導**（維持原行為）。<br>⚠ **刻意不加 CHECK**：小熊清單是**內容**不是狀態，會增加；壞值時 `rankBearSrc()` 會 fallback 回**銅牌熊**，不會壞掉。<br>📌 渲染規則：`rankBearSrc(avatar_bear \|\| rank)` |
| `members.rank` | NOT NULL **DEFAULT `'銅牌熊 I'`**，🔴 **沒有 CHECK**。<br>⚠ `rankBearSrc()` 是用 `indexOf` 逐條比對關鍵字（雀神→大師→鑽石→白金→金牌→銀牌→其餘銅牌），<br>所以 `'大師級銅牌熊'` 會匹配到**大師** —— 順序決定結果。今天只有系統在寫這欄，但值得知道 |
| `members.members_phone_chk` | NULL 或 `= migi_norm_phone(phone)`（2026-08-28 新增）—— **等於強制只收 09 開頭 10 碼**，市話與國際格式在寫入時就被擋 |
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
| `phone_otps.phone_otps_purpose_check` | **register / claim / change** 🆕 2026-08-30。<br>⚠ 註冊流程實際用的是 **`register`**（驗過之後由後端決定是註冊還是認領）；<br>`claim` 留給日後獨立出來的認領入口，`change` 給個人設定改手機 |

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
  find-or-bind-or-create，回傳 action ∈
    existing_line / rebound / line_conflict / existing_phone / created
  ⚠ **raise 的訊息是英文代碼不是中文人話**（前端必須自己翻，見 App.jsx 的 REG_ERR）：
    phone_invalid ／ display_name_reserved ／ display_name too long (max 12)
    ／ display_name required ／ need phone or line_user_id ／ org_id required
  ✅ 2026-08-28 起：**暱稱與手機都在「查詢之前」與「寫入之前」正規化**
    （migi_norm_nickname／migi_norm_phone），禁字改成明確 raise
    `display_name_reserved` 而不是讓 CHECK 拋 23514。
    🔴 在此之前只做 trim → 暱稱有連續兩個空格或全形空格就撞
      members_display_name_chk，客人看到「資料有誤」而永遠註冊不了。
rebind_line_user_tx(p_member_id, p_new_line_user_id, p_staff_id, p_reason)
  ⚠ 這是**店員的補救工具**不是註冊流程的一部分（簽名有 p_staff_id 就是證據）
get_my_profile_tx / get_wallet_tx / get_my_orders_tx / get_my_games_tx
set_my_nickname_tx / set_my_avatar_tx / set_my_title_tx / set_my_about_tx
set_my_sched_tx / set_my_style_tx / set_my_baby_tile_tx / set_my_see_score_tx
set_my_home_store_tx / set_my_birthday_tx / set_my_availability_tx / get_my_availability_tx
set_avatar_tx / admin_remove_avatar_tx / save_app_state_tx / mark_app_active_tx
set_invoice_pref_tx / list_members_tx

set_my_profile_basics_tx(p_org_id, p_member_id, p_birthday date = null, p_gender text = null)
  DEFINER · anon ✅ · 2026-08-28 新增
  ⚠ **null = 不動那一欄**（不是清空）—— 註冊時生日與性別可以分開補
  ⚠ 性別在函式裡驗（回 `gender_invalid`），不是丟給 CHECK 拋 23514
```

### 🔴 身分與簡訊驗證（2026-08-30 · **全部只給 service_role**）

```
otp_request_tx(p_org_id, p_phone, p_purpose, p_line_user_id)      → 產碼 ＋ 三道限流
otp_verify_tx(p_org_id, p_phone, p_code, p_purpose)               → 驗碼（5 次上限）
phone_recently_verified_tx(p_org_id, p_phone, p_line_user_id, p_purpose) → 15 分鐘內驗過？
otp_consume_tx(p_org_id, p_phone, p_line_user_id, p_purpose, p_member_id) → 用掉 ＋ 蓋章
claim_member_by_phone_tx(p_org_id, p_phone, p_line_user_id, p_purpose='register')
set_member_phone_tx(p_org_id, p_line_user_id, p_phone)
get_member_by_line_tx(p_org_id, p_line_user_id)                   → whoami（手機遮罩）
phone_in_use_tx(p_org_id, p_phone, p_line_user_id)                → ⏳ 目前沒有人呼叫
register_member_tx(...)                                           → 🔴 2026-08-30 收回 anon
```

🔴 **這九支一律 `只給 service_role`，前端一個都叫不動。**
  它們每一支不是「改你是誰」就是「決定要不要把一個帳號交給你」——
  唯一的入口是 Edge Function `line-login`（驗過 LINE 簽章之後才碰得到）。
  ⚠ 收的時候**兩個方向都要收**（硬規則 2.6／2.6b）：
  `revoke from public`（舊函式的 PUBLIC 繼承）＋
  `revoke from anon`（新函式的 default privileges 明確授權）。

🔴 **`get_my_profile_tx` 回的是完整手機，不是遮罩**（2026-08-30 下午改回來）。
  它一度做成 `phone_masked`（`0910***736`），當天就換掉 ——
  遮罩答不出「**這是我的哪一支**」，而那是個人設定顯示它的唯一用途。
  ⚠ 代價：這支是 **anon ＋ 前端送 `p_member_id`** ⇒ 知道某人的 member uuid
    就查得到他的手機。**已知並接受的取捨**（它本來就已經回生日與性別了），
    待辦 14 改吃 `auth.uid()` 之後歸零。
  ⚠ **`get_member_by_line_tx`（whoami）仍然是遮罩的** —— 那條路上沒有畫面
    在讀它。兩支的行為不同是刻意的，不是漏改。

📌 **`phone_in_use_tx` 現在沒有任何呼叫端。**
  它原本給註冊第 2 步「邊打邊查這支號碼有人用嗎」，
  2026-08-30 整個拿掉 —— 那個訊息是死路（**真正的號碼主人也被擋在門外**），
  而且它本身是一個「有 LINE 就能一直問某支號碼是不是會員」的查詢器。
  ⚠ 先留著不刪：它是**唯一**「不會順手建立帳號」的手機查詢，
  日後 POS 幫客人註冊時很可能會用到。**但下次盤點死碼時要重新問一次。**

### 🆕 段位（2026-08-31）

> 🔴 **規則以《決策紀錄》第二十三節為準。** 這一段只寫「資料庫裡實際是什麼」。
> ⚠ 2026-08-31 當天做過兩版：先是我憑對 LOL 的印象做的 Elo 版（已作廢），
>   當天改成拍板的**分段正和**。`apply_session_results_tx` 已刪除。

```
apply_session_rounds_tx(p_session_id, p_rounds)     🔴 只給 service_role
  p_rounds = [ [ {"member_id":"…","finish_rank":1}, …四人 ], …一將一個陣列 ]
  一將一將依序套用 → 寫 finish_rank/score_points/rating_after → 更新 rating/rank
  ⚠ 未滿 2 將 → too_few_rounds　｜　不是四人 → need_four_players
  ⚠ 冪等：任一人已有 finish_rank → already_applied（重按不會再扣一次分）
  ⚠ 名次必須剛好是 1..n（不接受並列、不接受跳號）
reset_season_ratings_tx(org, season, drop_tiers=2)  🔴 只給 service_role
  先記冠軍 → 所有人降 2 大階（360 分）→ 夾在 910　｜　同一季只能結一次
member_rank_tx(member_id) → text  anon ✅  含大師的對手多樣性判斷
get_my_rank_tx(org, member) → jsonb anon ✅  成績頁 Hero 用（含大師的對手多樣性）
rank_detail_tx(rating)    → jsonb anon ✅
  小級：rank / tier / sub / band / tier_min / progress / to_next / at_top
  大階：next_tier / to_next_tier / tier_progress   ← Hero 的進度條用這一組
rank_from_rating(rating)  → text  anon ✅  只是取 rank_detail_tx 的 rank
```

🔴 **名次只給 service_role**：那是店員登記的**事實**，不是客人可以宣告的。
  讓前端叫得動就等於「自己填自己第一名」（同待辦 40 的稱號那個病）。
  ⏳ 店員登入（待辦 20）做好之後 POS 包一層 DEFINER 呼叫；
  名次的最終來源是**電子計分**（決策紀錄二十四）。

### 🔴 兩條容易搞混的降階規則

| | 銅／銀／金 | 白金以上 |
|---|---|---|
| **賽季中** | 🛡 **不掉階**（扣分後夾在當前階的下限） | ✅ 會掉 |
| **賽季末** | ✅ **降 2 大階** | ✅ 降 2 大階 |

🎯 **賽季中的保護不需要 `peak_rating`** —— 規則是「不掉階」的話，
  當前分數本身就記著他到過哪一階（因為他掉不出去），夾在當前階下限即可自我維持。
⚠ **階內仍然可以降小級**（I→II→III→IV）。
⚠ **band 會在一場之內重算** —— 白金掉到金牌之後，下一將吃的是低段的 −20 不是 −30。
⚠ **大階寬度從主檔算，不要寫死 180** —— 每階 45 一定會調。

### 🎯 小級與大階是兩組數字，不要混用

| | 用在哪 |
|---|---|
| **小級**（`progress` / `to_next`） | 標題的「金牌熊 **II**」—— 動得比較頻繁，細顆粒回饋 |
| **大階**（`tier_progress` / `to_next_tier`） | **成績頁 Hero 的進度條與副標** |

🔴 **進度條一定要用大階**：獎勵是小熊，而**小熊只在大階換** ——
  進度條填滿卻什麼都沒發生，是最糟的一種回饋。
⚠ **進度條與副標必須同一個維度**，一個講小級一個講大階的話，
  條滿了字還說「還差 90 分」，那看起來就是壞的。
⚠ `next_tier` **要看全部的階**（含 `auto=false` 的大師熊）——
  客人爬到鑽石 I 之後仍然要看得到「大師熊」這個目標。

### 🎯 認領的分級（`claim_member_by_phone_tx`）

| 舊帳號的狀態 | 自助 | 回傳 |
|---|---|---|
| 已經綁在**你自己**的 LINE 上 | ✅ | `already_yours`（**排在驗證檢查之前** —— 見下） |
| 手機**驗過** | ✅ | `claimed` |
| 未驗 ＋ 沒訂單也沒餘額 | ✅ | `claimed` |
| 未驗 ＋ **有訂單或有餘額** | 🔴 | `staff_required` |
| 已綁**別的** LINE | 🔴 | `line_bound_elsewhere` |
| 你的 LINE 已經有別的會員 | 🔴 | `merge_required` |

🔴 **`already_yours` 與 `unchanged` 必須排在驗證檢查之前。**
  驗證碼**用過一次就消耗**，排在後面的話雙擊的第二次會拿到 `not_verified`
  —— 客人看到「成功的那一次顯示失敗」。
  **冪等不可以依賴一個會被用掉的東西。**
  ⚠ 那不是洩漏：它只認得出「這個帳號已經綁在你自己的 LINE 上」，
  而 `whoami` 開機時早就告訴他了。

✅ ~~沒有「改手機」的 RPC~~ → **`set_member_phone_tx` 已於 2026-08-30 建立**
  （待辦 36 的 D2）。舊號碼是什麼**不重要** —— 你證明的是「我控制這支新號碼」。
  驗不了（手機已經不在手上）才要找店員。

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
migi_norm_phone(p text)   INVOKER · anon ✅ · 2026-08-28 新增
  去掉所有非數字 → `+886`／`886` 開頭補回 `0` → 必須符合 `^09\d{8}$`，否則回 null
  ⚠ **`register_member_tx` 在「查詢之前」與「寫入之前」都會正規化** ——
    所以客人填 `0912-345-678` 找得到用 `0912345678` 註冊的舊帳號。
    那正是情境 C（換 LINE 帳號）唯一的橋。
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
