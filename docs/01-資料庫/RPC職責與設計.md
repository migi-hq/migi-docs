# RPC 職責與設計

> **這是什麼**：每支 RPC 負責什麼、怎麼設計的、能不能用。
> **什麼時候讀**：要呼叫後端功能、或評估「這個功能該新開發還是改既有的」之前。
>
> ⚠ **簽名與參數順序一律以 [`db-現況快照.md`](db-現況快照.md) 為準**，本檔只講職責與設計要點。
> 改既有函式前還要先 `pg_get_functiondef` 撈線上版（`CLAUDE.md` 硬規則 3）——
> **`sql/applied/` 不是線上現況的鏡像。**
>
> 合併自 `後端RPC清單` 與 `資料模型與RPC`（2026-08-15）。

> **為什麼需要這份**：規劃文件曾長期把 `open_session_tx` 列為「待接」，
> 讓人以為是修改既有函式，實際上它**從未存在** —— 這種誤會會讓工時估算全錯。
> 本檔只記查證過的事實。

---

## 一、結帳核心

### `checkout_tx` ✅ 可用（最重要的一支）

**職責**：所有收款的唯一入口。任何要收錢的流程都應委派給它，不要自己重寫。

**`p_items` 格式**

```json
[{"product_id":"...","name":"水餃","kind":"fnb","qty":1,"unit_price":80}]
```

`kind` 限 fee / fnb / goods。

> 🔴 **價格來自傳入的 `unit_price`，不讀 `products` 表。**
> 前端送什麼價格就記什麼價格，**可以送 0**。
> POS 是店員在用風險可控，但 KIOSK 或任何會員端能觸發結帳的路徑一出現就是漏洞。
> **KIOSK 開工前必須改成只送 `product_id` + `qty`。** 見 `CLAUDE.md` 待辦 2。

**`p_payments` 格式**

```json
[{"method":"cash","amount":70,"cash_received":100,"change_given":30}]
```

`method` 限 cash / credit_card / line_pay。

**執行順序（v1.9）**

1. **冪等檢查** —— `idempotency_key` 已存在就直接回原結果，不重複扣款
2. **小計** —— 伺服器依 items 重算，按 kind 分成 fee / fnb / goods 三桶
3. **券折抵** —— 依 `coupons.applies_to`（table_fee / fnb / null 通用）決定可折範圍；
   `discount_type` 分 free（該範圍全免）／fixed（定額）／percent（百分比）；
   檢查 `min_spend` 門檻、套用 `max_discount` 上限；free 券可綁 `free_product_id` 指定商品
4. **等級折扣** —— 凍結當下等級與折扣率，基準為券折後金額
5. **點數折抵** —— 夾在 `[0, min(錢包餘額, 應付金額)]`
6. **收款驗證** —— `p_payments` 金額總和必須**剛好等於**應付減點數後的餘額
7. **寫入五張表** —— `orders`（order_no 由 trigger 產生）、`order_items`、
   `wallet_txns`（點數扣款一筆 spend，`counter_account='liability'`）、
   `order_payments`、`member_coupons`（券核銷）

**設計要點：這是 tender 模型。**
先算出應付金額（元），**點數只是折抵手段之一**，剩餘用現金／刷卡補足。
所以它天生支援純點數／純現金／混合付款 —— 元計價改制時後端幾乎沒動。

### `pos_addon_checkout_tx` ✅ 可用（2026-08-15 新增）

POS 加購專用。`SECURITY DEFINER` 包住 `checkout_tx`，**只收商品、不再收檯費**。

存在的理由：`checkout_tx` 是 INVOKER（見下方警告），POS 用 anon 無 session 呼叫不到。

---

## 二、開桌流程（2026-08-07 上線）

一律**兩步制**：先開桌建立場次（不收費）→ 每來一人收費入座 → 滿四或店員手動啟動。

### `open_session_tx` ✅
建立場次，**不收費**。

