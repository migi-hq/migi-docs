# migi-pos 原始碼現況與待辦 1、2 的技術發現

> 這是什麼：2026-08-14 對 migi-pos 原始碼的盤點結果，
> 以及待辦 1（`enterTable` 改走新結帳頁）與待辦 2（還原座位）目前卡在哪裡。
> 什麼時候讀：接手待辦 1 或 2 之前。

## 檔案清單

`src/` 共 10 個檔案：

| 檔案 | 行數 | 狀態 |
| --- | --- | --- |
| `OpenCheckoutPage.jsx` | 1018 | 已改寫，新版開桌結帳頁 |
| `App.jsx` | 432 | 已改，含 `BoardPage` 桌況與 `enterTable` |
| `OpenSetupPage.jsx` | 199 | 新增 |
| `SeatPage.jsx` | 152 | |
| `lib/api.js` | 146 | |
| `TablePage.jsx` | 82 | **舊檔，已壞** |
| `lib/supabase.js` | 28 | |
| `shared.jsx` | 18 | |
| `main.jsx` | 10 | |
| `vite.config.js` | 9 | |

## 待辦 1 的實際狀況：比「假資料」更嚴重

`App.jsx` 的 `enterTable` 目前是 `setDetailNo(t.label); setPage("detail")`，
接著把寫死的 `DETAIL_PLAYERS`（小明／阿華／美美／阿強）灌進 `TablePage`。

但問題不只是假資料——`TablePage.jsx` 傳給 `OpenCheckoutPage` 的是**舊 props**：

```jsx
ctx={{ table, mode2: "open" }}
```

而改寫後的 `OpenCheckoutPage` 解構的是：

```jsx
{ sessionId, table, mode, rounds, minutes, kind, flower, stakeLabel }
```

`mode`、`minutes` 全是 undefined，`PRIV_LABEL[undefined]` 會直接炸。
也就是說這條路現在是**壞的**，不是單純顯示假資料。

因此待辦 1 不是「改個路由目標」，要先決定：
**`TablePage` 重寫，還是直接繞過讓 `enterTable` 走 `OpenCheckoutPage`。**

## 卡住待辦 1、2 的未知數

`enterTable` 拿到的 `t` 物件裡**有沒有 `session_id`**，決定了工作範圍：

- 有 → 純前端就能解決待辦 1
- 沒有 → 得連 `list_tables_tx` 這支 RPC 一起改，或前端多打一次查詢

目前 `BoardPage` / `TableCard` 只用到 `t.id`、`t.label`、`t.status`、
`t.players`、`t.seats`、`t.started_at`、`t.area`、`t.note`，
看不出 `list_tables_tx` 到底回了什麼。

同理，待辦 2 要用 `get_session_tx` 還原座位，也得先知道它的回傳結構
（哪個欄位標示已結帳、哪個標示代付中）。

**依照「不線上猜欄位」的規矩，這兩題要等資料庫盤點結果出來才動工。**
盤點用的唯讀 SQL 見 `sql/pending/db-introspect-m2.sql`，
執行結果建議存成 `docs/db-snapshot-<日期>.md`。

## 順帶記下的架構事實

- POS 用 anon key、沒有 auth session，而資料表都有 RLS
  （`org_id = current_org_id()`），所以**直接 `supabase.from('表').select()`
  會回空陣列且不報錯**——必須走 SECURITY DEFINER 的 RPC。
  這種 bug 很難抓，是硬規則的由來。
- `tables` 表沒有 `status` 欄位，桌況從 `table_sessions` 動態算。
- `table_sessions.status` 的 constraint 只允許
  `open` / `completed` / `voided`（是 `voided`，不是 `void`）。
