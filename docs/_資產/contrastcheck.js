/* ============================================================
   執行期對比掃描器 —— 文字（WCAG 1.4.3）＋ 非文字（1.4.11）
   ============================================================
   2026-09-10 建立。

   🔴 **這支在此之前不存在。** `docs/04-設計系統/顏色對比規範.md` 第 166 行
     寫著「完整實作見 `docs/_資產/`」，而那個資料夾裡 26 個檔案沒有一個是它 ——
     2026-09-09 那次掃描是用臨時貼進 console 的片段做的，**沒有存下來**。
     ⇒ 於是「量出來的那些數字要怎麼重現」沒有答案，而**不能重現的量測
       等於一次性的意見**。今天第二次踩到同一件事（第一次是 `jsxcomment.py`
       —— 硬規則 3.6 寫著它存在，而它從來沒存在過）。
     📌 **寫「實作在某處」之前，先確認那個檔案真的在那裡。**

   ── 怎麼用 ────────────────────────────────────────────────
   把整個檔案貼進瀏覽器 console，或用工具送進去執行。回傳一個摘要物件，
   並把完整清單放在 `window.__contrast`。

   🔴 **掃描前先裝寫入攔截器**（硬規則 11.6）—— 本機 dev 連的是正式資料庫。
   🔴 **順序是「先載入頁面，再裝攔截器」** —— reload 會把 window.fetch 還原。

   ── 三件非做不可的事（少一件結果就是錯的）──────────────────
   ① 半透明背景要**逐層混合** —— rgba 直接拿去算會得到錯的比值
   ② 門檻**依字級而定** —— 大字（≥24px，或 ≥18.7px 且 ≥700 粗）是 3.0，其餘 4.5
   ③ 只看**自己有文字節點**的元素 —— 否則父層會被重複計算

   ── 非文字那一半（1.4.11）的範圍是刻意收窄的 ─────────────────
   規範原文是「**辨識 UI 元件與狀態所必需**的視覺資訊」⇒
   **不是每一條有顏色的線都要 3:1**。分隔線是裝飾，不在範圍內。
   ⇒ 這裡只看**互動元件**：button / a / input / select / textarea /
     [role=button] / [tabindex] / cursor:pointer。
   ⚠ 把分隔線也掃進來會產生大量雜訊，而**一個充滿雜訊的報告等於沒有報告**
     （同硬規則 3.5：一個永遠紅的檢查會讓人學會忽略紅色）。

   ⚠ 邊框取**內外兩側較高的那一個**。一條線只要與**任一側**有足夠反差
     就看得見 —— 那正是聚焦框用兩層環的同一個道理。
   ============================================================ */
