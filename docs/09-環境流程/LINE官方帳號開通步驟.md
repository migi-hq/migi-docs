# LINE 官方帳號開通步驟

> 2026-09-04 建。**照著做的順序**，不是說明文件。
>
> 🔴 為什麼獨立一份：CLAUDE.md 待辦 38 有完整的脈絡與理由，
> 但那是**一段長文** —— 實際操作時會漏掉其中一兩格，
> 而漏掉的通常是**第 5 步**（`Add friend option`）。
>
> 🎯 **為什麼優先做這一項**：它是四件待辦裡**唯一會被「等」卡住**的 ——
> 門市 QR 要印刷，而 QR 上的加好友 URL 需要官方帳號 ID。
> 其他三項的速度都由你控制。

---

## 🔴 開始之前：一個硬條件

**Messaging API channel 必須建在同一個 Provider（`咪吉有限公司`）底下。**

LINE 的 `userId` 是 **per-Provider 不是 per-channel** ——
同 Provider 的所有 channel，同一個人拿到同一個 `userId`；
**不同 Provider 會是兩個不同的值**。

而 `members.line_user_id` 只有一欄 ⇒ 分成兩個 Provider 的話，
同一個人在會員 App 與官方帳號會變成兩個 id，
**而且不會報錯，只是接不起來**。

---

## 步驟

### 1️⃣ 建立官方帳號（🔴 2026-09-05 更正：流程跟這份文件原本寫的不一樣）

🔴 **不能再從 LINE Developers Console 直接建 Messaging API channel。**
實際點下去看到的是：

> It's no longer possible to create Messaging API channels directly from
> the LINE Developers Console. To create a Messaging API channel, create a
> LINE Official Account using the Create a LINE Official Account button below,
> and then enable the use of the Messaging API on the LINE Official Account Manager.

⚠ 這份文件原本寫「`Create a new channel` → `Channel type: Messaging API`」——
**那是舊流程**，照著做會走進死路。
📌 順帶說明它為什麼會錯：那一段是 2026-09-04 憑對 LINE 後台的印象寫的，
**沒有實際點過**。同硬規則 3：猜錯的成本遠高於多問一次。

### 新的順序

```
① developers.line.biz → 咪吉有限公司 → Create a new channel → Messaging API
   → 會看到上面那段說明 → 按綠色的「Create a LINE Official Account」
② 跳到 LINE Official Account Manager（外部網站）→ 建立官方帳號
③ 回到 LINE Official Account Manager → 設定 → Messaging API → **啟用**
④ 啟用完，channel 才會出現在 LINE Developers Console 裡
```

### 🔴 第 ③ 步會問你要掛在哪個 Provider —— **一定要選「咪吉有限公司」**

**這是整份文件最關鍵的一格。**
LINE 的 `userId` 是 **per-Provider 不是 per-channel**：

```
同一個 Provider  → 同一個人在所有 channel 拿到同一個 userId
不同 Provider    → 同一個人會是兩個不同的值
```

而 `members.line_user_id` **只有一欄** ⇒ 選錯（或順手建了新的 Provider）的話，
同一個客人在會員 App 與官方帳號會是兩個 id，
**而且不會報錯，只是接不起來** —— 症狀是「推播永遠找不到人」。

⚠ 那一步**沒有「之後再改」這個選項**：Provider 綁定後不能搬。

### ⚠ 建立官方帳號時要填的（客人看得到的是這個）

| 欄位 | 建議 | 為什麼 |
|---|---|---|
| **帳號名稱** | `MIGI 咪吉麻將` | 🔴 **客人在 LINE 聊天列表看到的就是這個**，跟 channel 名稱不同 |
| 類別 | 娛樂／休閒 之類 | 影響 LINE 內部的分類，不影響功能 |
| 地區 | 台灣 | |

🔴 **帳號名稱不可含「LINE」或近似字串**（跟 channel 同一條規則）。

### 2️⃣ 記下官方帳號 ID

建立後在 channel 的基本設定裡會看到 `@` 開頭的 ID（例如 `@123abcde`）。

**加好友 URL 就是**：
```
https://line.me/R/ti/p/@官方帳號ID
```

