# 後端 RPC 清單與職責

> **這是什麼**：資料庫裡所有 RPC 函式的職責、參數、狀態（可用／已封存／未開發）。
> **什麼時候讀**：要呼叫後端功能、或評估「這個功能要新開發還是改既有的」之前。
> **為什麼重要**：規劃文件曾長期把 `open_session_tx` 列為「待接」，讓人誤以為是修改既有函式，實際上它從未存在——這種誤會會讓工時估算全錯。本文只記查證過的事實。

---

## 一、結帳核心

### `checkout_tx` ✅ 可用（最重要的一支）

**職責**：所有收款的唯一入口。任何要收錢的流程都應委派給它，不要自己重寫。

**參數**
```
p_member_id, p_store_id, p_items(jsonb), p_coupon_ids(uuid[]),
p_points_used(bigint), p_payments(jsonb), p_idempotency_key, p_staff_id
```

**p_items 格式**
```json
[{"product_id":"...","name":"水餃","kind":"fnb","qty":1,"unit_price":80}]
```
kind 限 fee / fnb / goods。**價格來自這裡傳入的 unit_price，不讀 products 表**。

**p_payments 格式**
```json
[{"method":"cash","amount":70,"cash_received":100,"change_given":30}]
```
method 限 cash / credit_card / line_pay。

**執行順序（v1.9）**
1. 冪等檢查（idempotency_key 已存在 → 直接回原結果，不重複扣款）
2. 小計：伺服器依 items 重算，按 kind 分成 fee / fnb / goods 三桶
3. 券折抵：依 coupons.applies_to（table_fee / fnb / null 通用）決定可折範圍；discount_type 分 free（該範圍全免）／fixed（定額）／percent（百分比）；檢查 min_spend 門檻、套用 max_discount 上限；free 券可綁 free_product_id 指定商品
4. 等級折扣：凍結當下等級與折扣率，基準為券折後金額
5. 點數折抵：夾在 [0, min(錢包餘額, 應付金額)]
6. 收款驗證：p_payments 金額總和必須**剛好等於**應付減點數後的餘額
7. 寫入五張表：orders（order_no 由 trigger 自動產生）、order_items、wallet_txns（點數扣款一筆 spend，counter_account='liability'）、order_payments（收款明細）、member_coupons（券核銷）

**回傳**：order_id, order_no, subtotal, coupon_discount, tier, tier_rate, tier_discount, payable, points_used, cash_due, new_balance

**設計要點**：這是 **tender 模型**——先算出應付金額（元），點數只是折抵手段之一，剩餘用現金／刷卡補足。因此它天生支援「純點數／純現金／混合付款」，元計價改制時後端幾乎不用動。

---

## 二、開桌流程（2026-08-07 上線）

一律**兩步制**：先開桌建立場次（不收費）→ 每來一人收費入座 → 滿四或店員手動啟動。

### `open_session_tx` ✅ 可用
建立場次，**不收費**。
```
p_table_id, p_mode('matched'|'private'), p_stake_level_id,
p_planned_rounds(2|3), p_planned_minutes(120|300|1440),
p_staff_id, p_open_method('auto'|'manual'), p_idempotency_key
```
**安全設計**：org_id / store_id **由桌位反查**，不接受呼叫端傳入，防跨租戶操作。

### `calc_session_fee_tx` ✅ 可用
試算檯費，讓店員收費前先看到金額與品名。依 mode + join_type 推出 SVC-TBL-* 貨號再查 products。
- 配桌 opener → planned_rounds=2 取 `SVC-TBL-M2`，否則 `SVC-TBL-M3`
- 配桌 mid_join / sub → `SVC-TBL-MID`
- 包桌 opener → 依 planned_minutes 取 P02 / P05 / P24
- 包桌非 opener → 回 0 元（整桌計價，後續入座不另收）

### `join_session_tx` ✅ 可用
加人並收費。**收費全部委派給 checkout_tx**，本身只負責「決定收哪個檯費商品」與「入座」。
```
p_session_id, p_member_id, p_join_type('opener'|'mid_join'|'sub'),
p_coupon_ids, p_points_used, p_payments, p_staff_id, p_idempotency_key
```
- 落實「一律會員」鐵則：member 不存在直接擋下
- 冪等鍵帶入座序號（`session:member:seq`），同一人退出後再加入視為新的收費事件
- 收費後補上 orders 的桌次脈絡（session_id / table_id / channel / entity_id）
- 金額為 0（包桌後續入座）時不建訂單，直接入座

### `activate_session_tx` ✅ 可用
啟動桌子（滿四自動／店員手動）。寫入 activated_at，不改 status。

### `get_session_tx` ✅ 可用
POS 本桌頁用。回傳場次資訊 + 玩家清單（含暱稱、段位、頭像、入座類型、實付金額）。

### `check_session_blocks_tx` ✅ 可用
互黑檢查。**只警示不阻擋**——系統處理標準，人處理例外。

---

## 三、錢包（M1）

`wallet_topup_tx` 儲值 ・ `reverse_txn_tx` 退款沖正 ・ `settle_session_tx` 收桌結算（仍是空殼待改寫）
共用核心 `_charge_core`：鎖錢包列 → 查冪等 → 驗餘額 → 寫流水 → 更新快取餘額。
另有讀取用 `get_wallet_tx`（餘額 + 交易明細）。

---

## 四、已封存 ⛔

| 函式 | 為什麼停用 |
|---|---|
| `charge_matched_tx` | v1.0 純點數扣款，不支援現金與混合付款；且查 pricing_tiers（該表為空）必報錯 |
| `charge_private_tx` | 同上 |

**封存方式**：`REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`
函式本體保留供稽核，只是前端無法呼叫。改用 `join_session_tx`。

`charge_fnb_tx` 同屬舊系列，POS 做點餐功能時一併改走 checkout_tx（尚未處理）。

---

## 五、待開發

| 功能 | 狀態 |
|---|---|
| 當日暢打（SVC-TBL-DAY）的收費路徑 | open_session_tx 只收 matched / private，暢打商品建了卻收不到 |
| `settle_session_tx` 改寫 | 目前空殼。需補：包桌超時補收、建立發票、消費累積、店員業績歸因 |
| 超時提醒（時段結束前 10 分鐘） | 未實作，需 pg_cron 或前端計時 |
| `has_store_access()` 門市權限檢查 | 待 Supabase Auth 接上後補，限制店員只能操作自己門市 |

---

## 六、輔助函式

### `current_org_id()` ⚠️ 關鍵
RLS policy 的核心，回傳當前登入者所屬的 org_id。
先查 `staff.auth_uid = auth.uid()`，再查 `members.line_user_id = auth.jwt()->>'sub'`。

**必須是 `SECURITY DEFINER` + `SET search_path = public`**，否則查表時受 RLS 限制 → 觸發那些表的 policy → 又呼叫 current_org_id() → 無限遞迴 → `stack depth limit exceeded`。詳見《踩過的坑》。