**安全設計**：`org_id` / `store_id` **由桌位反查**，不接受呼叫端傳入 —— 防跨租戶操作。

### `calc_session_fee_tx` ✅
試算檯費，讓店員收費前先看到金額與品名。依 mode + join_type 推出 `SVC-TBL-*` 貨號再查 `products`：

| 情境 | 貨號 |
|---|---|
| 配桌 opener，`planned_rounds=2` | `SVC-TBL-M2` |
| 配桌 opener，其他 | `SVC-TBL-M3` |
| 配桌 mid_join / sub | `SVC-TBL-MID` |
| 包桌 opener | 依 `planned_minutes` 取 P02 / P05 / P24 |
| 包桌非 opener | **回 0 元**（整桌計價，後續入座不另收）|

回傳含 `product_id` —— 所以要改成「後端自己查價」時，這條路是通的。

### `join_session_tx` ✅
加人並收費。**收費全部委派給 `checkout_tx`**，本身只負責「決定收哪個檯費商品」與「入座」。

- 落實「一律會員」鐵則：member 不存在直接擋下
- 冪等鍵帶入座序號（`session:member:seq`）—— 同一人退出後再加入視為新的收費事件
- 收費後補上 `orders` 的桌次脈絡（`session_id` / `table_id` / `channel` / `entity_id`）
- 金額為 0（包桌後續入座）時不建訂單，直接入座
- **代付**走 `p_pay_for uuid[]` 參數，**沒有獨立函式**

### `activate_session_tx` ✅
啟動桌子（滿四自動／店員手動）。寫入 `activated_at`，**不改 status**。

### `get_session_tx` ✅
POS 本桌頁用。回傳場次資訊 + 玩家清單（暱稱、段位、頭像、入座類型、實付金額）。

> ⏳ **目前不回傳 `members.title`**，所以 POS 座位卡的稱號永遠顯示不出來。
> 見 `CLAUDE.md` 待辦「座位卡的稱號永遠不會顯示」。

### `check_session_blocks_tx` ✅
互黑檢查。**只警示不阻擋** —— 系統處理標準，人處理例外。

### `list_tables_tx` ✅
桌況列表。回傳含 `session_id`，POS 進入已開桌就靠它。

### `cleanup_empty_sessions_tx` ✅（2026-08-14）
作廢「開超過 N 分鐘且無人入座」的場次，pg_cron 每 10 分鐘跑一次。

存在的理由：開桌設定按下去就建 session，店員中途離開會留下「使用中但 0 人」的桌，
桌位卡住無法再開。

> 曾考慮改成「延後建立 session」（第一個客人結帳時才建），
> 但那會讓「加了人就離開」的狀態完全存不住。**立刻建立 + 自動清理**是較好的組合。

---

## 三、錢包（M1）

`wallet_topup_tx` 儲值 ・ `reverse_txn_tx` 退款沖正 ・ `get_wallet_tx` 讀餘額與明細。

共用核心 `_charge_core`：鎖錢包列 → 查冪等 → 驗餘額 → 寫流水 → 更新快取餘額。

`wallet_txns` **沒有觸發器會自動同步 `wallets.balance`** ——
手動插流水之後要呼叫 `fix_wallet_balance_tx` 重算。

---

## 四、⚠️ INVOKER 陷阱

以下函式是 `SECURITY INVOKER`（其餘絕大多數 `_tx` 都是 DEFINER）：

```
_charge_core     charge_fnb_tx     charge_matched_tx    charge_private_tx
checkout_tx      reverse_txn_tx    wallet_topup_tx      settle_session_tx
```

被其他 DEFINER 函式**內部呼叫沒問題**；
但 POS 用 anon key 且無 auth session，**直接呼叫會被 RLS 擋成空結果且不報錯**。

→ 這就是為什麼有 `pos_addon_checkout_tx` 這種 DEFINER 包裝層。
→ 實作 `settle_session_tx` 時**必須改成 DEFINER**，且依硬規則 2 要先 `DROP FUNCTION`。