📌 這個 URL **永遠不會失效**（官方帳號 ID 穩定），
不像 LIFF app 刪掉就讓所有印出去的 QR 全部作廢。
⇒ **門市 QR 要印的就是它。**

### 3️⃣ 決定回應模式

```
LINE Official Account Manager → 設定 → 回應設定
```

⚠ **有人要顧聊天室嗎？** 沒有的話：
- 聊天 → **關閉**
- 自動回應訊息 → 開（設一則「本帳號不提供文字客服，請洽門市」）
- Webhook → 現在不用開

🔴 硬規則 5.5：**需要有人每天維護的東西，先確認那個人存在。**
開著聊天而沒有人回，比關掉更傷。

### 4️⃣ 🔴 回到 LIFF 設定改 `Add friend option`

```
developers.line.biz → 咪吉有限公司 → MIGI 咪吉麻將
  → LIFF → 「MIGI 咪吉麻將」（會員端那個）
  → Add friend option：Off → **On (Normal)**
```

🔴 **這一格最容易漏，而漏了的後果最大。**
它讓「LINE 授權」與「加好友」**一步完成** ——
沒開的話，客人註冊完卻沒加好友，
⇒ **你有他的 id，但通知送不到他。**

⚠ **不要選 `On (Aggressive)`** —— 它會在同意畫面**之後**再開一個獨立畫面
強迫加好友，客人的第一印象變成被推銷。

✅ 已查證：**已經是好友的人不會多一步**（官方文件明寫，
只顯示「已加為好友」的狀態）⇒ 這一格開著對走「先加好友」
那條路的客人**完全沒有摩擦**。

⚠ POS 那個 LIFF（`MIGI POS`）**保持 Off** —— 店員不需要加官方帳號好友。

### 5️⃣ 設定加入好友的歡迎訊息

```
LINE Official Account Manager → 加入好友的歡迎訊息
```

🔴 **第一句就要給 LIFF 連結**，不要只寫「感謝加入」。

```
https://liff.line.me/2011312117-Zuul0Ndo
```

⚠ 那是**會員端**的 LIFF ID（不是 POS 那個）。

### 6️⃣ 圖文選單（Rich Menu）

「會員」按鈕連到 **LIFF URL**（不是 `app.migi.tw`）：
```
https://liff.line.me/2011312117-Zuul0Ndo
```

🎯 走 LIFF URL 客人才會**自動登入**（在 LINE 內免授權畫面）。
連 `app.migi.tw` 的話會變成外部瀏覽器，每次都要重新授權。

---

## 🔴 三個入口指向不同的網址（不要搞混）

```
門市 QR       → 加好友 URL（https://line.me/R/ti/p/@官方帳號ID）
                 → 歡迎訊息（含 LIFF 連結）→ 註冊
圖文選單      → LIFF URL（常駐入口，客人之後都從這裡回來）
朋友分享／廣告 → LIFF URL → 靠 Add friend option 補上加好友
```

🔴 **門市 QR 指的是「加好友」不是 LIFF。**
理由：**先加好友才保證推播送得到**，而配桌湊滿的通知是 MIGI 的核心。
QR 直接指 LIFF 的話，客人註冊完卻沒加好友 —— 你有他的 id 但通知不到他。
⚠ 代價是多一步 → 用**歡迎訊息第一句給 LIFF 連結**把它壓成零摩擦。

---

## 為什麼「是會員」不等於「能通知他」

| | |
|---|---|
| 客人用 LINE 登入 | ✅ 拿到 `line_user_id`，他是會員 |
| 你要推播給他 | 🔴 **他必須先加官方帳號好友**，否則送不到 |

對 MIGI 這件事很具體：配桌最關鍵的一則訊息是
**「你的牌局湊滿了 · 今晚 21:00 · 3 號桌」**。

App 內通知（`app_notifications`）要他打開 App 才看得到 ——
**而人不會沒事打開 App。**
⇒ 「湊滿了但當事人不知道」會直接讓配桌的價值垮掉。

---

## ⏳ 做完之後才輪到的

- **推播的程式碼**（Messaging API push）—— 那是另一批，要等
  `app_notifications` 決定哪些事件要推
- **官方帳號的認證**（藍勾）—— 要送審，而且可能要對得上公司登記名稱