(() => {
  const parse = (c) => {
    const m = String(c).match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(/[,\s/]+/).filter(Boolean).map(Number);
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  };

  /* 半透明疊在底色上的真實顏色。① 那一條就是這裡。 */
  const over = (fg, bg) => ({
    r: fg.r * fg.a + bg.r * (1 - fg.a),
    g: fg.g * fg.a + bg.g * (1 - fg.a),
    b: fg.b * fg.a + bg.b * (1 - fg.a),
    a: 1,
  });

  const lum = (c) => {
    const f = (v) => {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };

  const ratio = (a, b) => {
    const x = lum(a), y = lum(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  };

  /* 這個元素**實際上**站在什麼顏色上：往上找，遇到半透明就繼續往上混合。
     🔴 光看自己的 background 是錯的 —— 大多數元素是 transparent，
       真正的底色來自祖先。這是靜態掃描做不到的部分。 */
  const bgOf = (el) => {
    let cur = el, acc = null;
    while (cur && cur !== document.documentElement.parentNode) {
      const c = parse(getComputedStyle(cur).backgroundColor);
      if (c && c.a > 0) {
        acc = acc ? over(acc, c) : c;
        if (acc.a >= 1 || c.a >= 1) return acc.a >= 1 ? acc : over(acc, { r: 255, g: 255, b: 255, a: 1 });
      }
      cur = cur.parentElement;
    }
    return acc ? over(acc, { r: 255, g: 255, b: 255, a: 1 }) : { r: 255, g: 255, b: 255, a: 1 };
  };

  const visible = (el) => {
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || Number(s.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };

  /* ③ 只算「自己直接掛著文字」的元素 */
  const ownText = (el) => {
    for (const n of el.childNodes) {
      if (n.nodeType === 3 && n.textContent.trim()) return n.textContent.trim();
    }
    return '';
  };

  const label = (el) => {
    const t = (ownText(el) || el.getAttribute('aria-label') || '').slice(0, 24);
    return el.tagName.toLowerCase() + (t ? ' 「' + t + '」' : '');
  };

  const INTERACTIVE =
    'button,a,input,select,textarea,summary,[role="button"],[tabindex]';

  const textFails = [];
  const uiFails = [];
  let textN = 0, uiN = 0;

  for (const el of document.querySelectorAll('*')) {
    if (!visible(el)) continue;
    const s = getComputedStyle(el);
    const bg = bgOf(el);

    /* ── 文字（1.4.3）────────────────────────────────── */
    const t = ownText(el);
    if (t) {
      const fg0 = parse(s.color);
      if (fg0) {
        const fg = fg0.a < 1 ? over(fg0, bg) : fg0;
        const px = parseFloat(s.fontSize) || 16;
        const w = parseInt(s.fontWeight, 10) || 400;
        // ② 大字的定義：≥24px，或 ≥18.7px 且 ≥700 粗
        const big = px >= 24 || (px >= 18.66 && w >= 700);
        const need = big ? 3.0 : 4.5;
        const r = ratio(fg, bg);
        textN++;
        if (r < need) {
          textFails.push({
            誰: label(el), 對比: +r.toFixed(2), 門檻: need,
            字級: px + 'px/' + w, 字色: s.color,
          });
        }
      }
    }

    /* ── 非文字：互動元件的可辨識性（1.4.11）───────────── */
    if (el.matches(INTERACTIVE) || s.cursor === 'pointer') {
      uiN++;
      const bw = ['Top', 'Right', 'Bottom', 'Left']
        .map((d) => parseFloat(s['border' + d + 'Width']) || 0);
      const hasBorder = Math.max(...bw) > 0 && s.borderTopStyle !== 'none';
      const own = parse(s.backgroundColor);
      const inside = own && own.a > 0 ? over(own, bg) : bg;
      const outside = bgOf(el.parentElement || document.body);

      if (hasBorder) {
        const bc0 = parse(s.borderTopColor);
        if (bc0 && bc0.a > 0) {
          const bcIn = bc0.a < 1 ? over(bc0, inside) : bc0;
          const bcOut = bc0.a < 1 ? over(bc0, outside) : bc0;
          // ⚠ 內外兩側取較高者：一條線與任一側有反差就看得見
          const r = Math.max(ratio(bcIn, inside), ratio(bcOut, outside));
          if (r < 3.0) {
            uiFails.push({
              誰: label(el), 靠什麼辨識: '邊框',
              對比: +r.toFixed(2), 邊框色: s.borderTopColor,
            });
          }
        }
      } else if (own && own.a > 0) {
        // 沒有邊框 ⇒ 靠自己的填色與周圍分開
        const r = ratio(inside, outside);
        if (r < 3.0) {
          uiFails.push({
            誰: label(el), 靠什麼辨識: '填色',
            對比: +r.toFixed(2), 填色: s.backgroundColor,
          });
        }
      }
      // 沒邊框也沒填色的（純文字連結／文字按鈕）不在這一項 ——
      // 它們靠文字本身，已經由上面的 1.4.3 那一段管了。
    }
  }

  window.__contrast = { text: textFails, ui: uiFails };
  return {
    網址: location.pathname,
    文字: '檢查 ' + textN + ' 個，未達門檻 ' + textFails.length + ' 個',
    互動元件: '檢查 ' + uiN + ' 個，未達 3.0 的 ' + uiFails.length + ' 個',
    文字前五: textFails.slice(0, 5),
    元件前五: uiFails.slice(0, 5),
    完整清單: 'window.__contrast',
  };
})()