---

## 五、已封存 ⛔

| 函式 | 為什麼停用 |
|---|---|
| `charge_matched_tx` | v1.0 純點數扣款，不支援現金與混合付款；且查 `pricing_tiers`（該表為空）必報錯 |
| `charge_private_tx` | 同上 |

**封存方式**：`REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`。
函式本體保留供稽核，只是前端無法呼叫。改用 `join_session_tx`。

`charge_fnb_tx` 同屬舊系列，POS 做點餐功能時一併改走 `checkout_tx`（尚未處理）。

---

## 六、待開發

| 功能 | 狀態 |
|---|---|
| **`settle_session_tx` 改寫** | 目前是空殼。需補：包桌超時補收（依 `activated_at` 算實際時長比對級距補差額）、建立發票、消費累積、店員業績歸因。**目前最大的洞，也是唯一牽涉收錢的**（`CLAUDE.md` 待辦 3）|
| **會員消費明細 `get_my_orders_tx`** | 不存在。會員 App 現在只看得到點數流水，**付現金的消費完全看不到**（`CLAUDE.md` 待辦 1）|
| 當日暢打（`SVC-TBL-DAY`）收費路徑 | `open_session_tx` 只收 matched / private，暢打商品建了卻收不到。規則細節也尚未拍板 |
| 超時提醒（時段結束前 10 分鐘）| 未實作，需 pg_cron 或前端計時 |
| `has_store_access(p_store_id)` | ✅ **2026-08-23 已撈全文驗證**：`exists(select 1 from current_staff() cs where cs.role='hq' or cs.store_id = p_store_id)` —— `hq` 通吃，其餘比對門市，邏輯是對的。<br>🔴 **但它現在恆為 false**：`current_staff()` 靠 `members.line_user_id = auth.jwt()->>'sub'`，而 POS 用 anon 沒有 JWT。要等 LINE 接上（CLAUDE.md 待辦 20）才會活過來。 |

---

## 七、已知待修

### `leave_match_queue_tx` 有多載孤兒版

三參數版（舊）與四參數版（新，含 `p_reason`）並存。
`migi-web/src/lib/social.js` 一律傳具名參數，PostgREST 只會打到新版，全專案無其他呼叫點。
→ 舊版可安全刪除，見 `sql/pending/2026-08-14_drop_leave_match_queue_overload.sql`。

### `list_match_queues_tx` 的 `p_member` 語意

參數是為**會員端**設計的（「我的房」）。
POS 要的是「本店所有進行中的房」，**得先確認 `p_member` 傳 null 的行為**
才能接配桌列表（`CLAUDE.md` 待辦「配桌列表整頁是假資料」）。

---

## 八、輔助函式

### `current_org_id()` ⚠️ 關鍵

RLS policy 的核心，回傳當前登入者所屬的 org_id。
先查 `staff.auth_uid = auth.uid()`，再查 `members.line_user_id = auth.jwt()->>'sub'`。

**必須是 `SECURITY DEFINER` + `SET search_path = public`**，
否則查表時受 RLS 限制 → 觸發那些表的 policy → 又呼叫 `current_org_id()` →
無限遞迴 → `stack depth limit exceeded`（讀取 500）。

這是 Supabase RLS 教科書級陷阱，詳見 [`../08-決策與踩坑/踩過的坑.md`](../08-決策與踩坑/踩過的坑.md) 第 8 條。

### 其他

`current_member_id()` / `current_staff()` / `next_doc_no()` / `_blocked_between()`（互黑判斷）。

**觸發器函式不要直接呼叫**：`app_events_no_mutate`、`payments_no_mutate`、
`block_txn_mutation`、`prevent_org_change`、`set_updated_at`、`set_is_test_from_store`、
`audit_wallet_balance`、`trg_orders_set_no`、`trg_topup_set_no`、`trg_coupon_set_code`。
