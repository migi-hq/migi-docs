# 獎勵頁 UI 規格（最終版）

> 這是什麼：`src/pages/rewards.jsx`（底部 tab「獎勵」）本輪 UI 改版的最終規格。
> 什麼時候讀它：要再動獎勵頁、點心櫃、扭蛋、小熊養成區的視覺時。

---

## 一、點心櫃（SnackSheet）— 改為列表版

原本是雙欄卡片格，改為單欄列表，沿用全站 `.irow` 列表語言。

**改版理由**：列表把每列資訊橫向攤開、掃視更快；點心種類增加時往下延伸不會擠。

### 版面結構（每列）

```
[44px 圓形點心圖] [品項名 + ×N] [動作鈕]
                  [成長 +N / 店裡消費可獲得]
```

| 元素 | 規格 |
|---|---|
| 點心圖 | 44×44、`borderRadius:'50%'`；未擁有 `filter:grayscale(1)` + `opacity:.6` |
| 品項名 | `var(--m)`、`fontWeight:700`、`var(--ink)` |
| 數量 `×N` | **與品項名同行並排**、`var(--m)`、`fontWeight:800`、`var(--accent)` 桃紅、**無底色** |
| 副標行 | `11px`、`var(--gray-2)`、`fontWeight:700` |
| 已擁有動作 | 「餵小熊」墨底白字膠囊鈕 |
| 未擁有動作 | 「未獲得」`--gray-4` 底、`--gray-2` 字 |
| 分隔線 | `.5px solid var(--gray-4)`，最後一列不加 |
| 整列 | 未擁有時 `opacity:.85` |

### 文案

- 標題：**小熊的點心櫃**
- 副標：**收集店裡的點心，餵給小熊長大（不同點心成長不同）**
- 動作鈕：**餵小熊**

⚠️ **點心櫃內所有小熊名字連動（`getBearName()`）已全數移除，固定寫「小熊」兩字。**

---

## 二、熊卡右上角餅乾計數

**無膠囊底**，僅餅乾圖 + 桃紅數量。

| 項目 | 規格 |
|---|---|
| 定位 | `position:absolute; top:14; right:16` |
| 餅乾圖 | 22×22 圓形（原 16px 放大） |
| 數量 | `×N` 格式、`fontSize:14`、`fontWeight:800`、`var(--accent)` |
| 底色 | 無（原 `rgba(255,255,255,0.7)` 膠囊已移除） |
| 互動 | 點擊開啟點心櫃 |

---

## 三、餵食按鈕

- 文案：**「餵 1 片小熊餅乾」**
- **按鈕內餅乾 icon 已移除**（純文字）
- 樣式：墨底白字；`snacks.cookie <= 0` 時底色轉 `--field-bd` 並 disabled

---

## 四、扭蛋「省 50」pill

十連主打大按鈕上的省錢標籤，改為**桃紅底白字**以提升對比：

```jsx
background: 'var(--accent)', color: 'var(--white)',
fontSize: 11, fontWeight: 800, borderRadius: 'var(--r-pill)'
```

（原為粉底桃紅字 `--brand` / `--accent`）

---

## 五、小熊餅乾圖統一

`src/assets/snack-cookie.webp` 已換為新版插畫（奶油＋焦糖色，與 `--gold` 同家族）。

**圖片處理要點**：原始圖奶油圓外有一圈白邊，直接圓形裁切會露白圈。處理方式為貼著奶油圓邊界裁切後縮至 **256×256**（與其他 snack 圖同規格），webp 品質 88，約 2.7KB。

### 生效範圍（共 7 處）

覆蓋圖檔即自動生效（3 處）：
- 點心櫃庫存列
- 熊卡右上餅乾計數
- 餵食按鈕（本次已移除 icon）

需程式改動才生效（4 處）：
- 七日簽到的餅乾節點（原為 🍪 emoji，改為圓裁圖 + 數量）
- 扭蛋開獎大圖（112px 圈內置入 72px 圖）
- 十連結果列表（54px 圈內置入 36px 圖）
- 獎池四階資料掛上 `img` 欄位

### 獎項渲染邏輯

獎池項目保留 `e`（emoji）欄位作為 fallback，新增 `img` 欄位。渲染時**有 `img` 用圖、無則回退 emoji**，因此其他獎項（點心、折抵券、T恤等）完全不受影響。

```jsx
{prize.img
  ? <span style={{ width:72, height:72, borderRadius:'50%', overflow:'hidden', display:'inline-flex' }}>
      <img src={prize.img} alt="" width="100%" height="100%" style={{ display:'block' }} />
    </span>
  : prize.e}
```

**圖檔快取**：`images.js` 採 registry 設計，換檔後建置 hash 自動變動，不會咬到舊快取。
