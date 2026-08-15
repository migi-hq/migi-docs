# MIGI 設計 Token 規範

> 這是什麼：MIGI 會員 App（migi-web）全站設計變數的權威清單，定義於 `src/styles.css` 的 `:root`。
> 什麼時候讀它：寫任何新畫面、新元件、調整既有樣式之前。**新程式碼一律用變數，不寫死色碼與數值。**

---

## 一、色彩

### 主品牌色（雙主色）

MIGI 的品牌識別由**蜜桃粉與奶茶色並列**構成。蜜桃粉偏甜、奶茶色偏穩，搭配使用可避免畫面過於粉氣，維持溫潤而有質感的調性。

| Token | 色值 | 用途 |
|---|---|---|
| `--brand` | `#FAD6DC` | 蜜桃粉：主品牌色、按鈕、卡片 |
| `--milktea` | `#EFE3DA` | 奶茶色：主品牌色（與蜜桃粉並列）、溫潤中性、餐飲/活動/稀有 |
| `--brand-light` | `#FFE7EE` | 淺粉：Hero 卡、提示欄底 |
| `--ink` | `#2E2B2C` | 深墨：主文字、黑底按鈕 |
| `--accent` | `#C2607A` | 桃紅：強調文字、連結、讚 icon |
| `--gold` | `#E8B89B` | 金棕：稱號邊框、點綴 |

### 灰階（數字越大越淺）

| Token | 色值 | 用途 |
|---|---|---|
| `--gray-1` | `#7A7572` | 次要文字 |
| `--gray-2` | `#9A9491` | 提示文字 |
| `--gray-3` | `#ECEAE9` | 邊框 |
| `--gray-4` | `#F2F0EE` | 淺灰底：次要按鈕、分隔線 |

### 功能 / 表單色

| Token | 色值 | 用途 |
|---|---|---|
| `--white` | `#FFFFFF` | 外殼／卡片底 |
| `--field-bg` | `#F8F7F6` | 輸入框、次要卡片底 |
| `--field-bd` | `#ECE7E4` | 輸入框邊框 |
| `--danger` | `#B23B3B` | 錯誤／警示紅 |

### 牌面質感色（麻將擬物專用）

| Token | 色值 | 用途 |
|---|---|---|
| `--tile-face` | `#FFFDF9` | 牌面底（象牙白） |
| `--tile-face-bd` | `#E5DCCF` | 牌面邊框 |
| `--tile-face-lip` | `#E0D6C6` | 牌面下緣立體感 |

---

## 二、圓角（五階）

依全站實際主力用值收斂而成，非憑空發明。

| Token | 值 | 用途 |
|---|---|---|
| `--r-pill` | `999px` | 膠囊：按鈕、chip、pill、tab |
| `--r-lg` | `16px` | 大卡：Hero 卡、抽屜 |
| `--r-card` | `14px` | 標準卡片 |
| `--r-field` | `12px` | 輸入框、小卡、黑底按鈕 |
| `--r-sm` | `8px` | 小元件：牌面、迷你按鈕 |

局部微調用的零星圓角值（3/6/10/11/13/15/18/20/22/24）刻意保留為數字，不強制收斂，避免破壞個別元件的視覺意圖。

---

## 三、陰影（三階）

| Token | 值 | 用途 |
|---|---|---|
| `--shadow-sm` | `0 2px 8px rgba(46,43,44,.08)` | 貼地：列表卡 |
| `--shadow-md` | `0 4px 14px rgba(0,0,0,.08)` | 浮起：主卡片 |
| `--shadow-lg` | `0 6px 24px rgba(0,0,0,.25)` | 懸浮：抽屜、彈窗 |

---

## 四、間距（4px 基準，六階）

`--sp-1:4px` `--sp-2:8px` `--sp-3:12px` `--sp-4:16px` `--sp-5:20px` `--sp-6:24px`

**僅供新程式碼使用。** 既有上千處 inline 數字刻意不回填——純風險、零收益。

---

## 五、字級與字型

| Token | 值 |
|---|---|
| `--xs` | `13px` |
| `--s` | `14px` |
| `--m` | `15px` |
| `--l` | `16px` |
| `--xl` | `19px` |
| `--h` | `38px` |
| `--font-sans` | `-apple-system, "PingFang TC", "Microsoft JhengHei", sans-serif` |

---

## 六、使用方式

```jsx
// JSX inline style
<div style={{ color: 'var(--ink)', background: 'var(--milktea)', borderRadius: 'var(--r-card)' }} />
```

```css
/* CSS */
.card { color: var(--ink); border: .5px solid var(--gray-3); border-radius: var(--r-card); }
```

改任何品牌色、圓角、陰影，只需動 `:root` 一行即可全站生效。
