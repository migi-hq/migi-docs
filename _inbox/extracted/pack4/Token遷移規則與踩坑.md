# Token 遷移規則與踩坑紀錄

> 這是什麼：把硬編色碼／數值換成設計 token 的執行規則，以及過程中踩到的坑。
> 什麼時候讀它：要對新檔案或新頁面做 token 化之前；或替換後畫面出現異常時排查。

---

## 一、已完成的遷移範圍

全站約 **1,290 處**硬編色碼、**190 處**圓角、**10 處**陰影已接上 token。涵蓋 `styles.css` 與所有 JSX 頁面。`:root` 以外已無任何品牌色的字面值。

---

## 二、替換規則

### 一律替換（品牌色盤內）

```
#2E2B2C → var(--ink)          #FAD6DC → var(--brand)
#FFFFFF/#FFF → var(--white)   #EFE3DA → var(--milktea)
#C2607A → var(--accent)       #FFE7EE → var(--brand-light)
#9A9491 → var(--gray-2)       #E8B89B → var(--gold)
#7A7572 → var(--gray-1)       #F8F7F6 → var(--field-bg)
#F2F0EE → var(--gray-4)       #ECE7E4 → var(--field-bd)
#ECEAE9 → var(--gray-3)       #B23B3B / #C0392B → var(--danger)
#FFFDF9 → var(--tile-face)
```

圓角：`999`/`99` → `--r-pill`，`16` → `--r-lg`，`14` → `--r-card`，`12` → `--r-field`，`8` → `--r-sm`

### 已淘汰的字面值（找最接近標準色取代）

| 原值 | 原用途 | 改為 |
|---|---|---|
| `#D8D4D2` | 牌譜小牌邊框 | `--field-bd` |
| `#E0DEDC` | 牌譜按鈕邊框 | `--field-bd` |
| `#F2DDE3` | 配桌佇列分隔線 | `--brand`（粉色家族，不可壓成灰） |

### 刻意保留為字面值（不要替換）

1. **SVG 屬性內的 hex**（`fill="#..."`、`stroke="#..."`）——SVG 屬性不支援 `var()`，替換會讓圖形消失。全站約 33 處。
2. **有語意的局部色**——麻將花色綠藍紅、LINE 綠 `#06C755`、獎牌金屬色、spinner 軌道粉、空位虛線粉 `#E2A9B8`、黑名單粉底 `#FCF4F3` 系列等，約 90 處。這些不屬於品牌色盤，硬壓會破壞語意與設計意圖。

---

## 三、踩過的坑

### 坑 1：`var()` 注入 SVG 屬性 → 圖示隱形

批次替換時，`ThumbIcon` 的 `fill={...}` / `stroke={...}` **屬性**被換成 `var(--ink)`，導致讚圖示完全不顯示。

**解法**：把 fill/stroke 從 SVG 屬性移到 `style` 物件承載，`var()` 即可生效，同時達成完整 token 化。

```jsx
// 錯誤：SVG 屬性不吃 var()
<svg fill={filled ? fill : 'none'} stroke={color}>

// 正確：改用 style
<svg style={{ fill: filled ? fill : 'none', stroke: color }}>
```

**通則**：批次替換後務必檢查 `grep -E '(fill|stroke)=\{[^}]*var\(--'`，結果必須為 0。

### 坑 2：`styles.css` 整段重複貼上

檔案尾端曾有一整段規則重複複製（`.back2`／`bearNom`／搓麻將 tile 動畫），中間夾一行殘缺碎片 `00%{opacity:1;transform:scale(1)}}`。瀏覽器會忽略壞行、重複規則後者覆蓋前者，**畫面不會壞**，但會誤導後續編輯。已清除（160 → 125 行）。

**排查指令**：`grep -c '@keyframes spin' src/styles.css` 應為 1；括號 `{` `}` 數量必須相等。

---

## 四、驗證流程（每次替換後必跑）

```bash
# 1. :root 外不得有品牌色字面值
awk '/^:root\{/{r=1} r&&/^\}/{r=0;next} !r' src/styles.css | grep -oE '#[0-9A-Fa-f]{6}'

# 2. var() 不得進入 SVG 屬性（結果須為 0）
grep -rcE '(fill|stroke)=\{[^}]*var\(--|(fill|stroke)="var' src

# 3. 建置驗證
npx vite build
```

單檔語法快速驗證：
```bash
npx esbuild target.jsx --loader:.jsx=jsx --jsx=automatic --outfile=/tmp/out.js
```

---

## 五、已知的極輕微視覺變化（已接受）

- **配桌佇列分隔線**：`#F2DDE3` → `--brand`，粉色略飽和一點。若嫌搶眼可改 `--brand-light`。
- **陰影收斂**：原本 `.06`/`.1`/`.18` 等微調透明度統一收進三階，差異需截圖疊比才看得出。
- **黑名單警示紅**：`#C0392B` → `--danger`（`#B23B3B`），紅色深淺極輕微差異。
