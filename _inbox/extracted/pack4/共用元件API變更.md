# 共用元件 API 變更（`src/lib/ui.jsx`）

> 這是什麼：本輪對共用 UI 元件的介面變更與新增能力。
> 什麼時候讀它：要呼叫 toast、或要在其他頁面使用按讚動畫時。

---

## 一、`showToast` 新增第三參數 `icon`

### 簽名

```js
showToast(msg, top, icon)
```

| 參數 | 型別 | 說明 |
|---|---|---|
| `msg` | string | 訊息文字 |
| `top` | boolean | `true` 從頂部出現，否則從底部 |
| `icon` | string | **（新增）** 圖片網址。傳入時左側圓圈改顯示該圖，否則顯示預設綠勾 |

### 使用範例

```jsx
showToast('已拒絕（對方不會收到通知）')                          // 預設綠勾
showToast('已送出', true)                                        // 頂部出現
showToast('領到小熊餅乾 ×2', false, SNACK_IMGS.cookie)          // 自訂圖示
```

### 相容性

採「往後新增參數」方式擴充，**現有所有呼叫完全不受影響**。未傳 `icon` 即維持原本的綠勾圈，其他頁面 toast 全部照舊，零波及。

### 實作要點

Toast 元件的左側圈依 `t.icon` 有無切換：

```jsx
{t && t.icon
  ? <span style={{ width:26, height:26, borderRadius:'50%', overflow:'hidden', display:'inline-flex', flex:'0 0 26px' }}>
      <img src={t.icon} alt="" width="26" height="26" style={{ display:'block' }} />
    </span>
  : <span style={{ /* 預設綠勾圈 */ }}>...</span>}
```

### 已套用處

- 每日報到領獎 → `showToast('領到小熊餅乾 ×2', false, SNACK_IMGS.cookie)`
- 任務領獎 → `showToast('領到小熊餅乾 ×N', false, SNACK_IMGS.cookie)`

（原本寫法是把 🍪 emoji 塞在文字裡，已改為真圖 + 純文字。）

---

## 二、`ThumbIcon` 改用 style 承載 fill / stroke

### 變更原因

原本 fill / stroke 寫在 SVG **屬性**上，SVG 屬性不支援 CSS 變數，導致 token 化後圖示隱形。改用 `style` 物件承載即可正常吃 `var()`。

```jsx
function ThumbIcon({ size = 16, color = 'var(--ink)', filled = false, fill = 'var(--brand)' }) {
  return <svg width={size} height={size} viewBox="0 0 24 24"
    strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"
    style={{ flex: '0 0 auto', fill: filled ? fill : 'none', stroke: filled ? 'var(--ink)' : color }}>
    ...
  </svg>
}
```

呼叫端的 `color` prop 也應傳 token（例：`color="var(--ink)"`），不再傳 hex。

---

## 三、按讚彈跳動畫（已採用版本）

牌咖列表的按讚鈕採「**無圓框 + 彈跳**」版本：

- **未按**：灰線條拇指（`var(--gray-2)`）
- **已按**：粉填墨線（`fill="var(--brand)"`）+ `scale(1.15)`
- **無圓框**：拇指放大至 22px（框內版本為 16px），點擊熱區維持 34px
- **彈跳**：`.migi-pop-bare` class，沿用成桌卡 `popIn` 的過衝曲線 `cubic-bezier(.34,1.56,.64,1)`，0.45s

```css
@keyframes migiPopBare{
  0%{transform:scale(.6)}
  45%{transform:scale(1.5) rotate(-10deg)}
  70%{transform:scale(.9) rotate(4deg)}
  100%{transform:scale(1.15) rotate(0)}
}
```

**設計理由**：拆掉圓框後畫面更輕、列表更乾淨；因少了粉底作為狀態訊號，改以拇指本身填粉來表達「已按」，同時解決了原版「粉底＋白拇指在粉色系 App 中對比偏低」的辨識度問題。彈跳沿用既有動態語言，非新發明。

`ThumbIcon` 的圓框版本仍保留用於**被動顯示獲讚數**的場景（牌咖卡右上、個人頁）。
