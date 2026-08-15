# Icon 使用盤點與設計原則

> 這是什麼：MIGI 會員 App 目前所有介面 icon 的完整清單、位置，以及「少 icon」的設計立場。
> 什麼時候讀它：考慮新增 icon、或決定某處該用文字還是圖示時。

---

## 一、設計立場：刻意少用 icon

MIGI 走**溫潤、手感、插畫感**路線（奶茶＋蜜桃粉、圓潤卡片、養成小熊、擬物麻將牌）。這種調性適合「少 icon、多留白、用文字與插畫說話」。塞入大量線條 icon 會讓產品變得像工具型 App，破壞親和感。

中文 App 另有先天優勢：中文字表意能力強，「錢包」兩字比錢包 icon 更好懂，因此比英文 App 更不需要 icon。

**分工原則**：
- 線條 icon → 只留在真正需要辨識的功能點（搜尋、編輯、時間選擇）
- 內容表現 → 交給有溫度的插畫（小熊、麻將牌、點心圖）

**代價與對策**：少了 icon 這個視覺錨點，可讀性與節奏全靠文字撐起。因此**排版層次必須更用心**——字級、字重、顏色分層要清楚。

---

## 二、介面 icon 完整清單（共 5 種）

全部定義於 `src/lib/ui.jsx`，皆為線條風 SVG。

### 1. SearchIcon（搜尋）— 3 處
- `src/lib/components.jsx:233`
- `src/pages/buddies.jsx:144` — 搜尋團名輸入框
- `src/pages/buddies.jsx:265` — 搜尋牌咖暱稱輸入框

### 2. CalIcon（日曆）— 1 處
- `src/lib/ui.jsx:17` — `DateField` 日期選擇欄

### 3. ClockIcon（時鐘）— 1 處
- `src/lib/ui.jsx:32` — `TimeField` 時間選擇欄（與日曆成對）

### 4. PencilIcon（鉛筆／編輯）— 3 處
- `src/pages/buddies.jsx:95` — 修改團名
- `src/pages/rewards.jsx` — 小熊名字旁改名
- `src/pages/profile.jsx:228` — 個人暱稱旁改名

### 5. ThumbIcon（讚）— 3 處
- `src/lib/components.jsx:26` — 牌咖卡右上獲讚數
- `src/pages/buddies.jsx:394` — 牌咖列表按讚鈕（含彈跳動畫）
- `src/pages/profile.jsx:216` — 個人頁獲讚數

---

## 三、歸納

介面 icon 集中於三種用途，全為功能性、無裝飾性使用：

| 用途 | icon |
|---|---|
| 找東西 | SearchIcon |
| 填表單 | CalIcon、ClockIcon |
| 執行動作 | PencilIcon、ThumbIcon |

**底部 tab 列為純文字**（錢包／配桌／成績／牌咖／獎勵），刻意不配圖示。

---

## 四、不算介面 icon 的內容圖像

以下屬**品牌插畫**性質，與 UI icon 是兩回事，不納入 icon 盤點：

- 小熊餅乾圖（`snack-cookie.webp`）、七階段位熊、教練熊
- 麻將牌面（擬物 tile-face 系列）
- 點心 emoji 與圖（珍珠奶茶、布丁、提拉米蘇等）
- 扭蛋獎項 emoji

---

## 五、一般 App 的 icon 慣例（判斷依據）

icon 通常只在這些「功能性」場景出現：底部導覽列、頂部工具列（搜尋／通知／設定／返回）、列表項左側分類識別、按鈕內強化語意、輸入框清除鍵、空狀態插圖。

核心原則：**icon 是為了加速辨識或節省空間，不是裝飾。**
